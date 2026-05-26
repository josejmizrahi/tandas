# Plan único — Alineación de Ruul con la doctrina de 25 primitivas

> **Plan único activo.** Doctrina fuente: `Plans/Active/GroupPrimitives.md`.
> Cualquier otro plan fue archivado en `Plans/Archive/` (2026-05-26).
> No se abre otro plan hasta cerrar éste.
>
> **Orden no negociable:** primero backend (Supabase), después UI (iOS).
> No tocar iOS hasta cerrar la Fase B.

---

## 0. Marco

La app modela grupos. La doctrina dice que un grupo se compone de 25 primitivas. Esta plan reordena el código (schema + RPCs + edge functions + modelos + UX) para que cada primitiva quede explícita, nombrada con vocabulario humano, y separable.

Reglas del plan:

1. Una fase a la vez. No se empieza la siguiente hasta cerrar la previa.
2. **Backend = squash.** Todo Supabase converge en una sola migración canónica `00001_canonical_schema.sql`. Las 63 migraciones actuales se archivan en `_archive/` (no se borran).
3. El reshape se ejecuta en un **branch Supabase via MCP**. No se toca producción hasta validar.
4. Data viva de dogfooding (cenas + Money 2.0 settlements) se preserva via script de export/import.
5. Codegen Swift↔TS se regenera una sola vez al final de Fase A.
6. La UI no se toca hasta que el backend canónico esté mergeado a producción.
7. Vocabulario prohibido en código y UX: `governance`, `governance_rules`, `fund` (como sinónimo de pool), `ledger` (como pestaña), "registrar = aprobar", `fine` (cuando sea `sanction`).
8. Append-only se preserva: `ledger_entries`, `system_events`, `vote_ballots`, `rsvp_actions`, `rule_versions` mantienen su carácter inmutable.

---

## 1. Mapa de cobertura (estado actual)

| # | Primitiva | Backend | iOS | Acción |
|---|---|---|---|---|
| 1 | Miembros | ✅ | ✅ | nada (Fase B5 podría agregar niveles) |
| 2 | Membresía | 🟡 | 🟡 | Fase A4 (estados: provisional/suspendido/exmiembro) |
| 3 | **Propósito** | ❌ | ❌ | **Fase A2** (tabla + RPC + onboarding) |
| 4 | Reglas | ✅ | ✅ | Fase A1 (limpiar `rule_conflicts` muerta) |
| 5 | Roles | ✅ | ✅ | nada |
| 6 | Poder/Autoridad | 🟡 | 🟡 | Fase A3 (rename `governance` → `decision_rules`) |
| 7 | Comunicación | 🟡 | 🟡 | post-V1 (canales/chat fuera de scope) |
| 8 | Recursos | ✅ | ✅ | nada |
| 9 | Contribuciones | 🟡 | 🟡 | Fase A6 (tipo `non_monetary_contribution`) |
| 10 | Incentivos | ❌ | ❌ | post-V1 |
| 11 | Sanciones | ✅ | ✅ | Fase A5 (rename `fines` → ver §3) |
| 12 | **Confianza/Reputación** | ❌ | ❌ | **Fase A7** (registro auditable, no score público) |
| 13 | Memoria | ✅ | 🟡 | Fase B6 (narrativa en UX) |
| 14 | **Resolución de conflictos** | 🟡 | 🟡 | **Fase A8** (`disputes` + mediación) |
| 15 | Entrada/Salida | ✅ | ✅ | Fase A4 (cierre + liquidación) |
| 16 | Decisiones | ✅ | ✅ | Fase A3 (renames) |
| 17 | Permisos | 🟡 | 🟡 | Fase A3 (matriz explícita) |
| 18 | Propiedad | 🟡 | 🟡 | Fase A9 (`ownership_kind` en resources) |
| 19 | Contabilidad | ✅ | ✅ | Fase A1 (drop legacy expenses/pots) |
| 20 | **Cultura** | ❌ | ❌ | **Fase A10** (norms/values/taboos opt-in) |
| 21 | **Ritual** | 🟡 | ❌ | **Fase A11** (anotar significado en recurrence) |
| 22 | Legitimidad | 🟡 | 🟡 | Fase A3 (anotar `source` en cada decisión) |
| 23 | **Representación** | ❌ | ❌ | **Fase A12** (`mandates` + revocación) |
| 24 | Cuidado/Mantenimiento | 🟡 | 🟡 | post-V1 |
| 25 | **Disolución** | ❌ | 🟡 | **Fase A13** (proceso, no solo archive) |

