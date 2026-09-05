---
title: Inicio
nav_order: 1
---

# Motor de Emparejamiento — PoC del experimento E01

Documentación del **Reto 1** (ARTI4109 · Arquitectura de Software): validar el patrón **LMAX** —libro de órdenes en memoria con un único escritor por partición— con **sharding por activo** e ingesta **gRPC**, contra los dos ASR críticos del sistema.

| ASR | Atributo | Criterio |
|---|---|---|
| ASR-02 | Latencia (Critical) | Emparejamiento p95 ≤ 200 ms a 1.000 emp/min (Ambiente A) |
| ASR-03 | Escalabilidad transitoria (Critical) | 1.000 → 5.000 emp/min sostenido hasta 30 min con p95 ≤ 200 ms (Ambiente B) |

## Grupo 1 - Arquitectura de Software

- Carlos Chaparro
- Nestor Javier Rodriguez
- Rafael Alexander Reyes
- Nicolás E Rozo Espinosa

## Contenido

Cuatro documentos, en el orden en que conviene leerlos:

- **[Experimento E01](experimento.html)** — la apuesta: qué se prueba, las hipótesis H1/H2/H2b, las fases F1–F4 y los criterios de éxito.
- **[Implementación](implementacion.html)** — cómo funciona el prototipo: el viaje de una orden, de la táctica al código, las perillas y cómo se mide.
- **[Evidencia de corridas](evidencia-corridas.html)** — los resultados, cómo se leen los números, los hallazgos y las salidas crudas.
- **[Construcción de componentes](construccion-componentes.html)** — con qué está construida cada pieza del monorepo y qué decisión hay detrás.

## Ejecutar el proyecto

```bash
make build     # compila los 3 módulos (Gradle + Java 21)
make up        # router :8080 + 2 shards LMAX (Docker Compose)
make smoke     # verificación de ~1 min con k6
make f1        # corrida oficial F1 (baseline ASR-02)
```

`make help` lista todos los comandos. El detalle de las corridas de carga está en el [README de load](https://github.com/MATI-MBIT/arqsoft-reto-1/blob/main/load/README.md).

---

El trabajo del reto sigue el método **ADD 3.0** con escenarios de calidad de seis partes; el registro canónico (problema, stakeholders, restricciones, requisitos y experimentos) vive en la plataforma **Helix** del curso, y esta documentación es su espejo técnico en el repositorio.
