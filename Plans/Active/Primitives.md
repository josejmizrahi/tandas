# Ruul — Canonical Primitives

> Status: **canónico, no implementación**. Documento de referencia
> arquitectónica para decisiones Phase 2+. **No dispara refactor durante
> Beta 1.** Cualquier ajuste de código que se derive de este doc se
> agenda después del cierre de Beta 1 (ver `Beta1.md` § 6).
>
> Audiencia: founder + cualquier sesión futura que necesite ubicar dónde
> encaja una primitive nueva (slot, fund, asset, rotation…) sin abrir
> verticales.

---

## 0. Por qué este documento

Phase 2 va a empezar a meter primitives nuevas (Rotation, Slot, Fund,
Asset, Booking, Contribution…) en función de lo que las cenas reales
de Beta 1 demanden. Sin un mapa explícito de qué cuenta como primitive
y a qué nivel, cada primitive nueva se agrega ad-hoc — exactamente el
patrón que produjo `group_type` y la confusión template/módulo que
Beta 1 intentó cerrar.

Este doc fija:

1. **El patrón base** (Atom vs Projection) que aplica a varias primitives.
2. **Los 5 niveles** y qué primitive vive en cada uno.
3. **La regla canónica de Resource** (cuándo algo merece serlo).
4. **Las reducciones conceptuales** (Vote/Fine como derivados, Module
   como Registry+Resolver, Role/Permission/Policy como stack único).
5. **El estado actual** vs lo que falta — pero **sin fechas ni tareas**.

Las decisiones de cuál primitive ejecutar primero se documentan
en `Beta1.md` § 6 y luego en `Phase2.md`.

---

## 1. Patrón base — Atom vs Projection

Varias primitives existentes y futuras siguen el mismo patrón estructural
y conviene reconocerlo explícitamente.

| Atom (append-only, autoritativa) | Projection (derivada, leíble) |
|---|---|
| `system_events` | History view / `group_history` |
| `votes` casts (cuando exista granular) | `votes.tally` / `Decision` |
| `account.move.line` (futuro Ledger) | `Balance` per holder |
| `fines.events` (audit trail interno, hoy implícito) | `Fine.status` |
| `rules` revisions (cuando lleguen) | `Rule.current` |

**Regla**:

- Las **atoms** son append-only. No se editan, no se borran. Son la
  fuente única de verdad. Se escriben con `record_*` SECURITY DEFINER
  o equivalente.
- Las **projections** son derivadas. Pueden cachearse, recomputarse,
  invalidarse. Son lo que la UI lee.

**Implicaciones de diseño**:

- Cualquier primitive nueva que dependa de "estado actual derivado de
  hechos pasados" se modela como atom + projection separadas. No se
  modelan como tabla mutable única.
- El rule engine (`supabase/functions/_shared/ruleEngine.ts`) consume
  atoms (`system_events`) y produce atoms (más events + fines). Las
  projections no se le dan al engine — se construyen para humanos.
- Las migrations 00039 (events → resources dual-write) y 00043 (vote
  cast → user_action resolve) son ya instancias de este patrón aunque
  no estén nombradas así.

**Cuando aparezca Fund / Ledger / Balance** (Phase 4): ledger es atom,
balance es projection. **No** modelar `balance_per_member` como tabla
editable.

---

## 2. Niveles de primitives

Los niveles no son temporales (no son fases). Son **arquitectónicos**:
qué tan fundamental es cada primitive para que Ruul exista.

### L1 — Núcleo (sin esto no hay Ruul)

| Primitive | Estado | Notas |
|---|---|---|
| **Group** | ✅ vivo | Comunidad persistente. `groups` table. |
| **Identity** | ✅ vivo | `auth.users`. La persona, no su relación con un grupo. |
| **Membership** | ✅ vivo | `group_members`. La relación Identity ↔ Group. **Es L1, no L5.** |
| **Role** | ✅ parcial | `group_members.role` text libre hoy; `groups.roles` jsonb pendiente (`RolesV2.md`). Parte del stack Role/Permission/Policy (§ 4). |
| **Module + Registry + Resolver** | ✅ done (con deuda de SoT) | Tripleta completa (§ 3). Deuda viva: divergencia `fines_enabled` ↔ `active_modules` ↔ `governance.finesEnabled`. Plan multi-slice en § 3. |
| **Resource** | ✅ vivo | Polimórfico vía `resources.resource_type`. Solo entidades con gobernanza propia (§ 5). |
| **Rule** | ✅ vivo | WHEN/IF/THEN jsonb. Engine server-only. |
| **SystemEvent** | ✅ vivo | `system_events` append-only. Atom canónica. |
| **Atom/Projection** (meta) | ✅ aplicado | Patrón, no tabla. Documentado en § 1. |

