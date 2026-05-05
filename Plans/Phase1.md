# Phase 1 — ruul Platform — Gap Plan

> Spec canónica: el prompt completo que pegaste el 2026-05-04. Este doc
> mapea **lo que ya hay** vs **lo que falta**, propone orden de
> ejecución, y deja explícitas las decisiones que tenés que tomar
> antes de tirar más código.

**Estado del repo al 2026-05-04**: branch `main` @ `2799b79`. Sprint 0 + 1a + 1b + 1c mergeados. 18 migrations aplicadas (00001 → 00018). 9 edge functions deployadas.

---

## 0. Snapshot — qué hay hoy

### Backend

- `resources` + `events_view` (00014) — abstracción Resource lista pero **vacía** (`events` real sigue en tabla `events` legacy)
- `system_events` + index unprocessed (00014)
- `user_actions` (00014)
- `appeals` + `appeal_votes` + `appeal_vote_counts` view (00014) — **hardcoded a fines**, no es Vote genérico
- `fine_review_periods` (00014, hourly cron pendiente)
- `rules` extendida con `name, is_active, conditions, consequences` (00014). Columnas legacy `code, title, trigger, action, exceptions, enabled, status` siguen.
- `groups`: `group_type, event_label, frequency_type, frequency_config, rotation_mode, grace_period_events, monthly_fine_cap_mxn, finance_*, fund_*` como columnas flat. **Sin `governance`, `base_template`, `active_modules`, `settings` jsonb.**
- `members`: `role text` single-value. **Sin `roles jsonb` array.**

### Edge functions

✅ `process-system-events` (cron 1m), `evaluate-event-rules` (sync), `auto-close-events` (cron 1h), `auto-generate-events` (cron 2h), `generate-wallet-pass` (stub), `send-event-notification` (stub), `send-otp` + `verify-otp` + `send-whatsapp-invite`.

❌ Faltan: `finalize-fine-reviews`, `start-vote`, `cast-vote`, `finalize-vote`, `send-fine-reminders`, `emit-deadline-events`.

### iOS

- `Platform/Models/` 14 archivos: `Resource, ResourceType, Rule, RuleTrigger, RuleCondition, RuleConsequence, SystemEvent, SystemEventType, ConditionType, ConsequenceType, UserAction, Appeal, Fine, JSONConfig`. **Sin `Vote*, Template, GroupModule, GovernanceRules, PermissionLevel, Member` (Member está en `Models/`), AnyCodable.**
- `Platform/Repositories/`: `AppealRepository, FineRepository, SystemEventRepository, UserActionRepository`. Falta `ResourceRepository, RuleRepository (existe en Supabase/Repos), VoteRepository, TemplateRepository`.
- `Platform/Services/`: solo `SystemEventEmitter`. **Sin `GovernanceService, VoteService, RuleEngineService` (cliente).**
- `Platform/Modules/`: ❌ MISSING. Sin `ModuleRegistry`.
- `Platform/Templates/`: ❌ MISSING como folder. `Templates/DinnerRecurring/DinnerRecurringTemplate.swift` existe pero sin registry.
- `MainTabView`: 4 tabs (Inicio/Inbox/Reglas/Yo) ✓ matching prompt
- Onboarding founder steps: welcome → identity → templateSelect → group → vocabulary → rules → invite → phoneVerify → otp → confirm. **Falta `GovernanceConfigView` entre rules e invite (paso 6 del prompt).**
- `Features/Inbox` + `Features/Rules` + `Features/Fines` existen. **Sin `Features/History` ni `GroupHistoryView`.**

### Docs

❌ `Docs/Platform.md, TemplateGuide.md, ModuleGuide.md, EventTypes.md, ConditionTypes.md, ConsequenceTypes.md, RuleAuthoring.md, Governance.md` no existen.

---

## 1. Gap inventory (mapping a las 11 secciones del prompt)

