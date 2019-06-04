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
            scos.devDeployTrigger('presto')
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
        def terraform = scos.terraform(parameters.environment)
        terraform.init()
        terraform.plan(terraform.defaultVarFile, parameters)
        terraform.apply()
    }
}