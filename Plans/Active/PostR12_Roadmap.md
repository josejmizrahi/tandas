# Post-R.12 Roadmap — Plan vivo (single source 2026-06-16)

**Fecha:** 2026-06-16
**Status:** 🟢 Motor cerrado · UX completion + Honesty Sweep en curso
**Reemplaza:** `Plans/Completed/PreR6_Roadmap.md` (cerrado en R.5V.5 ✅ del 2026-06-07; no reflejaba R.9.*/audits/FE 1-9/R.10/R.11/R.12 shipped después)

## Founder lock firmado 2026-06-16

> **(1) Primero quiero que los flujos estén completos y conectados.**
> **(2) Y que no haya nada que no tenga que estar.**
> **Tanto en el frontend como en el backend.**

Dos criterios congelados. Las "3 capas estructurales" (Compliance/Billing/Assurance) salen del scope inmediato. **Antes de cualquier feature nueva** se cierra:

1. **Completitud de flujos** — cero ⚠️ founder smoke en device. Toda creación auto-pushea al detail. Toda action visible tiene destino real. Toda atención del inbox abre el flow correcto.
2. **Honesty Sweep frontend+backend** — cero placeholder "Próximamente" sin backend ready · cero action_key sin handler · cero widget/section/capability/RPC del catalog sin consumer real · cero sistema duplicado (3 atenciones → 1).

---

## 0. Estado real (verificado contra código 2026-06-16)

**El motor está cerrado.** No hay grieta estructural pendiente. Lo que falta es **UX completion** sobre flujos tipados y un par de gaps de routing.

### Shipped completo (verificado por migración + RPC client + view)

| Capa | Shipped |
|---|---|
| **Backend MVP2 core** | mvp2_000…mvp2_009 · R.2D-T · R.4B-D · R.5A/B · R.5W · R.5Y · R.5Z fixes · R.6 A-H · R.7 A-H + R.7.x · R.8 A-C · R.9 A-J · 20 audit migrations · FE 1-9 · R.12 A/F/G |
| **iOS doctrina** | 3 gates (Session/Person/MainTabShell) · 5 tabs F.NAV · stores por pantalla · `ActionPresentationCatalog` + `ActionRouter` · `AttentionDispatcher` único · `RPCErrorMapper`/`UserFacingError` · `RuulDetailHero`/`RuulStatusBadge`/`RuulEmptyState`/`RuulErrorState`/`RuulLoadingState`/`RuulSkeletonList`/`DynamicForm` · Subtype Picker R/E/D field schemas · Liquid Glass iOS 26 |
| **Auditabilidad** | Activity events append-only · `_emit_activity` en RPCs mutantes (R.9.A) · activity_event_catalog · idempotencia `p_client_id` en record_fine/record_game_result (R.9.B) · execute_decision/execute_governance_action con `for update` locks |
| **Dinero con autoridad backend** | Split server-side `p_split_basis` event_weights con guests + plus_count (R.9.C) · ledger completo (R.9.D mappings expense/payment/settlement/fine/contribution/payout/game_result) · novación viva R.2N · settlement handshake 2-vías + apelación R.5Z.fix |
| **Pools R.8** | A schema + B contribute + C resolve (winner_takes_all/equity_target/proportional FE.8) · pool_account_detail + preview · iOS PoolDetailView + PoolDetailStore |
| **Governance R.7** | Camino A (catalog 12 rows + idempotency) + B (alias resolver + data-driven policy + request_governance_action sha1) + C (execute PUSH NEVER raises + AFTER UPDATE trigger) + D (PULL gate `_aa_apply_governance_mode`) + iOS (ActionMode + DecisionDetailView wire) + R.7.x (4 RPCs canónicos set_membership_state/transfer_resource_ownership/archive_rule/forgive_obligation) |
| **Rule Engine R.6** | A idempotency + emit_attention sink · B trigger auto-dispatch · C pg_cron 4 detectores · D DSL closed-grammar validator · E iOS Rules · F seeds demo |
| **Resource model** | Subtype Picker UX D (Class → Subtype → Form) · 17 classes / 28 subtypes seedeados · 9 polymorphic renderers (Generic/Financial/RealEstate/Vehicle/Equipment/DigitalAsset/Document/Trip/Space) · `class/subtype` taxonomy alineado · R.12.A field_schemas declarativos · DynamicForm engine |
| **Event model** | event_subtype field_schemas (R.12.F) · DynamicForm en Create/Edit Event · add/remove_event_participants · host_confirm_participant · event_guests RPCs · plus_count · update_calendar_event metadata |
| **Document model** | inmutables (Documents V2) · archive_document · supersedes relation · register_document canonical emit `document.created` · QuickLook + ShareSheet · R.12.G CHECK alineado con catalog (cert/contract/policy/receipt/statement/legacy) · DynamicForm en AttachDocumentView |
| **UX founder loop** | R.5Z smoke iPhone JJ 2 fixes shipped (Money tab rebuild + Reservation conflict NavigationLink) · 0 ❌ blockers · 8 ⚠️ documentados |
| **UI Apple-native** | R.5V.0-2 doctrina + 8 componentes Ruul* · R.5V.3-5 (HomeView/ContextDetailV2/ResourceDetailV2 migrados) · R.10 polish ResourceDetail · R.11 Home+Contextos rediseño · zero hardcoded colors |
| **Hygiene** | function search_path explicit · 20 audit migrations (FK indexes hot-path · child tables audit · RLS membership fastpath · policy roles normalization · partition-ready PKs · money_splits invariant) |

