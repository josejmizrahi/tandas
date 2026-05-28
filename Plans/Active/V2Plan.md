# V2 Plan — Ruul post-V1 (profundización del modelo + calidad)

> **Plan complementario activo.** Hermano de `Plans/Active/Plan.md`
> (backend canónico) y `Plans/Active/UIBottomUpPlan.md` (iOS bottom-up).
>
> Acordado 2026-05-27. **Reescrito 2026-05-27** después de feedback
> founder: el plan original quedaba en "capa de calidad" pero no
> tocaba la *profundización* (votos completos, rule engine activo,
> conexión cross-primitiva). Esta versión separa **V2 (Depth/Engine/
> Integrations)** de **V3 (Quality/Launch)**.
>
> Doctrina vigente:
> - V1 contesta: *"¿se puede coordinar un grupo aquí?"* → sí, 22/22 primitivas.
> - **V2 contesta: *"¿las primitivas trabajan juntas?"*** — votos
>   completos, rule engine corriendo, multas conectadas a dinero,
>   decisiones que mutan reglas/membresía, mandatos en cada acción.
> - V3 contesta: *"¿se siente vivo, claro y confiable a diario?"*
> - Primitivas post-V1 explícitas (Comunicación 7, Incentivos 10,
>   Cuidado 24) NO entran en V2/V3 — quedan post-launch.
> - Slices chicos, mergeables, instalables en device por sesión.

---

## 0. V1 close — 5 slices de polish (~4-5 sesiones)

V1 está al ~85% real. Estos 5 slices cierran los flows pendientes
antes de empezar V2. Cada uno tiene RPC backend ya disponible — todo
el trabajo es UX/wire en iOS.

| # | Slice | Backend (ya existe) | iOS | Tamaño |
|---|---|---|---|---|
| V1.1 | Apelación de sanción (Primitiva 11) | `dispute_sanction` + `escalate_dispute_to_vote` | Borrar `AppealSanctionView` placeholder; wire botón "Apelar" del `SanctionDetailView` → `DisputeSanctionSheet`; CTA opcional `escalateToVote` post-disputa | 1-2 h |
| V1.2 | Verify contribución (Primitiva 9) | `verify_contribution` | Swipe action en `ContributionsListView` (Aceptar/Rechazar) + badge de estado (claimed/verified/rejected) + admin gate `contribution.verify` | 3 h |
| V1.3 | Transferir propiedad (Primitiva 18) | `set_resource_ownership` | `TransferOwnershipSheet` en `ResourceDetailView` con picker `ownership_kind` (group/member/external) + member picker cuando aplique | 4 h |
| V1.4 | Estados de membresía (Primitiva 2) | `set_membership_state` | Acciones admin en `MemberDetailView`: Suspender / Reactivar / Expulsar, con razón opcional + duración para suspensión, gated por `members.suspend` / `members.remove` | 4 h |
| V1.5 | Proponer norma cultural (Primitiva 20) | `propose_cultural_norm` | Toolbar `+` en `CulturalNormsListView` que abre `EditCulturalNormView` en modo crear | 30 min |

**Done V1**: build verde, tests verdes, smoke en device de los 5 flows, push a main, V1 release tag `v1.0.0-rc`.

---

## 1. Convenciones

Las mismas que `UIBottomUpPlan.md §1`. Prefijo de commits:
- Durante V1 close: `foundation:`
- Después de `v1.0.0-rc`: `v2:` para fase Depth, luego `v3:` para Quality.

---

## 2. V2 — Depth / Engine / Integrations

> **El núcleo de lo que hace Ruul interesante.** Las primitivas
> existen aisladas (V1) pero no se conectan automáticamente. Acá
> activamos el tejido: votos con métodos reales, rule engine
> evaluando eventos, decisiones que mutan estado de otras
> primitivas, multas con flujos de pago verdaderos, mandatos que
> permiten actuar en nombre de.
>
> Estado backend actual (verificado 2026-05-27):
> - `group_decisions.method` acepta 8 métodos canónicos
>   (admin/majority/supermajority/consensus/consent/ranked_choice/
>   weighted/veto) — iOS sólo expone ~1-2.
> - `group_decisions.decision_type` acepta 11 tipos
>   (proposal/poll/election/budget/rule_change/membership/
>   sanction_appeal/mandate_grant/mandate_revoke/dissolution/other)
>   — iOS expone ~1.
> - `group_decisions.legitimacy_source` acepta 10 fuentes — iOS no
>   las muestra.
> - `rule_shapes_catalog` + `group_rule_evaluations` existen, pero
>   `evaluate_rules_for_event(...)` nunca se invoca: 0 filas en
>   `group_rule_evaluations`.
> - `mandate_id` aceptado por `record_expense`/`record_settlement`/
>   `record_pool_charge` pero iOS pasa siempre `null`.

