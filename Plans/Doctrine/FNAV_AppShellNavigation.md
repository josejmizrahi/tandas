# F.NAV — App Shell Navigation (Doctrina)

Founder-signed 2026-06-04. **Deroga formalmente** las doctrinas previas:

- `doctrine_r0h_no_yo_tab` (2026-06-01)
- `doctrine_r1_context_first` (2026-06-01)
- Cualquier línea de `CLAUDE.md` que diga "sin tabs globales".

Motivo: el producto evolucionó. Backend ya soporta actor/context/available_actions/
activity_feed/hierarchy/subscriptions. La UX correcta NO es ocultar tabs —
es exponer **contextos y atención** como ciudadanos de primera clase.

---

## 1. Principio rector

Ruul NO es una colección de primitivas (recursos / eventos / decisiones / dinero).
Ruul ES una herramienta para coordinar **familias, empresas, proyectos, viajes,
patrimonios, comunidades**.

La navegación principal debe responder:

- **¿Qué requiere mi atención?**
- **¿Qué estoy organizando?**

No: "¿Qué tabla quiero abrir?".

---

## 2. Tab Bar global (5 tabs)

| Tab | Propósito |
|---|---|
| 🏠 **Home** | Atención global cross-context |
| 📁 **Contextos** | Todo lo que organizo (favoritos / recientes / todos) |
| ➕ **Crear** | Iniciar una intención (no una primitiva) |
| 🔔 **Actividad** | Señales relevantes (feed personalizado R.3A) |
| 👤 **Yo** | Perfil, suscripciones, trust graph, configuración |

ContextHome deja de ser raíz. Vive **dentro** del flujo de Contextos (y se abre
desde Home / Activity / Search también).

---

## 3. Home (global, NO por contexto)

Layout fijo (4 secciones):

1. **⚠ Requiere tu atención** — máx 5 items, CTA directa por card.
2. **Continuar** — contextos recientes, cards horizontales.
3. **⚡ Acciones globales** — exactamente 3: ➕ Crear · 🔍 Buscar · 🤖 Preguntar a Ruul.
4. **Actividad relevante** — timeline resumido (R.3A `activity_feed`).

Cada item de atención lleva `cta_action_key` que dispara `ActionRouter` (F.2X).

---

## 4. Contextos (pantalla dedicada)

- Header: "Mis Contextos".
- ⭐ **Favoritos** (sticky arriba).
- **Todos** (lista completa).
- Cada card: nombre · tipo · miembros · actividad reciente.
- Tap → abre el Context Home dentro del flujo de Contextos.

---

## 5. Context Switcher (full sheet)

Se conserva el switcher PERO se rediseña.

- Antes: dropdown pequeño en toolbar.
- Ahora: tap sobre el título del contexto activo → **sheet completa** (estilo
  Apple Maps / Music / Notion):
  - Cambiar contexto.
  - Favoritos / Recientes / Todos.
  - Acción inferior: ➕ Crear contexto.

---

## 6. Central "+" (intent-first sheet)

Title: "¿Qué quieres hacer?".

Opciones:
- 📅 Programar algo
- 💰 Registrar movimiento
- 📝 Crear propuesta
- 📄 Subir documento
- ➕ Crear contexto

Sin exponer primitivas (`Crear recurso` / `Crear evento` / etc.).

---

## 7. Perfil (Yo)

Secciones:
- Mi actividad
- Mis contextos
- Mis recursos
- Mis suscripciones
- Mi red de confianza
- Configuración

---

## 8. Reglas de UX (idénticas a F.2X)

Prohibido `if resource.type == ...` / `if event.type == ...` / `if decision.type == ...`.
Permitido: `available_actions` del backend.

---

## 9. Escalabilidad

Si mañana aparecen nuevos tipos (asientos / NFTs / licencias / yates / membresías
/ acciones / criptowallets), la navegación NO cambia. Sólo cambian
`capabilities` + `available_actions` en backend. Y se añaden entradas a
`ActionPresentationCatalog` si los keys son nuevos.

---

## 10. Definition of Done

1. Tab bar global con las 5 tabs.
2. Home global basado en atención.
3. Contextos en pantalla propia con favoritos/recientes/todos.
4. Context Switcher rediseñado como full sheet.
5. Botón central abre sheet intent-first.
6. Context Home usa `context_available_actions` (✅ F.2X.2).
7. Cero acciones hardcodeadas por tipo (✅ F.2X.5).
8. Navegación escalable a nuevos resources.
9. UX alineada con Apple HIG.
10. Ruul se percibe como sistema de coordinación, no como ERP.

---

## 11. Slicing aprobado

| Slice | Alcance |
|---|---|
| **F.NAV.0** | Backend foundation: `attention_inbox()`, `mark_context_favorite()`, `mark_context_visited()`, `list_context_favorites()`, `list_recent_contexts()`, `actor_context_preferences` table, smokes. |
| F.NAV.1 | iOS Tab Shell — 5 tabs, stubs seguros, fallback a ContextShell si algo falla. |
| F.NAV.2 | HomeView real (4 secciones), cards CTA, intent-first router. |
| F.NAV.3 | ContextsView (favoritos / recientes / todos). |
| F.NAV.4 | Context Switcher full sheet (rediseño). |
| F.NAV.5 | Central "+" intent-first sheet. |
| F.NAV.6 | Yo/Profile tab consolidado. |
| F.NAV.7 | Cleanup + doctrine lock + archivar R.0H/R.1A + actualizar CLAUDE.md. |

---

## 12. Restricciones founder

- No romper flujos existentes. Cada slice con build verde.
- Sin lógica doctrinal en frontend. Home consume backend.
- Tabs son navegación, no modelo de datos.
- Incrementalmente — fallback a ContextShell mientras F.NAV.2-6 está incompleto.
