# Roadmap Plataforma — De V1 a la Visión

> Plan de construcción desde la base actual hacia la visión completa
> (~130 categorías de grupos en autogobierno) con **escalabilidad como
> restricción de primer nivel**, no como afterthought.
>
> Versión 2026-05-04.

---

## 0. Premisa

La arquitectura del repo ya tiene la forma correcta: 7 primary citizens
(Group, Member, Resource, Rule, SystemEvent, Action, Vote), templates
como configuración, módulos componibles, rule engine determinístico
server-only. Eso es el 70% del trabajo intelectual.

El 30% restante — y donde se gana o se pierde la escalabilidad — está
en **lo que no se ve**: sincronización de tipos cliente↔servidor,
testing de RLS, observabilidad, migrations seguras, codegen, contratos
estables entre capas. Si esto no se hace ahora, cada nuevo template va
a costar el doble. Ya pasó con la sincronización de enums (3 incidents
documentados).

Este plan asume:
- iOS nativo se mantiene como cliente principal
- Supabase (Postgres + Edge Functions) se mantiene como backend
- Tu vision es plataforma multi-template, no una app de cenas con extras
- "Escalable" significa: 50,000 grupos sin reescribir, 20 templates sin
  reescribir, 10 desarrolladores sin pisarse, 3 países sin reescribir

---

## 1. Estado actual — mapa honesto

**Shipped en backend (prod)**: 25 tablas, 51 RPCs, 11 edge functions,
RLS amplia, rule engine con 24 SystemEventTypes / 16 ConditionTypes /
15 ConsequenceTypes, governance configurable, fines + apelaciones,
anti-tirania, tipología de miembros.

**Shipped en iOS**: onboarding de 11 pasos, Home, EventDetail,
CreateEvent, Inbox, Rules (read-only), Fines, Appeals, MyFeed,
GroupHistory, Profile. Bloque 12.4 cerrado.

**Gap real identificado** (P0 en `UICompleteCoverage.md`):
- Reglas son read-only post-onboarding → governance es un one-shot
- Manual fine sin entry point
- Void fine sin entry point
- Vista de votos abiertos solo cubre `fine_appeal` (1 de 7 tipos)
- Member management read-only
- Module toggles inalcanzables

**Gap arquitectónico (no documentado)**:
- Sincronización Swift↔TS de enums es manual y frágil
- No hay codegen de tipos
- RLS policies no testeadas en CI (probablemente)
- No hay feature flags formales
- Telemetría de estado de rule engine en producción no documentada
- Migrations no tienen tests de rollback
- Falta plan de archival para `system_events` (crece sin techo)

**Lo que la plataforma promete pero no demuestra**:
- "Template-agnostic" (solo un template en prod: `recurring_dinner`)
- "Cualquier grupo escribe su contrato" (UI no permite editar contrato
  después de onboarding)

---

## 2. Principios de escalabilidad — gobiernan todas las fases

Cada decisión técnica de aquí en adelante se valida contra estos
ocho principios. Si algo los viola, no se mergea.

### P1. Un solo source of truth para tipos

Los enums de `SystemEventType`, `ConditionType`, `ConsequenceType`,
`ResourceType`, `GovernanceAction`, `PermissionLevel` viven en **un solo
lugar** y se proyectan a Swift y TS por codegen. Sin esto, cada
nueva variante introducida en el server crashea el cliente al decodificar.

**Implementación recomendada**: archivo `platform/types/catalog.ts` (o
JSON schema), script `scripts/gen-swift-enums.ts` que produce
`Platform/Types/Generated.swift`, ejecutado en pre-commit y CI.
Decoding en Swift usa siempre el bucket `unknown(String)` para versiones
que el cliente no conoce todavía.

### P2. Toda mutación produce un SystemEvent

Cero side-effects fuera del log. Si una RPC modifica estado y no emite
SystemEvent, no se mergea. Esto es lo que permite replay, auditoría,
observabilidad y eventualmente warehouse export.

### P3. Reglas son data, evaluadas server-only, determinísticamente

El RuleEngine ya es server-only. Mantenerlo así. Cero `Date.now()`,
cero RNG, cero shared state. El timestamp viene del SystemEvent
disparador. Tests de evaluators son tests puros.

