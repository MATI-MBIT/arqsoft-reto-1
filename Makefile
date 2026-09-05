# ==============================================================================
# arqsoft-reto-1 — PoC experimento E01 (Reto 1, ARTI4109)
#
# La regla de este archivo: los comandos son congruentes con lo que se prueba.
# QUÉ se corre vive en load/plan.tsv --una fila por corrida, con la hipótesis a
# la que sirve--; CÓMO se corre, en load/experimento.sh. Aquí solo hay atajos.
#
# Agregar un punto de medida es agregar una línea al plan, no un comando nuevo.
# ==============================================================================

COMPOSE   := docker compose -f deploy/docker-compose.yml
SHARDS_N4 := matching-shard-0:9090,matching-shard-1:9090,matching-shard-2:9090,matching-shard-3:9090

# Confinamiento de recursos por partición, para levantar la topología a mano.
# En el plan lo declara cada corrida. Verificar con `make verify-limits`:
# deploy.resources se ignora en silencio fuera de Swarm.
SHARD_CPUS   ?= 0
SHARD_CPUSET ?=
SHARD_MEM    ?= 0
export SHARD_CPUS SHARD_CPUSET SHARD_MEM

# Costo medio por orden en µs. Sin declararlo, la lógica de negocio va apagada
# y el p95 que salga no es el de un motor real.
BIZ_MICROS ?= 8000
export BIZ_MICROS

.DEFAULT_GOAL := help

##@ Experimento — lo que valida las hipótesis

.PHONY: plan
plan: ## Muestra el plan de corridas y a qué hipótesis sirve cada una
	@printf "\n  \033[1m%-16s %-6s %-5s %-7s %-3s %s\033[0m\n" grupo hipót. fase perfil N pregunta
	@awk -F'\t' '!/^#/ && NF>3 {printf "  %-16s %-6s %-5s %-7s %-3s %s\n", $$1,$$3,$$4,$$5,$$6,$$9}' load/plan.tsv
	@printf "\n  correr todo: make experimento   ·   un grupo: make grupo G=h2-quiebre\n\n"

.PHONY: experimento
experimento: ## El plan COMPLETO (~4h30m): las 3 fases contractuales + los 37 puntos de estudio
	./load/experimento.sh

.PHONY: oficial
oficial: ## Solo las 3 fases contractuales largas (~1h30m): F1, F2+F3 y partición caliente
	./load/experimento.sh oficial

.PHONY: grupo
grupo: ## Un grupo del plan: make grupo G=h2-quiebre (ver make plan)
	@test -n "$(G)" || { echo "falta G. Grupos disponibles:"; awk -F'\t' '!/^#/ && NF>3 {print "  "$$1}' load/plan.tsv | sort -u; exit 1; }
	./load/experimento.sh $(G)

.PHONY: smoke
smoke: ## Humo de ~1,5 min para verificar el montaje antes de invertir horas
	cd load/k6 && k6 run -e PHASE=f1 -e SMOKE=1 poc.js

##@ Topología y observación

.PHONY: up
up: ## Levanta N=2 + Prometheus + Grafana (make up SHARD_CPUS=1.0 para confinar)
	$(COMPOSE) up --build -d
	@echo "Router gRPC :8080 · Grafana http://localhost:3000 · Prometheus http://localhost:9090"

.PHONY: up-n4
up-n4: ## Levanta N=4 + observabilidad
	SHARDS=$(SHARDS_N4) $(COMPOSE) --profile n4 up --build -d

.PHONY: down
down: ## Detiene y elimina los contenedores (conserva el histórico de Prometheus)
	$(COMPOSE) --profile n4 down --remove-orphans

.PHONY: ps
ps: ## Estado de los contenedores
	$(COMPOSE) --profile n4 ps

.PHONY: logs
logs: ## Sigue los logs (percentiles de cada partición cada 10 s)
	$(COMPOSE) --profile n4 logs -f

.PHONY: tablero
tablero: ## Abre el tablero de Grafana con la evidencia
	@echo "http://localhost:3000/d/e01-motor-emparejamiento"
	@open http://localhost:3000/d/e01-motor-emparejamiento 2>/dev/null || true

.PHONY: verify-limits
verify-limits: ## Comprueba EN EL CGROUP que los límites declarados se aplicaron de verdad
	@echo "declarado: SHARD_CPUS=$(SHARD_CPUS) SHARD_CPUSET='$(SHARD_CPUSET)' SHARD_MEM=$(SHARD_MEM)"
	@docker inspect $$($(COMPOSE) ps -q matching-shard-0 2>/dev/null) \
	   --format '  cgroup real -> NanoCpus={{.HostConfig.NanoCpus}} CpusetCpus="{{.HostConfig.CpusetCpus}}" Memory={{.HostConfig.Memory}}' \
	   2>/dev/null || echo "  (no hay partición levantada: correr make up primero)"
	@$(COMPOSE) logs matching-shard-0 2>/dev/null | grep -m1 "runtime:" | sed 's/.*EngineMain - /  lo que ve la JVM -> /' \
	   || echo "  (sin línea runtime)"

##@ Compilación y documentación

.PHONY: build
build: ## Compila los 3 módulos y genera los stubs de Protobuf/gRPC
	./gradlew build

.PHONY: test
test: ## Ejecuta las pruebas unitarias
	./gradlew test

.PHONY: clean
clean: ## Limpia Gradle y borra contenedores Y volúmenes (incluye el histórico de Prometheus)
	./gradlew clean
	$(COMPOSE) --profile n4 down -v --remove-orphans 2>/dev/null || true

.PHONY: docs-serve
docs-serve: ## Previsualiza el sitio Jekyll en http://localhost:4000/arqsoft-reto-1/
	cd docs && bundle install && bundle exec jekyll serve

.PHONY: help
help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