### L2 — Operación (lo que hace que el grupo funcione día a día)

| Primitive | Estado | Notas |
|---|---|---|
| **Vote** | ✅ vivo, derivado | Instrumento, no átomo (§ 6). |
| **Fine** | ✅ vivo, derivado | Instrumento de consequence (§ 6). |
| **Appeal** | ✅ vivo | Especialización de Vote. |
| **Notification** | ✅ parcial | `notifications_outbox` + APNs cron. |
| **Permission** | ⚠️ implícito | Hoy embebido en `MemberRole` enum + RLS. Parte del stack (§ 4). |
| **Policy** | ⚠️ implícito | `groups.governance` jsonb empieza a expresarlo. Parte del stack (§ 4). |
| **Cycle** | ❌ no existe | Periodo recurrente (semana, mes, temporada). Necesario antes de Rotation. |
| **Rotation** | ❌ no existe | Orden rotativo sobre Members o Resources. Phase 2 candidate. |
| **Assignment** | ❌ no existe | "A quién le toca". Hoy hardcoded en `event_hosts`. Phase 2 candidate. |
| **Proposal** | ⚠️ parcial | Existe como `vote_type='rule_change'`. Falta primitive genérica para "cambio sugerido a cualquier Resource/Rule/Policy". |

### L3 — Económico (desbloquea tandas, fondos, gastos, clubes)

| Primitive | Estado | Notas |
|---|---|---|
| **Fund** | ❌ no existe | Bote común. `Resource` con tipo `fund`. |
| **Contribution** | ❌ no existe | Aporte individual a Fund. Atom. |
| **Payout** | ❌ no existe | Distribución desde Fund. Atom. |
| **Expense** | ❌ no existe | Gasto del grupo. `Resource` con tipo `expense`. |
| **Settlement** | ❌ no existe | Liquidación final entre members. Projection. |
| **Ledger** | ❌ no existe | Atom económica. |
| **Balance** | ❌ no existe | Projection del Ledger. |
| **Payment** | ⚠️ parcial | Hoy solo `Fine.amount_paid_mxn`. Generalizar. |

### L4 — Físico/Slots (desbloquea palcos, casas, canchas, reservas)

| Primitive | Estado | Notas |
|---|---|---|
| **Asset** | ❌ no existe | Recurso físico/digital compartido. `Resource` con tipo `asset`. |
| **Slot** | ❌ no existe | Ventana de uso de Asset. `Resource` con tipo `slot`. |
| **Booking** | ❌ no existe | Reserva de Slot por Member. `Resource` con tipo `booking`. |
| **GuestPass** | ❌ no existe | Invitado temporal con permisos limitados. |
| **AccessRule** | ❌ no existe | Restricción de acceso a Asset/Slot. Especialización de Rule. |

### L5 — Sociales avanzadas (comunidades complejas, federación)

| Primitive | Estado | Notas |
|---|---|---|
| **MembershipClass** | ❌ no existe | Categoría formal (admin/regular/guest/observer/honorary). Diferente de Role. |
| **Multi-Membership** | ❌ no existe | Una Identity en múltiples Groups federados. |
| **Constitution** | ❌ no existe | Reglas fundamentales inmodificables sin supermayoría. Especialización de Policy. |
| **Jurisdiction** | ❌ no existe | Alcance de reglas (este grupo, este sub-grupo, esta cena). |
| **Sanction** | ❌ no existe | Consequence no monetaria. Hermana de Fine. |
| **Badge** | ❌ no existe | Reconocimiento. Hermana inversa de Sanction. |
| **Reputation** | ❌ no existe | Projection histórica de Sanctions/Badges/Fines/Votes. |
| **Ritual** | ❌ no existe | Actividad recurrente simbólica. Posible Cycle + Resource. |
| **Commitment** | ❌ no existe | Promesa con deadline. Posible Resource especial. |
| **CheckIn** | ⚠️ parcial | Existe como `event_attendees.check_in` para events. Generalizar. |

