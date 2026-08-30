pluginManagement {
    repositories {
        mavenCentral()
        gradlePluginPortal()
    }
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == "com.google.protobuf") {
                useModule("com.google.protobuf:protobuf-gradle-plugin:${requested.version}")
            }
        }
    }
}

rootProject.name = "arqsoft-reto-1"

include(
    "services:common-proto",
    "services:matching-engine",
    "services:ingest-router",
)
