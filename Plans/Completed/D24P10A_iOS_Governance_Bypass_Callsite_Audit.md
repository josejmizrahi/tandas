# D24P10A — iOS Governance Bypass Call-Site Audit

**Status:** audit-only. **NO migrations, NO schema, NO refactor.**
**Scope:** mapear cada RPC P0/P1 del audit `D24_P10_Governance_Bypass_Audit.md` a su call-site iOS (repo + store + view), clasificar A/B/C/D/E.
**Output del founder esperado:** lista quirúrgica de qué wrappear en D24P10B.

---

## Resumen ejecutivo

**Buenas noticias:** iOS ya tiene un patrón establecido. La mayoría de repositorios canónicos exponen **dos variantes** por cada acción P0:
- `repo.actionMethod(...)` — direct legacy path
- `repo.actionMethodViaGovernance(...)` — via `requestOrExecuteAction` (devuelve `ActionOutcome`)

Las stores ya migraron la mayoría de los flujos visibles del usuario a la variante governance. Lo que falta es:

1. **Algunos stores siguen usando direct** cuando debieran usar governance (revoke_mandate, dispute resolution, role assign/revoke).
2. **Algunos sheets disparan repos direct** sin pasar por store (raro pero existe).
3. **Algunas RPCs P1 no tienen variante governance disponible** en el repo (lock_fund, transfer_right, issue_sanction).
4. **Hay variantes Via no expuestas** en repo (boundary policy tiene `setBoundaryPolicyViaGovernance` pero ningún store la llama).

**14 archivos iOS** ya importan `requestOrExecuteAction`. La pipeline `ActionOutcome` está plenamente operativa.

---

## Clasificación condensada

| Categoría | Significado | Conteo |
|---|---|---|
| **A** | Already routed through action governance (`*ViaGovernance` en store) | 7 RPCs |
| **B** | Direct RPC, intencional (self-service / low-risk) | 5 callsites |
| **C** | Direct RPC P0/P1, **must wrap** | 8 RPCs |
| **D** | Backend RPC sin call-site iOS (unused desde cliente) | 6 RPCs |
| **E** | Internal/preview/test helpers | N/A |

---

## Matriz por RPC

### P0 — must pass governance

| RPC | Repo path | Store callsite | Status | Categoría | Recomendación |
|---|---|---|---|---|---|
| `set_membership_state` | `CanonicalMembersRepository.setMembershipState` + `setMembershipStateViaGovernance` | `MembersStore.saveStateDraft` ✓ governance · `MembersStore.rejectRequest` direct (self-withdraw) | **A** (sheet) + **B** (self-withdraw OK) | `MembershipStateSheet` ya governance. `rejectRequest` queda direct por doctrine (self) |
| `assign_role_to_member` | `CanonicalRolesRepository.assignRole` (NO Via variant) | `RolesStore.assignRole` direct | **C** | Crear `assignRoleViaGovernance` para founder/admin keys |
| `revoke_role_from_member` | `CanonicalRolesRepository.revokeRole` (NO Via) | `RolesStore.revokeRole` direct | **C** | Crear `revokeRoleViaGovernance` para founder/admin keys |
| `create_custom_role` | `CanonicalRolesRepository.createCustomRole` + `createCustomRoleViaGovernance` ✓ | `RolesStore` línea 173 governance ✓ | **A** | OK |
| `update_role_permissions` | `CanonicalRolesRepository.updateRolePermissions` + `updateRolePermissionsViaGovernance` ✓ | `RolesStore` línea 162 governance ✓ | **A** | OK |
| `set_group_visibility` | `CanonicalPrivacyRepository.setVisibility` + `setVisibilityViaGovernance` ✓ | `PrivacyStore` línea 57 governance ✓ | **A** | OK |
| `set_group_boundary_policy` | `CanonicalBoundaryRepository.setBoundaryPolicy` + governance variant ✓ | **¿BoundaryPolicyStore?** — no usa Via variant | **C** | Auditar `BoundaryPolicyView`: ¿llama repo direct? Wirear store→Via |
| `set_decision_rules` | `CanonicalDecisionRulesRepository.setDecisionRules` + `setDecisionRulesViaGovernance` ✓ | `DecisionRulesStore` línea 170 governance ✓ | **A** | OK |
| `set_resource_ownership` | `CanonicalResourcesRepository.setOwnership` + `transferOwnershipViaGovernance` ✓ | `ResourcesStore` línea 316 governance ✓ | **A** | OK |
| `add_resource_owner` (D.24 P3A) | NO en iOS repo todavía (backend-only ship) | N/A | **D** | iOS no cablea aún — al hacerlo, ofrecer Via variant para primary owner changes |
| `end_resource_owner` (D.24 P3A) | NO en iOS repo todavía | N/A | **D** | Igual |
| `update_sanction_status` | NO en iOS repo (solo backend via execute_decision) | N/A | **D** | OK — solo invocado vía decision execution |
| `record_dispute_resolution` | `CanonicalDisputesRepository.recordResolution` (NO Via) | `DisputesStore` línea 325 direct | **C** | Crear `recordResolutionViaGovernance` |
| `archive_rule` | `CanonicalRulesRepository.archiveRule` + `archiveRuleViaGovernance` ✓ | `RulesStore` línea 330 governance ✓ | **A** | OK |
| `publish_rule_version` | NO call-site iOS visible | N/A | **D** | Backend-only — OK |
| `propose_dissolution` | `CanonicalDissolutionRepository.propose` (NO Via) | `DissolutionStore` línea 79 direct | **B** | OK — el start del proceso es la propuesta (acceptable direct); approve+finalize ya van via execute_decision |
| `revoke_mandate` | `CanonicalMandatesRepository.revoke` (NO Via) | `MandatesStore.revoke` línea 156 direct | **C** | Crear `revokeViaGovernance` |
| `grant_mandate` | `CanonicalMandatesRepository.grant` + `grantViaGovernance` ✓ | `MandatesStore.grant` línea 114 governance ✓ | **A** | OK |