| # | Sección del prompt | Estado | Severidad |
|---|---|---|---|
| 1 | Migration Supabase (groups+governance, members+roles[], votes genérico, vote_casts, templates table) | Parcial — base existe, faltan columnas/tablas | **Alta** — bloquea governance + voting genérico |
| 2 | Modelos Swift de plataforma (24 esperados, hay 14) | Parcial | **Alta** — bloquea (3) y (4) |
| 3 | Rule engine: 6 triggers + 9 conditions + 5 consequences | TS-only en edge fns. Coverage real desconocido — pendiente auditar | **Media** — funcional, falta verificar cobertura completa |
| 4 | Modules + Templates registries (Swift) | ❌ | **Media** — bloquea Fase 2, no V1 |
| 5 | Governance (`GovernanceService` + per-action checks) | ❌ | **Alta si no recortás** — toca cada acción mutable |
| 6 | Repositories (12) + edge functions (10) | Parcial — 4 repos, 9 edge fns; faltan 8 repos + 6 edge fns | **Alta** |
| 7 | Onboarding (TemplateSelector ✓, GovernanceConfig ❌) | Parcial | **Alta si no recortás** |
| 8 | Vistas universales (Inbox ✓, Rules ✓ read-only, **History ❌**, Profile ❌, Fines ✓, Voting ✓ hardcoded) | Parcial | **Alta** — History es no-negociable per prompt |
| 9 | Vistas template Dinner | Parcial — existen en `Features/Events`, no en `Templates/DinnerRecurring/Views/` | **Baja** — funcional aunque mal organizado |
| 10 | Tests (rule engine + snapshots + integration) | Mínimo. No hay snapshot tests committed. | **Media** |
| 11 | Plan rollout dual-write | ❌ — `events` legacy y `resources` (vacío) coexisten sin dual-write | **Alta** — `events_view` proyecta `resources`, queda en cero |
| extra | Documentación viva (`Docs/*.md`) | ❌ MISSING | **Media** |
| extra | Generic Vote (no hardcoded a appeals) | ❌ — appeals tiene su propia tabla | **Alta si no recortás** |

---

## 2. Decisiones que necesito de vos antes de seguir

El prompt mismo (sección "Notas finales") da 3 puntos de recorte. Decidí cada uno:

### Decisión A — Governance configurable

**Mantener**: agregar `groups.governance jsonb` + `GovernanceService` + 6 PermissionLevels + `GovernanceConfigView` paso 6 + permission checks en cada acción mutable. ~1 semana extra.

**Recortar**: hardcoded "founder edita reglas + invita; any member crea votos; host cierra eventos". ~1 sem ahorro. Implica: cuando algún día quieras "votar para cambiar regla X" hay refactor.

→ **Elegí**: ☐ Mantener   ☐ Recortar

### Decisión B — History rica

**Mantener**: `GroupHistoryView` + `HistoryTimelineView` + filtros (miembro/tipo/fecha/recurso) + `SystemEventDetailView` + CSV export. ~3 días.

**Recortar**: timeline simple sin filtros ni export. ~3 días ahorro. Implica: pierde transparencia (prompt dice "no es opcional").

→ **Elegí**: ☐ Mantener   ☐ Recortar

### Decisión C — Vote genérico

**Mantener**: refactorizar `appeals + appeal_votes` → `votes + vote_casts` con `vote_type`. `start-vote/cast-vote/finalize-vote` edge fns genéricos. ~4 días.

**Recortar**: dejar `appeals` hardcoded como está. ~4 días ahorro. Implica: `ruleChange/memberRemoval/fundWithdrawal` votes en V2 requieren rewrite.

→ **Elegí**: ☐ Mantener   ☐ Recortar

### Decisión D — Modules registry (no recorte del prompt, pero pregunta válida)

**Mantener**: `ModuleRegistry` + 5 modules de V1 (BasicFines, RotatingHost, RSVP, CheckIn, AppealVoting) en Swift. ~3 días.

**Recortar**: dejar V1 sin module abstraction; agregar cuando llegue Fase 2. ~3 días ahorro. Implica: en Fase 2 necesitás extraer modules de código existente (mantenible).

→ **Elegí**: ☐ Mantener   ☐ Recortar

### Decisión E — Reorg `Features/` → `Universal/` + `Templates/DinnerRecurring/Views/`

Cosmético. ~1 día. Bajo riesgo de regresiones (renames + import updates). Mejora claridad arquitectural.

→ **Elegí**: ☐ Hacer ahora   ☐ Posponer al final

### Decisión F — Migration de `groups` flat → `settings jsonb`

El prompt dice: `event_label, frequency_*, rotation_mode, grace_period_events, monthly_fine_cap_mxn` viven en `groups.settings jsonb`, no como columnas flat.

**Mantener**: migrar columnas a `settings`. ~1 día. Backward compat via view que las proyecta.

**Recortar**: dejar las columnas flat; aceptar que el `settings` jsonb propuesto es para futuras extensiones. ~1 día ahorro. Implica: divergencia respecto a Spec; un grupo tiene "settings flat" + "settings jsonb" = confuso.