### Verdict 2026-06-16

> El plan PreR6_Roadmap.md cerró en R.5V.5 ✅. **Todo lo que listaba como pendiente** (R.5Z + R.6 + Documents V2 + Subtype Picker + R.5W.fix + V.6-V.8) **está shipped**, más capas enteras agregadas después (R.7.x · R.8.A-C · R.9.A-J · 20 audits · FE 1-9 · R.10/R.11/R.12).
>
> El founder sentía estar atorado por **falta de plan vivo**, no falta de progreso. Este documento es el plan vivo.

---

## 1. Backlog activo (verificado, founder smoke R.5Z + post-R.12 + lock 2026-06-16)

Ordenado por **fit con los 2 criterios founder**: (1) completitud de flujos + (2) cero exceso. Las "3 capas estructurales" (Compliance/Billing/Assurance) reportadas en revisión Vision.md quedan **fuera de scope** hasta firma adicional.

### Tier R.13 — Honesty Sweep (frontend+backend, cumple AMBOS criterios founder)

Slice cohesivo de 1-2 sesiones que cierra "nada que no tenga que estar". Frontend filtra defensivo lo que no puede manejar; backend elimina del catalog lo que no tiene path real; ambos quedan en paridad.

**iOS — eliminar exceso visible al user:**

| ID | Item | Acción | Effort |
|---|---|---|---|
| R.13.A | 8 placeholders "Próximamente" inventariados | Por cada uno: si backend ready → wirear flow (PoolResolveView, archive_context, set_event_participant_plus_one). Si NO ready → ESCONDER del UI (no row, no button). NUNCA mostrar "Próximamente" como copy estructural. | M (4-6h) |
| R.13.B | 12+ action_keys sin handler | Gating defensivo en TODOS los detail views: filtrar `availableActions` con `ActionRouter.knownActionKeys` whitelist. iOS NO muestra button que no puede ejecutar. | S (2-3h) |
| R.13.C | `R.5Z.fix.CC.2` AttentionDispatcher catalog completo | Extender dispatcher para `rule_attention_items.*`, `obligation.overdue`, `document.expiring`, `reservation.starting_soon`, `right.expiring` (R.6.A/R.6.C ya emiten desde backend) → push a ContextDetailV2/RuleDetail/ObligationDetail/DocumentDetail/ResourceDetail según `cta_target_type`. Eliminar `UnsupportedAttentionView`. | M (2-3h) |

**Backend — eliminar exceso del catalog:**

