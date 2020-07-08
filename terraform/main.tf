provider "aws" {
  version = "2.54"
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
  source = "git@github.com:SmartColumbusOS/scos-tf-rds?ref=1.0.1"

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

module "presto_storage" {
  source = "git@github.com:SmartColumbusOS/scos-tf-bucket?ref=1.1.0"

  name   = "presto-hive-storage-${terraform.workspace}"
  region = "${var.os_region}"

  policy = "${data.aws_iam_policy_document.eks_bucket_access.json}"

  providers {
    aws = "aws"
  }
}

data "aws_iam_policy_document" "eks_bucket_access" {
  statement {
    sid = "AllowListBucket"

    principals {
      type        = "AWS"
      identifiers = ["${data.terraform_remote_state.env_remote_state.eks_worker_role_arn}"]
    }

    effect = "Allow"

    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "${module.presto_storage.bucket_arn}",
    ]
  }

  statement {
    sid = "AllowObjectWriteAccess"

    principals {
      type        = "AWS"
      identifiers = ["${data.terraform_remote_state.env_remote_state.eks_worker_role_arn}"]
    }

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]

    resources = [
      "${module.presto_storage.bucket_arn}/*",
    ]
  }
}

resource "local_file" "helm_vars" {
  filename = "${path.module}/outputs/${terraform.workspace}.yaml"

  content = <<EOF
global:
  environment: ${terraform.workspace}
  ingress:
    annotations:
      alb.ingress.kubernetes.io/ssl-policy: "ELBSecurityPolicy-TLS-1-2-2017-01"
      alb.ingress.kubernetes.io/scheme: "${var.is_internal ? "internal" : "internet-facing"}"
      alb.ingress.kubernetes.io/subnets: "${join(",", data.terraform_remote_state.env_remote_state.public_subnets)}"
      alb.ingress.kubernetes.io/security-groups: "${data.terraform_remote_state.env_remote_state.allow_all_security_group}"
      alb.ingress.kubernetes.io/certificate-arn: "${data.terraform_remote_state.env_remote_state.tls_certificate_arn}"
      alb.ingress.kubernetes.io/tags: scos.delete.on.teardown=true
      alb.ingress.kubernetes.io/actions.redirect: '{"Type": "redirect", "RedirectConfig":{"Protocol": "HTTPS", "Port": "443", "StatusCode": "HTTP_301"}}'
      alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
      kubernetes.io/ingress.class: alb
  objectStore:
    bucketName: ${module.presto_storage.bucket_name}
    accessKey: null
    accessSecret: null
kubernetes-data-platform:
  metastore:
    deploy: ${var.image_tag != "" ? "{container: {tag: ${var.image_tag}}}" : "{}"}
    allowDropTable: ${var.allow_drop_table ? "true": "false"}
    timeout: 360m
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
backup_executor:
  sa_name: "${local.presto_backup_executor_role}"
  role_arn: "${aws_iam_role.presto_backup_executor.arn}"
  source_region: "${var.os_region}"
  source_bucket: "${module.presto_storage.bucket_name}"
  destination_bucket: "${module.presto_storage_backup.bucket_name}"
EOF
}

resource "null_resource" "helm_deploy" {
  provisioner "local-exec" {
    command = <<EOF
set -ex

export KUBECONFIG=${local_file.kubeconfig.filename}

export AWS_DEFAULT_REGION=us-east-2

(
cd ${path.module}/../chart
helm init --client-only
helm repo add scdp https://smartcitiesdata.github.io/charts
helm repo update
helm dependency update
helm upgrade --install kdp \
    ./ \
    --namespace kdp \
    -f ${local_file.helm_vars.filename} \
    -f ./${var.environment}_values.yaml \
    ${var.extra_helm_args}
)
EOF
  }

  triggers {
    # Triggers a list of values that, when changed, will cause the resource to be recreated
    # ${uuid()} will always be different thus always executing above local-exec
    hack_that_always_forces_null_resources_to_execute = "${uuid()}"
  }
}

provider "aws" {
  alias   = "backup"
  version = "2.54"
  region  = "${var.os_backup_region}"

  assume_role {
    role_arn = "${var.os_role_arn}"
  }
}

module "presto_storage_backup" {
  source = "git@github.com:SmartColumbusOS/scos-tf-bucket?ref=1.1.0"

  name   = "presto-storage-backup-${terraform.workspace}"
  region = "${var.os_backup_region}"

  lifecycle_enabled = true
  lifecycle_days    = 30

  providers {
    aws = "aws.backup"
  }
}

data "aws_iam_policy_document" "presto_backup_executor_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    condition {
      test     = "StringEquals"
      variable = "${data.terraform_remote_state.env_remote_state.eks_cluster_oidc_provider_host}:sub"
      values   = ["system:serviceaccount:kdp:${local.presto_backup_executor_role}"]
    }

    principals {
      identifiers = ["${data.terraform_remote_state.env_remote_state.eks_cluster_oidc_provider_arn}"]
      type        = "Federated"
    }
  }
}

data "aws_iam_policy_document" "presto_backup_executor_rights" {
  statement {
    sid = "AllowListBucket"

    effect = "Allow"

    actions = [
      "s3:ListBucket",
    ]

    resources = [
      "${module.presto_storage.bucket_arn}",
      "${module.presto_storage_backup.bucket_arn}",
    ]
  }

  statement {
    sid = "AllowObjectReadAccessSource"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectTagging",
    ]

    resources = [
      "${module.presto_storage.bucket_arn}/*",
    ]
  }

  statement {
    sid = "AllowObjectWriteAccessDestination"

    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
    ]

    resources = [
      "${module.presto_storage_backup.bucket_arn}/*",
    ]
  }
}

resource "aws_iam_role_policy" "presto_backup_executor_rights" {
  name = "presto_backup_executor_rights"
  role = "${aws_iam_role.presto_backup_executor.id}"

  policy = "${data.aws_iam_policy_document.presto_backup_executor_rights.json}"
}

resource "aws_iam_role" "presto_backup_executor" {
  assume_role_policy = "${data.aws_iam_policy_document.presto_backup_executor_assume.json}"
  name               = "presto_backup_executor"
}

locals {
  presto_backup_executor_role = "presto-backup-executor"
}

variable "chart_version" {
  description = "Version of the Helm chart used to deploy the app"
  default     = "1.3.0"
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

variable "os_backup_region" {
  description = "Region for backup of select OS resources"
  default     = "us-east-2"
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
