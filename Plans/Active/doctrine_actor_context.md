# Doctrina Actor / Context — Ruul

**Status:** Doctrina vigente post R.1-BE (2026-06-02).
**Principio rector:** Backend = actor-centric. UX = context-centric.

---

## 1. Primitivas

### Actor — unidad de datos

Todo dueño/participante del sistema es un actor: `person`, `group`, `legal_entity`
(extensible vía CHECK whitelist a family/trust/dao sin modelo paralelo).
UUIDs compartidos: `actors.id = profiles.id` (person), `actors.id = groups.id` (group).

### Contexto — vista operativa de un actor

NO hay tabla `contexts`. Un contexto es la proyección de un actor a través de las
context views: `my_world_summary` (person, self-scoped), `group_world_summary`,
`legal_entity_world_summary`, todas delegando net worth a `actor_net_worth`.

### Resource — existe una sola vez

Una sola tabla física `resources`. `group_id` es scope legacy opcional (NULL = personal).
`canonical_owner_actor_id` es **cache/UI hint**, NUNCA autoridad — se sincroniza por
trigger desde el OWN activo de mayor percent.

### Rights — fuente formal de relevancia actor ↔ recurso

`resource_rights` universal (15 kinds). **OWN es la única fuente de verdad de ownership.**
- Todo resource nuevo genera OWN 100% automático para su canonical owner (trigger R.1-WIRE.2).
- Los write-paths legacy (add_resource_owner / end_resource_owner / set_resource_ownership)
  hacen dual-write a rights — no existe drift.
- `list_actor_resources` explica relevancia por `right_kind`.

### Relationships — vínculos semánticos

`actor_relationships` (14 types, exactly-one object actor/resource).
- `member_of` se proyecta automáticamente desde `group_memberships` (trigger R.1-REL.1).
- Relaciones de legal entity (controls/beneficiary_of/shareholder_of) se gestionan vía
  helpers gated por autoridad sobre la entity.
- NO se crea relationship `owns` — ownership vive exclusivamente en rights.

### Memberships — participación operativa

`group_memberships` sigue siendo user-based (aceptado en R.1). Se proyecta al grafo como
`member_of`; la participación de actores no-persona en grupos queda para R.2.

---

## 2. Modelo de autorización (R.1-SEC)

Dos sistemas ortogonales que los RPCs sensibles componen:

1. **`has_actor_authority(actor, action)`** — ¿el caller puede actuar EN NOMBRE del actor?
   (governance interna)
   - person → `auth.uid() = actor_id`
   - group → `has_group_permission` (+ mapping de acciones doctrina → permission keys del catálogo)
   - legal_entity → relación activa controls/trustee_of/admin_of, o creator
2. **`actor_has_right(actor, resource, kind)`** — ¿qué puede el actor SOBRE un recurso?
   (rights formales)

Regla de composición ejemplo (`grant_right` de un kind ejecutivo):
`actor_has_right(caller, resource, 'OWN') OR has_actor_authority(canonical_owner, 'resources.transfer')`.

### Gating de contexto

| Context view | Quién puede leer |
|---|---|
| my_world | solo self |
| group world | miembros activos + quien tenga `context.view` authority |
| legal entity world | quien controle la entity |
| net worth | self, miembros (para grupos), `finance.view` authority |

anon no ejecuta NADA del contrato actor-céntrico (REVOKE PUBLIC/anon explícito).

---

## 3. Governance y Money (diferidos a R.2)

Siguen group-centric por doctrina explícita. Camino de generalización (additive, no destructivo):

- **Governance:** `proposer_actor_id`/`voter_actor_id` nullable en decisions/votes;
  el layer `action_catalog`/`resolve_action_governance` (D.22) ya es independiente del
  actor-type y es el punto de enganche para `has_actor_authority`.
- **Money:** `debtor_actor_id`/`creditor_actor_id` nullable en obligations/settlements/
  transactions + backfill desde membership.user_id + overloads actor-aware de los RPCs.

---

## 4. Invariantes (enforced por smokes)

1. Todo resource activo con `canonical_owner_actor_id` tiene OWN right activo.
2. Toda membership activa (user_id NOT NULL) tiene `member_of` activa en el grafo.
3. `canonical_owner_actor_id` = holder del OWN activo de mayor percent.
4. Ningún RPC del contrato actor-céntrico es ejecutable por anon.
5. Ninguna tabla crítica (actors/resources/rights/relationships/legal_entities/
   action_catalog/quotas) tiene RLS disabled.
6. Los write RPCs actor-céntricos componen autorización (authority + rights), nunca
   solo autenticación.

Smokes que protegen estos invariantes:
`_smoke_r1sec_actor_authority` (10 casos) · `_smoke_r1wire_resource_rights_wiring` (8 casos) ·
`_smoke_r1rel_relationship_wiring` (5 casos) · `_smoke_r1_backend_contract` (contrato completo).
