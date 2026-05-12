# `GovernanceRules` jsonb-driven (eliminar struct typed)

> Status: stub. Ejecución pre-Fase 4 (cuando Fund + Contribution +
> Cycle agreguen nuevos `whoCan*`). Tracked en
> `Plans/Completed/Audit-2026-05-06.md` § 4.3 Riesgo 3.

## Por qué

`GovernanceRules` Swift struct (`RuulCore/PlatformModels/GovernanceRules.swift`)
hoy declara seis `whoCan*` campos hardcoded:

```swift
public struct GovernanceRules: Codable, Sendable {
    public var whoCanModifyRules: PermissionLevel
    public var whoCanInviteMembers: PermissionLevel
    public var whoCanRemoveMembers: PermissionLevel
    public var whoCanCloseEvents: PermissionLevel
    public var whoCanCreateVotes: PermissionLevel
    public var whoCanModifyGovernance: PermissionLevel
    public var votingQuorumPercent: Int
    public var votingThresholdPercent: Int
    public var votingDurationHours: Int
    public var votesAreAnonymous: Bool
}
```

Cada nuevo `whoCan*` requiere coordinar:

1. Swift release con campo nuevo + default deserializer + tests
2. Migration backfill de `groups.governance` jsonb con la key nueva
3. Sync de toda RLS / RPC que mire la key

Cuando Fase 4 traiga Fund, vamos a necesitar:

- `whoCanWithdrawFromFund`
- `whoCanContribute`
- `whoCanAuditFund`
- `whoCanCloseFundCycle`

Cuando Fase 5 traiga Proposals + Comments:

- `whoCanCreateProposal`
- `whoCanComment`
- `whoCanCloseProposal`

Y cuando Fase 6 traiga marketplace de templates:

- `whoCanForkTemplate`
- `whoCanPublishTemplate`