### P4. Templates y módulos son configuración, no código

Ya lo hicieron. Defenderlo. Si alguien propone "vamos a hacer un
template hardcoded para ahorrar tiempo", la respuesta es no — se rompe
la promesa de plataforma y bloquea Fase 4 (autoría visual).

### P5. RLS es la autoridad de seguridad, no el cliente

Cada tabla tiene policies. Ninguna lógica de "este usuario puede ver
esto" vive en el cliente o en RPCs sin policy. Tests de RLS en CI
contra cada policy.

### P6. Observabilidad desde el día 1

Cada SystemEvent + cada RPC + cada rule firing debe ser observable en
producción sin acceso al device del usuario. Logs estructurados, métricas
de p50/p99 de cada RPC, alertas en error rate. Sin esto, debugging en
producción es una pesadilla y escalar es imposible.

### P7. Migrations idempotentes y rollback-tested

Cada migration tiene su `down`. CI corre `up → down → up` antes de mergear.
Migrations destructivas (DROP COLUMN, ALTER TYPE) van por feature flag y
periodo de cohabitación, no por reemplazo directo.

### P8. Fronteras claras entre capas

```
Client (iOS)
  ↓ tipos generados
RPC (Postgres function)
  ↓ inserta en tabla
Trigger (after insert)
  ↓ encola SystemEvent
Process queue (Edge Function cron)
  ↓ corre RuleEngine
Rule firing
  ↓ ejecuta consequences
Side effects (más SystemEvents, recursos creados, notifs, etc.)
```

El cliente nunca llama directamente a una tabla. Siempre RPC. Esto
permite versionar APIs (`_v2`), cambiar implementación sin romper
clientes viejos, y aplicar rate limiting / observabilidad en un punto.

---

## 3. Las fases

Cada fase tiene: Goal · Trabajos · DoD · Riesgos · Métrica de éxito.

---

### Fase 0 — Hardening de fundación

**Duración**: 4–6 semanas.
**Goal**: Cerrar deuda arquitectónica que se vuelve imposible de pagar
después. Sin esto, Fase 2 cuesta 3x.

**Trabajos**:

1. **Codegen de tipos compartidos** (P1).
   - Mover catálogos a `platform/types/`.
   - Script `gen-swift-enums.ts` y `gen-ts-types.ts`.
   - Decoder Swift defensivo: `unknown(String)` en lugar de crash.
   - CI verifica que `gen` no produce diff (forces regen on PR).

2. **RLS testing harness en CI**.
   - Test fixture: 3 usuarios en 2 grupos, perfiles distintos.
   - Cada policy tiene un test "puede X" + "no puede Y".
   - Cobertura objetivo: 100% de tablas con policies.

3. **Migrations rollback testing**.
   - GitHub Action: aplica migration, verifica schema, hace rollback,
     verifica vuelta a estado previo.
   - Bloquea merge si la migration no tiene `down` o no es idempotente.

4. **Observabilidad mínima**.
   - Sentry (o Datadog) integrado en iOS y Edge Functions.
   - Logs estructurados (JSON) en todas las edge functions.
   - Dashboard básico: rule firings/min, error rate por RPC,
     decode failures por tipo.
   - Alertas: error rate > 1%, decode failures > 0.

5. **Cerrar P0 de UICompleteCoverage**.
   - `EditRulesView` + `EditRuleSheet` (gobernanza-aware)
   - `GovernanceSettingsView` (post-onboarding edit)
   - `AddManualFineSheet` + `VoidFineSheet`
   - `OpenVotesView` (genérica para 7 tipos de voto)
   - `EditMembersSheet` (promote, remove, reorder turn)

6. **Decisión iOS 26 vs 17** (ver §5).

**DoD**:
- [ ] CI tiene 4 nuevos gates: codegen-clean, rls-tests, migration-rollback, swift-decoder
- [ ] Sentry capturando crashes en TestFlight
- [ ] Dashboard de rule engine accesible a todo el equipo
- [ ] Los 5 P0 de UICompleteCoverage shipped y QA'd
- [ ] Plan de archival de `system_events` documentado (no implementado todavía)

