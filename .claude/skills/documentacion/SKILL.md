---
name: documentacion
description: Conventions for writing or updating documentation in this repo — the docs/ Jekyll site (just-the-docs), the top-level README, and load/README.md. Covers front matter and nav_order, which doc owns which content, the ADD 3.0 tab structure of experimento-e01.md (it mirrors Helix, the canonical source), the mermaid/table-heavy style, the traceability rule (every number needs a source), how corrections get recorded instead of silently overwritten, and the three-level (beginner/intermediate/expert) format for explanatory content, written in plain, human language. Use whenever adding a doc page, updating experiment results, documenting a new component, editing README.md, or explaining a concept/decision to someone.
---

# Documentación — arqsoft-reto-1

La documentación no es prosa libre: cada afirmación cuantitativa debe poder rastrearse a una corrida o a una fuente en el código, y cada documento tiene un dueño de contenido claro para no duplicar entre archivos.

## Dónde vive cada cosa

| Documento | Rol | No hagas aquí |
|---|---|---|
| `README.md` (raíz) | Entrada rápida: qué es el proyecto, quickstart, tabla de comandos `make`, estructura del monorepo | No repitas el detalle de hipótesis/resultados — enlaza a `docs/` |
| `docs/index.md` | Portada del sitio Jekyll: los dos ASR críticos, integrantes, índice de contenido | Solo enlaces y resumen de una línea por documento |
| `docs/experimento-e01.md` | La ficha del experimento — **espejo técnico de Helix** (la plataforma del curso es la fuente canónica) | No inventes estructura nueva: sigue las pestañas de Helix (ver abajo) |
| `docs/implementacion.md` | Cómo funciona el sistema en conjunto: flujo de una orden, mapeo táctica→código, configuración, metodología de medición | No expliques *por qué* se construyó así cada pieza — eso es `construccion-componentes.md` |
| `docs/construccion-componentes.md` | Cómo se construyó cada componente por separado: tecnología, decisiones, conexión con el resto | No repitas el flujo end-to-end — eso ya está en `implementacion.md` |
| `docs/evidencia-corridas.md` | Resultados: veredicto, cómo leer los números, tablas de resultados, hallazgos, limitaciones, **salidas crudas** | Es el único lugar con salidas crudas de k6/HdrHistogram — no las pegues en otro doc |
| `load/README.md` | Cómo correr el generador k6: comandos, fases, flags | No documentes resultados aquí — solo mecánica de ejecución |

Antes de escribir, ubica cuál de estos documentos es el dueño del contenido. Si no encaja en ninguno, es señal de que falta una sección, no un documento nuevo — este set es deliberadamente pequeño.

## Tres niveles de audiencia

Toda documentación **explicativa** que generes con este skill —una guía nueva, una sección que te pidan explicar, un README, material de onboarding— se entrega en **tres niveles que cubren la misma información completa**, no un resumen seguido del detalle. Cada nivel responde las mismas preguntas de principio a fin; lo único que cambia es cuánto necesita saber el lector de antemano para seguirlo.

- **Nivel 1 — Para cualquiera.** Cero jerga sin explicar: si aparece un término técnico (shard, p95, ring buffer, backpressure), se explica ahí mismo con una analogía cotidiana, no con una definición de manual. "Sencillo" no es "incompleto" — no se omite nada importante, se prioriza la idea sobre el mecanismo interno: el qué y el por qué, no la clase Java que lo implementa. Sin código, sin nombres de clase, sin fórmulas.
  Ejemplo de tono para este proyecto: en vez de "el router aplica sharding determinístico `hash(símbolo) % N`", algo como *"cada acción bursátil tiene siempre el mismo encargado fijo — como la recepción de un hotel que ya sabe a qué piso mandar a cada huésped según su apellido, sin tener que preguntar cada vez"*.
- **Nivel 2 — Para quien programa pero no vive en este sistema.** Vocabulario técnico correcto, explicado la primera vez que aparece, sin analogías infantilizadas. Cubre el cómo general —patrones, decisiones, trade-offs principales—, con nombres de componentes y diagramas, pero sin fórmulas derivadas ni líneas de código citadas.
- **Nivel 3 — Para quien va a tocar o decidir sobre el sistema.** Todo el detalle: nombres de clase y archivo con línea, fórmulas (`techo = 1/S`, `ρ = λ·S`), cifras exactas con su fuente, trade-offs cuantificados, limitaciones declaradas. Es el nivel que ya sigue el resto de las reglas de este documento (tablas, mermaid, trazabilidad numérica) — el nivel por defecto de los documentos técnicos existentes del repo.

**Cómo entregarlos:** si no te piden un nivel específico, entrega los tres, en el mismo archivo, bajo encabezados `## Nivel 1 — ...`, `## Nivel 2 — ...`, `## Nivel 3 — ...`, en ese orden. Si piden un nivel puntual, entrega solo ese, pero autocontenido — nunca "ver nivel 3 para más detalle".

**Excepción:** `docs/experimento-e01.md` conserva su estructura fija de pestañas Helix (ver abajo) porque es el espejo de una plataforma externa — no se fragmenta en tres niveles. Si alguien pide una versión nivel 1 de ese contenido (por ejemplo para explicárselo a alguien no técnico), va en un documento aparte que enlaza al original, sin reemplazarlo.

