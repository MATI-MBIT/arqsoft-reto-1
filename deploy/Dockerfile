# Imagen multi-etapa para cualquiera de los servicios Java del monorepo.
# Uso:  docker build -f deploy/Dockerfile --build-arg SERVICE=matching-engine .
FROM gradle:8.14-jdk21 AS build
ARG SERVICE
WORKDIR /src
COPY settings.gradle.kts build.gradle.kts ./
COPY gradle ./gradle
COPY services ./services
RUN gradle :services:${SERVICE}:installDist --no-daemon --console=plain

FROM eclipse-temurin:21-jre
ARG SERVICE
ENV SERVICE_NAME=${SERVICE}
# ZGC (D-02): pausas de GC sub-milisegundo — la causa #1 de cola larga según el análisis.
ENV JAVA_OPTS="-XX:+UseZGC -XX:+ZGenerational -Xms256m -Xmx512m"
COPY --from=build /src/services/${SERVICE}/build/install/${SERVICE} /app
# JFR_OPTS se ANEXA a JAVA_OPTS en vez de reemplazarlo: sustituir la cadena
# entera apagaria ZGC sin avisar, y la corrida perfilada mediria otro colector.
ENTRYPOINT ["/bin/sh", "-c", "JAVA_OPTS=\"$JAVA_OPTS $JFR_OPTS\" exec /app/bin/$SERVICE_NAME"]