**Riesgos**:
- Codegen mal hecho rompe la confianza. Hacerlo simple y reversible.
- Sentry "siempre todo verde" en early stage es engañoso. Definir SLOs
  realistas para early V1.

**Métrica de éxito**:
- 0 crashes por decode failure en una semana de testflight con 50 usuarios.
- 100% de RLS policies con test verde.

---

### Fase 1 — V1 launch sobre `recurring_dinner`

**Duración**: 4–6 semanas.
**Goal**: 100–500 grupos activos en cenas. Validar que el producto
funciona en la vida real, no solo en el simulador.

**Trabajos**:

1. **Push notifications via APNs**.
   - Token registration en `notification_tokens`.
   - Edge function `send-event-notification` real (hoy es stub).
   - Eventos a notificar: RSVP deadline, fine emitted, vote opened,
     event reminder.
   - Configuración de notif preferences por usuario.

2. **Onboarding round 5**.
   - Funnel telemetry: cuántos llegan al paso 11.
   - Reducir pasos si la métrica es < 60% completion.
   - Empty states de cada vista: claros, accionables, no apologéticos.

3. **WhatsApp invite flow polished**.
   - El share-to-WhatsApp es el canal #1 de adopción en LatAm.
   - Mensaje con link universal, deep link al app o App Store.
   - Tracking de quién invitó a quién (referral graph).

4. **App Store submission**.
   - Privacy nutrition labels, App Privacy report, screenshots.
   - Review notes claras al equipo de Apple (rule engine, OTP).
   - Plan B si rechazan: ya tener TestFlight con 200 beta testers.

5. **Customer support tooling**.
   - Admin web (Next.js — el `web-deprecated/` se reusa) con búsqueda
     por usuario / grupo, lectura de SystemEvents, capacidad de re-disparar
     rule engine para un grupo.
   - Cero capacidad de **mutar** datos sin pasar por RPCs (P5/P8).

**DoD**:
- [ ] App live en App Store
- [ ] 100 grupos creados orgánicamente (no de Jose o equipo)
- [ ] Funnel onboarding > 65% completion
- [ ] Push notif delivery rate > 95%
- [ ] 0 incidents Sev1 en producción 14 días seguidos

**Riesgos**:
- App Store rechazo por OTP custom (Apple a veces empuja a Sign in
  with Apple). Plan B: Sign in with Apple como opción adicional.
- Push delivery rate baja (devices con notifs muteadas).
- iOS 26+ corta TAM (ver §5).

**Métrica de éxito**: 100 grupos activos pagando atención (≥ 1 evento
cerrado, ≥ 1 multa generada o explícitamente waived).

---

### Fase 2 — Template #2: `shared_resource`

**Duración**: 8–12 semanas.
**Goal**: Demostrar que la plataforma es realmente template-agnostic.
Esta es **la prueba** del 70% de trabajo arquitectónico ya hecho.
Mercado objetivo: palcos, cabañas, casas de playa, yates compartidos —
los 17 casos de la categoría 2 de la conversación.

**Trabajos**:

1. **Nuevos primitives**:
   - `ResourceType.slot` — un turno asignado a un miembro
   - `ResourceType.position` — un rol rotativo (host actual, etc.)
   - Tabla `resources` ya soporta esto, pero el client no.

2. **Nuevos módulos**:
   - `slot_assignment` — asignación de slots a miembros
   - `rotating_position` — rotación con orden configurable
   - `slot_swap_request` — petición de cambio entre miembros
   - Conflict matrix con `rotating_host` (no pueden coexistir)

3. **Nuevos SystemEventTypes**:
   - `slotAssigned`, `slotDeclined`, `slotExpired`, `slotSwapRequested`,
     `slotSwapApproved`, `positionChanged`

4. **Nuevos Conditions/Consequences**:
   - Conditions: `slotIsUnassigned`, `slotExpiresInHours`
   - Consequences: `assignSlotByRotation`, `notifyAboutSlot`,
     `chargeFineForRefusal`

5. **Template config `shared_resource`**:
   - Migration que inserta el row en `templates`
   - `defaultModules`: slot_assignment, rotating_position, basic_fines
   - `defaultGovernance`: founder edits, anyMember accepts/declines slot
   - `eventVocabulary`: "turno" (parametrizable: partido, fin de semana, etc.)
   - 3-5 reglas default