## `docs/experimento-e01.md` sigue las pestañas de Helix (ADD 3.0)

Este documento no es libre: reproduce la estructura de pestañas de la plataforma Helix (Planning → Results & analysis) porque **es un espejo, no el original**. Si cambias una hipótesis o un escenario aquí, ese cambio también le corresponde a Helix — decláralo si no puedes actualizar ambos.

Pestaña **Planning**: Design Hypothesis (cada hipótesis como *apuesta de diseño* que referencia el escenario de calidad enlazado — la medida vive en el escenario, no se transcribe en la hipótesis) → Linked Quality Scenarios (tabla con ASR) → Tactics and Patterns → Experiment Design (fases, métricas, limitaciones declaradas) → Experiment planning (recursos, elementos de arquitectura, esfuerzo estimado).

Pestaña **Results & analysis**: tabla de resultados por fase con veredicto, Analysis of results, Architectural Decision (Paso 8 de ADD: ADOPTAR/RECHAZAR/etc. con condiciones de cierre).

## El patrón "Qué es / Cómo se construyó / Decisiones"

`construccion-componentes.md` documenta cada pieza con la misma forma tripartita — mantenla si agregas un componente nuevo:
- **Qué es** — una o dos frases, el propósito.
- **Cómo se construyó** — tecnología y mecánica concreta.
- **Decisiones** — tabla `Decisión | Por qué`, solo las no obvias (nunca "usamos Java porque es el lenguaje del curso").

## Estilo

- **Suena humano, no a IA** — esto aplica a los tres niveles, incluido el experto. Ritmo de frase variable, no todas del mismo largo. Cero relleno de piloto automático ("es importante destacar que", "cabe mencionar", "en resumen" al final de cada sección). No repitas la misma estructura de párrafo en cada punto. Usa ejemplos concretos del propio proyecto (cifras reales de las corridas, nombres reales de símbolos/clases) en vez de ejemplos abstractos genéricos — un ejemplo inventado se nota y le resta credibilidad al resto.
- **Español**, denso, sin relleno. Números con unidad siempre (`p95 = 74,32 ms`, no "74.32"); usa coma decimal como el resto del repo.
- **Negrita** para el término o la cifra que sostiene la frase, no para frases completas.
- **Tablas** para cualquier comparación estructurada (config, decisiones, resultados por fase) en vez de listas prosificadas.
- **Mermaid nativo** (`flowchart`, `sequenceDiagram`, `xychart-beta`) — el sitio lo renderiza vía `mermaid.version: "10.9.0"` en `docs/_config.yml`, no hace falta imagen ni librería extra. Usa `flowchart LR` para pipelines/flujos y `xychart-beta` para comparar una métrica entre fases.
- **Toda cifra debe tener fuente**: una corrida (`make f2`, `make sweep-service`), un archivo de resultados, o una medición en el código citada con línea. Una afirmación sin número o sin fuente no entra a `evidencia-corridas.md`.
- **Limitaciones y deuda son su propia sección explícita**, nunca una omisión silenciosa — sigue el patrón `implementacion.md#8` / `experimento-e01.md` (tabla "Diferencias entre el diseño y lo construido"): declara qué se diseñó pero no se implementó, y por qué.

## Correcciones: se anotan, no se reescriben en silencio

Cuando una corrida o un hallazgo posterior invalida una conclusión previa, el patrón de este repo es **dejar rastro del cambio**, no borrar la versión anterior:
- Un callout `> **Actualización del [fecha].**` al inicio del documento explicando qué estaba mal y qué cambió (ver la cabecera de `experimento-e01.md`).
- Una tabla explícita "Qué cambió al encender la lógica de negocio" / antes-después, mostrando la afirmación vieja y la nueva lado a lado, con la advertencia de que ninguna de las dos era "un error de medición" sino correcta para lo que medía.
- Una sección de trazabilidad (`Notas de trazabilidad para la validación`) que registra qué se conservó, qué se recortó y qué falta.

Si vas a actualizar resultados existentes, sigue este patrón en vez de sobrescribir sin dejar evidencia de la versión anterior.

## Registrar una página nueva

1. Front matter obligatorio: `title` + `nav_order` (el tema `just-the-docs` arma el menú lateral solo con eso, no hay un archivo de navegación central que editar).
2. Enlázala desde `docs/index.md` → sección "Contenido" (una línea, con el link `.html`).
3. Si es un documento de primer nivel (no un detalle interno), añádela también a la tabla de "Documentación" en `README.md` (raíz), con link `.md` relativo — GitHub renderiza `.md` directo, Jekyll convierte a `.html` en el sitio publicado; no mezcles las extensiones entre ambos archivos.
4. Previsualiza con `make docs-serve` (Jekyll + bundler) antes de dar por buena la página — el mermaid y la navegación lateral no se validan solo leyendo el Markdown.

## Enlaces entre documentos

Dentro de `docs/`, los enlaces cruzados usan extensión `.html` (`experimento-e01.html`, `evidencia-corridas.html`) porque Jekyll sirve el sitio compilado. Desde `README.md` hacia `docs/`, usa la ruta del repo con `.md` (GitHub los renderiza directamente). No copies un enlace `.html` a `README.md` ni viceversa.