→ **Elegí**: ☐ Mantener   ☐ Recortar

### Decisión G — Rule engine en Swift (Parte 3 del prompt)

El prompt detalla `actor RuleEngine` + protocols Swift. Pero la Regla 6 del prompt dice "Rule engine 100% en servidor". Hoy el motor real corre en TS edge fns.

**Interpretación 1**: las protocols Swift son tipos compartidos para tests + previews; lógica real queda en TS. Bajo costo.

**Interpretación 2**: motor cliente Swift completo + cliente decide cuándo el server lo overrides. Viola Regla 6.

→ **Voto**: Interpretación 1. Confirmar: ☐ OK   ☐ Distinto

---

## 3. Plan secuenciado de implementación (escenario "mantener todo")

Cada bloque es una PR/commit independiente, mergeable, ordenado por dependencias. Si recortás, eliminamos los bloques marcados [B/C/D] al final.

### Bloque 1 — Migration plataforma (1-2 días)

`00019_platform_v2_groups_members_governance.sql`:

- `groups`: add `governance jsonb`, `base_template text default 'dinner_recurring'`, `active_modules jsonb default '["basic_fines","rotating_host","rsvp","check_in","appeal_voting"]'`, `settings jsonb default '{}'`. Backfill `governance` con defaults del template (decisión A). Backfill `settings` desde columnas flat si Decisión F = mantener.
- `members`: add `roles jsonb default '["member"]'`. Backfill from `role` text. Set founder.roles = `["founder","member"]`.
- Drop legacy columns en migration posterior (después de 2 semanas paridad).

`00020_platform_votes_generic.sql` [decisión C = mantener]:

- New tables `votes`, `vote_casts`, view `vote_counts_view` (per prompt schema).
- Migration data: `appeals` rows → `votes (vote_type='fine_appeal')` + `appeal_votes` → `vote_casts`. Keep `appeals/appeal_votes` as readable views over the new tables for backward compat 2 weeks. Drop after.

`00021_templates_table.sql`:

- New table `templates (id, version, config jsonb, available)`.
- Insert `dinner_recurring` row con `config` serializado (mismo contenido que `Templates/DinnerRecurring/DinnerRecurringTemplate.swift` actual).

**Rollback SQL** completo para los 3.

**DoD**: migrations aplicadas en staging branch primero, smoke pasa, RLS regression tests pasan.

### Bloque 2 — Models Swift faltantes (0.5-1 día)

`Platform/Models/`:

- `Vote.swift, VoteType.swift, VoteCast.swift, VoteChoice.swift, VoteCounts.swift, VoteResolution.swift` (decisión C)
- `Template.swift, TemplateRule.swift, TabConfig.swift, OnboardingStepConfig.swift`
- `GroupModule.swift` (decisión D)
- `GovernanceRules.swift, PermissionLevel.swift` (decisión A)
- `AnyCodable.swift` (helper jsonb)
- `Member.swift` mover a `Platform/Models/` y refactor `role: String → roles: [MemberRole]`.

Mantener back-compat decoders donde aplique (legacy Group sin governance → defaults).

**DoD**: `xcodebuild build` SUCCEEDED; tests existentes pasan; round-trip Codable test por cada model nuevo.

### Bloque 3 — GovernanceService [decisión A = mantener] (1-1.5 días)

- `Platform/Services/GovernanceService.swift` actor.
- Single API: `func canPerform(_ action: GovernanceAction, member: Member, group: Group, context: GovernanceContext?) async -> Bool`.
- `enum GovernanceAction { case modifyRule, inviteMember, removeMember, closeEvent, createVote, modifyGovernance }`.
- Cada use-case llama el service en lugar de checkear `isAdmin` directo.

**Refactors necesarios**:
- `RulesView` edit gate
- `InviteMembersView`
- `EventHostActionsSection.close`
- `Vote` create entry points

**DoD**: cada acción mutable verifica permisos via service; tests por cada PermissionLevel.

### Bloque 4 — Generic Vote service + edge fns [decisión C = mantener] (3-4 días)

- iOS: `VoteRepository, VoteCastRepository, VoteService` (genérico).
- Edge fns: `start-vote, cast-vote, finalize-vote` genéricos.
- Refactor `Features/Fines/AppealVoting` → consume generic Vote API con `vote_type='fine_appeal'`. UI no cambia visible.
- `OpenVotesListView` (Universal/Voting/) lista todos los votos abiertos del grupo.