6. **Vistas iOS específicas**:
   - `SharedResourceHomeView` (reemplaza `DinnerHomeView`)
   - `SlotDetailView`, `AssignSlotSheet`, `RequestSwapSheet`
   - Onboarding flow nuevo (más corto: ~6 pasos)

7. **Test E2E de la promesa**:
   - Family de 5 personas crea un palco → admin asigna 17 partidos →
     un miembro rechaza → multa se aplica → otro pide swap → vote.

**DoD**:
- [ ] Template `shared_resource` instalable en prod
- [ ] 10 grupos beta cerrados usando el template
- [ ] 0 cambios en código de Platform/ para shippearlo (criterio fuerte)
- [ ] El cambio de `eventVocabulary` propaga a todas las vistas via tokens

**Riesgos**:
- **El más grande**: descubrir asunciones ocultas de `recurring_dinner`
  hardcodeadas en Platform/. Si aparecen, hay que refactorizar antes
  de shippear template #2. Mejor descubrirlas ahora que en template #5.
- Onboarding diferente requiere step dispatcher genérico que aún no
  está validado.

**Métrica de éxito**: shippear template #2 con ≤ 200 líneas de cambio
en `Platform/`. Si requiere más, la arquitectura no es lo que pretende.

---

### Fase 3 — Template #3: `pool` (tandas)

**Duración**: 10–14 semanas.
**Goal**: Abrir categoría completamente diferente — dinero rotativo.
Mercado: tandas LatAm, susus africano-caribeños, hui asiáticos, comités
centroamericanos. Categoría 3 de la conversación, 5 sub-casos
inmediatos.

**Trabajos**:

1. **Nuevos primitives**:
   - `ResourceType.fund` — pool de dinero del grupo
   - `ResourceType.contribution` — aporte individual a un fund
   - `ResourceType.payout` — distribución del fund a un miembro

2. **Nuevos módulos**:
   - `pool_contribution` — calendario de aportes
   - `pool_rotation` — rotación de quién recibe el fund
   - `payment_tracking` — registra pagos, no los procesa todavía
   - `defaulter_handling` — qué pasa si alguien deja de aportar

3. **Decisión crítica: payments**.
   - Opción A: tracking only (manual). Lanza rápido, sin riesgo regulatorio.
   - Opción B: integración con Stripe / MercadoPago / Conekta.
     Riesgo regulatorio (KYC, AML, reglas de envío de dinero por país).
   - Recomendación: empezar con A, agregar B como módulo opcional
     después de validar product-market fit.

4. **Localización cultural**.
   - El mismo template sirve para tanda (México), susu (Caribe), hui
     (Asia), comité (Centroamérica), tontine (África francófona).
   - Diferencia es UI labels y onboarding, no primitivas.
   - String catalogs por locale (es-MX, es-HN, es-PR, en-US, en-CA, etc.).

5. **Manejo de defaulters**.
   - Caso real: alguien recibe el bote y deja de pagar.
   - Esto no es solo una multa — es una falla del producto si no
     hay mecanismo de recuperación.
   - Reglas default: warning, exclusion, vote para cobertura grupal.

6. **Onboarding tanda**.
   - Diferente a cena: monto del aporte, frecuencia, número de turnos,
     orden inicial (sorteo o consenso).

**DoD**:
- [ ] Template `pool` instalable
- [ ] 20 tandas cerradas exitosamente (todos cobran)
- [ ] 0 cambios en `Platform/` mayores a 300 líneas
- [ ] Manual de defaulter-handling validado con 3 incidents reales

**Riesgos**:
- **Regulatorio**: si algún país clasifica esto como "money transmission
  service", aplica KYC. Investigar antes de shippear en MX, US, CA.
- **Confianza**: la tanda es un producto basado en confianza. Si la
  app mete fricción innecesaria, no se usa.
- **Default cascade**: si un miembro defaultea, todo el grupo tiene
  que ajustarse. La UX de eso es delicada.

**Métrica de éxito**: 20 tandas completas (12 meses cada una en
promedio = 1 año de uso real), default rate < 10%.

---

### Fase 4 — Tooling de autoría de templates

