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
            deployTo('dev', "--set presto.deploy.container.tag=${env.DEV_IMAGE_TAG} --set metastore.deploy.container.tag=${env.DEV_IMAGE_TAG} --recreate-pods")
        }

        doStageIfMergedToMaster('Process Dev job') {
            scos.devDeployTrigger('kdp')
        }

        doStageIfMergedToMaster('Deploy to Staging') {
            deployTo('staging')
            scos.applyAndPushGitHubTag('staging')
        }

        doStageIfRelease('Deploy to Production') {
            deployTo('prod')
            scos.applyAndPushGitHubTag('prod')
        }
    }
}

def deployTo(environment, extraArgs = []) {
    dir('terraform') {
        def extraVars = [
            'environment': environment
        ]

        def terraform = scos.terraform(environment)
        terraform.init()
        terraform.plan(terraform.defaultVarFile, extraVars, extraArgs)
        terraform.apply()
    }
}