| ID | Item | Acción | Effort |
|---|---|---|---|
| R.13.D | Catalog rows sin path real (`execution_rpc=null` sin handler iOS) | Mig: borrar del `action_catalog` y `governance_action_catalog` toda row sin destino. O marcar `is_active=false` con razón en comment. | S (1 mig) |
| R.13.E | 6 capabilities NO_EFFECT (`approval_required`/`depreciable`/`monetary`/`rentable`/`sellable`/`usable`) | Si UI no las renderea ni RPC las consulta: drop del catalog. Si alguna sí se usa → marcar y documentar. | S (1 mig) |
| R.13.F | 10 widgets INERT + 44 section rows INERT (R.5X audit) | Auditar contra `WidgetCatalog.swift`/section render path. Eliminar del catalog rows sin renderer. | M (1-2 migs + iOS verify) |
| R.13.G | `audit_8_rpc_deprecation_register` cleanup | Revisar wrappers marcados deprecated; eliminar los ya consolidados. | S (1 mig) |
| R.13.H | 3 sistemas atención paralelos → 1 | Congelar oficialmente `notifications` R.4D (comment en tabla "deferred hasta push real"). Confirmar `attention_inbox()` UNION cubre `rule_attention_items` (R.6.A) + invitaciones + votos + governance pending. iOS solo lee `attention_inbox()`. | M (1 mig + iOS audit) |
| R.13.I | `activity_event_catalog` gap closure verificación | Smoke `_smoke_r13_activity_coverage` que asserte: TODO RPC del catalog emite un event_type listado en `activity_event_catalog`. | S (1 mig smoke) |

**DoD R.13 (founder firma):**
- iPhone JJ install: cero "Próximamente" visible · cero action que no abre destino · cero atención que cae a Unsupported.
- Backend smoke: cero catalog row sin path · cero RPC deprecated en uso · `attention_inbox()` única fuente.
- Founder firma: *"no veo nada que no debería estar"*.

### Tier R.5Z.fix (UX completion post-Honesty Sweep)

Después de R.13, los 8 ⚠️ del founder smoke quedan trabajables sin ruido:

| ID | Slice | Evidencia | Effort |
|---|---|---|---|
| **P0.1** | `R.5Z.fix.1` post-create auto-push | Sheets Create Context/Resource/Event/Decision/Obligation no pushean al detail recién creado · Founder Flow #1/#2.c | M (~6h sweep) |
| **P0.2** | `R.5Z.fix.3` invitados pre-accept en MembersListView | `MembersListView` filtra `status='active'`; invitados invisibles para inviter | S (1h) |
| **P0.3** | `R.5Z.fix.10.a` `intent.document` en CreateIntentSheet | Wire `AttachDocumentView` (pattern análogo `intent.obligation` shipped) | S (1h) |

### Tier P1 — typed flows + slice mayores (medium, iOS-only o iOS+backend small)

| ID | Slice | Evidencia | Effort | Memo |
|---|---|---|---|---|
| **P1.1** | **D.PICKER** decisión target | `CreateDecisionView` 539 LOC solo crea free-floating; backend `governance_actions.target_type/id` ya soportado (R.7.B + R.7.x.iOS shipped `df255283`) | L iOS-only (1 sesión) | Founder smoke Flow #9 — decisiones desconectadas del modelo |
| **P1.2** | **R.RES.POLICY** reservation_policy por resource subtype + UX Airbnb | Hoy DatePicker genérico para todo · Founder espera día (casa) vs partido (palco) vs hora (vehículo) · `RuulCalendarMonthGrid` ya existe | XL backend+iOS (slice mayor) | Founder smoke Flow #5 (2 hallazgos) |
| **P1.3** | **D.CATALOG** document_type tipado per resource/event subtype + AI vision auto-fill | R.12.G CHECK ya alineado con catalog (cert/contract/policy/receipt/statement); falta filtrar selector per resource_subtype · pattern `ExpenseSuggestionService` ya existe (R.6.AI.7) para AI vision | L (medium-large) | Founder smoke Flow #10.c |
| **P1.4** | `R.5Z.fix.10.b` documentos sueltos (sin recurso) | `documents.resource_id` not nullable hoy · founder: estatutos/contratos macro/comprobantes admin sin recurso atado | M backend mig + iOS (1 sesión) | Founder smoke Flow #10.b |

### Tier P2 — cleanup pre-R.6 (no bloqueante)

