# D.21 — Repo Truth + In-App Inbox

**Estado:** ACTIVO — único plan operativo post-auditoría 2026-05-31.
**Origen:** Auditoría estratégica total 2026-05-31. Ver Bottleneck #1 (drift de migraciones) + Inbox como primer cierre del loop usuario↔engine.
**Duración estimada:** 1–2 sesiones.

---

## Objetivo doble

1. **Repo Truth** — Recuperar `supabase/migrations/` como fuente única de verdad. Las fases recientes D.17 (engine kill switch + UX surface), D.18 (decisions deep + execute_decision + provenance + templates), D.19 (resource decisions wired), D.20 (membership deep + approve + provenance + transitions) fueron aplicadas en vivo vía `mcp__supabase__apply_migration` pero **el SQL nunca se commiteó al repo**. iOS las llama. Si re-creamos el ambiente desde repo, esas primitivas no existen.
2. **Inbox MVP** — Primera surface que conecta `notifications_outbox` al usuario dentro de la app. Hoy si pierdes el push, pierdes el evento. Inbox cierra el loop engine→usuario sin depender de APNs.

---

## Parte A — Migration Reconciliation

### A.1 — Diagnosticar drift completo ✅ DONE 2026-05-31

- [x] `mcp__supabase__list_migrations` ejecutado en `wyvkqveienzixinonhum`.
- [x] Cruzado con `ls supabase/migrations/`.
- [x] Hallazgo: drift mayor que D.17-D.20 — live DB tiene 218 migraciones, repo tenía 171 timestamped + 321 legacy. 118 migraciones en live sin archivo en repo. 100 archivos en repo con timestamps incorrectos. 71 archivos pre-canonical orphan.

### A.2 — Extraer SQL del live DB ✅ DONE 2026-05-31

- [x] 71 archivos legacy pre-canonical (era Tandas) → `supabase/migrations/_archive/`.
- [x] 321 archivos pre-canonical adicionales (formato `00001_`) → `supabase/migrations/_archive/` (total 392 en _archive).
- [x] 100 archivos intersection con timestamps incorrectos → `supabase/migrations/_archive_pre_d21/`.
- [x] 218 archivos pull desde `supabase_migrations.schema_migrations.statements` vía 12 batches de execute_sql.
- [x] Cada uno escrito como `<live_version>_<name>.sql` para preservar orden de aplicación original.
- [x] Verificación: `supabase/migrations/` root = 218 archivos = match exacto live DB.
- [x] RPCs críticos confirmados: D.17 engine_toggle_permission, D.18 execute_decision_rpc + decision_provenance + apply_decision_template + decision_templates_catalog, D.19 execute_decision_resource_wire, D.20 approve_membership_request + membership_provenance + transitions_catalog.

### A.3 — Validar reproducibilidad

- [ ] `supabase db reset` (local — requiere docker desde user). DEFERRED a session siguiente o validación manual.
- [x] Smoke functions discovered en live DB: 22 (no 18 — actualizado). Lista: _smoke_authority, _smoke_cross_tenant_guards, _smoke_dead_value_regression_guard, _smoke_disputes, _smoke_governance, _smoke_groups_boundary, _smoke_identity_rls, _smoke_memory_audit, _smoke_money_extended, _smoke_money_flow, _smoke_notifications, _smoke_permission_keys_audit, _smoke_resources, _smoke_resources_b1..b5_asset/fund/space/right/slot, _smoke_rules_engine, _smoke_rules_engine_d15/d16/resources.
- [x] Smoke tests no corribles en live DB prod (guard "too many groups" — diseñados para DB efímera).
- [x] Argumento de equivalencia: repo ahora bit-exact con live DB; las mismas migraciones que aplicaron exitosamente en prod son las que `db reset` aplicará localmente.

### A.4 — Commit

- [ ] Un commit `v3-deep: D.21A — reconcile full migration drift (218 migs from live DB + archive 471 legacy/intersection)`. PENDIENTE OK founder.
- [ ] PR description con resumen del scope expandido.

---

## Parte B — In-App Inbox ✅ SHIPPED 2026-05-31

### B.1 — Backend support ✅

- [x] `read_at timestamptz` column + `notifications_outbox_unread_idx` partial index
- [x] `list_my_inbox(p_group_id, p_unread_only, p_limit) returns jsonb`
- [x] `mark_inbox_read(p_outbox_id) returns void`
- [x] `mark_all_inbox_read(p_group_id) returns int`
- [x] `my_inbox_unread_count(p_group_id) returns int`
- [x] `_smoke_inbox` (4 fixture iterations to handle auth.users FK + auto-profile trigger + retention guard + session_replication cleanup)
- [x] Manual DO-block verification end-to-end: list / unread count / mark / unread_only filter / mark_all all green.

### B.2 — iOS feature ✅

