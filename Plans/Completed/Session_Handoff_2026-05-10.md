# Session handoff — Ruul / Tandas iOS OpenPlatform work

Copy-paste the block below as the first message of the new Claude session.

---

```
Estoy continuando trabajo en Ruul (iOS native + Supabase). Es una plataforma
abierta de "Resources × Capability Blocks" — no verticales hardcoded.

## Estado actual (último commit: d24b4da en main)

Sesión anterior cerró 16 commits implementando:
- Phase A: three-level rules scope (group / module / resource)
- BigBang OpenPlatform Foundation (mig 00078): dropea ~24 columnas legacy
  de `groups`, crea 4 tablas nuevas (resource_series, resource_capabilities,
  ledger_entries, rsvp_actions), agrega provided_capability_blocks a modules
- Swift Rewrite: bare Group model, capability-driven UI
- S1 Founder Welcome Flow: onboarding de 5 pasos con preset picker (3 cards:
  recurring_dinner, shared_resource, blank)
- S2 Capability-aware Home empty state + skeleton loader
- U Universal ResourceWizard: type picker + dynamic field renderer + per-type
  ResourceBuilder protocol. Agregar un nuevo resource type = 1 archivo nuevo
- Resource surfaces: HomeView gana sección "Recursos", ResourceDetailSheet
  polimórfico, GroupTabView gana sub-tab "Recursos"
- "+" centrado en tab bar (entre tabs Home y Grupo)
- EventDetailView gana cards "Reglas de este evento" + "Movimientos"
  (placeholders esperando Phase 3 Money + Phase 4 in-event rules)

App instalada en iPhone de JJ (`00008140-00121C9E1A88801C`). Build verde.

## La taxonomía canónica está aquí

- `Plans/Active/Taxonomy_Resources_and_Capabilities.md` — 22 resource types
  + 50 capability blocks + dependencies + conflicts + presets
- `Plans/Active/OpenPlatform_Phase0_2026-05-10.md` — phasing/architecture
- `Plans/Active/L1_Audit_2026-05-10.md` — la deuda técnica que motivó BigBang

## Contrato de scopes (NO LO ROMPAS)

Rules table tiene 4 scope columns:
  - group_id        siempre (todas las rules pertenecen a un grupo)
  - module_key      nullable → module-scoped si está set
  - series_id       nullable → ResourceSeries-scoped si está set
  - resource_id     nullable → resource-instance scoped si está set
  - membership_id   nullable → member-scoped si está set

Más específico GANA sobre más general.

Lo mismo para ledger_entries / rsvp_actions / resource_capabilities — todas
tienen `resource_id` para scope. Las del grupo dejan `resource_id` null.

UI debe respetar esto:
  Tab Grupo → Reglas        muestra rules WHERE module_key=NULL AND resource_id=NULL
  EventDetailView "Reglas"  muestra rules WHERE resource_id = event.id
  EventDetailView "Movimientos" muestra ledger_entries WHERE resource_id = event.id

## Stack técnico

- iOS 26+ deployment target (Liquid Glass real, no fallback)
- SwiftUI exclusively, Swift 6 strict concurrency
- supabase-swift SDK
- Xcode 16+, xcodebuild scheme=Tandas, sim=iPhone 17 Pro
- Backend: Supabase project `fpfvlrwcskhgsjuhrjpz`
- iOS code: `/Users/jj/code/tandas/ios/Packages/{RuulCore, RuulUI, RuulFeatures}`
- Migrations: `/Users/jj/code/tandas/supabase/migrations/` (up to 00081 applied)

## MCP tools disponibles

- mcp__supabase__apply_migration   — aplica migración al remote (NUNCA sin
                                     aprobación explícita del usuario)
- mcp__supabase__execute_sql        — SQL queries arbitrarios
- mcp__supabase__get_logs           — postgres/edge function logs
- mcp__supabase__list_migrations    — qué versiones están aplicadas

## Comandos clave

Build sim:   cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas \
             -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
Build device: cd /Users/jj/code/tandas/ios && xcodebuild -scheme Tandas \
              -destination 'platform=iOS,id=00008140-00121C9E1A88801C' \
              -configuration Debug -derivedDataPath build/DD \
              -allowProvisioningUpdates build
Install:     xcrun devicectl device install app --device 00008140-00121C9E1A88801C \
             /Users/jj/code/tandas/ios/build/DD/Build/Products/Debug-iphoneos/Tandas.app

## Auto mode rules (el usuario ya lo activó antes)

- Ejecutar inmediato, sin pedir aprobación para work rutinario
- PERO: apply_migration al remote + wipes de data SIEMPRE requieren "apruebo" explícito
- Commits y pushes a main están autorizados implícitamente cuando hay slice cerrado
- El usuario espera updates concisos (no narrar el thinking)

## Próximos slices candidatos

Pendientes con scope-aware implementation:

1. **Money capability real (Phase 3)** — cerrar el placeholder "Movimientos"
   en EventDetailView. Implementar:
   - RPCs `record_expense(group, resource?, amount, from_member, to_member, type)`
   - `record_iou`, `record_settlement`, `record_contribution`, `record_payout`
   - LedgerEntryRepository ya existe en iOS (mig 00078); falta UI
   - Balance projection view (server-side) o computed client-side
   - "Registrar movimiento" sheet que escribe ledger_entries con
     resource_id = event.id (RESPETAR EL SCOPE)

2. **In-event rule creation (Phase 4)** — cerrar el placeholder "Reglas"
   en EventDetailView. Implementar:
   - Sheet con form: trigger / conditions / consequences (basado en
     CapabilityCatalog.v1 "rules" block)
   - Write a `rules` table con resource_id = event.id
   - Validación server-side de que el creator tiene permiso

3. **Fund + Contribution + Payout builders** — desbloquea cards
   "Próximamente" del wizard. RPCs nuevos + builders + agregar al
   registry en AppState.swift.

4. **Slot builder re-habilitar** — requiere resourcePicker funcional en
   BuilderFieldRenderer (cargar lista de assets del grupo). Hoy es
   placeholder text-field, por eso slot está en "Próximamente".

5. **S3 Polish Pass** — Liquid Glass consistency audit (mix de
   RuulCard.tile/.glass), inline errors con retry CTA, animation polish.

6. **Settings unification** — merge GroupSettingsSheet +
   GovernanceSettingsView + EditMembersSheet en una sheet única.

7. **Test crash investigation** — full xcodebuild test suite crashes 9
   onboarding tests en SwiftData ModelContext.insert. Aislado pasan.
   Pre-existing flakiness, no urgente pero queda como deuda.

## Archivos clave para entender la arquitectura

iOS:
- ios/Packages/RuulCore/Sources/RuulCore/Capabilities/
    CapabilityBlock.swift, CapabilityCatalog.swift,
    ResourceBuilder.swift, ResourceBuilderRegistry.swift,
    {Event,Asset,Slot}ResourceBuilder.swift,
    CapabilityResolver+Expanded.swift
- ios/Packages/RuulCore/Sources/RuulCore/PlatformModels/
    ResourceSeries.swift, LedgerEntry.swift, RsvpAction.swift,
    ResourceCapability.swift, Resource.swift, Rule.swift
- ios/Packages/RuulFeatures/Sources/RuulFeatures/Features/Resources/
    ResourceWizardSheet.swift, ResourceWizardCoordinator.swift,
    ResourceTypePickerView.swift, BuilderFieldRenderer.swift,
    ResourceDetailSheet.swift
- ios/Packages/RuulCore/Sources/RuulCore/AppState.swift — DI container

SQL:
- supabase/migrations/00071-00076 — Phase A (rules scope)
- supabase/migrations/00078 — BigBang foundation
- supabase/migrations/00079 — create_group_with_admin bare
- supabase/migrations/00080 — create_event_v2 post-BigBang
- supabase/migrations/00081 — set_auto_no_show_at fix

## Empieza por

1. Leer Plans/Active/Taxonomy_Resources_and_Capabilities.md para
   confirmar la mental model.
2. Leer este handoff (estás en él).
3. Preguntarme cuál slice quiero arrancar (recomiendo Money capability
   real porque cierra el placeholder más visible y valida el contrato
   de scopes end-to-end).
4. Crear plan con TaskCreate, ejecutar, build + install + commit + push
   como slice cerrado.

Importante: respeta el scope contract en cada feature. Movimientos
dentro de un evento → resource_id = event.id. Reglas dentro de un
evento → rules.resource_id = event.id. Si algo escribe a group-level
cuando debería ser resource-level, eso es bug crítico.
```

---

## Notas para mí (no para pegarle al nuevo Claude)

- Si el nuevo Claude pide screenshots, son del iPhone 16 Pro Max (id en el handoff)
- Sesión anterior consumió ~16 commits en main, ~10 migrations aplicadas
- Tasks closed counts: 70+
- Si hay drift de schema entre lo que el iOS espera y el remote, primero `mcp__supabase__get_logs` postgres → buscar "column X does not exist" o "field X has no field Y"
- Si el wizard parece "no hacer nada", primero verifica `validateRequiredFields` y los defaults en `selectBuilder`