### P1 — recommended but not blocker

| RPC | Repo path | Store callsite | Status | Categoría | Recomendación |
|---|---|---|---|---|---|
| `issue_sanction` | `CanonicalSanctionsRepository.issue` (NO Via) | `SanctionsStore.issue` línea 110 direct | **C** | Crear `issueViaGovernance` para sanctions monetarias > threshold |
| `archive_resource` | `CanonicalResourcesRepository.archive` + `archiveResourceViaGovernance` ✓ | `ResourcesStore` línea 240 governance ✓ | **A** | OK |
| `update_resource_value` | NO Via variant, NO store callsite directo | N/A | **D** | Sheet `RecordValuationSheet` lo llama? Verificar. Backend-only por ahora. |
| `lock_fund` | `CanonicalResourcesRepository.lockFund` (NO Via) | `ResourcesStore` línea 602 direct | **C** | Crear `lockFundViaGovernance` (lock irreversible) |
| `transfer_right` | `CanonicalResourcesRepository.transferRight` (NO Via) | `ResourcesStore` línea 886 direct | **C** | Wrap solo si non-self (holder transferable=true) |
| `reverse_transaction` | NO Via, NO store callsite | N/A | **D** | Solo via `execute_decision.money_movement` con action_key. iOS no expone direct. OK |
| `record_payout` | NO call-site iOS | N/A | **D** | Solo backend via `execute_decision.money.payout`. OK |
| `promote_norm_to_rule` | `CanonicalCulturalNormsRepository.promoteNormToRule` (NO Via) | No store call-site direct | **B** | El path real via `execute_decision.norm.promote_to_rule` (action_key). El repo direct existe pero no se invoca en flujo normal. **Verify**: drop repo method si no se usa |

---

## Hallazgos puntuales

### 1. `BoundaryPolicyView` (verificar)

`CanonicalBoundaryRepository.setBoundaryPolicy` + `setBoundaryPolicyViaGovernance` ambos existen, pero `BoundaryPolicyStore` solo expone `setBoundaryPolicy` direct (línea 14 según test). Hay que confirmar el call-site en `BoundaryPolicyView.swift`.

Si la sheet llama direct → **C** (debe wrap a governance).
Si ya hay flujo Via store → **A**.

### 2. `MandatesStore.revoke` línea 156 (CRITICAL)

```swift
try await repository.revoke(mandateId: mandateId, reason: reason)
```

Llama direct. Pero `execute_decision.mandate_revoke` ya rutea via governance cuando se ejecuta una decisión que revoca. El problema es que iOS expone el botón "Revocar" en `MandatesListView` con direct path. Si admin tiene `mandates.revoke` perm → revoca instantáneo sin voto.

**Categoría C**. Recomendación: crear `revokeViaGovernance` con action_key=`mandate.revoke`.

### 3. `RolesStore.assignRole / revokeRole` (CRITICAL para founder/admin)

Líneas 222-229: direct sin governance check. Hoy admin puede mover otro admin con un tap.

**Categoría C**. Recomendación: en repo crear `assignRoleViaGovernance` y `revokeRoleViaGovernance` que sigan el patrón D.22: si el role-key es `founder/admin` → governance; si es role custom → direct allowed.

### 4. `SanctionsStore.issue` línea 110

Direct. Admin emite sanction con un tap. Aceptable para sanctions menores; problemático para sanctions monetarias.