✅ cubierto • 🟡 parcial • ❌ ausente

---

## 2. Decisiones doctrinales que cierran ambigüedades

Antes de empezar, fijamos estas decisiones (las usamos como criterio en cada PR):

1. **Confianza/Reputación** no es score numérico público. Es un *registro auditable de momentos* (cumplió, no cumplió, apeló, contribuyó). La UI no ranquea. Sólo expone hechos cuando son relevantes.
2. **Cultura** es opt-in. El grupo decide si quiere expresar valores/tabúes. No se infiere automáticamente.
3. **Ritual** se modela como una *anotación sobre recurrencia ya existente* (`resource_series` + `meaning` + `marker_type`). No es una primitiva nueva con tabla pesada.
4. **Sanciones** > fines. `fines` se renombra a `sanctions` y queda preparada para tipos no monetarios (warning, suspension, repair_task). Migración con view de compatibilidad.
5. **Disolución** es un proceso de 3 estados (`proposed` → `liquidating` → `archived`), no un flag.
6. **Representación** es un mandato revocable con scope (`internal`, `external`, `legal`, `financial`). Distinto de rol.
7. **Propósito** vive en el grupo: declarado (texto corto), operativo (qué hace hoy), opcional (emocional/simbólico). Se pregunta al crear.
8. **Permisos** seguimos con `group_policies` + `has_permission`. No se crea un sistema paralelo; se rellena la matriz.

---

## 3. Vocabulario canónico (nace correcto, no se renombra)

Como vamos a squash + reshape (§4), el schema canónico **nace con estos nombres**. No hay views de compat ni typealiases temporales — la 00001 es la única migración.

| Concepto | Nombre canónico | Notas |
|---|---|---|
| Reglas de decisión del grupo | `groups.decision_rules` (jsonb) | reemplaza `governance` |
| Decisiones tomadas | `votes` + `vote_ballots` | columna `legitimacy_source` por voto |
| Política por acción | `permission_policies` | reemplaza `group_policies` |
| Sanciones | `sanctions` (`kind: monetary | warning | suspension | repair`) | reemplaza `fines` |
| Apelación | `dispute_vote_id` en sanction → `disputes` | reemplaza `appeal_vote_id` |
| Pertenencia | `group_members.membership_state` (enum) | reemplaza `active boolean` |
| Aportes no monetarios | `ledger_entries.type='non_monetary_contribution'` | nuevo enum value |
| Confianza | `trust_events` | append-only, sin score |
| Disputas | `disputes` + `dispute_resolutions` | nuevo |
| Cultura | `cultural_norms` (opt-in) | nuevo |
| Ritual | `resource_series.ritual_meaning` + `ritual_marker_kind` | anotación, no tabla |
| Representación | `mandates` (scope + revocable) | distinto de rol |
| Propiedad | `resources.ownership_kind` + `ownership_metadata jsonb` | |
| Propósito | `group_purposes` (kind: declared/operative/emotional) | |
| Disolución | `group_dissolutions` (status: proposed/liquidating/archived) | proceso |

**Tablas que NO existen en el schema canónico** (legacy muerto):
`pots`, `pot_entries`, `rule_conflicts`, `appeals`, `appeal_vote`, `expenses`, `expense_shares`, `payments`, `group_balances` (view).

**Vocab UI prohibido (Swift + strings):** `governance`, `gobernanza`, `fondo`, `ledger`, `cuenta`, `fine`, "Estilo de gobernanza".

---

## 4. FASE A — Backend canónico (squash + reshape)

> Todo el trabajo de backend converge en **una sola migración**: `00001_canonical_schema.sql`. Las 63 migraciones actuales se archivan en `supabase/migrations/_archive/` (no se borran, se mueven). El reshape se hace contra un Supabase **branch nuevo via MCP**, con script de export/import de la data viva. Cuando el branch valida, se mergea. La iOS app NO se toca durante toda esta fase.

