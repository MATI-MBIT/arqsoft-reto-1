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

### Versiones técnicas (todas las cifras, todas las fórmulas, todos los detalles)

- **[Experimento E01](experimento-e01.html)** — la ficha del experimento (espejo de Helix): hipótesis H1/H2/H2b, escenarios de calidad vinculados, fases F1–F4, métricas y criterios de éxito.
- **[Implementación](implementacion.html)** — cómo está construido el PoC: componentes y flujo de una orden, mapeo táctica → código, configuración, metodología de medición, despliegue y limitaciones.
- **[Evidencia de corridas](evidencia-corridas.html)** — resultados detallados de cada corrida, cómo leer los números y salidas crudas.
- **[Construcción de componentes](construccion-componentes.html)** — cómo se construyó cada pieza del monorepo por separado.

### Versiones intermedias (para equipos técnicos sin especialización en arquitectura)

Mismo contenido que las versiones técnicas, pero sin código citado, sin fórmulas derivadas paso a paso, sin líneas de archivo — pensadas para quien programa pero no vive todavía en este sistema:

- **[Experimento E01](experimento-e01_v2.html)** — qué se probó, las hipótesis de diseño H1/H2/H2b, las tres fases principales y el veredicto.
- **[Implementación](implementacion_v2.html)** — los tres componentes, cómo viaja una orden, la metodología de medición y las limitaciones.
- **[Evidencia de corridas](evidencia-corridas_v2.html)** — los resultados, cómo interpretarlos, qué se encontró y las limitaciones de la medición.
- **[Construcción de componentes](construccion-componentes_v2.html)** — qué tecnología se usó, qué decisiones se tomaron y cómo encaja todo.

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
