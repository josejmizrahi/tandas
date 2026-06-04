# F.2X — Intent-First Contextual Actions (Doctrina)

Founder-signed 2026-06-03.

---

## 1. Principio rector

**Las Quick Actions no pertenecen a la app. Pertenecen al objeto que el usuario está viendo.**

El usuario no piensa en "crear recurso", "crear reservación", "crear obligación".
El usuario piensa en "reservar Casa Valle", "registrar gasto del Viaje Japón",
"votar constructor de la nave", "asignar asientos del Mundial".

La UX refleja esa realidad: cada objeto expone exactamente las acciones que el
backend considera ejecutables para este actor, ahora mismo, en este contexto.

---

## 2. Regla fundamental

Toda acción visible debe provenir de:

```
available_actions[]   (forma canónica de 7 campos — ver §5)
```

Nunca de:

```
resource_type
event_type
decision_type
actor_subtype
obligation_kind
```

El frontend no infiere acciones. El frontend **presenta** y **enruta**.

---

## 3. Home

Las Quick Actions globales se reducen a tres acciones mínimas, idénticas en
cualquier home:

- ➕ **Crear**
- 🔍 **Buscar**
- 🤖 **Preguntar a Ruul**

Nada más. El layout de Home queda:

1. **Atención requerida** (conflictos, decisiones pendientes, pagos por cobrar/pagar)
2. **Acciones globales** (las 3 de arriba)
3. **Contextos recientes**
4. **Actividad relevante**

---

## 4. Context / Resource / Event / Decision

Cada detalle muestra una sección **⚡ Acciones rápidas** alimentada por
`available_actions[]` del RPC canónico de su dominio:

| Vista              | Fuente canónica                                              |
|--------------------|---------------------------------------------------------------|
| ContextHomeView    | `context_summary().available_actions` *(o RPC dedicado)*     |
| ResourceDetailView | `resource_detail().available_actions`                        |
| EventDetailView    | `event_detail().available_actions` *(RPC nuevo F.2X.0)*      |
| DecisionDetailView | `decision_detail().available_actions`                        |
| ObligationDetail   | `obligation_detail().available_actions`                      |
| ReservationDetail  | `reservation_detail().available_actions`                     |

El orden, las secciones y el `reason` de cada acción los dicta el backend.

---

## 5. Forma canónica `AvailableAction`

```json
{
  "action_key":            "string",
  "label":                 "string (es-MX)",
  "section":               "string (reservations | money | …)",
  "enabled":               true | false,
  "reason":                "string | null",
  "required_rights":       ["OWN", "USE", …],
  "required_capabilities": ["reservable", …]
}
```

- `enabled=false` se muestra deshabilitado con `reason` visible.
- `label` lo proporciona el backend en español (founder locale).
- iOS NO traduce ni reinterpreta `reason`.

---

## 6. `ActionPresentationCatalog` (iOS)

Vive en iOS bajo `RuulApp/Components/ActionPresentationCatalog.swift`.
Su única responsabilidad: convertir `action_key` → `(SF Symbol, flow)`.

Ejemplo:

```
"reserve"           → 📅 / CreateReservationFlow
"record_expense"    → 💰 / CreateExpenseFlow
"create_decision"   → 📝 / CreateDecisionFlow
"allocate_seats"    → 🎟 / AllocateSeatsFlow
"invite_member"     → 👥 / InviteMembersFlow
"upload_document"   → 📄 / AttachDocumentFlow
```

**Prohibido** en el catalog:
- Cualquier branch por `resource_type` / `event_type` / `decision_type`.
- Cualquier label que difiera del que mandó backend (el catalog usa `label` del
  backend; el catalog sólo agrega ícono y destino de navegación).

---

## 7. Navigation Rule

El router de Quick Actions es un `switch` puro sobre `action_key`. Cada caso
abre un flow específico. No hay heurísticas, no hay tablas paralelas.

```
ActionRouter.open(actionKey: String, context: ActionContext) -> some View
```

`ActionContext` carga el objeto fuente (`resource_id` / `event_id` / `decision_id`
/ `context_actor_id`) para que el flow tenga lo que necesita.

---

## 8. Frontend Rules (Hard No)

Prohibido en el shell, en cualquier feature:

```swift
if resource.type == .house  { … }
if event.type    == .trip   { … }
if decision.type == .vote   { … }
```

Permitido:

```swift
ForEach(detail.availableActions) { action in
    QuickActionButton(action, onTap: { router.open(action.actionKey, …) })
}
```

---

## 9. Escalabilidad

Si mañana aparece un nuevo tipo (Yate, Membresía, Licencia, NFT, Asiento,
Cuenta de inversión, Programa de lealtad…), **no se modifica la UI**.

Sólo se modifican:
- `resource_capabilities` (backend)
- `available_actions` (backend)
- Si la acción es nueva: una entrada nueva en `ActionPresentationCatalog`.

---

## 10. Definition of Done

1. Home tiene únicamente acciones globales mínimas (3).
2. ContextHomeView muestra acciones contextuales desde `available_actions`.
3. ResourceDetail muestra acciones contextuales desde `available_actions`.
4. EventDetail muestra acciones contextuales desde `available_actions`.
5. DecisionDetail muestra acciones contextuales desde `available_actions` (ya
   shipped en R.2S.2).
6. ObligationDetail muestra acciones contextuales desde `available_actions` (ya
   shipped en R.2R).
7. ReservationDetail muestra acciones contextuales desde `available_actions`
   (ya shipped en R.2S.2).
8. No quedan ramificaciones por `resource_type` / `event_type` / `decision_type`.
9. Existe `ActionPresentationCatalog` con cobertura para todos los `action_key`
   que el backend emite hoy.
10. Navegación basada exclusivamente en `action_key` vía `ActionRouter`.
11. La UI escala sin cambios al agregar nuevos tipos de recursos.

---

## 11. Slicing

| Slice  | Alcance                                                                       |
|--------|-------------------------------------------------------------------------------|
| F.2X.0 | Backend: `context_available_actions` + `event_available_actions` (o embed en summary/detail). |
| F.2X.1 | iOS: `ActionPresentationCatalog` + `QuickActionsSection` + `ActionRouter` skeleton. No wire de comportamiento aún. |
| F.2X.2 | iOS: ContextHomeView rebuild (Atención / Globales / Recientes / Actividad).   |
| F.2X.3 | iOS: ResourceDetailView "⚡ Acciones rápidas" wired (extiende R.2S.2).         |
| F.2X.4 | iOS: EventDetailView "⚡ Acciones rápidas" wired.                              |
| F.2X.5 | Cleanup: erradicar todo `if type == …` residual; doctrina lock + smoke test. |

---

## 12. Resultado esperado

Ruul deja de comportarse como un ERP basado en pantallas y tipos.
Se convierte en un sistema guiado por intención: cada objeto expone exactamente
las acciones relevantes para el usuario según sus permisos, capacidades y
contexto.