| ID | Slice | Evidencia | Effort |
|---|---|---|---|
| **P2.1** | God-views split (post-cleanup) | `DecisionDetailView.swift` 1349 LOC · `ContextSettingsView.swift` 1156 LOC · `RecordExpenseView.swift` 915 LOC · ContextDetailViewV2 ya partido por sections (D.V2 files) | M each |
| **P2.2** | Catalog cleanup capabilities NO_EFFECT (6) + widgets INERT (10) + section rows INERT (44) | Catalog seedea, UI no expone destino · Audit R.5X | L (sweep) |
| **P2.3** | Unificar moneda + label subtipo contexto | 2 `formatCurrency` privados (ContextDetailV2:1539 + ResourceDetailV2:1492) · "Espacio"/"Contexto"/"Grupo" inconsistente | S (cleanup) |
| **P2.4** | 3 sistemas atención paralelos | `rule_attention_items` ∥ `attention_inbox()` ∥ `notifications` R.4D · congelar R.4D hasta push real | M doctrina + cleanup |

### Tier P3 — optimización post-MVP

| ID | Slice |
|---|---|
| **P3.1** | Helper Descriptor.has()/.section()/.action() sin uso |
| **P3.2** | JSONValue holdouts (`linkedEvents`/`linkedObligations`/`linkedDecisions` inline; `membership`/`context` opaque) |
| **P3.3** | Dormant descriptor fields (`metrics.balance/lastMovementAt`, `state.archivedAt/lockedForGovernance/openDecisionId`) |
| **P3.4** | Maintenance.due detector R.6.C.5 (requiere capability tracking) |
| **P3.5** | Push notifications R.4D capa real |

---

## 2. Visión MVP 2.0 — qué define "shipped"

La visión sigue siendo la del founder firmada 2026-06-02:

```
Actor / Contexto / Resource / Right / Membership / Event / Rule
Decision / Obligation / Money / Activity
```

**No hay tablas group-céntricas.** El "grupo" es solo un actor `collective`. Backend = autoridad; frontend = operación clara por contexto.

### Cierre conditions MVP 2.0 (founder smoke "lunes cualquiera, 10 flujos sin pensar")

| # | Flow | Status post-smoke 2026-06-09/10 + R.10-R.12 |
|---|---|---|
| 1 | Crear familia | ⚠️ post-create push pendiente (P0.2) |
| 2 | Crear casa | ✅ Subtype Picker shipped + R.12.D fields + R.10.F renderers |
| 3 | Invitar miembro | ⚠️ invitados pre-accept (P0.3) |
| 4 | Crear evento | ✅ R.12.F event subtype fields + DynamicForm |
| 5 | Reservar recurso | ⚠️ R.RES.POLICY pendiente (P1.2) — slice mayor |
| 6 | Registrar gasto | ✅ shipped (Money tab rebuild + EVENT.1) |
| 7 | Generar deuda | ✅ R.12 obligation kind con fields (verificar wire) |
| 8 | Resolver conflicto | ✅ shipped (ReservationConflict NavigationLink) |
| 9 | Tomar decisión | ⚠️ D.PICKER pendiente (P1.1) |
| 10 | Subir documento | ⚠️ intent.document toolbar (P0.4) + docs sueltos (P1.4) + D.CATALOG (P1.3) |

**Cero ❌.** El stack funciona. Lo que queda es pulir flujos founder-canónicos.

---

## 3. Orden de ejecución firmado (founder lock 2026-06-16)

```
1. R.13 Honesty Sweep (frontend + backend)   ← arrancar AQUÍ
2. R.5Z.fix P0 quick wins (post-create push + invited + intent.document)
3. P1 typed flows (D.PICKER → R.RES.POLICY → D.CATALOG)
4. P2 cleanup pre-R.6 (god-views split + naming + currency unify)
5. Capas estructurales (Compliance/Billing/Assurance) — solo con firma adicional
```

**Recomendación inmediata:** arrancar `R.13.C AttentionDispatcher catalog` (P0 visibilidad founder lock) en paralelo con `R.13.B gating defensivo action_keys` (mata 12+ comingSoon alerts en obligation/document/context detail). Después barrer R.13.A→I en orden. iOS + backend juntos por slice; cada slice termina con install verde iPhone JJ + smoke backend verde.

---