**Duración**: 8–10 semanas.
**Goal**: El equipo interno puede shippear nuevos templates sin
involucrar engineering. Eventualmente, abrir a comunidad.

**Trabajos**:

1. **Admin web app** (Next.js, reusando `web-deprecated/`):
   - Lista de templates en prod
   - Editor de `templates.config` con schema validation
   - Preview de onboarding flow
   - Toggle de availability por versión

2. **Module catalog UI**:
   - Vista de todos los módulos
   - Dependencies / conflicts visualizados
   - Tests de combinaciones (¿este set de módulos es válido?)

3. **Rule library**:
   - Reglas reutilizables entre templates
   - Cada regla es un row tipado, no un blob
   - Búsqueda por trigger / condition / consequence

4. **A/B testing framework**:
   - Variantes de un template
   - Asignación por grupo nuevo
   - Métricas comparativas

**DoD**:
- [ ] PM puede shippear un template parametrizado nuevo sin tocar Swift
- [ ] 3 templates más en prod sin código nuevo de Platform/
- [ ] Tests de combinaciones de módulos verdes en CI

**Métrica de éxito**: tiempo de shippear un template parametrizado
< 1 semana, sin engineering.

---

### Fase 5 — Custom rules per group

**Duración**: 10–14 semanas.
**Goal**: Power users (grupos maduros, > 6 meses, > 5 reglas activas)
pueden escribir sus propias reglas. Esto cubre el long tail de las
130 categorías sin shippear más templates.

**Trabajos**:

1. **Visual rule builder en iOS**:
   - Composer WHEN [trigger] IF [conditions...] THEN [consequences...]
   - Pickers tipados (no free text — el usuario elige de catálogo)
   - Preview con sample data antes de activar

2. **Rule versioning per group**:
   - Cada cambio de regla emite SystemEvent + crea versión nueva
   - Reglas viejas siguen aplicables a multas pre-cambio (rule
     snapshots — ya tienen esto en anti-tirania)

3. **Rule sharing**:
   - Un grupo puede "fork" la regla de otro grupo
   - Eventualmente: marketplace de reglas

4. **Rule limits**:
   - Cap por grupo (ej: 25 reglas activas) para evitar overcomplication
   - Conflict detection (dos reglas que se contradicen)

**DoD**:
- [ ] 50 grupos con al menos 1 rule custom
- [ ] 0 incidents por reglas mal formadas (validation server-side)
- [ ] Cap-de-reglas tested en CI

**Métrica de éxito**: NPS > 50 en encuesta a power users,
"poder escribir mis reglas" mencionado como feature top-3.

---

### Fase 6 — Plataforma transversal (ongoing)

Features que aplican a todos los templates y aumentan retención
+ valor.

- **Calendar sync** (Google, Apple) — eventos y deadlines salen del app.
- **Payments**: integración real para tandas, fines settlement,
  expense splits. Por país: Stripe/MercadoPago/Conekta.
- **Cross-group analytics**: "estás en 7 grupos, te quedan 3 pagos
  pendientes este mes".
- **Web companion app**: para users no-iOS (familias, comunidades
  religiosas) o operations heavy (governance edits desde laptop).
- **Export / data portability**: GDPR compliance + transferencia de
  ownership.
- **Group transfer / merge / split**: founder se va, grupo continúa.
- **Audit log download**: contadores, abogados, finanzas familiares.
- **Multi-region**: Supabase region per país (latencia + soberanía
  de datos).

---

## 4. Riesgos arquitectónicos y mitigación

| Riesgo | Severidad | Cuándo aparece | Mitigación |
|---|---|---|---|
| Drift de enums Swift↔TS | Alta | Ya pasó 3x | Codegen en Fase 0 |
| `system_events` crece sin techo | Alta | ~100k grupos | Particionado por mes + archival a cold storage. Documentar en Fase 0, implementar antes de Fase 2 |
| RLS performance degrada | Media | ~10k grupos | Índices revisados + EXPLAIN en CI para queries top-10 |
| Cron de rule engine no escala | Media | ~50k grupos | Migrar de "every 1m cron" a event-driven (NOTIFY/LISTEN o pg-boss). Plan en Fase 2 |
| Migrations bloqueantes en prod | Alta | Cada release grande | Zero-downtime migration playbook. Add column nullable → backfill → make required. Documentar en Fase 0 |
| Multi-region split brain | Alta | Cuando agregue regiones | Defer hasta Fase 6. Por ahora single-region. |
| Rate limiting / abuse | Media | App pública | Edge function rate limiter por IP + user. Implementar en Fase 1 |
| Apple rejection del rule engine | Media | App Store submission | Documentar como "group rules engine" no "scripting". Defer Edge cases |
| Codegen complejidad | Baja | Si se hace mal | Mantener simple: TS source → Swift enum. Sin features fancy |