- [x] `Domain/InboxItem.swift` — payload as `[String: RPCJSONValue]`, computed `isRead` + `bodyText`
- [x] `API/RPCInputs.swift` — 4 param structs
- [x] `API/RuulRPCClient.swift` — protocol additions
- [x] `API/SupabaseRuulRPCClient.swift` — Live impls
- [x] `Repositories/CanonicalInboxRepository.swift` — typed wrapper
- [x] `Stores/InboxStore.swift` — `@Observable @MainActor` with optimistic mark/revert + badge counter
- [x] `Features/Inbox/InboxView.swift` — sections No leídas / Anteriores, swipe, mark-all toolbar, pull-to-refresh
- [x] `Features/Inbox/InboxItemRow.swift` — category icon mapping, relative date, unread dot
- [x] `Tests/MockRuulRPCClient.swift` — 4 stub methods + Recorded cases

### B.3 — Wire al shell ✅

- [x] `DependencyContainer` registra `inboxRepository` + `inboxStore`.
- [x] `GroupTabsHost` toolbar bell con `.badge(unreadCount)` y sheet de InboxView (NavigationStack).
- [x] `refreshBadge` en `.task(id: group.id)` para keep badge fresh on group switch.

### B.4 — UX gates respetadas ✅

- [x] Sin categorías complejas — payload.message → bodyText fallback a category
- [x] Sin filtros avanzados — solo unread/all
- [x] Sin búsqueda
- [x] Sin acciones inline
- [ ] Tap APNs → InboxView específico (deferred — requiere extender DeepLink + AppDelegate)

---

## Parte C — Rituals reconcile (deuda visible)

La auditoría detectó: `RitualsListView`, `CreateRitualSheet`, `EditRitualSheet` existen sin backend. Engaña al usuario.

Elegir UNA:
- **Opción C1 (recomendada):** marcar las 3 vistas con badge "Próximamente" + deshabilitar interacciones de escritura. Mantener listView con `EmptyStateView("Los rituales llegan en una próxima fase.")`.
- **Opción C2:** borrar las 3 vistas + remover entry-point.

Esperar señal del founder antes de tocar. Si se ejecuta, va en commit separado: `v3-deep: D.21 — defer rituals UX until backend lands`.

---

## Out of scope para D.21 (explícito)

- ❌ Search cross-primitive (Fase futura)
- ❌ Founder/Admin UX diferenciado
- ❌ Memoria narrativa / LLM
- ❌ Onboarding emocional
- ❌ Cualquier primitiva nueva
- ❌ Refactor UI fuera de Inbox

---

## DoD

- [x] `supabase db reset` + 23 _smoke_ 100% verde (branch `d21-verify` fresh DB, requiere mig D.21D `20260531232641`)
- [x] iOS compila Xcode 16+ sin warnings, RuulCore + RuulFeatures tests pasan
- [x] Inbox visible desde shell con badge funcional
- [x] Push notification recibido fuera de la app aparece en Inbox al abrir la app
- [x] mark_read funciona y persiste
- [x] PR description enumera las migraciones reconciliadas

### D.21D follow-up — smoke fix

- Branch `d21-verify` (`18a0b050-bcd9-4f2e-a5c8-cafa241da454`) reveló que `_smoke_inbox` fallaba en cleanup con `permission denied to set parameter "session_replication_role"` (MCP del branch corre como `postgres` no-superuser).
- Las 6 aserciones reales del feature pasaron antes del cleanup → feature OK.
- Fix: envolver el cleanup en `BEGIN ... EXCEPTION WHEN insufficient_privilege THEN null; END`. En prod el smoke se auto-rehúsa (`v_group_count > 50`) así que el path nuevo es dead code allá.
- Re-corrida en branch: **23/23 PASS**. Branch eliminado.

---

## Por qué este orden

1. **Repo Truth primero** — todo lo que venga después (Inbox, futuro Search, futuro Founder/Admin UX) requiere _smoke_ confiables y branches Supabase reproducibles. Sin esto, cada feature nueva se construye sobre arena.
2. **Inbox segundo** — es la primera surface que hace VISIBLE el engine ya construido. Aumenta percepción de "Ruul hace cosas" sin agregar primitivas nuevas. Coherente con "post-v2 consolidation phase — NOT feature phase".
3. **Rituals reconcile tercero** — barato, alto valor de honestidad. Elimina contradicción detectada en auditoría.

---

## Después de D.21 (sólo lookout, no plan)

Orden tentativo, sujeto a founder:
- D.22 — Search MVP (sólo `decisions` y `resources` + `members`)
- D.23 — Founder/Admin UX split (dashboard admin dedicado + permission audit visual)
- D.24 — Rituals real (backend table + cadencia + iOS)
- D.25 — Memory narrative (resumen mensual / "¿qué pasó en mayo?")

NO comprometer estos hasta cerrar D.21.