**DoD**: appeal voting sigue funcional end-to-end; nuevo `vote_type` se agrega en V2 sin tocar core.

### Bloque 5 — Module registry + Template registry [decisión D = mantener] (2-3 días)

- `Platform/Modules/Module.swift` protocol + `ModuleRegistry.swift` (Sendable, in-memory).
- 5 módulos V1 escritos como structs estáticos: `BasicFinesModule, RotatingHostModule, RSVPModule, CheckInModule, AppealVotingModule`. Cada uno declara `providedRules, providedResourceTypes, providedSystemEventTypes, providedTabs, dependencies`.
- `Platform/Templates/TemplateRegistry.swift` lee de `templates` table en boot, expone `template(id)`.
- `DinnerRecurringTemplate` ahora carga desde DB (no hardcoded en Swift).

**DoD**: Group conoce su `baseTemplate` + `activeModules`; `MainTabView` arma tabs desde registry, no hardcoded.

### Bloque 6 — Onboarding GovernanceConfigView [decisión A = mantener] (1 día)

- Nuevo `Features/Onboarding/Founder/Views/GovernanceConfigView.swift`.
- Inserta entre `InitialRulesView` (paso 5) e `InviteMembersView` (paso 7) → es paso 6.
- Cards: who_can_modify_rules, who_can_create_votes, voting (quórum, threshold, duración, anonymous).
- Botón "Usar defaults" (skip aplicando defaults del template).

**DoD**: founder puede ajustar governance en onboarding; defaults respetan el template; persiste a `groups.governance`.

### Bloque 7 — GroupHistoryView + filtros + CSV export [decisión B = mantener] (2-3 días)

- `Universal/History/GroupHistoryView.swift` (o `Features/History/`, según decisión E).
- `HistoryTimelineView, RuulTimelineItem, HistoryFilterBar, SystemEventDetailView, HistoryExportService`.
- Acceso desde tab "Yo" → "Historial del grupo".
- Filtros: miembro, tipo, fecha rango, recurso.
- Infinite scroll por `system_events`.
- CSV export via `ShareLink`.

**DoD**: usuario ve linealmente qué pasó; tap → detail; export funciona; tests de filter logic.

### Bloque 8 — Edge functions faltantes (2 días)

- `finalize-fine-reviews` (cron 1h) — oficializa multas pasado grace period
- `send-fine-reminders` (cron diario) — recordatorios 3/7/14 días
- `emit-deadline-events` (cron 5min) — emite `rsvpDeadlinePassed` para events vencidos

**DoD**: cron jobs scheduled en Supabase Dashboard; smoke test cada uno con SQL fixture.

### Bloque 9 — Migración `groups` flat → `settings jsonb` [decisión F = mantener] (1 día)

- `00022_groups_settings_consolidate.sql`: leer columnas flat en `settings` jsonb; mantener columnas flat 2 semanas; drop posterior.
- iOS `Group` decoder lee de `settings` con fallback a flat (transition).

**DoD**: backend único source of truth para settings; legacy columns siguen leíbles.

### Bloque 10 — Reorg folders [decisión E = ahora] (1 día)

- `Features/Inbox → Universal/Inbox`
- `Features/Rules → Universal/Rules`
- `Features/Fines → Universal/Fines`
- `Features/History → Universal/History` (si decisión B)
- `Features/Profile → Universal/Profile`
- `Features/Voting → Universal/Voting` (si decisión C)
- `Features/Events → Templates/DinnerRecurring/Views/` (con renames si conflict)
- xcodegen regenerate; imports update.

**DoD**: `xcodebuild build` SUCCEEDED; tests pasan; sin warnings nuevos.

### Bloque 11 — Docs viva (1.5-2 días)

- `Docs/Platform.md` — los 7 ciudadanos primarios + diagrama flow rule engine
- `Docs/EventTypes.md, ConditionTypes.md, ConsequenceTypes.md` — catálogos con estado (implementado/reservado)
- `Docs/RuleAuthoring.md` — cómo se compone una regla, ejemplos
- `Docs/TemplateGuide.md, ModuleGuide.md` — tutoriales con `dinner_recurring` como ejemplo
- `Docs/Governance.md` — PermissionLevels, defaults, evaluación

**DoD**: docs son scannable; cada concepto tiene una sola fuente de verdad.

### Bloque 12 — Rule engine coverage audit + tests faltantes (2 días)

Auditar: ¿hay Triggers/Conditions/Consequences que el prompt pide V1 pero el código TS no implementa? Listar gaps. Implementar faltantes en TS. Tests Deno end-to-end por cada uno.

