job("kdp-dev-trigger") {
    triggers {
        urlTrigger {
            cron("*/5 * * * *")
            url("https://hub.docker.com/v2/repositories/smartcitiesdata/presto/tags/development/") {
                inspection("change")
            }
            url("https://hub.docker.com/v2/repositories/smartcitiesdata/metastore/tags/development/") {
                inspection("change")
            }
        }
    }
    steps {
        downstreamParameterized {
            trigger("SmartColumbusOS/kdp-deploy/master") {
                block {
                    buildStepFailure("FAILURE")
                    failure("FAILURE")
                    unstable("UNSTABLE")
                }
                parameters {
                    booleanParam("DEV_DEPLOYMENT", true)
                }
            }
        }
    }
}