### A0 — Audit de data viva (lectura, no escritura)
- `mcp__supabase__list_tables` en producción. Capturar `count(*)` por tabla.
- Identificar qué filas reales existen de dogfooding (grupos, miembros, events, ledger_entries, obligations, settlements, rules, votes, sanctions/fines, system_events).
- Producir `Plans/Active/CanonicalSchema_DataInventory.md` con: tabla → filas → ¿se conserva? → mapping al schema canónico.
- **Done:** sabemos exactamente qué data hay que mover y qué se descarta.

### A1 — Diseño del schema canónico (`00001_canonical_schema.sql`)
**Estado:** draft v0 publicado en `Plans/Active/CanonicalSchema.sql` (2026-05-26). Sigue las 10 decisiones de `doctrine_canonical_schema_decisions.md`. Pendiente: review humano + dos anexos (`CanonicalSchema_RLS.md` con policy set completo y `CanonicalSchema_RPCs.md` con el catálogo de funciones).

Un solo archivo SQL que define **todo** Ruul desde cero, ordenado por las primitivas. Estructura:

1. **Identity & membership** — `profiles`, `groups`, `group_members` (con `membership_state` enum), `invites`, `group_purposes`.
2. **Authority** — `groups.decision_rules` jsonb, `permission_policies`, `mandates`, `role_definitions` (jsonb en `groups.roles`).
3. **Resources** — `resources` (polimórfico, con `ownership_kind` + `ownership_metadata`), `resource_series` (con `ritual_meaning` + `ritual_marker_kind`), `bookings`, `resource_capabilities`.
4. **Rules** — `rules`, `rule_versions`, `rule_evaluations`, `rule_shapes_catalog`.
5. **Money** — `ledger_entries` (con `non_monetary_contribution` en el enum `type`), `obligations`, `settlements`, `settlement_obligations`.
6. **Sanctions & disputes** — `sanctions` (con `kind`), `disputes`, `dispute_resolutions`.
7. **Decisions** — `votes`, `vote_ballots`, con `legitimacy_source` por voto.
8. **Trust** — `trust_events` (append-only, sin score).
9. **Culture & ritual** — `cultural_norms` (opt-in), ritual ya está en `resource_series`.
10. **Memory** — `system_events` (append-only universal).
11. **Lifecycle** — `group_dissolutions`.
12. **Notifications** — `notification_outbox`, `notification_tokens`, `notification_preferences`.
13. **RLS policies** — uniformes, en una sección clara.
14. **Triggers** — agrupados por dominio.
15. **Seeds mínimos** — templates, role catalog, capabilities.

Reglas de diseño:
- Cada tabla tiene comentario SQL explicando la primitiva que cubre.
- Enums explícitos (no `text` con check constraint).
- `created_at`/`updated_at` consistentes.
- Foreign keys con `ON DELETE` explícito por caso.
- Sin columnas `legacy_*`, sin `deprecated_*`.

- **Done:** review humano del SQL completo antes de aplicar. Founder lee y aprueba.

### A2 — Diseño de RPCs canónicos
Catálogo de funciones expuestas a iOS. Una por acción humana:

- Membership: `invite_member`, `accept_invite`, `set_membership_state`, `remove_member`.
- Purpose: `set_group_purpose`.
- Resources: `create_resource`, `update_resource`, `set_resource_ownership`, `archive_resource`.
- Rules: `propose_rule`, `enact_rule`, `archive_rule`, `toggle_rule`.
- Money: `record_expense`, `record_contribution`, `record_non_monetary_contribution`, `record_settlement`, `record_pool_charge`.
- Sanctions: `issue_sanction` (kind: monetary/warning/suspension/repair).
- Disputes: `open_dispute`, `assign_mediator`, `record_mediation_outcome`, `escalate_to_vote`.
- Decisions: `start_vote`, `cast_ballot`, `finalize_vote` (con `legitimacy_source`).
- Mandates: `grant_mandate`, `revoke_mandate`.
- Culture: `propose_norm`, `endorse_norm`, `retire_norm`.
- Dissolution: `propose_dissolution`, `approve_dissolution`, `record_liquidation_step`, `finalize_dissolution`.
- Authorization: `has_permission(group_id, user_id, action)`.