---

## 3. Module = Registry + Resolver, no solo string

Module como primitive tiene tres partes:

```
Module = (declaración) + (registro) + (resolución de capabilities)
```

| Componente | Qué hace | Estado real (auditado 2026-05-08) |
|---|---|---|
| **Module declaration** (`GroupModule`) | Nombre + providedRules / providedResourceTypes / providedSystemEventTypes / providedTabs + dependencies + conflictsWith. | ✅ done — `RuulCore/PlatformModels/GroupModule.swift` + 5 V1 modules en `RuulCore/PlatformModules/V1Modules.swift`. |
| **ModuleRegistry** | Catálogo + lookup + validate (deps + conflicts). | ✅ done — `RuulCore/PlatformModules/ModuleRegistry.swift`. |
| **CapabilityResolver** | Dado un grupo, responde "está activo este módulo / tipo de resource / tab". | ✅ done — `RuulCore/Capabilities/CapabilityResolver.swift` (179 LoC). Wired en `AppState.capabilityResolver`. Cubre `isModuleActive`, `finesEnabled`, `appealsEnabled`, `rsvpEnabled`, `checkInEnabled`, `rotationEnabled`, `availableResourceTypes`, `supports(resourceType:)`, `availableTabs(for:template:)` con fallback V1. |

### Deuda real (no la que el doc original imaginaba)

El antipatrón `activeModules.contains("basic_fines")` **no existe en
iOS hoy**. Lo que sí existió era **divergencia entre tres fuentes de
verdad** para el mismo concepto:

| Fuente | Tipo | Origen | Estado post-Slice 3 |
|---|---|---|---|
| `groups.fines_enabled` | boolean column | Migration 00011 (V1 onboarding). | derivada del trigger 00049, eliminable en Slice 4. |
| `groups.active_modules` contiene `"basic_fines"` | jsonb | Migration 00019 (Platform V2). | **canónico**. |
| `groups.settings ->> 'finesEnabled'` | jsonb dormant | Migration 00019 línea 103, write-only never read. | **eliminado en mig 00056**. |

**Migration 00019 backfilleó `active_modules = [todos los 5 V1]` para
todos los grupos sin filtrar por `fines_enabled`.** Resultado: cualquier
grupo con `fines_enabled=false` desde antes de 00019 ahora tiene
`"basic_fines"` en `active_modules` igualmente. El resolver dice "on";
feature code (5 callsites) lee la column y dice "off". Divergencia
silenciosa.

> **Nota correctiva**: la documentación inicial de mig 00049 nombró el
> 3er SoT como `groups.governance ->> 'finesEnabled'`. La key real
> vive en `groups.settings`, no en `governance`. La auditoría del Slice 3
> confirmó que ningún edge function ni iOS callsite lee la key, así que
> mig 00056 la eliminó completamente sin migración de readers necesaria.

**Callsites legacy** (originalmente leían `group.finesEnabled` directo;
todos migrados a resolver en Slice 2 — read-path — y a `setModule` en
Slice 3 — write-path):

- `RuulFeatures/.../Group/Views/GroupTabView.swift:145` — read via resolver ✅
- `RuulFeatures/.../Groups/GroupSettingsSheet.swift:165, 171` — read via resolver ✅; write via `setModule` ✅
- `RuulFeatures/.../Events/Coordinator/EventCreationCoordinator.swift:44` — read via resolver ✅
- `RuulFeatures/.../Onboarding/Founder/Coordinator/FounderOnboardingCoordinator.swift` — write via `setModule` ✅; analytics read via resolver ✅

### Acción canónica (multi-slice)

**Slice 1 — Reconciliación de SoT (backend, low-risk)**
- Backfill: `update groups set active_modules = active_modules - 'basic_fines' where fines_enabled = false and active_modules ? 'basic_fines'`.
- Trigger sync: cuando se actualiza `fines_enabled` o `active_modules`, mantener consistencia bidireccional en mismo statement.
- Test: verificar que post-migración `('basic_fines' = ANY(active_modules)) = fines_enabled` para todas las rows.

