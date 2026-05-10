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