Documentar en `Plans/Active/CanonicalSchema_RPCs.md`. Cada RPC: signature, RLS, primitiva que sirve.
- **Done:** founder revisa el catálogo. iOS sabe qué va a llamar.

### A3 — Script de export/import
Un script SQL/TS que:
1. Exporta data viva de producción a un dump intermedio.
2. Transforma columna por columna al schema canónico (mappings de A0).
3. Importa al branch nuevo.
4. Verifica conteos esperados.

Mappings principales:
- `fines.*` → `sanctions.*` con `kind='monetary'`.
- `groups.governance` (jsonb) → `groups.decision_rules` (jsonb, mismo shape).
- `group_members.active` → `membership_state` (`true`→`active`, `false`+`leftAt`→`left`).
- `appeals` legacy → `disputes` con `kind='sanction_appeal'`.
- `expenses`/`expense_shares`/`payments` → ya están como `ledger_entries`+`obligations` post Money 2.0, descartar legacy.
- `pots`, `rule_conflicts` → descartar.

- **Done:** script idempotente y reversible. Tests contra dump de staging.

### A4 — Aplicar en target limpio (local o dev project)
**Pivot 2026-05-26:** descartamos Supabase branches porque (a) `create_branch` requiere `confirm_cost_id` no expuesto en el MCP actual, (b) el branch hereda 343 migraciones legacy con `MIGRATIONS_FAILED`, y (c) cobra por hora. Reemplazado por flujo local/dev-project documentado en `Plans/Active/CanonicalApply.md`.

Bundle a aplicar en orden (todo en `Plans/Active/`):
1. `CanonicalReset.sql` — `DROP SCHEMA public CASCADE` + re-grants.
2. `CanonicalSchema.sql` — 43 tablas + triggers + helpers + seeds + `create_group`.
3. `CanonicalRLS.sql` — policies + realtime publication.
4. `CanonicalRPCs.sql` — bodies de las 50 RPCs (pendiente de escribir).

Targets (pick uno):
- **Opción A — local docker** (`supabase start` + `psql -f`). Gratis, repetible, recomendado para iteración.
- **Opción B — nuevo Supabase project free tier**. Mismo surface que prod (RLS/realtime/storage/edge functions). Founder lo crea via dashboard, comparte `project_ref`, yo aplico via `mcp__supabase__apply_migration`.

Smoke test mínimo:
```sql
select count(*) from public.permissions;        -- expect 44
select tablename from pg_tables where schemaname='public' order by 1;   -- expect ~43
select count(*) from pg_policy where polrelid::regclass::text like 'public.group_%';
```

- **Done:** schema canónico aplicado limpio + smoke verde en target dev.

### A5 — Reescribir edge functions
Edge functions actuales (`process-system-events`, `dispatch-notifications`, `finalize-votes`, `finalize-fine-reviews`, `send-event-notification`, `create-placeholder-member`, etc.) se reescriben contra el schema canónico:

- `_shared/ruleEngine.ts` se mantiene; lee/escribe contra nuevos nombres.
- `finalize-fine-reviews` → `finalize-sanction-disputes`.
- Todas usan vocab canónico.

Desplegar a branch via `mcp__supabase__deploy_edge_function`.
- **Done:** edge functions corren contra branch y pasan sus tests.

### A6 — Import de data viva al branch
- Ejecutar script A3 contra branch.
- Verificar conteos vs A0 inventory.
- Spot-check: una cena conocida sigue teniendo sus RSVPs/ledger/obligations/settlements correctos.
- **Done:** branch tiene data realista y verificable.

### A7 — Paridad funcional
- Lista de queries críticas (lo que la iOS app llama hoy). Para cada una: ejecutar contra branch, comparar resultado con producción.
- Si una query falla por nombre, anotar en `CanonicalSchema_iOSImpact.md` (input para Fase B).
- **Done:** sabemos exactamente qué iOS calls van a fallar y cuáles funcionan idénticos.

