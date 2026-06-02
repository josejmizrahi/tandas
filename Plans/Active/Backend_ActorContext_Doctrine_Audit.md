# Backend Audit — Actor-Centric / Context-Centric Doctrine (post-R.1)

**Status:** Re-audit post R.1-BE. El audit original (pre-R.1, estado PARCIAL) vive en PR #131.
**Fecha:** 2026-06-02 (actualizado tras shipping de R.1-BE).
**Live DB:** `wyvkqveienzixinonhum` (proyecto "ruul").
**Detalle de implementación:** `Plans/Active/R1_Backend_Hardening_Wiring.md`.
**Doctrina:** `Plans/Active/doctrine_actor_context.md`.

---

## 1. Respuesta a la pregunta del audit

> ¿El backend actual de Ruul soporta la visión final (backend actor-centric, UX context-centric)?

| Momento | Respuesta |
|---|---|
| Pre-R.1 (PR #131) | **PARCIAL** — esqueleto correcto, enforcement y cableado ausentes |
| **Post-R.1 (este doc)** | **SÍ para R.1 backend** — enforcement + cableado completos; Governance/Money actor-aware diferidos a R.2 per doctrina |

---

## 2. Clasificación por área

| Área | Pre-R.1 | Post-R.1 | Evidencia |
|---|---|---|---|
| Actors | 🟢 | 🟢 | 232 actors, forward-sync, cero huérfanos |
| Resources | 🟡 | 🟢 | Fuente única de ownership (`resource_rights.OWN` 100% poblada) + dual-write legacy + `create_personal_resource` |
| Rights | 🟡/🔴 | 🟢 | Autorización compuesta en grant/revoke; creación genera OWN automático; 112 rights activos; `list_actor_resources` |
| Relationships | 🟡 | 🟢 | Autorización; 148 `member_of` proyectadas desde memberships; helpers de legal entity |
| Context Views | 🟡/🔴 | 🟢 | 4/4 views con auth gating; anon revocado; `has_actor_authority` como building block |
| Memberships | 🟡 | 🟢 (R.1) | Proyección automática a `member_of`; user-based aceptado para R.1 |
| Governance | 🟡 (aceptado) | 🟡 **diferido R.2** | 100% group-centric; generalización additive documentada |
| Money | 🟡 (aceptado) | 🟡 **diferido R.2** | 100% membership-coupled; camino actor→actor documentado |
| iOS Contract | 🟡 | 🟢 backend | 18 RPCs del contrato existen, seguros, verificados por `_smoke_r1_backend_contract`; bindings iOS = siguiente ciclo |
| Supabase Hygiene | 🔴 | 🟡 | RLS crítico resuelto (0 tablas sin RLS); quedan compat views SECDEF (intencionales) + warnings legacy pre-existentes |

**Resumen: 8 GREEN, 2 YELLOW (ambos diferidos explícitamente por doctrina), 0 RED.**

---

## 3. Hallazgos críticos del audit original — estado

| # | Hallazgo (PR #131) | Estado |
|---|---|---|
| 1 | `grant_right`/`revoke_right`/`create_actor_relationship`/`end_actor_relationship` sin autorización | ✅ RESUELTO (R.1-SEC.2) — autorización compuesta authority + rights |
| 2 | `group_world_summary`/`legal_entity_world_summary`/`actor_net_worth` SECDEF ejecutables por anon sin gating | ✅ RESUELTO (R.1-SEC.1 + SEC.4) — gating + REVOKE anon/PUBLIC |
| 3 | `group_rule_engine_quotas` y `action_catalog` con RLS disabled | ✅ RESUELTO (R.1-SEC.3) — RLS enabled + policies scoped |
| 4 | `has_actor_authority` no existe | ✅ RESUELTO (R.1-SEC.1) — creada con semántica person/group/legal_entity |
| 5 | 33 resources sin OWN right activo | ✅ RESUELTO (R.1-WIRE.1) — backfill + verificación inline |
| 6 | Creación de resources no genera rights | ✅ RESUELTO (R.1-WIRE.2) — trigger chokepoint AFTER INSERT |
| 7 | 3 write-paths de ownership paralelos sin sincronizar | ✅ RESUELTO (R.1-WIRE.3) — dual-write legacy→universal |
| 8 | Sin path de creación de recursos personales | ✅ RESUELTO (R.1-WIRE.4) — `create_personal_resource` |
| 9 | `list_actor_resources` no existe | ✅ RESUELTO (R.1-WIRE.4) |
| 10 | `actor_relationships` con 0 rows, sin sync de memberships | ✅ RESUELTO (R.1-REL.1) — 148 member_of activas + trigger |
| 11 | RLS SELECT `qual=true` en rights/relationships/legal_entities | ✅ RESUELTO (R.1-SEC.3) — policies scoped por participación |
| 12 | Governance/Money group-centric | 🟡 ACEPTADO — diferido a R.2 per doctrina #7/#8/D5 |

**Hallazgo nuevo de R.1:** `add_resource_owner` estaba roto en producción desde R.0B.1
(compat INSTEAD OF INSERT perdía defaults). Corregido en `r1wire3b`.

---

## 4. Riesgos residuales

| # | Riesgo | Severidad | Plan |
|---|---|---|---|
| R1 | Compat views SECURITY DEFINER (advisor ERROR ×5) | 🟡 Media | Intencionales (compat layer R.0B.1); drop en R.2/R.3 tras migrar ~96 funciones legacy |
| R2 | ~112 funciones legacy group-céntricas con EXECUTE de anon (advisor WARN) | 🟡 Media | Pre-existente; todas con auth interno; sweep de REVOKE en R.2/R.3 con audit caso por caso |
| R3 | `transfer_resource` actor→actor aún no existe | 🟡 Baja | El path existe vía `grant_right` ejecutivo + `set_resource_ownership` dual-write; RPC dedicada en R.2 |
| R4 | net worth funcionalmente vacío (0 resources con `estimated_value` reales) | 🟡 Baja | Riesgo de percepción; data ingestion del producto lo llena |
| R5 | Drift entre `resource_owners` legacy y rights si alguien escribe legacy con SQL directo | 🟢 Baja | Los RPCs sincronizan; escrituras directas a tablas legacy requieren service_role |

---

## 5. Contrato backend listo para iOS (verificado por `_smoke_r1_backend_contract`)

```
my_world_summary()                                    ✅ gated (self)
group_world_summary(p_group_id)                       ✅ gated (member / context.view)
legal_entity_world_summary(p_actor_id)                ✅ gated (context.view)
actor_net_worth(p_actor_id)                           ✅ gated (self / member / finance.view)
list_actor_resources(p_actor_id)                      ✅ gated (self / resources.view)
actor_has_right(p_actor_id, p_resource_id, p_kind)    ✅ authenticated only
has_actor_authority(p_actor_id, p_action)             ✅ authenticated only
grant_right(...)                                      ✅ autorización compuesta
revoke_right(p_right_id)                              ✅ autorización compuesta
create_actor_relationship(...)                        ✅ autorización por subject
end_actor_relationship(p_relationship_id)             ✅ autorización subject/object/creator
list_actor_relationships(...)                         ✅ gated por participación
create_personal_resource(...)                         ✅ nuevo — OWN automático
create_legal_entity(...)                              ✅ + controls creator→entity
update_legal_entity(...)                              ✅ gated (entity.manage)
add_legal_entity_controller/beneficiary/shareholder   ✅ nuevos — gated (entity.manage)
```