---

## 5. Decisiones que tienes que tomar antes de Fase 0

Estas no son recomendaciones, son decisiones que dependen de info
que no tengo. Cada una afecta el plan.

### D1. iOS 26+ exclusivo o bajar a iOS 17/18

**Trade-off**: Liquid Glass real vs TAM accesible.

iOS 26 hoy tiene <40% adoption (a meses de release). Para los 130
casos de la conversación — palcos familiares, cenas con primos
mayores, círculos religiosos, tandas con migrantes, comunidades
indígenas — el porcentaje en iOS 26 es bajo. Si una persona del grupo
no tiene la app, el sistema no funciona (los grupos son frágiles).

**Recomendación**: bajar a iOS 18 deployment target. Liquid Glass como
enhancement opcional con fallback a Material en iOS < 26. La pureza
estética no vale el costo de TAM en early stage.

**Si rechazas la recomendación**: el plan se mantiene pero los números
de Fase 1 (100 grupos en 6 semanas) deberían bajarse a 30-50.

### D2. Web companion: ahora o después

**Trade-off**: alcance Android/desktop vs foco iOS.

`web-deprecated/` ya existe. Una versión read-only "ver mi grupo" en
web cuesta ~3 semanas. Esto cubre Android users en grupos mixtos sin
shippear app Android.

**Recomendación**: hacer web companion read-only en Fase 1 como
"plan B". No drena recursos significativos y abre canal.

### D3. Payments timeline

**Trade-off**: monetización + retención vs riesgo regulatorio.

Sin payments, las tandas son tracking-only — útil pero no diferenciador
fuerte vs Excel. Con payments, hay PMF claro pero KYC, AML, money
transmission licenses en cada país.

**Recomendación**: tracking-only en Fase 3, decisión de payments en
Fase 6 con base en demanda real y consulta legal por país.

### D4. ¿Open source el rule engine o mantener cerrado?

**Trade-off**: credibilidad técnica vs posible competencia copy-paste.

El rule engine es ~2000 líneas de TS. Es replicable pero no trivial.
Open-sourcearlo construye comunidad técnica y respeto. No abre tu
moat real, que es la composición de templates + governance + UX.

**Recomendación**: open source el rule engine (`platform/ruleEngine`
solo) en Fase 4. Mantener templates, módulos, UI cerrados.

### D5. Sentry vs Datadog vs PostHog

**Trade-off**: costo y profundidad.

Para early stage: Sentry para crashes/errors + PostHog para producto
analytics. Datadog es overkill hasta Fase 4+.

**Recomendación**: Sentry + PostHog. Migrar a Datadog si tracing
distribuido se vuelve necesario (probablemente Fase 5+).

### D6. Co-Authored-By Claude / claude-flow visible o no

**Trade-off**: transparencia + dev cred vs perception risk con
investors o usuarios conservadores.

Hoy los commits llevan `Co-Authored-By: claude-flow`. No hay nada
malo con eso pero algunos investors de hardware/biotech leen
"AI-generated code" como riesgo.

**Recomendación**: mantener trailer en commits internos, removerlo de
release tags públicos. Decisión cosmética.

---

## 6. Stack de observabilidad

Lo que necesitas instrumentar desde Fase 0.

**iOS**:
- Sentry: crashes, errors, slow renders
- PostHog: events de producto (group_created, event_rsvp,
  rule_proposed, vote_cast, etc.)
- Performance traces en RPC calls

**Edge Functions**:
- Logs estructurados (JSON)
- Sentry para errors no manejados
- Métricas: latencia p50/p95/p99 por function, error rate
- Custom metric: `rule_firings_per_minute` por template

