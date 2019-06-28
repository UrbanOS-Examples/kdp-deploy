library(
    identifier: 'pipeline-lib@4.6.1',
    retriever: modernSCM([$class: 'GitSCMSource',
                          remote: 'https://github.com/SmartColumbusOS/pipeline-lib',
                          credentialsId: 'jenkins-github-user'])
)

properties([
    pipelineTriggers([scos.dailyBuildTrigger()]),
    parameters([
        booleanParam(defaultValue: false, description: 'Deploy to development environment?', name: 'DEV_DEPLOYMENT'),
        string(defaultValue: 'development', description: 'Image tag to deploy to dev environment', name: 'DEV_IMAGE_TAG')
    ])
])

def doStageIf = scos.&doStageIf
def doStageIfDeployingToDev = doStageIf.curry(env.DEV_DEPLOYMENT == "true")
def doStageIfMergedToMaster = doStageIf.curry(scos.changeset.isMaster && env.DEV_DEPLOYMENT == "false")
def doStageIfRelease = doStageIf.curry(scos.changeset.isRelease)

node('infrastructure') {
    ansiColor('xterm') {
        scos.doCheckoutStage()

        doStageIfDeployingToDev('Deploy to Dev') {
            deployTo('environment': 'dev', 'image_tag': env.DEV_IMAGE_TAG)
        }

        doStageIfMergedToMaster('Process Dev job') {
            jobDsl(targets: 'kdpDeployTrigger.groovy')
        }

        doStageIfMergedToMaster('Deploy to Staging') {
            deployTo('environment': 'staging')
            scos.applyAndPushGitHubTag('staging')
        }

        doStageIfRelease('Deploy to Production') {
            deployTo('environment': 'prod')
            scos.applyAndPushGitHubTag('prod')
        }
    }
}

def deployTo(parameters = [:]) {
    dir('terraform') {
        def versionVarFile = '../version.tfvars'
        def terraform = scos.terraform(parameters.environment)
        terraform.init()
        sh('''
        #### TEMP TO MIGRATE INTO MODULE ####
        terraform state mv aws_db_instance.metastore_database module.metastore_database.aws_db_instance.database
        terraform state mv aws_db_subnet_group.metastore_subnet_group module.metastore_database.aws_db_subnet_group.subnet_group
        terraform state mv aws_secretsmanager_secret.presto_metastore_password module.metastore_database.aws_secretsmanager_secret.password
        terraform state mv aws_secretsmanager_secret_version.presto_metastore_password_version module.metastore_database.aws_secretsmanager_secret_version.password_version
        terraform state mv aws_kms_key.metastore_key module.metastore_database.aws_kms_key.key
        terraform state mv aws_kms_alias.metastore_key_alias module.metastore_database.aws_kms_alias.key_alias
        terraform state mv random_string.metastore_password module.metastore_database.random_string.password
        #### TEMP TO MIGRATE INTO MODULE ####
        ''')
        terraform.plan(terraform.defaultVarFile, parameters, ["--var-file=${versionVarFile}"])
        terraform.apply()
    }
}