## 4. Doctrina founder consolidada (sigue vigente)

1. **Backend = autoridad.** UI sólo presenta + enruta.
2. **Triada Actor/Context/Resource lockeada.** No introducir `entity` ni fusionar.
3. **Descriptor-driven render.** No hardcode por subtype en iOS (cero `switch resource.type` — verificado vacío).
4. **`available_actions[]` autoritativa.** iOS NO inventa acciones.
5. **`execute_resource_action` único dispatcher backend** para actions del catalog.
6. **`AttentionDispatcher` único punto de navegación** por attention item presente o futuro.
7. **Permission chain `descriptor.actions[].enabled → UI .disabled() → RPC SECURITY DEFINER gate`.** Nunca botón fantasma.
8. **Errores backend nunca llegan crudos.** `RPCErrorMapper` los traduce a `UserFacingError`. `0A000/not_implemented` → "Próximamente".
9. **Activity events:** backend autoritativo. iOS no emite.
10. **Documents inmutables**, versions = nuevo doc + `supersedes`.
11. **Native first.** Antes de crear un componente custom, revisar si existe equivalente nativo de Apple. Componentes Ruul* son wrappers de native.
12. **Catálogo es single source.** Cuando se agrega subtype/event_type/document_type/obligation_kind nuevo, primero se agrega al catalog backend + field_schema; iOS lo consume via descriptor (no hardcode).
13. **`p_client_id` en todo RPC mutante.** Idempotencia pareja desde R.9.B.
14. **Plan vivo o se archiva.** Todo `Plans/Active/*.md` refleja estado real verificado contra código; cualquier slice cerrado se mueve a `Plans/Completed/`.

---

## 5. Referencias activas

| Documento | Función |
|---|---|
| `Plans/Active/R5V_UXDoctrine.md` | UX Doctrine (vocabulario · 5 anclas inmutables founder firmadas) |
| `Plans/Active/R6_RuleEngineArchitecture.md` | Rule Engine arquitectura (ya shipped — referencia histórica vigente) |
| `Plans/Active/R7_GovernanceOrchestrationEngine.md` | Governance arquitectura (ya shipped — referencia histórica vigente) |
| `Plans/Active/R8_PoolPrimitive.md` | Pool primitive (A/B/C shipped) |
| `Plans/Active/R5Z_FounderFlowsValidation.md` | Smoke device 10 flows (ejecutado 2026-06-09/10; backlog vivo de hallazgos ⚠️) |
| `Plans/Active/MVP2_iOS_Contract.md` | Contrato RPCs backend↔iOS (⚠️ requiere refresh post R.9/R.12 — agendar como housekeeping P3) |
| `Plans/Reports/2026-06-10_Auditoria_Integral_Ruul.md` | Auditoría integral histórica (la mayoría de gaps ya cerrados; queda atención unificada P2.4 + naming UI) |
| `Plans/Completed/PreR6_Roadmap.md` | Roadmap histórico R.5X→R.5V→R.5Z→R.6 (CERRADO 2026-06-07) |

---

## 6. Próxima acción

Founder firma slice top de R.13. Propuesta arranque:

**R.13.C + R.13.B en paralelo** (1 sesión, ambos iOS-only, ambos cierran "nada que no tenga que estar"):

- **R.13.C — AttentionDispatcher catalog completo:** extender `AttentionDispatcher.destination(for:)` para los 5 kinds que hoy caen a `UnsupportedAttentionView` (rule_attention_items/obligation.overdue/document.expiring/reservation.starting_soon/right.expiring). Mata el "atención rota" del Home founder lock.
- **R.13.B — Gating defensivo action_keys:** filtrar `availableActions` en ObligationDetail/ContextDetailV2/ResourceDetailV2/DocumentDetail con whitelist `ActionRouter.knownActionKeys`. Mata todos los alerts "Próximamente" estructurales en una sola pasada.

Backend acompañante: **R.13.D** (mig que quita rows `execution_rpc=null` del action_catalog sin handler iOS — alineación frontend↔backend).

Total estimado: 1 sesión de 4-6h. Commit por slice. Install iPhone JJ + smoke backend verde antes de pasar a R.13.A/E/F/G/H/I.
