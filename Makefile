# ==============================================================================
# arqsoft-reto-1 — PoC experimento E01 (Reto 1, ARTI4109)
#
# La regla de este archivo: un target existe si produce EVIDENCIA que la
# documentación cita, o si es parte del ciclo diario. Los atajos que solo
# parametrizan a otro target no existen — se pasan como variable.
#   make f4 PEAK=500        en vez de  make f4-peak PEAK=500
#   make up SHARD_CPUS=1.0  en vez de  un target por cuota
# ==============================================================================

COMPOSE   := docker compose -f deploy/docker-compose.yml
K6_DIR    := load/k6
SHARDS_N4 := matching-shard-0:9090,matching-shard-1:9090,matching-shard-2:9090,matching-shard-3:9090

# Confinamiento de recursos por partición. 0 = sin límite (el PoC corre sobre
# 14 vCPU, cosa que ningún despliegue real hace). Verificar con `make verify-limits`:
# deploy.resources se ignora en silencio fuera de Swarm.
SHARD_CPUS   ?= 0
SHARD_CPUSET ?=
SHARD_MEM    ?= 0
export SHARD_CPUS SHARD_CPUSET SHARD_MEM

# Punto de operación: costo medio por orden en µs. Sin declararlo, la corrida
# mide el patrón con la lógica de negocio apagada.
BIZ_MICROS ?= 0
export BIZ_MICROS

# Tasa a explorar en F4 y capacidad del barrido.
PEAK ?= 84

# Salida a Prometheus, para que el tablero de Grafana cubra la corrida.
# K6_OUT= (vacío) la apaga en un anfitrión sin observabilidad levantada.
K6_ENV := K6_PROMETHEUS_RW_SERVER_URL=http://localhost:9090/api/v1/write \
          K6_PROMETHEUS_RW_TREND_STATS='p(50),p(95),p(99),p(99.9),max,avg' \
          K6_PROMETHEUS_RW_PUSH_INTERVAL=5s
K6_OUT ?= -o experimental-prometheus-rw
K6     = cd $(K6_DIR) && $(K6_ENV) k6 run $(K6_OUT)

.DEFAULT_GOAL := help

##@ Compilación

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

##@ Topología

.PHONY: up
up: ## Levanta N=2 + observabilidad (make up SHARD_CPUS=1.0 BIZ_MICROS=8000 para confinar y declarar S)
	$(COMPOSE) up --build -d
	@echo "Router gRPC :8080 · Grafana http://localhost:3000 · Prometheus http://localhost:9090"

.PHONY: up-n4
up-n4: ## Levanta N=4 + observabilidad
	SHARDS=$(SHARDS_N4) $(COMPOSE) --profile n4 up --build -d
	@echo "Router gRPC :8080 con 4 particiones · Grafana http://localhost:3000"

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
tablero: ## Abre el tablero de Grafana con la evidencia en vivo
	@echo "http://localhost:3000/d/e01-motor-emparejamiento"
	@open http://localhost:3000/d/e01-motor-emparejamiento 2>/dev/null || true

.PHONY: verify-limits
verify-limits: ## Comprueba EN EL CGROUP que los límites declarados se aplicaron de verdad
	@echo "declarado: SHARD_CPUS=$(SHARD_CPUS) SHARD_CPUSET='$(SHARD_CPUSET)' SHARD_MEM=$(SHARD_MEM)"
	@docker inspect $$($(COMPOSE) ps -q matching-shard-0 2>/dev/null) \
	   --format '  cgroup real -> NanoCpus={{.HostConfig.NanoCpus}} CpusetCpus="{{.HostConfig.CpusetCpus}}" Memory={{.HostConfig.Memory}}' \
	   2>/dev/null || echo "  (no hay partición levantada: correr make up primero)"
	@$(COMPOSE) logs matching-shard-0 2>/dev/null | grep -m1 "runtime:" | sed 's/.*EngineMain - /  lo que ve la JVM -> /' \
	   || echo "  (sin línea runtime: imagen anterior a la instrumentación)"

##@ Corridas del experimento (requiere k6 >= 0.49)

.PHONY: smoke
smoke: ## Humo de ~1,5 min para verificar el montaje completo
	$(K6) -e PHASE=f1 -e SMOKE=1 poc.js

.PHONY: f1
f1: ## F1 — Línea base ASR-02: 2 min calentamiento + 12 min a 17/s · p95 < 200 ms
	$(K6) -e PHASE=f1 poc.js

.PHONY: f2
f2: ## F2+F3 — Rampa a 84/s, pico de 30 min y retorno a régimen (ASR-03) · p95 < 200 ms
	$(K6) -e PHASE=f2 poc.js

.PHONY: f4
f4: ## F4 — Partición caliente, exploratoria (make f4 PEAK=500 para buscar el quiebre)
	$(K6) -e PHASE=f4 -e PEAK=$(PEAK) poc.js

.PHONY: e2e
e2e: ## Ciclo oficial completo (~1h40m): F1 → F2+F3 → F4 → exploración. Declarar S: make e2e BIZ_MICROS=8000
	./load/run-e2e.sh full

.PHONY: e2e-smoke
e2e-smoke: ## El mismo ciclo en corto (~25 min): la regresión a correr tras cada cambio
	./load/run-e2e.sh smoke

##@ Estudios (cada uno responde una pregunta y produce una tabla de la evidencia)

.PHONY: sweep-service
sweep-service: ## Presupuesto de tiempo de servicio en el perfil oficial (N=2, pico repartido)
	MICROS="0 5000 10000 15000 20000 25000" PHASE=f2 PEAK=84 N=2 ./load/sweep-service.sh

.PHONY: sweep-hot
sweep-hot: ## Presupuesto en el peor caso: todo el pico contractual en una sola partición
	MICROS="0 1000 5000 8000 10000 12000" PHASE=f4 PEAK=84 N=1 ./load/sweep-service.sh

.PHONY: compare-cpus
compare-cpus: ## Efecto del confinamiento de CPU: 0 / 2 / 1 / 0,5 núcleos por partición
	./load/compare-cpus.sh 0 2.0 1.0 0.5

.PHONY: compare-journal
compare-journal: ## Cláusula de H1: bitácora off vs paralelo vs serie
	./load/compare-journal.sh off paralelo serie

.PHONY: profile-jfr
profile-jfr: ## Perfila una fase con Java Flight Recorder y atribuye los atascos
	./load/profile-jfr.sh f2

##@ Documentación

.PHONY: docs-serve
docs-serve: ## Previsualiza el sitio Jekyll en http://localhost:4000/arqsoft-reto-1/
	cd docs && bundle install && bundle exec jekyll serve

.PHONY: help
help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^[a-zA-Z0-9_-]+:.*##/ { printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo ""
