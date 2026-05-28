# A0 — Inventario de data viva en producción

> Snapshot capturado 2026-05-26 vía `mcp__supabase__list_tables` + `execute_sql` contra `fpfvlrwcskhgsjuhrjpz`.
> Sirve como input para A1 (diseño del `00001_canonical_schema.sql`) y A3 (script export/import).

---

## TL;DR

- **343 migraciones forward** actualmente vivas (no 63 como decía CLAUDE.md).
- **Data total ≤ 100 filas** en todas las tablas con contenido. Esto vuelve el reshape trivial.
- **Las tablas legacy del audit ya no existen**: `pots`, `pot_entries`, `expenses`, `expense_shares`, `payments`, `appeals`, `appeal_vote`, `group_balances` — todas ya droppeadas en migraciones previas.
- Lo único legacy vivo: `rule_conflicts` (0 filas), `member_capability_overrides` (0 filas).
- Money 2.0 (Phase 4+): tablas existen pero **0 filas en prod**. La validación on-device del 2026-05-26 fue en dev/staging, no en este project.

---

## Tablas con contenido (preservar en migración)

| Tabla | Filas | Naturaleza | Mapping al canónico |
|---|---:|---|---|
| `profiles` | 11 | usuarios reales (dogfooding) | `profiles` — mismo nombre |
| `groups` | 3 | grupos reales | `groups` — renombra jsonb `governance` → `decision_rules` |
| `group_members` | 13 | memberships reales | `group_members` — convertir `active` → `membership_state` enum |
| `invites` | 10 | mayoría placeholders | `invites` — mismo |
| `identity_atoms` | 12 | atoms de identidad (placeholder linking) | `identity_atoms` — mismo |
| `resources` | 7 | 3 fund · 2 asset · 1 event · 1 space | `resources` — agregar `ownership_kind='group'` default |
| `system_events` | 27 | mostly `member.placeholder_created` (10) + RSVPs (3) + groupCreated (3) + ledgerEntry/asset/valuation/event lifecycle | `system_events` — append-only, mover tal cual |
| `group_policies` | 24 | seeds per-grupo (8×3) | `permission_policies` (rename) — re-seed desde scratch al crear grupo |
| `rsvp_actions` | 3 | append-only RSVP atoms | `rsvp_actions` — mismo |
| `user_actions` | 2 | inbox items | `user_actions` — mismo |
| `ledger_entries` | 1 | un único entry de dogfooding | `ledger_entries` — mismo, ya tiene shape Money 2.0 |
| `notifications_outbox` | 1 | un push pending/sent | `notifications_outbox` — mismo |
| `notification_tokens` | 1 | APNs token | `notification_tokens` — mismo |

**Total filas a mover: ~115.** Cabe en un dump SQL de pocos KB.

---

## Tablas vacías que se conservan (estructura + lógica)

Sin filas en prod hoy, pero **son parte del modelo canónico** y siguen vigentes:

- `rules`, `rule_versions`, `rule_evaluations`, `rule_shapes`, `rule_templates` — rule engine.
- `votes`, `vote_casts` — decisiones.
- `fines` → renombrar a `sanctions` con `kind`.
- `fine_review_periods` → renombrar a `sanction_review_periods` (o colapsar si no se usa).
- `obligations`, `settlements`, `settlement_obligations` — Money 2.0 Phase 4 (validated en dev).
- `templates`, `modules`, `capabilities`, `resource_capabilities` — catálogos.
- `resource_series`, `resource_link_kinds`, `resource_links`, `bookings` — recurso polimórfico.
- `check_in_actions` — atom de attendance.
- `notification_preferences` — settings de push.
- `otp_codes` — auth.
- `system_event_payload_schemas` — validación de payload.

---

## Tablas vacías y muertas (NO existen en canónico)

| Tabla | Filas | Razón |
|---|---:|---|
| `rule_conflicts` | 0 | nunca se evalúa; concept reemplazado por publish-time check |
| `member_capability_overrides` | 0 | "post-beta" desde hace tiempo; sin uso real |
| `data_subject_rights_requests` | 0 | GDPR scaffold — mantener si hay app code que lo llama; investigar en A1 |
| `data_deletion_log` | 0 | idem |

**Decisión A1:** drop `rule_conflicts` + `member_capability_overrides`. `data_*` se decide al revisar si edge functions / RPC actuales (`delete_and_export_my_data`, `data_rights_janitor`) los llaman.

---

## Views actuales (recrear desde tablas canónicas)

- `group_money_summary_view` — Money 2.0
- `member_balances_per_group` — Money 2.0
- `member_obligations_view` — Money 2.0 (v2)

Las 3 se reconstruyen en `00001_canonical_schema.sql` § Money, idénticas en shape para que callers iOS sigan funcionando post-rename de columnas.

---

## Distribución de resources (7 filas)

- `fund`: 3
- `asset`: 2
- `event`: 1
- `space`: 1

Sirve como sanity check post-import.

---

## Distribución de system_events (27 filas)

| event_type | count |
|---|---:|
| `member.placeholder_created` | 10 |
| `rsvpSubmitted` | 3 |
| `groupCreated` | 3 |
| `ledgerEntryCreated` | 2 |
| `assetCreated` | 2 |
| `valuationRecorded` | 2 |
| `eventUpdated` | 1 |
| `spaceCreated` | 1 |
| `eventCreated` | 1 |
| `fundDeposit` | 1 |
| `rsvpChangedSameDay` | 1 |

Confirma que el grueso del log son atoms de creación + RSVP, sin sanciones ni disputas reales.

---

## Implicaciones para el plan

1. **Export/import es trivial.** ~115 filas de data viva. El script A3 puede ser un único `pg_dump --data-only` sobre la lista de tablas + `psql` import al branch, con un pequeño script de transformación de columnas renombradas (`groups.governance → decision_rules`, `group_members.active → membership_state`, `fines → sanctions`).
2. **Empty tables** no necesitan migración de data, solo recrear shape. Toda la lógica vive en `00001_canonical_schema.sql`.
3. **Seeds idempotentes.** `modules`, `capabilities`, `templates`, `rule_shapes`, `rule_templates`, `resource_link_kinds`, `system_event_payload_schemas` se seedean dentro de `00001_canonical_schema.sql` (no hace falta importar de prod).
4. **`group_policies` (24 filas)** son seeds per-grupo, no data del usuario. Se descartan y se re-seedean automáticamente cuando el script de import dispara el trigger de `create_group_with_admin` o equivalente. Confirmar en A1.
5. **`base_template` nullable** (mig `20260526075716`) — ya está nullable. El canónico lo respeta.
6. **Money 2.0 está implementada pero no probada en prod.** A6 (smoke test post-import) debe incluir un escenario completo: registrar expense → ver obligation → registrar settlement → ver balance.
7. **Backup recomendado** justo antes de A8 (merge): `pg_dump` completo del DB de prod a un archivo local. Reversibilidad cero-costo.

---

## Próximo paso

A1 — diseñar `00001_canonical_schema.sql` ordenado por las 13 secciones del Plan §4.A1. Output: archivo SQL completo + comentario por tabla nombrando la primitiva que cubre.