### V2-G1 · Voting methods completos (Primitiva 16)

Hoy `ProposeDecisionSheet` solo asume mayoría simple. Backend ya
soporta los 8 métodos. **Slice**:

- Picker de `method` en `ProposeDecisionSheet` con explicación humana
  por método (Admin / Mayoría simple / Supermayoría 2/3 / Consenso /
  Consent / Ranked choice / Weighted / Veto).
- Picker de `legitimacy_source` (founder/election/committee/etc.) —
  qué legitima esta decisión.
- `VoteSheet` adaptativo por método:
  - `ranked_choice` → drag-to-reorder de opciones.
  - `consensus` → 3-state (a favor / objeto / me retiro).
  - `consent` → 2-state (consiento / bloqueo + razón obligatoria).
  - `weighted` → input numérico por opción (peso).
  - `veto` → 2-state (sin objeción / veto + razón).
- `DecisionDetailView` muestra resultados por método correctamente
  (tally diferente para ranked vs weighted vs consensus).
- Quorum enforcement real: `finalize_vote` ya está; verificar que
  respete `quorum_min` de `decision_rules`.

**Tamaño**: 3-4 sesiones.

### V2-G2 · Decision types tipados con outcome handlers

Hoy todas las decisiones son `decision_type='proposal'` (informativo,
sin side effects). Backend acepta 11 tipos. **Slice**:

- Surface en `ProposeDecisionSheet`: picker de `decision_type`,
  oculto en modo simple, expandible.
- Outcome handlers backend (RPCs nuevos cuando aplique):
  - `rule_change` → al finalize con outcome=passed, llama
    `apply_rule_change(p_decision_id)` que muta `group_rules` /
    `group_rule_versions`.
  - `membership` → al finalize, ejecuta admit/expel según outcome.
  - `mandate_grant` / `mandate_revoke` → al finalize, llama
    `grant_mandate`/`revoke_mandate` con metadatos del voto.
  - `sanction_appeal` → al finalize, si pasa → cancela sanción
    asociada (ya parcialmente conectado via dispute escalation).
  - `dissolution` → al finalize, llama `finalize_dissolution`
    si pasa.
  - `budget` → al finalize, crea el `group_obligations` /
    `pool_charges` correspondientes.
