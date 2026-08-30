# ==============================================================================
# arqsoft-reto-1 — PoC experimento E01 (Reto 1, ARTI4109)
# Comandos de ciclo de vida del proyecto. `make` o `make help` lista los targets.
# ==============================================================================

COMPOSE      := docker compose -f deploy/docker-compose.yml
K6_DIR       := load/k6
SHARDS_N4    := matching-shard-0:9090,matching-shard-1:9090,matching-shard-2:9090,matching-shard-3:9090

.DEFAULT_GOAL := help

# ---------- Build ------------------------------------------------------------

.PHONY: build
build: ## Compila los 3 módulos y genera los stubs de Protobuf/gRPC
	./gradlew build

.PHONY: test
test: ## Ejecuta las pruebas unitarias
	./gradlew test

.PHONY: clean
clean: ## Limpia artefactos de Gradle y baja los contenedores (incluye volúmenes)
	./gradlew clean
	$(COMPOSE) down -v --remove-orphans 2>/dev/null || true

# ---------- Topología (Docker Compose) ---------------------------------------

.PHONY: up
up: ## Levanta la topología N=2: router :8080 + 2 shards LMAX
	$(COMPOSE) up --build -d
	@echo "Router gRPC en localhost:8080 — logs: make logs"

.PHONY: up-n4
up-n4: ## Levanta la topología N=4: router :8080 + 4 shards LMAX
	SHARDS=$(SHARDS_N4) $(COMPOSE) --profile n4 up --build -d
	@echo "Router gRPC en localhost:8080 con 4 shards — logs: make logs"

.PHONY: down
down: ## Detiene y elimina los contenedores
	$(COMPOSE) --profile n4 down --remove-orphans

.PHONY: logs
logs: ## Sigue los logs de todos los servicios (percentiles de cada shard cada 10 s)
	$(COMPOSE) --profile n4 logs -f

.PHONY: ps
ps: ## Estado de los contenedores
	$(COMPOSE) --profile n4 ps

# ---------- Corridas del experimento (k6) ------------------------------------
# Requiere k6 >= 0.49 (gRPC nativo): brew install k6

.PHONY: smoke
smoke: ## Humo de ~1 min (F1 recortada) para verificar el montaje completo
	cd $(K6_DIR) && k6 run -e PHASE=f1 -e SMOKE=1 poc.js

.PHONY: smoke-f2
smoke-f2: ## Humo de ~5 min de la rampa (F2 recortada)
	cd $(K6_DIR) && k6 run -e PHASE=f2 -e SMOKE=1 poc.js

.PHONY: f1
f1: ## F1 — Baseline ASR-02: 1.000 emp/min por 12 min · criterio p95 < 200 ms
	cd $(K6_DIR) && k6 run -e PHASE=f1 poc.js

.PHONY: f2
f2: ## F2+F3 — Rampa a 5.000 emp/min, pico 30 min y retorno (ASR-03) · p95 < 200 ms
	cd $(K6_DIR) && k6 run -e PHASE=f2 poc.js

.PHONY: f4
f4: ## F4 — Partición caliente (exploratoria): 100 % del pico en un solo símbolo
	cd $(K6_DIR) && k6 run -e PHASE=f4 poc.js

.PHONY: experimento
experimento: up ## Corre la secuencia oficial completa sobre N=2: F1 → F2+F3 → F4
	$(MAKE) f1
	$(MAKE) f2
	$(MAKE) f4
	@echo "Corridas terminadas. Contrastar percentiles de k6 con los logs de los shards (make logs)."

# ---------- Utilidades -------------------------------------------------------

.PHONY: run-shard
run-shard: ## Corre un shard local sin Docker (SHARD_ID=0 PORT=9090)
	SHARD_ID=$${SHARD_ID:-0} PORT=$${PORT:-9090} ./gradlew :services:matching-engine:run

.PHONY: run-router
run-router: ## Corre el router local sin Docker (PORT=8080, SHARDS=localhost:9090)
	PORT=$${PORT:-8080} SHARDS=$${SHARDS:-localhost:9090} ./gradlew :services:ingest-router:run

.PHONY: help
help: ## Muestra esta ayuda
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

.PHONY: docs-serve
docs-serve: ## Previsualiza la documentación Jekyll en http://localhost:4000/arqsoft-reto-1/ (requiere Ruby + bundler)
	cd docs && bundle install && bundle exec jekyll serve

# ---------- Exploración F4 y comparación de sharding --------------------------

PEAK ?= 500

.PHONY: f4-peak
f4-peak: ## F4 exploratoria corta (~5 min) a tasa PEAK/s en un solo símbolo (make f4-peak PEAK=500)
	cd $(K6_DIR) && k6 run -e PHASE=f4 -e SMOKE=1 -e PEAK=$(PEAK) poc.js

.PHONY: f4-explore
f4-explore: ## Busca el punto de quiebre de un shard: corridas de ~5 min a 250, 500 y 1000/s
	-$(MAKE) f4-peak PEAK=250
	-$(MAKE) f4-peak PEAK=500
	-$(MAKE) f4-peak PEAK=1000
	@echo ""
	@echo "Leer en cada corrida: p95, rechazos (backpressure) y si k6 sostuvo la tasa objetivo."
	@echo "El punto de quiebre es la primera tasa donde alguno de los tres se degrada."

.PHONY: compare-sharding
compare-sharding: ## Compara N=2 vs N=4 con carga repartida a tasa PEAK/s (make compare-sharding PEAK=400)
	@echo "===== Topología N=2 @ $(PEAK)/s ====="
	$(COMPOSE) --profile n4 down --remove-orphans
	$(COMPOSE) up --build -d
	@sleep 20
	-cd $(K6_DIR) && k6 run -e PHASE=f2 -e SMOKE=1 -e PEAK=$(PEAK) poc.js
	@echo "===== Topología N=4 @ $(PEAK)/s ====="
	$(COMPOSE) down --remove-orphans
	SHARDS=$(SHARDS_N4) $(COMPOSE) --profile n4 up --build -d
	@sleep 20
	-cd $(K6_DIR) && k6 run -e PHASE=f2 -e SMOKE=1 -e PEAK=$(PEAK) poc.js
	@echo ""
	@echo "Evidencia de H2: si N=4 sostiene el p95/tasa donde N=2 se degrada, el throughput escala agregando shards."

# ---------- Ciclo E2E de un solo comando --------------------------------------

.PHONY: e2e
e2e: ## Ciclo E2E oficial completo (~1h40m): up → F1 → F2+F3 → F4 → F4-explore → down, resultados en load/k6/results/
	./load/run-e2e.sh full

.PHONY: e2e-smoke
e2e-smoke: ## Mismo ciclo E2E en corto (~25 min): la regresión a correr tras cada cambio de implementación
	./load/run-e2e.sh smoke