**Categoría C parcial**. Sugerencia: wrap solo si `amount > umbral_grupo`. Threshold puede vivir en `groups.governance.action_thresholds` (memory `doctrine_action_governance_tiers`).

### 5. `DisputesStore.recordResolution` línea 325

Direct. Resolver dispute es vinculante. Debe pasar por governance si es resolución sancionatoria.

**Categoría C**. Crear `recordResolutionViaGovernance`.

### 6. `ResourcesStore.lockFund` línea 602, `transferRight` línea 886

Direct. Locks de fondos y transferencias de derechos son significativos.

**Categoría C**. Wraps recomendados.

---

## Lista quirúrgica para D24P10B

### C (must wrap, priority order)

1. **`MandatesStore.revoke`** → `revokeMandateViaGovernance` (action_key: `mandate.revoke`)
2. **`RolesStore.assignRole/revokeRole`** → variants con governance solo para `founder/admin` keys (action_key: `role.assign`, `role.revoke`)
3. **`DisputesStore.recordResolution`** → `recordResolutionViaGovernance` (action_key: `dispute.resolve`)
4. **`SanctionsStore.issue`** → `issueViaGovernance` para sanctions monetarias > threshold (action_key: `money.sanction.issue`)
5. **`ResourcesStore.lockFund`** → `lockFundViaGovernance` (action_key: `resource.fund.lock`)
6. **`ResourcesStore.transferRight`** → `transferRightViaGovernance` cuando holder ≠ caller (action_key: `resource.right.transfer`)
7. **`BoundaryPolicyStore.setBoundaryPolicy`** (CONFIRMAR si está direct) → wirear `setBoundaryPolicyViaGovernance` existente

### B (intencional direct, OK)

- `MembersStore.rejectRequest` (self-withdraw)
- `DissolutionStore.propose` (start del proceso; approve/finalize ya governance)
- `RolesStore.assignRole/revokeRole` cuando role-key es custom (no founder/admin)

### A (already governance)

- Membership state (sheet): ✓
- Custom role create/update permissions: ✓
- Group visibility: ✓
- Decision rules: ✓
- Resource transfer ownership: ✓
- Resource archive: ✓
- Archive rule: ✓
- Grant mandate: ✓

### D (no iOS call-site, OK)

- `add_resource_owner` / `end_resource_owner` (P3A backend-only)
- `update_sanction_status` (solo via execute_decision)
- `publish_rule_version` (solo backend)
- `update_resource_value` (no call-site directo visible)
- `reverse_transaction` (solo via execute_decision.money_movement)
- `record_payout` (solo via execute_decision.money.payout)

---

## Compatibilidad iOS (D24P10B implications)

Para implementar los 7 wraps **C**:

1. Agregar al repo correspondiente la variante `*ViaGovernance` (siguiendo patrón D.22 que ya existe en 8 repos).
2. Cambiar store call-site para usar la variante governance.
3. Manejar `ActionOutcome` en el store (memory `doctrine_action_governance_tiers`):
   - `.executed` → refresh local state
   - `.decisionOpened` → mostrar "Decisión abierta para votar"
   - `.denied` → mostrar permission missing
   - `.unsupported` → log internal error
   - `.failed` → mostrar error.message

Cada wrap es **additive** — la variante direct queda intacta, los call-sites legacy siguen funcionando. iOS UI cambia solo lo necesario.

**Volumen estimado D24P10B:** ~7 repos a extender + ~7 store callsites a cambiar + UI handling de `ActionOutcome` donde no lo hay. Una sesión.

---

## Smoke / validación post-P10A

Esta fase es audit-only. No hay smoke.

Para D24P10B (futura sesión):
1. Smoke SQL: cada action_key (`mandate.revoke`, `role.assign`, etc.) en `action_catalog` con role_member sin perm → governance dispara, no error.
2. Build verde iOS.
3. Manual test en simulador: para cada uno de los 7 wraps, role=member sin perm intenta → sheet/banner muestra "se abrirá decisión" en vez de error.

---

## Conclusión

iOS está mejor de lo que la auditoría backend P10 sugería. **7 de los ~15 RPCs P0/P1** ya están routed via governance en stores. Quedan **7 RPCs C** donde el iOS expone direct path sin variante governance:

```
P0: revoke_mandate, assign_role_to_member, revoke_role_from_member,
    record_dispute_resolution, [boundary policy callsite — confirmar]
P1: issue_sanction (monetary > threshold), lock_fund, transfer_right (non-self)
```

**Recomendación firme:** ejecutar D24P10B (las 7 wraps) antes de tocar PHASE 7B, 11, 12, 13. Es una sesión chica y cierra el loop constitutional.

Después de D24P10B, ahí sí Storage / Read Models / Ledger Design.