### A8 — Cutover a producción
- Solo cuando A0–A7 están cerrados y el smoke en dev/local está verde.
- Ventana de mantenimiento corta (5–15 min). iOS queda temporalmente rota hasta B1.
- Backup completo previo: `pg_dump "<prod_connection>" > backup_pre_canonical_$(date +%Y%m%d_%H%M).sql`.
- Aplicar bundle en prod en este orden, con MCP `apply_migration`:
  1. `CanonicalReset.sql` (drop schema public cascade).
  2. `CanonicalSchema.sql`.
  3. `CanonicalRLS.sql`.
  4. `CanonicalRPCs.sql`.
- Inmediatamente después: correr `scripts/canonical_migration/import.ts` con la data exportada en A6.
- Mover las 343 migraciones legacy a `supabase/migrations/_archive/` y dejar el bundle como `supabase/migrations/00001_canonical_schema.sql` (concatenado).
- Rollback: `psql ... < backup_pre_canonical_*.sql`.
- **Done:** producción corre el schema canónico con data viva intacta. App iOS está temporalmente rota (esperado).

### A9 — Codegen Swift↔TS
- Regenerar tipos Swift desde el schema canónico (`scripts/codegen/`).
- Regenerar tipos TS para edge functions.
- Commit del diff de codegen — será grande.
- **Done:** `RuulCore/PlatformModels/Generated/` refleja el schema canónico.

### A — Cierre de fase
- `00001_canonical_schema.sql` es la única migración activa.
- Branch mergeado, producción estable con data viva intacta.
- Edge functions todas corriendo contra schema canónico.
- Codegen commiteado.
- `CanonicalSchema_iOSImpact.md` lista los call-sites a actualizar en Fase B.
- **Solo entonces** se empieza Fase B.

---

## 5. FASE B — iOS (RuulCore + RuulFeatures)

> Después del merge canónico, el código Swift no compila. Fase B restaura la compilación contra el schema canónico y luego construye las nuevas superficies UX. RuulUI sigue en delete-mode (no se tocan tokens ni primitivas). Toda B se hace en feature layer y RuulCore.

### B1 — Restaurar compilación contra schema canónico
- `RuulCore/PlatformModels/Generated/` ya está actualizado por A9; ahora arreglar todo lo que rompió.
- Renombrados Swift dirigidos por `CanonicalSchema_iOSImpact.md`: `GovernanceRules` → `DecisionRules`, `GovernanceService` → `AuthorizationService`, `GovernanceAction` → `PermittedAction`, `Fine` → `Sanction`, `Appeal` → `SanctionDispute`, etc.
- Repos cuyas tablas desaparecieron (`pots`, `expenses` legacy, etc.) → eliminar archivos completos.
- Repos con tablas renombradas → ajustar query paths.
- Strings UX: barrer `governance`, `gobernanza`, `fondo`, `ledger`, `cuenta`, `multa` (cuando sea `sanción`). Vocab doctrina.
- Borrar modelos huérfanos detectados en auditoría (`OnboardingProgress`/`Completion` colapsados, `UserAction` → `AuditLogEntry` si aplica).
- **Done:** `xcodebuild` verde. `xcodebuild test` pasa. `grep` de palabras prohibidas devuelve 0.

### B2 — Conectar primitivas nuevas (read path)
- Repos nuevos: `PurposeRepository`, `TrustRepository`, `DisputeRepository`, `MandateRepository`, `CulturalNormRepository`, `DissolutionRepository`.
- Mock + Live de cada uno.
- Sin UX visible todavía; sólo modelos y queries listas.
- **Done:** previews y tests compilan contra mocks; live consume Supabase.

### B3 — Propósito en onboarding y settings
- Al crear grupo: pregunta declarada de propósito (1 input opcional). Skip permitido.
- En `GroupSettingsView`: card "Para qué existe este grupo" con kinds declared/operative/emotional.
- En empty state del grupo: si hay propósito declarado, se muestra como hero.

### B4 — Decisiones del grupo (UX)
- Renombrar superficie "Gobernanza" → "Decisiones del grupo".
- Cuando se abre un voto, mostrar `legitimacy_source` ("Esta decisión se toma por mayoría del comité", "Por unanimidad").
- Cuando se cambia una regla, registrar y mostrar la fuente de la decisión.