iOS swift-testing: integration test "create event → close → multas se proponen → grace expira → oficializadas".

**DoD**: cobertura 100% de los 6 triggers + 9 conditions + 5 consequences que el prompt lista para V1.

### Bloque 13 — Rollout dual-write `events` → `resources` (3-4 días)

Hoy `events_view` proyecta de `resources` que está vacío. Necesitamos:

- Migration que arranca dual-write: cualquier INSERT/UPDATE de `events` también escribe en `resources`.
- Backfill incremental: copiar 1000 rows / batch hasta paridad.
- Lectura: continúa contra `events` (hoy es la SoT). Pero `events_view` ahora UNION `resources` filtered + `events`.
- Después de 2 semanas con paridad verificada (script de check), invertir SoT: lectura de `resources`, mantener `events` writable como mirror; otra semana; drop `events`.

**DoD**: paridad SQL = 100% durante 2 semanas; cero discrepancias en alertas.

---

## 4. Estimación total

| Escenario | Días full-time | Calendario part-time |
|---|---|---|
| Todo (A+B+C+D+E+F mantener) | 22-28 días | 8-10 semanas |
| Recortes "ligeros" (B+E posponer) | 16-20 días | 6-8 semanas |
| Mínimo viable (recortar A+B+C+D, mantener solo F+E+rollout+coverage+docs) | 8-10 días | 3-4 semanas |

El prompt dice "5-7 semanas full-time, 3-4 meses calendario" — coincide con escenario "todo" si es part-time intenso.

---

## 5. Riesgos

1. **Refactor `groups` con governance jsonb** rompe RLS policies existentes que asumen columnas flat. Mitigar con view de compat + tests RLS antes de drop.
2. **Migración de `appeals → votes` genérico** toca el feature más visible (apelaciones de multas). Si el refactor introduce regresión, usuarios pierden capacidad de apelar. Mitigar con feature flag + paridad shadow durante 1 semana.
3. **Drop de `events` legacy en bloque 13**: si la paridad no es 100% (algún campo edge case), perdemos datos. Mitigar: backup snapshot antes de drop + script de paridad corriendo continuamente 2 semanas.
4. **Reorg de folders (bloque 10)** puede romper xcodegen + CI. Mitigar: hacerlo en branch dedicado, build + test + smoke en simulator antes de merge.
5. **Tests del rule engine** descubren bugs preexistentes (cobertura 0% real). Aceptarlo como descubrimiento; dejar bugs documentados con issues separados.

---

## 6. Open questions (para vos)

1. **Decisiones A–G** arriba. Necesito tu vote en cada una antes de tirar el bloque correspondiente.
2. **Branch strategy**: ¿este plan se ejecuta en `main` con commits por bloque, o en un branch `phase-1-platform` con PRs por bloque y merge final?
3. **APNs cert / AASA / Wassenger / RUUL_QR_SECRET** — `EventLayerV1-FollowUp` y `OnboardingV1-FollowUp` listan estos como infra que vos provisionás. ¿Cuáles están listos hoy?
4. **Tests existentes**: vos confirmás si los tests actuales son canon (no romperlos) o si tienen falsos positivos / están deshabilitados (`HappyPathTests.swift` deshabilitado per follow-up).
5. **Rollout dual-write timing**: ¿2 semanas de paridad es aceptable o querés más/menos?
6. **Docs viva**: ¿los escribo yo en este plan o son tu responsabilidad? Yo voto que los escriba yo en cada bloque (Platform.md cuando termine bloques 1-5, EventTypes.md cuando termine bloque 12, etc.).

---

## 7. Lo que NO hace este plan (intencional)

- Otros templates (Recurso compartido, Tanda) — Fase 2+
- Editor visual de reglas — Fase 4
- Otros consequence types más allá de los 5 V1
- Otros vote types más allá de `fine_appeal` (la arquitectura los soporta cuando lleguen)
- Pagos / fondo común
- Multi-grupo simultáneo (ya hay `multi-group support` per commit `79fe808`, pero no es scope de este plan)
- Roles más allá de founder/member/host

---

## 8. Próximo paso

**Vos**: contestá las 7 decisiones. Luego empezamos por **Bloque 1** (migration plataforma) en una PR aislada.

**Yo**: una vez que tenga las decisiones, redacto la migration SQL completa de Bloque 1 + rollback en otro pass de review antes de aplicar a Supabase.
