# Nivel 8 — Governance / Rules: gaps + management UI

**Fecha:** 2026-05-15
**Estado:** Brainstorming → spec
**Decisor:** founder (jose.mizrahi@quimibond.com)
**Jerarquía:** `HierarchyReference.md` §1 (Layer 8) + §4 (Reglas: sobre qué pueden gobernar)
**Governance canónico:** `Plans/Active/Governance.md` (Beta-1 Rule Builder, Draft 3 hybrid-doctrine)
**Migraciones base:** `00084` (rule_shapes), `00181` (rule_templates + rule_versions + rule_evaluations + member_capability_overrides), `00182` (publish_rule_version RPC)
**Specs hermanos:** Niveles 0-5 todos shipped.

## Problema

Nivel 8 (Governance/Rules) es el sistema más maduro del app — la mayoría del esqueleto vive en BE + FE:

- `rules` + `rule_shapes` + `rule_templates` + `rule_versions` + `rule_evaluations` + `rule_conflicts` + `member_capability_overrides` (mig 00084/00181/00182).
- 8 shapes seedeadas + 5 templates Beta-1 (late_arrival_fine, no_show_fine, etc.).
- `RuleBuilderCoordinator` con state machine `templatePick → paramFill → publish → done`.
- `RuleBuilderView` + `RuleDetailView` + `RulesView` + `EditRulesView` + `ResourceRulesSheet`.
- `InterceptingRuleRepository` que consulta `GroupPolicyRepository` y abre votación si `policy.resolve == .voteRequired`.
- `RuleSummaryFormatter` + `RuleBuilderSentenceFormatter` para UX humana ("Si X → Y").

**Pero quedan 5 gaps user-facing visibles:**

1. **No se pueden editar params de una regla existente.** Una vez publicada `late_arrival_fine` con `amount=200, minutes=15`, no hay UI para cambiar los 15 minutos. `RuleDetailView` solo expone toggle on/off + amount. La única forma es deshabilitar + recrear.

2. **Scope picker está oculto.** `RuleBuilderCoordinator` acepta `scope: RuleScope` (group/series/resource) pero la UI Beta-1 fuerza scope group-only — el template tiene `scopeHint: .series` pero el coordinator lo ignora porque no hay UI para elegir resource o series.

3. **Per-resource rules son read-only.** `ResourceRulesSheet` muestra reglas con scope=resource o resource_type que aplican a este recurso, pero el botón "agregar regla aquí" o no existe o abre el builder en modo group-scope. Resultado: no se pueden crear reglas resource-específicas desde el detail del recurso.

4. **Conflicts visibles pero no bloqueantes.** `publish_rule_version` RPC devuelve `conflicts: [RuleVersionConflict]` con severity `warning` o `blocking`. UI muestra warning como alerta pero permite publish; `blocking` no se diferencia.

5. **Audit atoms invisibles.** `ruleEnabledChanged` + `ruleAmountChanged` + `pendingChangeApplied` se emiten a `system_events` pero el feed de Actividad (`ActivityView` / `HistoryItemPresentation`) no los renderiza con copy específico para reglas.

## Objetivo

Cerrar los 3 gaps más visibles:

- **Edit params de regla existente.** Tap regla → edit param form (mismos campos del builder) → save → llama `updateRuleParams` (RPC nuevo) o crea nueva `rule_versions` superseding la actual.
- **Scope picker en `RuleBuilderView`.** Antes del paramForm, mostrar "¿Aplica a todo el grupo / a un recurso / a una serie?". Si recurso o serie elegidos, contextualizar.
- **"Agregar regla aquí" desde `ResourceRulesSheet`.** Botón "+" que abre el builder pre-llenado con `scope: .resource(resource.id)`.

Lo demás (conflicts blocking, audit feed) → Pass 3+.

## Approach — 3 pasadas, Pass 1+2 en este plan

### Pass 1 · Edit params + scope picker en builder (4 tasks)

| Archivo | Acción | Notas |
|---|---|---|
| `Features/Rules/Coordinator/EditRuleCoordinator.swift` | **NEW** (~120 L) | Carga rule + version actual, expone `paramValues: [String: JSONConfig]` (mismo shape que builder), llama `publishRuleVersion` con `template_id` + nuevos params para crear new version + supersede |
| `Features/Rules/Views/EditRuleSheet.swift` | **NEW** (~180 L) | Reusa `RuleBuilderParamForm` (ya existe en `RuleBuilderView` step 2 — extraer si es necesario) con coordinator del task 1 |
| `Features/Rules/Views/RuleDetailView.swift` | **Modify** | "Editar parámetros" navrow (admin-only) → presenta `EditRuleSheet` |
| `RuulCore/Capabilities/RuleScope.swift` | **Modify** (si no expone .resource/.series ya) | Confirmar enum tiene group/resource/series con UUIDs assoc |

### Pass 2 · Scope selector + resource-scope creation (3 tasks)

| Archivo | Acción |
|---|---|
| `Features/Rules/Coordinator/RuleBuilderCoordinator.swift` | **Modify**. Step nuevo `scopePick` (entre `templatePick` y `paramFill`). Default a `template.scopeHint`. Si se pasa `initialScope` al init, salta el step (modo "agregar aquí") |
| `Features/Rules/Views/RuleBuilderView.swift` | **Modify**. Render `ScopePickerStep` cuando state == .scopePick. Tres opciones: "Todo el grupo" / "Este recurso (si initialScope tiene resource)" / "Esta serie (si tiene series)" |
| `Features/Resources/Detail/Sheets/ResourceRulesSheet.swift` (o equivalente) | **Modify**. Botón "+" toolbar que presenta `RuleBuilderView(initialScope: .resource(resource.id))` |