Llegamos a 12-15 campos. El patrón "agrega campo Swift cada vez" no
escala, viola "templates como configuración" (Vision §Principios #2),
y hace cada feature nueva más cara de lo que debería ser.

## Enfoque

Convertir `GovernanceRules` en wrapper sobre `[String: PermissionLevel]`
(jsonb directo), con conveniencia API typed para ergonomía:

```swift
public struct GovernanceRules: Codable, Sendable {
    private var permissions: [String: PermissionLevel]
    public var votingQuorumPercent: Int
    public var votingThresholdPercent: Int
    public var votingDurationHours: Int
    public var votesAreAnonymous: Bool

    public func permissionFor(_ action: GovernanceAction) -> PermissionLevel {
        permissions[action.rawValue] ?? action.defaultPermission
    }

    // Conveniencia typed:
    public var whoCanModifyRules: PermissionLevel {
        permissionFor(.modifyRules)
    }
    // ... etc
}
```

`GovernanceAction` (ya es `String` rawValue) gana cases nuevos sin
schema migration:

```swift
public enum GovernanceAction: String, Codable, Sendable {
    case modifyRules
    case inviteMembers
    // ...
    case withdrawFromFund    // Fase 4 — sin migration adicional
    case contribute          // Fase 4
    case createProposal      // Fase 5
}
```

Y `groups.governance` queda igual (jsonb), solo que ahora soporta keys
arbitrarias `whoCan*` sin migración.

## Tareas (cuando se ejecute)

1. **Refactor `GovernanceRules`**:
   - Cambiar campos typed → `[String: PermissionLevel]` privado +
     conveniencia accessors
   - Custom Codable decoder tolera ambas formas (typed legacy +
     jsonb-driven)
   - `recurringDinnerDefaults` se construye con dictionary literals
2. **`GovernanceAction` permissions defaults**:
   - Cada case tiene `defaultPermission: PermissionLevel` propiedad
   - Sirve cuando una key no está presente en jsonb
3. **`GovernanceService.canPerform`**:
   - Lee de `governance.permissionFor(action)`, no de campo typed
4. **Migration `groups.governance`**:
   - Existing groups: noop. Las keys actuales siguen funcionando.
5. **Tests**:
   - Decoder roundtrip para typed-legacy + jsonb-driven inputs
   - Forward-compat: governance que tiene `whoCanWithdrawFromFund`
     antes de que el cliente sepa de Fund — debe tolerarse silently
6. **Eliminar typed campos públicos** (sprint follow-up cuando 0 callers
   usan `governance.whoCanModifyRules` directo y todos pasan por
   `governance.permissionFor(.modifyRules)`):
   - Mantener accessors `whoCan*` como computed deprecated
   - Después de un release: eliminar accessors

## DoD

- [ ] Agregar un nuevo `whoCan*` no requiere Swift release (solo agregar
      `GovernanceAction` case). Confirmado porque cuando Fund llegue,
      `whoCanWithdrawFromFund` se introduce sin cambios a `GovernanceRules`.
- [ ] Decoder tolera grupos con governance jsonb que tiene keys custom
      no-en-enum (back-compat futura).
- [ ] `recurringDinnerDefaults` queda alineado.
- [ ] Tests de decoder cubren los 3 casos (typed-legacy, jsonb-driven, mixed).

## Cuándo NO hacerlo

- En V1. Struct typed funciona perfecto y `GroupGovernanceConfigView`
  está construida sobre los campos typed.
- Cuando no hay caso real para un `whoCan*` nuevo. Migrar prematuro =
  refactor sin ROI.
- Antes de Beta 1 close. Toca AppState, GovernanceService, governance
  config UI; demasiado churn pre-validación.

## Cuándo SÍ — gate concreto

Cuando la primera de estas dos cosas pase:

1. Fase 4 spec gane su primer `whoCan*` Fund-related. Hacer el refactor
   antes de empezar Fund (no junto, no después).
2. O alguien proponga "vamos a hardcodear `whoCanWithdrawFromFund` típado
   por simplicidad". Eso es la señal para detenerse y hacer el refactor.

## Costo estimado

2-3 días focused. Riesgo medio: toca `GroupGovernanceConfigView` y
`GovernanceConfigSheet`. Tests existentes deben pasar sin cambios
porque accessors typed se mantienen como conveniencia.

---

## Anexo (audit 2026-05-12) — Jerarquía `groups.governance` ↔ `public.group_policies`

Post-mig 00087 hay dos lugares donde vive política de gobernanza, y el
boundary no estaba documentado. Antes de tocar nada más, congelamos la
semántica.

### Capas

| Capa | Storage | Granularidad | Mutabilidad |
|---|---|---|---|
| **Global defaults** | `groups.governance` jsonb | grupo entero | edita founder o vote |
| **Action × Scope overrides** | `public.group_policies` rows | `(target_action, target_scope, target_resource_type?, target_resource_id?)` | edita founder o vote |

`groups.governance` declara los defaults que aplican cuando no hay
override más específico:

```json
{
  "whoCanModifyRules": "founder",
  "whoCanInviteMembers": "founder",
  "whoCanRemoveMembers": "majorityVote",
  "votingQuorumPercent": 50,
  "votingThresholdPercent": 50,
  "votingDurationHours": 72,
  "votesAreAnonymous": false
}
```

`group_policies` declara overrides progresivamente específicos:

| `target_scope` | Significado | Ejemplo |
|---|---|---|
| `group` | aplica al grupo entero (override directo de governance default) | "para *este* grupo, modifyRules requiere `unanimousVote`" |
| `resource_type` | aplica a todos los Resources del tipo | "para todos los Funds del grupo, withdrawFund requiere `majorityVote`" |
| `resource` | aplica a un Resource específico | "para el Fund Cumpleaños, withdraw requiere `unanimousVote`" |

### Resolución

`resolve_governance(group_id, action, resource?)` (mig 00088) ya
implementa la jerarquía. La regla es **más-específica-gana** con
desempate por `priority` descendente:

```
1. Buscar group_policies donde
     target_action = $action AND enabled = true AND (
       (target_scope = 'resource' AND target_resource_id = $resource.id)
       OR (target_scope = 'resource_type' AND target_resource_type = $resource.type)
       OR (target_scope = 'group')
     )
   ordenadas por
     (target_scope = 'resource')      DESC,   -- 1°: resource-specific
     (target_scope = 'resource_type') DESC,   -- 2°: type-wide
     (target_scope = 'group')         DESC,   -- 3°: group-wide override
     priority                          DESC,   -- desempate
     created_at                        ASC

2. Si hay match: usar policy.approval_config (quorum/threshold/permission).
3. Si no hay match: fallback a groups.governance[whoCanX] o
   whoCanX_default del enum GovernanceAction.
```

### Reglas de coexistencia (no negociables post-audit)

- **Una governance jsonb key no debe duplicar una policy row.** Si una
  key existe en governance Y existe una policy con `target_scope='group'`
  para esa acción, la policy gana — pero el row jsonb queda como
  documentación zombie. Cleanup: cuando se inserta la primera policy
  `target_scope='group'` para una acción, dropear la key correspondiente
  de governance jsonb en la misma transacción.

- **Resource-specific policies no necesitan governance jsonb default.**
  La governance es para el caso global; la policy específica es para el
  override. Si solo existe el override (sin global), el resolver cae al
  `defaultPermission` del enum case.

- **Nuevos `whoCan*` después del refactor jsonb-driven entran como
  `GovernanceAction` enum cases.** El resolver consulta primero
  `group_policies`, después `groups.governance.permissions[action]`,
  después `action.defaultPermission`. Tres niveles, mismo contrato.

### Por qué este boundary

Antes del audit: developers veían `group_policies` table y pensaban que
era el lugar canónico; otros veían `groups.governance` jsonb y pensaban
que ese era. Sin doc claro, cada feature elegía el suyo y la
inconsistencia se infiltraba.

Después: governance jsonb = defaults globales del grupo; group_policies =
overrides por (action × scope). Resolver lee policies primero, governance
después. El refactor de §"Por qué" sigue siendo válido — pero pasa a
ser refactor del lado *governance jsonb*, no del lado *group_policies*.