**Slice 2 — Migración de read-path en iOS**
- Cambiar 5 callsites a `appState.capabilityResolver.finesEnabled(in: group)`.
- `Group.finesEnabled` se mantiene como propiedad almacenada (decoder + write path) hasta Slice 3.

**Slice 3 — Migración de write-path** ✅ **done 2026-05-08**
- `GroupSettingsSheet` y `FounderOnboardingCoordinator` mutan
  `active_modules` directamente vía nuevo RPC
  `set_group_module(p_group_id, p_module_slug, p_enabled)` (mig 00055).
- Trigger del Slice 1 deriva `fines_enabled` automáticamente.
- iOS: `GroupsRepository.setModule(groupId:slug:enabled:)` añadido a
  protocolo + Mock + Live. Mock espeja la lógica del trigger para que
  los tests del coordinator sigan pasando con `g.finesEnabled`.
- 5 nuevos tests en `MockGroupsRepositoryTests` cubren add/remove/
  idempotencia/no-cross-effect/notFound.
- RPC verificado end-to-end contra prod (smoke test transaccional sin
  side-effects). 0 rows divergent post-slice.
- `GroupConfigPatch.finesEnabled` queda como deprecated-pero-funcional
  para callers internos. Slice 4 lo elimina junto con la columna.

**Slice 3 followup — server-side dep cascades** ✅ **done 2026-05-08**
- iOS `ModuleRegistry.validate(ids:)` ya enforce el dep graph
  client-side, pero el RPC `set_group_module` (mig 00055) flipea
  cualquier slug sin checkear deps. Eso permite que admin termine
  con `appeal_voting` activo y `basic_fines` apagado: el resolver
  compensa pero la data state miente sobre la intención.
- Mig 00057 reescribe `set_group_module` con cascade transitivo:
  ENABLE X también activa `transitive_deps(X)`; DISABLE X también
  apaga `transitive_dependents(X)`. Closures hardcoded en jsonb,
  espejo de `ios/.../V1Modules.swift`. Slugs unknown se flipean
  sin cascade (forward-compat).
- iOS `ModuleRegistry.transitiveDependencies(of:)` +
  `transitiveDependents(of:)` añadidas. `MockGroupsRepository.setModule`
  espeja la cascade. Test `transitiveClosures_matchSqlTables` guarda
  paridad iOS↔SQL.
- 5 cascade smoke tests ejecutados contra prod: enable cascade,
  disable cascade transitivo (rsvp → check_in/basic_fines/appeal_voting),
  disable basic_fines (→appeal_voting), idempotencia, slug unknown.
  Todos PASSED, prod state restaurado, invariante 00049 intacto.

**Slice 3.5 — 3rd SoT cleanup** ✅ **done 2026-05-08**
- Mig 00056 elimina la key `finesEnabled` del jsonb `groups.settings`
  para todos los grupos. Idempotente; en prod 0 rows la traían (la
  backfill 00019 solo aplicaba a rows con `settings is null or '{}'`),
  pero la migración deja el invariante explícito por si grupos
  futuros entran con settings poblado.
- iOS: drop del campo `GroupSettings.finesEnabled` (era write-only,
  ningún reader). Decoder Codable sigue verde porque era opcional.
- Resultado: solo quedan 2 SoT (column + jsonb membership), enlazados
  por el trigger 00049. Slice 4 ya puede dropear la columna sin dejar
  estado dormido detrás.

**Slice 4 — Drop column** (post-paridad de 2 semanas con triggers verdes)
- `alter table groups drop column fines_enabled`.
- `groups.governance.finesEnabled` también se deriva o se elimina.
- Update Group.swift: drop `finesEnabled` field, decoder, init.

Phase 2 primitives nuevas (Rotation, Fund, etc.) **no necesitan más
infraestructura del resolver** — solo declaración de `GroupModule`
nueva con `providedResourceTypes` poblado, y entradas en
`ModuleRegistry.v1Modules`. El resolver ya las soporta.

---

## 4. Role / Permission / Policy es un stack único

Estos tres no son primitives independientes — son capas de la misma
estructura:

```
Policy (group-wide governance config)
   └── parametriza
       Role (rol nombrado: founder, member, treasurer, arbiter)
              └── agrupa
                  Permission (capability granular: voidFine, fundWithdraw, modifyGovernance)
```

| Capa | Estado | Source of truth |
|---|---|---|
| **Permission** | ⚠️ implícito | Hoy hardcoded como check `myRole == .admin` o RLS. Sin enum/jsonb explícito. |
| **Role** | ✅ parcial | `group_members.role` text libre + Swift enum `MemberRole`. RolesV2 plan canónico (`groups.roles` jsonb). |
| **Policy** | ⚠️ parcial | `groups.governance` jsonb empieza a contener voting thresholds. Falta unificar con `roles` jsonb. |

**Reglas del stack**:

1. **Permission es el átomo.** Es lo que el código pregunta: "¿este
   member puede hacer X?".
2. **Role es agrupación nombrada de Permissions.** Configurable por
   grupo (RolesV2). Dos roles `system: true` (founder, member) son los
   únicos hardcoded.
3. **Policy parametriza Roles**: cuántos `treasurer` puede haber,
   qué quorum se necesita para asignar uno, qué Permissions son
   irrenunciables.
4. **Las tres viven en `groups`**: `groups.roles` + `groups.governance`
   jsonb. No tablas separadas — son configuración del grupo, no
   entidades con vida propia.

**Implicación**: cuando RolesV2 se ejecute, debe definir las tres capas
juntas. Ejecutar solo `roles` sin `permissions` declaradas formalmente
deja la deuda viva.

Ver `RolesV2.md` para el plan táctico.

---

## 5. Regla canónica de Resource

> **Algo es Resource si y solo si tiene gobernanza propia: rules que
> lo afecten, history que lo describa, votes que lo decidan, fines
> que se generen sobre él.**

### Qué SÍ es Resource

- **Event** (cena, junta, partido) — tiene rules (RSVP, late, no-show),
  history (asistencia), votes (anfitrión, lugar), fines.
- **Fund** (futuro) — tiene rules (mínimo aporte, máximo retiro),
  history (movimientos), votes (autorización de payout), fines (no
  aporte).
- **Asset** (futuro palco/casa) — tiene rules (quién puede usar),
  history (uso pasado), votes (cambio de owner), fines (daños).
- **Slot/Booking** (futuro) — tiene rules (anticipación mínima,
  no-show), history, votes (resolución de conflicto), fines.
- **Expense** (futuro) — tiene rules (límite, aprobación), history,
  votes (aprobar/rechazar), fines (no presentar comprobante).
- **Rotation** (futuro) — tiene rules (qué pasa si te toca y no
  puedes), history (rotaciones pasadas), votes (cambiar orden).

### Qué NO es Resource (aunque tenga `id`)

- **Member**. No se gobierna a sí mismo — lo gobiernan rules sobre
  Resources que él toca. Member es sujeto de governance, no objeto.
- **Identity** (auth.users). Lo mismo, un nivel arriba.
- **Notification**. Es canal/efecto, no objeto. No tiene history propia
  (la history está en el SystemEvent que la disparó).
- **Vote**. Es instrumento de decisión sobre otra Resource (§ 6).
- **Fine**. Es consequence sobre Member referente a una Rule sobre
  una Resource (§ 6).
- **Rule**. Es regla aplicada a Resources, no Resource ella misma.
  (Sí: Rule **revisions** podrían modelarse como Resource si el grupo
  vota sobre ellas — pero la rule en uso, no.)
- **Role / Permission / Policy**. Configuración del Group, no objetos
  separados.
- **Module**. Capability del Group, no Resource.

### Test rápido

Cuando aparezca una primitive candidata nueva, hacer estas 4 preguntas:

1. ¿Puede recibir una rule específica que la afecte?
2. ¿Aparece en history como "X pasó sobre esto"?
3. ¿Puede ser objeto de un vote ("¿aprobamos este X?")?
4. ¿Puede generar fines ("se infringió la rule sobre este X")?

Si **3 de 4** son sí → es Resource. Si menos → es otra cosa
(instrument, channel, config, projection).

---

## 6. Vote y Fine son instruments derivados

Conceptualmente:

```
Rule(threshold)         + Resource = Vote
Rule(THEN consequence)  + Member   = Fine
Rule(THEN consequence)  + Member   = Sanction (futuro, no monetario)
Rule(THEN reward)       + Member   = Badge (futuro)
```

**No son átomos**. Son cómo Rules + Resources + Members se materializan
en decisiones y consequences.

**Por qué importa**:

- Cuando lleguen Sanction (suspender voto 30 días), Badge
  (reconocimiento), Reward (payout extra), no son "primitives nuevas
  paralelas a Fine". Son **el mismo patrón** con consequence type
  distinto.
- Esto sugiere que Phase 5+ debería tener un `Consequence` table
  polimórfica (`consequence_type`: fine, sanction, badge, reward) en
  lugar de cinco tablas separadas. **Hoy no se ejecuta** — solo
  registrarlo.
- Mientras tanto, `fines` table sigue siendo la implementación práctica
  y se mantiene tal cual.

**No es un mandate de refactor.** Es nota arquitectónica para que
quien diseñe Sanction no haga `sanctions` tabla nueva sin pensar.

---

## 7. Resumen — la fórmula real

```
Group
  + Identity/Membership
  + Role/Permission/Policy
  + Module (Registry + Resolver)
  + Resource (polimórfico)
  + Rule
  + SystemEvent (atom) → History (projection)
  + Vote/Fine (instruments derivados)
= sistema social autoorganizado
```

Las 5 más fundamentales si hay que reducir aún más:

1. **Group** — comunidad
2. **Resource** — objeto gobernable
3. **Rule** — comportamiento
4. **SystemEvent** — memoria
5. **Module** — escalabilidad sin verticales

Con esas cinco bien hechas, el resto se deriva.

---

## 8. Qué este documento NO hace

- **No agenda refactor durante Beta 1.** Beta 1 está congelado
  arquitectónicamente (`Beta1.md` § 2). Cualquier item que aparezca
  como "deuda" aquí (CapabilityResolver formal, Atom/Projection
  explicitado en código, stack Role/Permission/Policy unificado) se
  ejecuta **después** del cierre de Beta 1.
- **No decide qué primitive de Phase 2 va primero.** Eso lo decide el
  journal de cenas (`Beta1.md` § 5–6). Este doc solo dice **dónde
  encajaría** cada candidata.
- **No reemplaza `Roadmap.md`.** Roadmap habla de fases temporales y
  features. Este doc habla de estructura conceptual ortogonal.
- **No reemplaza ADRs.** Decisiones específicas (e.g. "Fund vive en
  `resources` con `resource_type='fund'` vs tabla aparte") se
  documentarán como ADR cuando se ejecuten.

---

## 9. Cuándo modificar este documento

- Cuando una primitive cambie de nivel (ej: si `Identity` separada de
  `Membership` se vuelve necesaria por federación, mover MembershipClass
  de L5 a L1).
- Cuando una primitive nueva se materialice en código y haya que
  cambiar su estado de ❌ → ⚠️ → ✅.
- Cuando la regla de Resource (§ 5) gane o pierda casos límite con
  experiencia real.
- **No** se modifica para registrar tareas o sprints — eso vive en
  `Beta1.md`, `Phase2.md` (cuando exista), o ADRs.

---

## 10. Referencias cruzadas

- `Plans/Active/Beta1.md` — freeze arquitectónico vigente, journal,
  exit criteria.
- `Plans/Active/Roadmap.md` — fases temporales y features.
- `Plans/Active/RolesV2.md` — plan táctico para el stack
  Role/Permission/Policy (§ 4).
- `Plans/Active/RulesPlatformOnly.md` — drop de columnas legacy de
  rules; pre-requisito para tratar Rule como primitive limpia.
- `Plans/Active/GovernanceRulesJsonb.md` — migración de governance a
  jsonb (parte de Policy en § 4).
- `Plans/Active/Audit-2026-05-06.md` — auditoría de cierre F0.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/` — modelos
  Swift de las primitives L1/L2 vivas.
- `ios/Packages/RuulCore/Sources/RuulCore/PlatformModules/` —
  ModuleRegistry + V1Modules.
- `supabase/functions/_shared/ruleEngine.ts` — implementación actual
  del Rule + atom/projection.