- iOS muestra el handler aplicado en `DecisionDetailView` ("Esta
  decisión modificó la regla X" / "Esta decisión revocó el mandato Y").

**Tamaño**: 4-5 sesiones (cada handler es ~1 sesión).

### V2-G3 · Rule engine activation

`evaluate_rules_for_event` existe pero **nadie la invoca**.
Resultado: las reglas son texto bonito sin consecuencias automáticas.

**Slice**:

- **Sync evaluation** post-commit en RPCs canónicas que mutan
  estado: `record_expense`, `record_settlement`, `issue_sanction`,
  `leave_group`, `finalize_vote`, `record_pool_charge`.
- **Rule shapes ejecutables**: jsonb WHEN/IF/THEN en `group_rules.shape`.
  Ej:
  ```json
  {
    "when": "obligation.overdue",
    "if":   { "days_overdue": { "gte": 7 } },
    "then": { "action": "issue_sanction", "kind": "warning" }
  }
  ```
- **Guards de recursión**: max depth = 5 (doctrina).
- **`rule_evaluations` write path**: cada evaluación se persiste
  para auditoría.
- iOS: `RuleEvaluationsView` per-rule mostrando qué disparó qué
  últimamente.
- Migration: agregar columna `shape jsonb` a `group_rule_versions`
  + helper RPCs `validate_rule_shape`, `simulate_rule_eval`.

**Tamaño**: 5-6 sesiones (el más grande de V2; toca casi todo el
backend pero unlocked enorme valor).

### V2-G4 · Sanction ↔ Money deep

Hoy: multa monetaria crea obligation → pago via settlement to pool.
Falta lo real:

- **Pago parcial**: multa $1000 → pago $500 → outstanding $500. Hoy
  funciona técnicamente pero no se muestra el progreso. UI con
  progress bar + breakdown.
- **Plan de pago**: 3 pagos mensuales acordados. RPC nuevo
  `create_sanction_payment_plan(p_sanction_id, p_installments[])` +
  recordatorios via rule engine (V2-G3).
- **Auto-pay from fund**: si el fund del grupo o un fund personal
  vinculado tiene balance, opción "Pagar desde fondo X". Reuses
  `record_settlement` con `source_resource_id`.
- **Conversión a service post-voto**: si `decision_type =
  'sanction_appeal'` resuelve con outcome=`convert`, mutar
  `sanction_kind = 'monetary' → 'repair_task'`.

**Tamaño**: 3-4 sesiones.

### V2-G5 · Mandate ↔ Action sheets (cross-cutting)

Backend de mandates está completo + RPCs de dinero aceptan
`p_mandate_id`. Hoy iOS pasa siempre null. **Slice**:

- En cada sheet de mutación (RecordExpense / RecordSettlement /
  PaySanction / RecordPoolCharge / VoteSheet / IssueSanction):
  cuando el caller tiene mandatos activos con scope relevante,
  picker "Actuar en nombre de [member]".
- `mandate_id` se popula en el RPC.
- `MoneyMovementDetailView` muestra "Hecho por X representando a Y
  con mandato Z (vence W)".
- `MemberDetailView` muestra "Mandatos activos a su favor" + "Lo
  representa: ...".

**Tamaño**: 2-3 sesiones.

### V2-G6 · Cultural Norm → Rule promotion

Hoy las cultural norms son lista paralela a las rules. Falta el
puente:

- Norm endorsada N veces puede promoverse a Rule formal.
- Sheet "Convertir esta norma en regla" que pre-popula
  `create_text_rule(...)` + cierra la norm con
  `retire_cultural_norm(reason='promoted_to_rule', metadata={rule_id})`.
- Backend: RPC `promote_norm_to_rule(p_norm_id, p_rule_type, p_severity)`
  hace ambas operaciones atómicamente.

**Tamaño**: 1-2 sesiones.

### V2-G7 · Cross-primitive search & filters

Hoy `GroupHistoryView` es feed crudo, `MembersListView` busca solo
nombres. Falta navegación lateral:

- Search global por grupo: `search_in_group(p_group_id, p_query)`
  retorna entities matching (members + resources + decisions +
  sanctions + disputes).
- `GroupHistoryView` con filtros (entity_kind chips): Dinero ·
  Decisiones · Sanciones · Disputas · Miembros · Reglas · Cultura.
- Tap en cualquier row del history pushea al detail del entity
  (deep link via `entity_kind` + `entity_id` ya disponibles).

**Tamaño**: 2 sesiones.

### V2-G8 · Engine-driven UX (consequences visible)

Cuando V2-G3 activa, hay que mostrarle al usuario qué pasó:

- Banner en `GroupHomeFeedView`: "El sistema evaluó N reglas en las
  últimas 24h". Tap → muestra qué reglas dispararon qué.
- Sheet "¿Por qué pasó esto?" en cualquier evento generado por el
  engine — explica la cadena de evaluación + qué regla aplicó.
- Surface en `RuleDetailView`: "Esta regla ha disparado N veces"
  + listado de eventos generados.

**Tamaño**: 1-2 sesiones (depende de cómo cierre V2-G3).

### V2-G9 · Vote weights por rol/contribución

`method='weighted'` ya existe en backend. Pero ¿de dónde vienen los
pesos? **Slice**:

- Opción 1: peso fijo por rol (Admin=3, Member=1, Provisional=0.5).
- Opción 2: peso proporcional a contribuciones aceptadas.
- Opción 3: peso manual definido en `decision.metadata.weights`.
- `group_decisions.weight_strategy` column (jsonb).
- iOS expone en `ProposeDecisionSheet` solo cuando method=weighted.

**Tamaño**: 1-2 sesiones.

---

## 3. V3 — Quality / Launch (lo que era V2)

Solo después de V2 (depth) cerrar. Capas transversales, no features
nuevas.

### V3-A · Sensación de vivo (Real-time + Push)
- A1 Realtime subscriptions (events / disputes / decisions).
- A2 APNs token registration + deep-link handlers.
- A3 Notification preferences en device.
- A4 Notification handlers críticos.
- **Tamaño**: 3-4 sesiones.

### V3-B · Warmth / Onboarding
- B1 Templates de grupo (Casa familiar / Departamento / Viaje / Equipo / Comunidad).
- B2 Tutorial primer grupo.
- B3 Foundation hero tarjeta cuando ready.
- B4 Memoria narrativa editorial (notes opcionales en events).
- **Tamaño**: 3 sesiones.

### V3-C · Money advanced
- C1 In-kind con valuación (warehouse case).
- C2 Subtipos resources (fund/space/asset detail).
- C3 Pool charges admin UX.
- C4 In-kind contribution flow completo.
- **Tamaño**: 3-4 sesiones. *(V2-G4 + V2-G5 absorbieron parte
  del C original.)*

### V3-D · Cross-app reach
- D1 WidgetsExtension (target nuevo).
- D2 LiveActivity / Dynamic Island (target nuevo).
- D3 App Intents / Shortcuts (target nuevo).
- D4 Spotlight indexing.
- D5 Deep-link router robusto.
- **Tamaño**: 3-4 sesiones.

### V3-E · App Store ready
- E1 Localización `.xcstrings` real.
- E2 Accessibility audit.
- E3 Avatar real upload (PhotosPicker + Storage).
- E4 Phone/Email change verificado en device.
- E5 Account deletion.
- E6 Legal (ToS + Privacy).
- E7 App Store assets.
- **Tamaño**: 4 sesiones.

### V3-F · Operacional
- F1 Sentry wired.
- F2 Analytics opt-in.
- F3 Export del grupo (JSON/PDF).
- F4 Backup automático.
- F5 Admin dashboard mini.
- **Tamaño**: 2-3 sesiones.

---

## 4. Suma actualizada

| Fase | Sesiones |
|---|---|
| V1 close (5 slices polish) | 4-5 |
| **V2 Depth/Engine/Integrations** | **22-30** |
| V3 Quality/Launch | 18-22 |
| **Total post-Foundation** | **~44-57 sesiones** |

Ritmo realista 1 sesión cada 1-2 días = 2-4 meses calendario.
Launch realista: agosto-octubre 2026.

**Nota honesta**: V2 es donde está el verdadero trabajo. V3 es
re-packaging. Saltarse V2 = app shipping sin alma (multas
desconectadas de dinero, reglas decorativas, votos triviales).

---

## 5. Orden recomendado

| Sesión | Slice |
|---|---|
| 1-5 | V1 close (V1.5 → V1.1 → V1.2 → V1.3 → V1.4) |
| 6 | **V1 release tag** `v1.0.0-rc` |
| 7-10 | V2-G1 Voting methods completos |
| 11-15 | V2-G2 Decision types con outcome handlers |
| 16-21 | V2-G3 Rule engine activation (el grande) |
| 22-25 | V2-G4 Sanction ↔ Money deep |
| 26-28 | V2-G5 Mandate ↔ Action sheets |
| 29-30 | V2-G6 Norm → Rule promotion |
| 31-32 | V2-G7 Cross-primitive search |
| 33-34 | V2-G8 Engine-driven UX |
| 35-36 | V2-G9 Vote weights |
| 37 | **V2 release tag** `v2.0.0-rc` |
| 38-41 | V3-A Real-time + Push |
| 42-44 | V3-B Warmth |
| 45-48 | V3-C Money advanced |
| 49-52 | V3-D Cross-app |
| 53-56 | V3-E App Store ready |
| 57-58 | V3-F Operacional |
| 59 | TestFlight beta |
| 60 | **v1.0.0 production** |

---

## 6. Prompt sugerido para la próxima sesión

> Continuando Ruul post-Foundation. V1 está al ~85% — quedan 5
> slices de polish documentados en `Plans/Active/V2Plan.md §0`.
> Hoy arrancamos con **V1.5 Proponer norma cultural** (el más chico,
> 30 min). Sigue convenciones de `UIBottomUpPlan.md §1` + `V2Plan.md §1`.
> Cierra cada slice con: build green + tests green + device install +
> commit + push + actualizar §7 tracking.

---

## 7. Tracking

### V1 close (~4-5 sesiones)
- [x] V1.1 Apelación de sanción (Primitiva 11) — `d147f9f2`
- [x] V1.2 Verify contribución (Primitiva 9) — `26658ae0`
- [x] V1.3 Transferir propiedad (Primitiva 18) — `6b9c07a2`
- [x] V1.4 Estados de membresía (Primitiva 2) — `9548c89c`
- [x] V1.5 Proponer norma cultural (Primitiva 20) — `7290f797`
- [x] **V1 release tag** `v1.0.0-rc` — 2026-05-27

### V2 Depth/Engine/Integrations (~22-30 sesiones)
- [~] V2-G1 Voting methods completos — sub-slices 1+2+3: propose surface con 8 methods + LegitimacySource + adaptive VoteSheet (consensus 3-state / consent 2-state / veto 2-state + admin informativa) + DecisionDetail tally por método (narrativa + buckets semánticos + threshold/quorum + admin no-ballot + block-highlight para consent/veto). Falta sub-slice 4: ranked_choice drag-to-reorder + weighted input numérico (UX adaptativa para esos dos métodos).
- [ ] V2-G2 Decision types con outcome handlers (rule_change / membership / mandate_grant / mandate_revoke / sanction_appeal / dissolution / budget)
- [ ] V2-G3 Rule engine activation (sync eval + shapes + recursion guards + audit)
- [ ] V2-G4 Sanction ↔ Money deep (pago parcial / plan de pago / auto-pay from fund / convert to service)
- [x] V2-G5 Mandate ↔ Action sheets — write: RecordExpense / RecordSettlement / PaySanction (mig 20260528020000 + read en MoneyMovementDetailView). VoteSheet + IssueSanction quedan fuera (backend `cast_vote` / `issue_sanction` no aceptan `p_mandate_id` aún; pertenecen a V2-G9 vote-weights / sanction-on-behalf con migration aparte)
- [x] V2-G6 Norm → Rule promotion — mig 20260528010000 + PromoteNormToRuleSheet
- [x] V2-G7 Cross-primitive search & filters — chip strip + searchable + tap→DeepLinkRouter (client-side, sin RPC nueva)
- [ ] V2-G8 Engine-driven UX (consequences visible)
- [ ] V2-G9 Vote weights por rol/contribución
- [ ] **V2 release tag** `v2.0.0-rc`

### V3 Quality/Launch (~18-22 sesiones)
- [x] V3-A1 Real-time subscriptions — `3a596f3c`
- [x] V3-A2 APNs registration + handlers — `e67f87ae`
- [ ] V3-A3 Notification preferences
- [ ] V3-A4 Notification handlers críticos
- [ ] V3-B1 Templates de grupo
- [ ] V3-B2 Tutorial primer grupo
- [ ] V3-B3 Foundation hero
- [ ] V3-B4 Memoria narrativa editorial
- [ ] V3-C1 In-kind valuación
- [ ] V3-C2 Resource subtype details
- [ ] V3-C3 Pool charges admin UX
- [ ] V3-D1 WidgetsExtension
- [ ] V3-D2 LiveActivity / Dynamic Island
- [ ] V3-D3 App Intents / Shortcuts
- [ ] V3-D4 Spotlight indexing
- [ ] V3-D5 Deep-link robusto
- [ ] V3-E1 Localización `.xcstrings`
- [ ] V3-E2 Accessibility audit
- [ ] V3-E3 Avatar real upload
- [ ] V3-E4 Phone/Email change verificado
- [ ] V3-E5 Account deletion
- [ ] V3-E6 Legal (ToS + Privacy)
- [ ] V3-E7 App Store assets
- [ ] V3-F1 Sentry wired
- [ ] V3-F2 Analytics opt-in
- [ ] V3-F3 Export grupo
- [ ] V3-F4 Backup automático
- [ ] V3-F5 Admin dashboard mini

### Launch
- [ ] TestFlight beta
- [ ] App Store submission
- [ ] **v1.0.0 production**

---

## 8. Fuera de scope (explícito post-launch)

- Primitiva 7 Comunicación (chat/canales)
- Primitiva 10 Incentivos gamificados
- Primitiva 24 Cuidado/Mantenimiento dedicado
- iPad / macOS layouts custom
- I18n más allá de ES + EN
- Pricing / monetización
- Marketing site / landing
- Integraciones third-party (Splitwise import, etc.)
- AI features (resumen, sugerencias)