**Postgres**:
- pg_stat_statements habilitado
- Slow query log (> 100ms)
- Métricas: connections active, deadlocks, lock waits
- Auto-vacuum monitoring

**Dashboard mínimo (cualquier herramienta)**:
- Grupos creados / día
- Eventos cerrados / día
- Multas emitidas / día (manual vs auto-rule)
- Apelaciones abiertas / resueltas
- Rule firings (volumen + breakdown por consequence type)
- Error rate por RPC (top 10)
- Decode failures (SystemEventType, ConditionType, etc.)

**Alertas Sev2 (Slack)**:
- Error rate > 1% en cualquier RPC
- Decode failures > 0
- Edge function p99 > 5s
- Cron stuck > 3 ciclos

**Alertas Sev1 (Page)**:
- App crash rate > 0.5%
- Login failure rate > 5%
- Database connection pool exhausted

---

## 7. Modelo de releases y feature flags

A partir de Fase 1, releases siguen este modelo:

- **iOS**: TestFlight → production con 7 días de cohabitación.
- **Backend**: cada migration tiene feature flag (column `enabled`
  en tabla de flags). RPC nuevo se shippea behind flag, se enciende
  para 1% → 10% → 100%.
- **Templates**: tabla `templates.available` permite shippear nuevo
  template solo a beta users (flag por user role).

**Feature flag tabla**:
```sql
create table feature_flags (
  key text primary key,
  enabled boolean not null default false,
  enabled_for_groups uuid[] default '{}',
  enabled_for_users uuid[] default '{}',
  rollout_percent int default 0
);
```

Function `is_flag_enabled(key, group_id, user_id)` consultada en RPC.
Cliente no consulta flags directamente (server decide).

---

## 8. Cómo medir si la arquitectura realmente es escalable

Tres tests que se corren al final de Fase 2 y Fase 3.

**Test 1 — Template Velocity Test**.
Tiempo desde "decisión de shippear template X" hasta "10 grupos lo
están usando en prod". Objetivo: ≤ 8 semanas en Fase 2, ≤ 6 semanas en
Fase 3.

**Test 2 — Platform Stability Test**.
Líneas modificadas en `Platform/` por cada nuevo template shipped.
Objetivo: < 200 líneas en Fase 2, < 100 líneas en Fase 3.

**Test 3 — Multi-Tenant Isolation Test**.
Test automatizado: un grupo con datos extremos (1000 miembros, 500
reglas, 10000 events) no degrada performance de otro grupo. Cap
detectado y graceful en lugar de crash global.

Si alguno de estos tres falla, congelar nuevos templates y volver a
Fase 0 (hardening).

---

## Apéndice — Mapeo a las 130 categorías

Cuando termine cada fase, qué % de las 130 está cubierto:

| Fase | Templates en prod | Categorías cubiertas | % |
|---|---|---|---|
| 1 | recurring_dinner | 1, 5–12, 78–84, 109–112, 116–118 (cenas, clubs, religiosas, accountability) | ~25% |
| 2 | + shared_resource | 13–29 (recursos compartidos) | ~40% |
| 3 | + pool | 30–45 (dinero rotativo + vaquitas) | ~55% |
| 4 | + 3 templates parametrizados | edges de las primeras 3 categorías | ~70% |
| 5 | custom rules | long tail de 1, 2, 3 + edge cases de 5–8 | ~85% |
| 6 | + integraciones | resto | ~95% |

El último 5% requiere primitives nuevas (asambleas indígenas,
DAOs híbridas, custodia legal) que se evalúan caso a caso.

---

## Notas finales

Este plan es un draft. Tres cosas a discutir antes de adoptarlo:

1. Las decisiones D1–D6 de §5 son tuyas, no mías.
2. Las duraciones (4-6 semanas, 8-12 semanas) asumen 1-2 ingenieros
   full-time + 1 PM. Escalar arriba o abajo cambia los números.
3. Fase 0 puede sentirse como overhead vs cerrar gaps de UI. La razón
   por la que va primero es que **cada uno de esos hardening items se
   vuelve 3-5x más caro después de Fase 2**. Pagar ahora.

Si alguno de estos tres puntos cambia el cálculo, vuelvo y ajusto.
