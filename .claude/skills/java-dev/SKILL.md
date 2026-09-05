---
name: java-dev
description: Conventions and guardrails for writing or modifying Java code in this repo (matching-engine, ingest-router, common-proto) — module layout, build/run/test commands, the single-writer/no-locks discipline the LMAX pattern depends on, sharding invariants, gRPC/Protobuf ownership, env-var propagation, and the documented gaps (no tests, no cpuset). Use whenever adding a class, changing a hot path, adding a dependency or env var, or touching the matching engine, router, or proto contracts.
---

# Desarrollo Java — arqsoft-reto-1 (PoC experimento E01)

Monorepo Gradle (Kotlin DSL) de 3 módulos, Java 21, sin Kubernetes ni broker. El código existe para sostener las conclusiones de `docs/experimento-e01.md` (ASR-02 latencia, ASR-03 escalabilidad) — cualquier cambio que toque el camino crítico o los parámetros medidos afecta la validez de esas corridas, no solo el código.

## Mapa de módulos

- **`services/common-proto`** — único dueño de los `.proto`. Genera stubs gRPC/Protobuf vía `com.google.protobuf` plugin (`api(libs.grpc.protobuf)`, `api(libs.grpc.stub)`). Los otros módulos consumen los stubs generados vía `implementation(project(":services:common-proto"))`; **nunca** escribas a mano clases que el plugin genera.
- **`services:matching-engine`** — un proceso = una partición = un shard LMAX (`EngineMain`, `OrderBook`, `MatchingHandler`, `OrderSlot`, `BusinessLogicModel`). Disruptor 4.0.0, HdrHistogram, SLF4J.
- **`services:ingest-router`** — servicio gRPC que enruta por `hash(símbolo) % N` hacia los shards y aplica cola acotada con backpressure (`RouterMain`, `RouterService`).

Dependencias van al catálogo `gradle/libs.versions.toml` (`[versions]`/`[libraries]`), no inline en el `build.gradle.kts` del módulo.

## Comandos

```
make build          # ./gradlew build — compila los 3 módulos + genera stubs proto
make test           # ./gradlew test  — ver "Huecos conocidos": hoy no hay src/test
make run-shard SHARD_ID=0 PORT=9090   # shard local sin Docker
make run-router SHARDS=localhost:9090 # router local sin Docker
make up / up-n1 / up-n4               # topología completa vía Docker Compose
```

## Invariantes que no se pueden romper sin invalidar el experimento

1. **Un único escritor por partición, sin locks en el camino crítico.** `OrderBook`/`BusinessLogicModel` no son thread-safe *a propósito*: solo los toca el hilo matcher del Disruptor (`ProducerType.MULTI` al publicar, un solo consumidor). No agregues `synchronized`, colecciones concurrentes, ni I/O bloqueante dentro de `MatchingHandler`/`OrderBook`/`BusinessLogicModel.apply()` — eso es exactamente lo que H1 (LMAX) afirma que no existe.
2. **Nada de `sleep()` para simular costo.** Si necesitas modelar trabajo (como `BusinessLogicModel.burn()`), quema CPU con un bucle acotado por reloj monótono — un `sleep` libera el núcleo, no ensucia caché y no compite con GC/gRPC como haría trabajo real, y falsearía la medición.
3. **El invariante de sharding es `hash(símbolo) % N` determinístico** — toda orden de un símbolo debe caer siempre en el mismo shard. Si cambias la lista de símbolos del generador o la función de hash, reverifica la distribución (ver nota en `load/README.md`: con un set de símbolos distinto un shard puede quedar ocioso). El router expone `shard_id` en cada respuesta para que el generador pueda verificar esto en vivo — no rompas ese campo.
4. **Todo parámetro que afecte una medición debe ser explícito y trazable.** Si agregas una variable de entorno nueva (al estilo `BIZ_MICROS`/`BIZ_DIST`): (a) documéntala en el javadoc de cabecera de la clase `Main` que la lee, igual que `EngineMain`; (b) logueala al arrancar (patrón `describe()` de `BusinessLogicModel`) — una corrida no debe ser ambigua sobre su propia configuración; (c) **propágala explícitamente por toda la cadena**: `deploy/docker-compose.yml` (con default vía `${VAR:-default}`) y el `Makefile`/`load/run-e2e.sh` si un target la necesita fijar. El bug real del 2-sep (`docs/experimento-e01.md`) fue exactamente esto: el arnés no propagaba `BIZ_MICROS`, la variable nunca llegó al proceso, y una serie entera de corridas quedó sin validez sin que el código Java tuviera ningún error.
5. **Journaling, notificaciones y cualquier I/O van fuera del camino crítico** (asíncronos) si algún día se implementan — hoy están explícitamente fuera de alcance del PoC (`docs/experimento-e01.md`, tabla "Diferencias entre el diseño y lo construido"). No los agregues en el hilo del matcher sin sacarlos de ahí.

## Estilo del código existente

- Clases `final`, constantes `private static final` documentadas cuando el valor no es obvio (ver `BusinessLogicModel.WEIGHT`/`FACTOR`).
- Comentarios y Javadoc en **español**, y solo para el **por qué** (una decisión de diseño, un trade-off, una deuda registrada) — nunca para narrar el qué. Si vas a explicar un valor mágico o una decisión no obvia (p. ej. por qué `BlockingWaitStrategy` y no `BusySpin`), documenta el trade-off inline como hace `EngineMain`.
- Logging con SLF4J (`log.info` estructurado con placeholders `{}`), nunca `System.out`.
- Variables de entorno leídas con un helper simple (`env(name, default)`), nunca acopladas a un framework de config.

## Huecos conocidos (no los "corrijas" sin que te lo pidan)

- **No existe `src/test/java` en ningún módulo** pese a que `make test` invoca `./gradlew test`. JUnit no está en el catálogo de versiones. Si el usuario pide agregar pruebas, hay que añadir la dependencia y el plugin de test al `build.gradle.kts` del módulo correspondiente primero.
- **`cpuset` está comentado en `deploy/docker-compose.yml`** (solo aplica en Linux; en macOS Docker corre en una VM). No lo actives sin que el usuario confirme que corre en Linux — es una precondición declarada de varias mediciones de la Serie B.
- **No hay journaling, JFR, ni exportación a Prometheus/Grafana** — están fuera de alcance declarado, no ausencias accidentales.

## Al tocar `.proto` o contratos gRPC

Los `.proto` viven en `common-proto`; regenerar stubs es automático vía `./gradlew build` (plugin `com.google.protobuf`). Un cambio de contrato afecta a la vez a `matching-engine` (servidor) y `ingest-router` (cliente/servidor intermedio) — revisa ambos antes de dar el cambio por terminado, y si el cambio toca el campo `shard_id` de la respuesta, revisa también `load/k6/poc.js` (verifica `shard_routing_violations` con ese campo).
