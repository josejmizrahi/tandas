# Ruul AI — FoundationModels Integration Guide

> **Leer ANTES de tocar cualquier feature de AI en Ruul.**
> Esta carpeta contiene servicios on-device de Apple Intelligence usando
> el framework **FoundationModels** (iOS 26+).

---

## Tabla de contenido

1. [Doctrina founder](#doctrina-founder-no-negociable)
2. [Servicios shippeados](#servicios-shippeados)
3. [Patrón canónico](#patrón-canónico)
4. [Cómo agregar una nueva feature AI](#cómo-agregar-una-nueva-feature-ai)
5. [Guided vs Free generation](#guided-vs-free-generation-cuándo-usar-cada-una)
6. [Limitaciones del modelo](#limitaciones-del-modelo-saber-de-memoria)
7. [Availability check (4 razones)](#availability-check-las-4-razones)
8. [Errores comunes y troubleshooting](#errores-comunes-y-troubleshooting)
9. [Referencias](#referencias)

---

## Doctrina founder (NO negociable)

> **El modelo NUNCA decide ni modifica datos del backend. Solo pre-llena
> formularios o resume datos que ya existen. El usuario confirma con tap
> antes de que cualquier RPC se dispare.**

Cualquier feature que rompa esta doctrina (e.g., AI que llama RPCs sin
confirmación del usuario, AI que "ejecuta" acciones) **requiere firma
explícita del founder antes de empezar**. El framework de FoundationModels
soporta `Tool` calling que permite eso, pero NO está habilitado en Ruul hoy.

### Por qué importa

Ruul administra dinero, derechos, decisiones, propiedad. Un error del modelo
podría:
- Crear una multa indebida.
- Aprobar una decisión sin votos reales.
- Transferir un derecho sin consentimiento.

Por eso: **el modelo asiste, el humano decide**. Punto.

---

## Servicios shippeados

| Archivo | Feature | Tipo | Wire UI |
|---|---|---|---|
| `RuleSuggestionService.swift` | Sugerir reglas desde lenguaje natural | Guided (`@Generable`) | `CreateRuleWizard.swift` (sección `aiSuggestionSection`) |
| `IntentSuggestionService.swift` | Clasificar intent (qué form abrir) | Guided (`@Generable`) | `CreateIntentSheet.swift` (sección `aiIntentSection`) |
| `ActivitySummaryService.swift` | Resumir feed de actividad | Libre (texto) | `MyActivityFeedView.swift` (sección `aiSummarySection`) |

Cada uno tiene:
- Un shape `*Suggestion.swift` con `@Generable` (excepto Summary que es libre).
- Un `*Service.swift` con el wrapper `@Observable @MainActor`.

Lee `RuleSuggestionService.swift` como referencia canónica del patrón guided,
y `ActivitySummaryService.swift` como referencia para generación libre.

---

## Patrón canónico

### 1. Shape `@Generable` (solo para guided generation)

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(FoundationModels)
@available(iOS 26.0, *)
@Generable
public struct MySuggestion: Sendable, Equatable {
    @Guide(description: "Descripción precisa de qué debe llenar el modelo. Tono imperativo, sé específico sobre rangos y defaults.")
    public let someField: String

    @Guide(description: "Si no aplica, devolver 0. Rango válido: 5-120.")
    public let amount: Int
}
#endif
```

**`@Guide` es lo más importante.** Son las "instrucciones por campo". El
modelo las usa para llenar correctamente. Reglas:

- Tono **imperativo** ("devuelve…", "usa…", "elige…").
- **Especifica rangos** ("entre 5 y 120").
- **Especifica defaults** ("0 si no aplica", "cadena vacía si no aplica").
- **Idioma del output** ("en español, máximo 8 palabras").

### 2. Service wrapper

```swift
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@available(iOS 26.0, *)
@MainActor
@Observable
public final class MySuggestionService {
    public enum Phase: Sendable, Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
        #if canImport(FoundationModels)
        case loaded(MySuggestion)
        #endif
    }

    public private(set) var phase: Phase = .idle

    #if canImport(FoundationModels)
    private let model = SystemLanguageModel.default
    #endif

    public init() {
        refreshAvailability()
    }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = model.availability { return true }
        return false
        #else
        return false
        #endif
    }

    public func refreshAvailability() {
        #if canImport(FoundationModels)
        switch model.availability {
        case .available:
            if case .unavailable = phase { phase = .idle }
        case .unavailable(.deviceNotEligible):
            phase = .unavailable(reason: "Este dispositivo no soporta Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            phase = .unavailable(reason: "Activa Apple Intelligence en Ajustes.")
        case .unavailable(.modelNotReady):
            phase = .unavailable(reason: "El modelo se está descargando.")
        case .unavailable:
            phase = .unavailable(reason: "Sugerencias no disponibles ahora.")
        }
        #else
        phase = .unavailable(reason: "Sugerencias no disponibles en esta versión.")
        #endif
    }

    public func reset() {
        phase = isAvailable ? .idle : phase
    }

    #if canImport(FoundationModels)
    public func suggest(prompt userPrompt: String) async {
        guard isAvailable else { return }
        let trimmed = userPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        phase = .loading

        let instructions = """
            Eres un asistente que [...]. Hay N opciones:
            - opt1: descripción.
            - opt2: descripción.
            ...

            Reglas estrictas:
            1. ...
            2. ...
            """

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: userPrompt,
                generating: MySuggestion.self
            )
            phase = .loaded(response.content)
        } catch {
            phase = .failed(message: UserFacingError.from(error).message)
        }
    }
    #endif
}
```

### 3. UI consumer

```swift
@State private var suggestionService = MySuggestionService()
@State private var aiPromptText = ""

// En el body:
Section {
    TextField("Describe…", text: $aiPromptText, axis: .vertical)
        .disabled(!suggestionService.isAvailable)

    switch suggestionService.phase {
    case .idle:
        Button {
            Task { await suggestionService.suggest(prompt: aiPromptText) }
        } label: {
            Label("Sugerir", systemImage: "sparkles")
                .symbolRenderingMode(.hierarchical)
        }
        .disabled(aiPromptText.isEmpty || !suggestionService.isAvailable)

    case .loading:
        HStack { ProgressView(); Text("Pensando…") }

    case .loaded(let suggestion):
        VStack(alignment: .leading) {
            Text(suggestion.someField)
            Button("Aplicar") {
                applySuggestion(suggestion)  // <- llena los @State del wizard
                suggestionService.reset()
            }
        }

    case .unavailable(let reason):
        Label(reason, systemImage: "sparkles.slash")
            .foregroundStyle(.secondary)

    case .failed(let message):
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
    }
} header: {
    Label("Asistente", systemImage: "sparkles")
}
```

**Recuerda:** el botón "Aplicar" llena los `@State` del wizard manual.
NUNCA dispara RPCs directos. El usuario tapea "Crear" como en el flujo manual.

---

## Cómo agregar contexto a una feature AI — Doctrina pre-aggregation (R.6.AI.5)

> **Founder-firmada 2026-06-09**: pre-aggregation > tool calling.

Ruul siempre sabe qué slice del contexto necesita el modelo para sugerir.
En vez de pagar el costo de tool calling (~1200 tokens en definitions y
outputs entre roundtrips), pre-fetch UNA vez via `context_summary()` y
inyecta como prefix compacto del prompt. Una sola RPC, prefix ~200 tokens,
budget de 4096 tokens protegido.

Tool calling queda reservado para casos genuinamente agénticos (modelo
decide entre N caminos posibles), no para fetch predecible. Hoy NO usamos
tool calling.

**Patrón canónico:**

```swift
let snapshot = try await RuulAIContext.compact(
    rpc: rpc,
    contextId: contextId,
    fields: RuulAIContext.forXxxFeature  // preset por feature
)
let promptBody = snapshot.prefix.isEmpty
    ? userPrompt
    : "\(snapshot.prefix)\n\nPetición del usuario: \(userPrompt)"

let session = LanguageModelSession(instructions: instructions)
let response = try await session.respond(
    to: promptBody,
    generating: MyGenerable.self
)
phase = .loaded(response.content, considered: snapshot.considered)
```

La UI surface `snapshot.considered` como chips "DATOS CONSIDERADOS" para
transparencia (ver `CreateRuleWizard.consideredChip`).

**Presets por feature** en `RuulAIContext.swift`. Agrega uno nuevo cuando
crees una feature AI nueva.

---

## Cómo agregar una nueva feature AI

Receta paso a paso:

1. **Pide firma del founder** si la feature toca dinero/derechos/decisiones.
2. **Decide guided vs libre** (ver sección siguiente).
3. **Crea `MySuggestion.swift`** (solo guided) en `RuulCore/AI/` con
   `@Generable` + `@Guide` hints. Usa `RuleSuggestion.swift` como template.
4. **¿Necesita contexto?** Si sí, agrega un preset en `RuulAIContext` y
   usa el patrón pre-aggregation arriba. Si no, ignora.
5. **Crea `MySuggestionService.swift`** copiando el patrón canónico de
   `RuleSuggestionService` (incluye Phase.loaded con `considered: []`).
6. **Wire la UI** en la vista correspondiente:
   - `@State private var myService = MySuggestionService()`
   - Section con switch sobre `myService.phase`.
   - Si tu feature usa contexto, reusa el patrón de chips de
     `CreateRuleWizard.consideredChip`.
   - Botón "Aplicar" llena los `@State` del wizard manual.
7. **Probar en device** con Apple Intelligence ON.
8. **Probar el path unavailable**: ir a Ajustes → desactivar Apple
   Intelligence → reabrir → verificar que el copy aparece y el flujo
   manual sigue funcionando.

---

## Guided vs Free generation: cuándo usar cada una

### Guided (`@Generable`)

**Úsalo cuando:** el output va a llenar campos estructurados.

Ejemplos:
- Sugerir parámetros de una regla (`templateKey`, `amount`, `threshold`).
- Clasificar intent (`intentKey`).
- Parsear "le debo 500 a Moshe" en `{ amount: 500, counterparty: "Moshe" }`.

Ventajas:
- Garantía de tipo: el response viene en tu Swift struct, no en JSON crudo.
- El modelo se enfoca en los campos definidos.

### Libre (sin `@Generable`)

**Úsalo cuando:** el output es prosa para mostrar al usuario.

Ejemplos:
- Resumir actividad ("Esta semana registraste 3 gastos en Cena Semanal…").
- Explicación de por qué se aplicó una regla.
- Caption descriptivo de un contexto.

Ventajas:
- Más natural, menos restringido.
- Mejor para storytelling.

Desventajas:
- No hay garantía de formato. Si necesitas parsear, usa guided.

---

## Limitaciones del modelo (saber de memoria)

| Limitación | Detalle | Workaround |
|---|---|---|
| **Context window: 4096 tokens** | Input + instructions + response cuentan | Pre-agrega inputs en strings compactos (ver `ActivitySummaryService.buildSummaryInput`) |
| **Una sesión = un request a la vez** | Llamar 2 veces sin esperar crashea | Crear nueva session cada vez, o checkar `isResponding` |
| **No es bueno en matemática precisa** | "¿Cuánto es 47 × 83?" da resultados erróneos | Pre-calcula con código, pasa el resultado al modelo |
| **No es bueno en conteo exacto** | "¿Cuántas 'b' hay en 'bagel'?" falla | No le pidas conteo; cuenta tú |
| **No es bueno en lógica condicional compleja** | Decisiones de varios pasos pueden alucinar | Mantén guided generation simple |
| **No es bueno en generar código** | No le pidas Swift, Python, etc. | Para eso usa Claude o GPT-4 server-side |
| **Soporta idiomas limitados** | Es excelente en es/en, no en todos | El session puede lanzar `unsupportedLanguageOrLocale` |
| **Modelo no determinista** | Misma prompt puede dar respuestas distintas | Para tests, no asumas igualdad exacta |

---

## Availability check: las 4 razones

`SystemLanguageModel.default.availability` puede devolver:

```swift
.available
.unavailable(.deviceNotEligible)             // iPhone < 15 Pro / 16
.unavailable(.appleIntelligenceNotEnabled)   // OFF en Ajustes
.unavailable(.modelNotReady)                 // Descargando (puede tardar horas)
.unavailable(...)                            // Otros (network, etc.)
```

**El servicio DEBE mapear las 4 a copy honesto en español.** Mira la
implementación en `RuleSuggestionService.refreshAvailability()`.

**Cuándo refrescar availability:**
- En el `init()` del service.
- Cuando el `scenePhase` regresa a `.active` (el user pudo activar AI
  mientras estaba en Ajustes).
- Después de un timeout largo si `phase == .unavailable(.modelNotReady)`.

---

## Errores comunes y troubleshooting

### "El servicio devuelve siempre `.failed`"

Causa común: el `@Guide` no describe bien el output esperado, y el modelo
genera algo que no encaja con el shape.

Fix:
1. Lee los logs (Instruments Foundation Models tool).
2. Mejora los `@Guide` con rangos válidos y defaults explícitos.
3. Si persiste, agrega ejemplos few-shot en el `instructions`.

### "El modelo devuelve campos vacíos o 0 cuando no debería"

Causa: el system prompt no es claro sobre qué campos llenar.

Fix: en el `instructions` agrega regla explícita:
```
Reglas estrictas:
1. Llena SÓLO los campos relevantes a la categoría elegida.
2. Usa 0 (o cadena vacía) en los demás.
```

### "La UI no actualiza después de `phase = .loaded`"

Causa: `@Observable` requiere acceso desde main actor. Si llamas desde un
`Task.detached`, no funciona.

Fix: asegura que `suggest()` está marcado `@MainActor` o llama desde un
`Task { @MainActor in … }`.

### "`exceededContextWindowSize` error"

Causa: el input total (instructions + user prompt + schema) excede 4096
tokens.

Fix:
1. Acorta el `instructions`.
2. Pre-agrega el input del usuario en algo más compacto.
3. Reduce campos del `@Generable` shape.

### "El modelo se queda en `.loading` para siempre"

Causa: probablemente el session se está esperando en otra task. O Apple
Intelligence se desactivó mientras corría.

Fix:
1. Re-checkea `model.availability` antes del request.
2. Agrega timeout con `withTimeout()` helper si es crítico.

### "Funciona en simulator pero no en device"

Causa: el simulator falsea Apple Intelligence como `.available` siempre.
En device real puede estar `.modelNotReady` por horas mientras descarga.

Fix: prueba en device real antes de declarar shipped.

---

## Referencias

### Apple Documentation
- [FoundationModels framework](https://developer.apple.com/documentation/foundationmodels)
- [Generating content and performing tasks](https://developer.apple.com/documentation/foundationmodels/generating-content-and-performing-tasks-with-foundation-models)
- [Generating Swift data structures with guided generation](https://developer.apple.com/documentation/foundationmodels/generating-swift-data-structures-with-guided-generation)
- [TN3193: Managing the on-device foundation model's context window](https://developer.apple.com/documentation/Technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)

### WWDC sessions
- WWDC25 #286 — Meet the Foundation Models framework
- WWDC25 #301 — Deep dive into the Foundation Models framework
- WWDC25 #259 — Code-along: Bring on-device AI to your app

### Acceptable Use
- [Acceptable use requirements for Foundation Models framework](https://developer.apple.com/apple-intelligence/acceptable-use-requirements-for-the-foundation-models-framework)

### Internal Ruul
- `RuleSuggestionService.swift` — referencia canónica guided generation.
- `ActivitySummaryService.swift` — referencia canónica generación libre.
- `Plans/Doctrine/` — doctrinas founder firmadas (consulta antes de cambiar
  comportamiento crítico).

---

## Checklist antes de shippear una feature AI

- [ ] Firma del founder si toca dinero/derechos/decisiones.
- [ ] `@Generable` con `@Guide` específico por campo (si guided).
- [ ] Service con Phase enum + availability check con las 4 razones.
- [ ] `#if canImport(FoundationModels)` gates en service y shape.
- [ ] UI con switch sobre Phase (idle/loading/loaded/failed/unavailable).
- [ ] Botón "Aplicar" llena `@State` del wizard manual, NO dispara RPC.
- [ ] Copy honesto cuando `unavailable` (sin esconder el feature).
- [ ] Probado en device REAL con Apple Intelligence ON.
- [ ] Probado en device REAL con Apple Intelligence OFF (flujo manual sigue).
- [ ] Input compacto (no inflar context window).
- [ ] Cero RPCs disparadas por el modelo directamente.

---

*Última actualización: 2026-06-08. Mantenido cuando se agreguen features.*
