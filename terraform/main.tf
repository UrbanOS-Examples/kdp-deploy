provider "aws" {
  version = "1.39"
  region  = "${var.os_region}"

  assume_role {
    role_arn = "${var.os_role_arn}"
  }
}

terraform {
  backend "s3" {
    key     = "kdp"
    encrypt = true
  }
}

data "terraform_remote_state" "env_remote_state" {
  backend   = "s3"
  workspace = "${terraform.workspace}"

  config {
    bucket   = "${var.state_bucket}"
    key      = "operating-system"
    region   = "${var.alm_region}"
    role_arn = "${var.alm_role_arn}"
  }
}

resource "local_file" "kubeconfig" {
  filename = "${path.module}/outputs/kubeconfig"
  content  = "${data.terraform_remote_state.env_remote_state.eks_cluster_kubeconfig}"
}

module "metastore_database" {
  source = "git@github.com:SmartColumbusOS/scos-tf-rds?ref=1.0.0"

  prefix                   = "${var.environment}-metastore"
  name                     = "metastore"
  type                     = "postgres"
  attached_vpc_id          = "${data.terraform_remote_state.env_remote_state.vpc_id}"
  attached_subnet_ids      = ["${data.terraform_remote_state.env_remote_state.private_subnets}"]
  attached_security_groups = ["${data.terraform_remote_state.env_remote_state.chatter_sg_id}"]
  instance_class           = "${var.metastore_instance_class}"
}

data "aws_secretsmanager_secret_version" "metastore_database_password" {
  secret_id = "${module.metastore_database.password_secret_id}"
}

resource "aws_s3_bucket" "presto_hive_storage" {
  bucket = "presto-hive-storage-${terraform.workspace}"
  acl    = "private"

  versioning {
    enabled = false
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_policy" "presto_hive_storage" {
  bucket = "${aws_s3_bucket.presto_hive_storage.id}"

  policy = <<POLICY
{
   "Version": "2012-10-17",
   "Statement": [
        {
         "Effect": "Allow",
         "Principal": {
           "AWS":
            [
              "${data.terraform_remote_state.env_remote_state.eks_worker_role_arn}"
            ]
         },
         "Action": [
            "s3:ListBucket"
         ],
         "Resource": "${aws_s3_bucket.presto_hive_storage.arn}"
      },
      {
         "Effect": "Allow",
         "Principal": {
           "AWS":
            [
              "${data.terraform_remote_state.env_remote_state.eks_worker_role_arn}"
            ]
         },
         "Action": [
            "s3:GetObject",
            "s3:PutObject",
            "s3:DeleteObject",
            "s3:DeleteObjectVersion"
         ],
         "Resource": "${aws_s3_bucket.presto_hive_storage.arn}/*"
      }
   ]
}
POLICY
}

resource "local_file" "helm_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}.yaml"

  content = <<EOF
global:
  environment: ${terraform.workspace}
  ingress:
    annotations:
      alb.ingress.kubernetes.io/scheme: "${var.is_internal ? "internal" : "internet-facing"}"
      alb.ingress.kubernetes.io/subnets: "${join(",", data.terraform_remote_state.env_remote_state.public_subnets)}"
      alb.ingress.kubernetes.io/security-groups: "${data.terraform_remote_state.env_remote_state.allow_all_security_group}"
      alb.ingress.kubernetes.io/certificate-arn: "${data.terraform_remote_state.env_remote_state.tls_certificate_arn}"
      alb.ingress.kubernetes.io/tags: scos.delete.on.teardown=true
      alb.ingress.kubernetes.io/actions.redirect: '{"Type": "redirect", "RedirectConfig":{"Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      kubernetes.io/ingress.class: alb
  objectStore:
    bucketName: ${aws_s3_bucket.presto_hive_storage.bucket}
    accessKey: null
    accessSecret: null
metastore:
  deploy: ${var.image_tag != "" ? "{container: {tag: ${var.image_tag}}}" : "{}"}
  allowDropTable: ${var.allow_drop_table ? "true": "false"}
presto:
  workers: 2
  deploy: ${var.image_tag != "" ? "{container: {tag: ${var.image_tag}}}" : "{}"}
  deployPrometheusExporter: true
  useJmxExporter: true
  ingress:
    enable: true
    hosts:
    - "presto.${data.terraform_remote_state.env_remote_state.internal_dns_zone_name}/*"
    annotations:
      alb.ingress.kubernetes.io/healthcheck-path: /v1/cluster
    serviceName: redirect
    servicePort: use-annotation
postgres:
  enable: false
  service:
    externalAddress: ${module.metastore_database.address}
  db:
    name: ${module.metastore_database.name}
    user: ${module.metastore_database.username}
    password: ${data.aws_secretsmanager_secret_version.metastore_database_password.secret_string}
hive:
  enable: false
minio:
  enable: false
EOF
}

resource "null_resource" "helm_deploy" {
  provisioner "local-exec" {
    command = <<EOF
set -ex

export KUBECONFIG=${local_file.kubeconfig.filename}

export AWS_DEFAULT_REGION=us-east-2

helm init --client-only
helm repo add scdp https://smartcitiesdata.github.io/charts
helm repo update
helm upgrade --install kdp scdp/kubernetes-data-platform \
    --version ${var.chart_version} \
    --namespace kdp \
    -f ${local_file.helm_vars.filename} \
    -f ../helm_config/${var.environment}_values.yaml \
    ${var.extra_helm_args}
EOF
  }

  triggers {
    # Triggers a list of values that, when changed, will cause the resource to be recreated
    # ${uuid()} will always be different thus always executing above local-exec
    hack_that_always_forces_null_resources_to_execute = "${uuid()}"
  }
}

variable "chart_version" {
  description = "Version of the Helm chart used to deploy the app"
  default     = "1.0.0"
}

variable "is_internal" {
  description = "Should the ALBs be internal facing"
  default     = true
}

variable "alm_region" {
  description = "Region of ALM resources"
  default     = "us-east-2"
}

variable "alm_role_arn" {
  description = "The ARN for the assume role for ALM access"
  default     = "arn:aws:iam::199837183662:role/jenkins_role"
}

variable "os_region" {
  description = "Region of OS resources"
  default     = "us-west-2"
}

variable "os_role_arn" {
  description = "The ARN for the assume role for OS access"
}

variable "state_bucket" {
  description = "The name of the S3 state bucket for ALM"
  default     = "scos-alm-terraform-state"
}

variable "image_tag" {
  description = "The tag to deploy the component images"
  default     = ""
}

variable "environment" {
  description = "The environment to deploy kdp to"
}

variable "metastore_instance_class" {
  description = "The size of the hive metastore rds instance"
  default     = "db.t3.small"
}

variable "allow_drop_table" {
  description = "Configures presto to allow drop, rename table and columns"
  default     = false
}

variable "extra_helm_args" {
  description = "Helm options"
  default     = ""
}
