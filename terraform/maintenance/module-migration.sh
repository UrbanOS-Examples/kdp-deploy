#!/usr/bin/env bash
# to be run when migrating from embedded RDS to module based RDS in an environment for kdp, joomla, lime, etc.
terraform state mv aws_db_instance.metastore_database module.metastore_database.aws_db_instance.database
terraform state mv aws_db_subnet_group.metastore_subnet_group module.metastore_database.aws_db_subnet_group.subnet_group
terraform state mv aws_secretsmanager_secret.presto_metastore_password module.metastore_database.aws_secretsmanager_secret.password
terraform state mv aws_secretsmanager_secret_version.presto_metastore_password_version module.metastore_database.aws_secretsmanager_secret_version.password_version
terraform state mv aws_kms_key.metastore_key module.metastore_database.aws_kms_key.key
terraform state mv aws_kms_alias.metastore_key_alias module.metastore_database.aws_kms_alias.key_alias
terraform state mv random_string.metastore_password module.metastore_database.random_string.password