### B5 — Sanciones extendidas
- `SanctionDetailView` reemplaza `FineDetailView`. Tipos no monetarios renderizan distinto (warning sin monto, suspension con duración, repair_task con checklist).
- Strip de acciones: emitir advertencia / suspender / pedir reparación / emitir multa.

### B6 — Disputas (mediación previa a voto)
- Nueva superficie `Features/Disputes/` (no `Features/Conflicts/`).
- Flow: abrir disputa → asignar mediador → registrar resolución *o* escalar a voto (apelación de sanción cae aquí).
- Inbox surface las disputas abiertas que me involucran.

### B7 — Confianza visible sólo donde sirve
- Sin score ni ranking. En `MemberDetailView` aparece un tab "Historial en este grupo" que lista cumplimientos, sanciones resueltas, contribuciones, disputas — todo neutral.
- Nada de badges, estrellas o "trust score".

### B8 — Membresía con estados
- `MembersListView` agrupa por `membership_state` cuando aplique (provisional / activo / suspendido / exmiembro visible solo a admins).
- Flow de salida explícito: confirmar liquidación de obligaciones abiertas antes de marcar `left`.

### B9 — Representación
- Nueva surface dentro de "Decisiones del grupo": Mandatos vigentes (quién habla por el grupo en X, vencimiento, cómo revocar).
- Crear mandato requiere voto o admin según la política.

### B10 — Cultura opt-in
- `Features/Group/Culture/` (nuevo, simple). Tres listas: Valores, Tabúes, Historias del grupo.
- Cada miembro puede proponer; el grupo endorsa según política.

### B11 — Ritual: anotación en recurrence
- En cualquier sheet de recurrencia (event series, etc.), un picker opcional `ritual_meaning` con marker_kind.
- En el feed: cuando ocurre una instancia anotada, el copy refleja el significado ("Asamblea anual", "Reunión semanal del grupo").

### B12 — Disolución
- En "Decisiones del grupo": acción "Disolver este grupo" (founder + voto según política).
- Wizard de liquidación: ¿qué pasa con el dinero? ¿con los activos? ¿con la memoria? Pasos a marcar.
- Estado terminal: grupo `archived`, sigue siendo legible read-only.

### B13 — Memoria narrativa
- En cada surface principal, anotar el "por qué" en eventos relevantes. La feed ya guarda el qué; B13 agrega la narrativa corta (campo opcional `note` en system_events emitidos por user actions).
- Tab "Historia del grupo" en Group Settings: timeline editorial, no diagnóstico.

### B — Cierre de fase
- Build clean en Xcode 16+.
- `xcodebuild test` verde.
- Smoke manual en device de cada flow.
- Vocab audit: 0 ocurrencias de palabras prohibidas.
- Doctrine review: cada primitiva tiene al menos una superficie o un explícito "post-V1".

---

## 6. Fuera de scope (explícito)

No entra en este plan. Si aparece la tentación, abrir un plan separado **después** de cerrar éste.

- Chat / mensajería intra-grupo (primitiva 7 más allá de notifs).
- Incentivos gamificados (primitiva 10).
- Cuidado/Mantenimiento como UI dedicada (primitiva 24).
- Onboarding de cero-grupo del usuario (auth flow).
- iPad/macOS layouts.
- Push notifications fuera de las existentes.
- Cualquier feature nueva no listada arriba.

---

## 7. Done global

El plan está cerrado cuando:

0. `supabase/migrations/` tiene una sola migración viva: `00001_canonical_schema.sql`. Las antiguas viven en `_archive/`.
1. Un grupo nuevo se crea con propósito explícito.
2. Cada decisión muestra de dónde saca su legitimidad.
3. Una sanción puede ser advertencia, suspensión, reparación o multa.
4. Una disputa puede mediarse antes de votarse.
5. Una membresía puede estar provisional o suspendida.
6. Hay registro de confianza neutral, sin score.
7. Un grupo puede declarar valores, tabúes e historias.
8. Una recurrencia puede anotarse como ritual.
9. Un mandato representa al grupo en X con vencimiento.
10. Un grupo puede disolverse limpiamente.
11. La palabra "governance" no existe ni en código ni en UI.

Si los 12 puntos pasan en device, el plan se mueve a `Plans/Completed/`.
