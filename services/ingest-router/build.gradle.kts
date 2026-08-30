plugins {
    application
}

dependencies {
    implementation(project(":services:common-proto"))
    implementation(libs.grpc.netty)
    implementation(libs.slf4j.api)
    runtimeOnly(libs.slf4j.simple)
}

application {
    mainClass.set("co.mati.router.RouterMain")
}
