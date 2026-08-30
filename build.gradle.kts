// Convenciones comunes del monorepo — Reto 1 (ARTI4109), PoC del experimento E01.
plugins {
    java
}

subprojects {
    apply(plugin = "java")

    group = "co.mati.reto1"
    version = "0.1.0"

    repositories {
        mavenCentral()
    }

    extensions.configure<JavaPluginExtension> {
        toolchain {
            languageVersion.set(JavaLanguageVersion.of(21)) // TEC-1: JVM / Java 21
        }
    }

    tasks.withType<JavaCompile>().configureEach {
        options.encoding = "UTF-8"
    }
}