### Pass 3 (deferred): conflicts blocking + audit feed visibility

## Wireframe `EditRuleSheet`

```
┌─────────────────────────────────────────┐
│  Cancelar    Editar regla       Guardar │
│  ─────────────────────────────────────  │
│  Multa por llegar tarde                  │
│                                          │
│  Monto                                   │
│  ┌─────────────────────────────────┐    │
│  │ $200                           │    │
│  └─────────────────────────────────┘    │
│                                          │
│  Minutos de tolerancia                   │
│  ┌─────────────────────────────────┐    │
│  │ 15                             │    │
│  └─────────────────────────────────┘    │
│                                          │
│  Aplica a:                               │
│  ◉ Cenas de jueves (serie)              │
│  ○ Todo el grupo                         │
│                                          │
└─────────────────────────────────────────┘
```

## Wireframe `RuleBuilderView` con scope picker (Pass 2)

```
┌─────────────────────────────────────────┐
│  Cancelar      Nueva regla              │
│  ─────────────────────────────────────  │
│  Paso 2 de 4 — ¿Dónde aplica?            │
│                                          │
│  ◉ Todo el grupo                         │
│     "Multa por llegar tarde" aplicará a │
│     todas las cenas y eventos del grupo. │
│                                          │
│  ○ Solo este recurso                     │
│     Esta cena específica.                │
│                                          │
│  ○ Solo esta serie                       │
│     Todas las cenas de jueves            │
│     (recurrentes).                       │
│                                          │
│  ────────────────────────────────────   │
│                          [Siguiente]    │
└─────────────────────────────────────────┘
```

## Decisiones explícitas

1. **Edit params reusa el `paramForm` del builder.** Si extracción a `RuleBuilderParamForm` es necesaria, hacerlo en Task 2 — DRY beats duplication.

2. **Publish-as-new-version, no in-place mutation.** Editar una regla crea una nueva `rule_versions` row + supersede la actual. Audit trail intacto. RPC `publishRuleVersion` ya hace esto si se le pasa el mismo `rule_id` (verificar mig 00182).

3. **Si una regla está bajo voto pendiente, edit bloqueado.** `RuleDetailView` ya muestra `pendingRepealVote` — extender check para cualquier `pending_changes.target_rule_id`.

4. **Scope picker default = `template.scopeHint`.** Beta-1 templates declaran `scopeHint: .series`. Si el usuario lo respeta, un click menos. Si abre desde resource detail, default = `.resource(initialResourceId)`.

5. **`initialScope` skip-step.** Pasar scope al init salta el scope-pick step y pre-llena. Útil para "agregar regla aquí" desde `ResourceRulesSheet`.

6. **Pass 3 (audit + conflicts blocking) se difiere.** Conflicts blocking requiere clasificación per-shape; audit feed requiere coordinación con ActivityView que vive en otro nivel.

## Riesgos

| Riesgo | Mitigación |
|---|---|
| `RuleBuilderParamForm` no está extraído como view independiente | Task 1 incluye extracción si Task 2 lo necesita. Si ya está extraído, skip |
| `publishRuleVersion` puede no soportar "supersede existing rule_id" | Verificar RPC docs en mig 00182; si no, crear `update_rule_params` RPC simple |
| Scope picker default a `.series` requiere conocer la serie activa | Si template scopeHint es `.series` pero no hay serie disponible (resource creation aún no), fallback a group |
| Edit puede crear conflictos nuevos | Reusar mismo conflict detection del builder; mostrar warnings antes de save |
| Pending changes activos en una regla — edit silencioso podría adelantar/atrasar voto | Block edit con mensaje "Hay un voto pendiente; espera al resultado" |

## Tests

| Pass | Tests críticos |
|---|---|
| 1 | `EditRuleCoordinator`: load existing params + save new params. `EditRuleSheet`: muestra params actuales, save invoca publishRuleVersion. `RuleDetailView`: "Editar parámetros" oculto para no-admin |
| 2 | `RuleBuilderCoordinator`: scopePick step renderiza 3 opciones. `RuleBuilderView`: skip-step cuando initialScope dado. `ResourceRulesSheet` "+" abre builder con initialScope |

## Out of scope (futuros specs)

- Pass 3 — conflicts blocking + audit visibility
- Pass 4 — per-piece builder (shapes pickers públicos)
- Pass 5 — `member_capability_overrides` UI
- Pass 6 — `rule_evaluations` audit visible para admins (debug)
- Cross-group rule sharing (templates marketplace)
- Rule import/export

## Done When

- 7 tasks committed (4 Pass 1 + 3 Pass 2).
- Tap "Editar parámetros" en `RuleDetailView` abre `EditRuleSheet`.
- Save crea new `rule_versions` row.
- `RuleBuilderView` tiene scope picker step entre template y param.
- "Agregar regla aquí" en `ResourceRulesSheet` abre builder con resource scope pre-llenado.
- Build clean.

## Cobertura del plan inicial

**Pass 1 + Pass 2 en el primer commit** (~7 tasks). Pass 3+ como specs dedicados.
