# V2 Plan — Ruul post-V1 (capa de calidad sobre las primitivas)

> **Plan complementario activo.** Hermano de `Plans/Active/Plan.md`
> (backend canónico) y `Plans/Active/UIBottomUpPlan.md` (iOS bottom-up).
> Este plan rige la fase **post-Foundation**: V2 no agrega primitivas
> nuevas, agrega *capas* sobre las 22 primitivas accionables de V1
> para que el grupo se sienta vivo, claro y confiable en uso diario.
>
> Acordado 2026-05-27.
>
> Doctrina vigente:
> - V1 contesta: *"¿se puede coordinar un grupo aquí?"* → sí, 22/22 primitivas.
> - V2 contesta: *"¿se siente vivo, claro y confiable a diario?"*
> - Primitivas post-V1 explícitas (Comunicación 7, Incentivos 10,
>   Cuidado 24) NO entran en V2 — quedan para una fase posterior.
> - Slices chicos, mergeables, instalables en device por sesión.

---

## 0. V1 close — 5 slices de polish (~4-5 sesiones)

V1 está al ~85% real. Estos 5 slices cierran los flows pendientes
antes de empezar V2. Cada uno tiene RPC backend ya disponible — todo
el trabajo es UX/wire en iOS.

| # | Slice | Backend (ya existe) | iOS | Tamaño |
|---|---|---|---|---|
| V1.1 | Apelación de sanción (Primitiva 11) | `dispute_sanction` + `escalate_dispute_to_vote` | Borrar `AppealSanctionView` placeholder; wire botón "Apelar" del `SanctionDetailView` → `DisputeSanctionSheet`; CTA opcional `escalateToVote` post-disputa | 1-2 h |
| V1.2 | Verify contribución (Primitiva 9) | `verify_contribution` | Swipe action en `ContributionsListView` (Aceptar/Rechazar) + badge de estado (claimed/verified/rejected) + admin gate `contribution.verify` | 3 h |
| V1.3 | Transferir propiedad (Primitiva 18) | `set_resource_ownership` | `TransferOwnershipSheet` en `ResourceDetailView` con picker `ownership_kind` (group/member/external) + member picker cuando aplique | 4 h |
| V1.4 | Estados de membresía (Primitiva 2) | `set_membership_state` | Acciones admin en `MemberDetailView`: Suspender / Reactivar / Expulsar, con razón opcional + duración para suspensión, gated por `members.suspend` / `members.remove` | 4 h |
| V1.5 | Proponer norma cultural (Primitiva 20) | `propose_cultural_norm` | Toolbar `+` en `CulturalNormsListView` que abre `EditCulturalNormView` en modo crear | 30 min |

**Done V1**: build verde, tests verdes, smoke en device de los 5 flows, push a main, V1 release tag opcional (`v1.0.0-rc`).

---

## 1. Convenciones (las mismas de UIBottomUpPlan §1)

- iOS no escribe tablas directo.
- Toda mutación pasa por RPC canónica.
- Views no importan `Supabase`.
- Strings → `L10n.<Namespace>.<key>`.
- Stores `@MainActor @Observable`.
- Tolerant Codable.
- Errores → `CanonicalBackendError` → `UserFacingError`.
- Commits: `v2: <verb> <thing>` (cambia el prefijo `foundation:`→`v2:` para
  distinguir fase).
- Cada slice: build green + tests green + device install + push.
- Append-only se respeta.

---

## 2. V2 — Épicas

V2 no es secuencial estricto; cada épica entrega valor independiente.
Orden recomendado abajo (§4) basado en ROI percibido.

### V2-A · Sensación de vivo (Real-time + Push)

**Por qué**: hoy todo requiere pull-to-refresh. Una app que coordina
gente necesita reaccionar a eventos remotos sin que el usuario tenga
que ir a buscarlos.

- **A1 Real-time subscriptions**: Supabase Realtime para `group_events`
  (timeline), `group_disputes` (estado), `group_decisions` (votos
  abiertos). Cada store relevante actualiza in-place.
- **A2 APNs token registration**: device token → `notification_tokens`
  table. Handlers de tap deep-link al destino correcto.
- **A3 Notification preferences en device**: surface
  `notification_preferences` (ya existe tabla) en
  `NotificationSettingsView` — opt-in por categoría.
- **A4 Notification handlers críticos**: disputa abierta contra ti,
  sanción emitida contra ti, voto abierto donde puedes votar,
  recordatorio de deuda outstanding > 7 días, mandate vence en 24h,
  miembro nuevo aceptó invitación.

Backend ya tiene `dispatch-notifications` cron + `notifications_outbox`
table. Sólo falta wire device + handlers.

**Tamaño**: 3-4 sesiones.

### V2-B · Warmth / Onboarding

**Por qué**: hoy crear un grupo desde cero es seco. El founder
quiere que el primer grupo *se sienta como algo que ya estaba bien
pensado*.

- **B1 Templates de grupo**: presets que pre-pueblan al crear grupo
  (propósito declarado/operativo, reglas base, decision_rules,
  módulos activos sugeridos):
  - "Casa familiar" — money compartido, reglas simples, decisión
    consensus, fund común.
  - "Departamento compartido" — money split-friendly, suspensión
    posible, decision rules majority.
  - "Viaje con amigos" — temporal, fund común, sin sanciones por
    default.
  - "Equipo de trabajo" — roles + mandates pre-creados, decision
    rules supermajority.
  - "Comunidad" — cultural norms + ritual annotations sugeridas.
- **B2 Tutorial primer grupo**: 3-pantalla onboarding (qué es Ruul,
  cómo se crea, primeros pasos) — skippable.
- **B3 Foundation hero tarjeta**: cuando `group_foundation_status =
  ready`, mostrar hero "Tu grupo está listo" con CTAs sugeridos
  (registrar primer gasto, abrir primera decisión, definir cultura).
- **B4 Memoria narrativa editorial**: campo opcional `note` en
  `record_system_event` (mig small) — UI permite anotar el "por
  qué" en eventos clave (sanción, disolución, gasto grande).

**Tamaño**: 3 sesiones.

### V2-C · Money advanced

**Por qué**: V1 cubre el caso simple (gasto split + settlement). Hay
patrones reales (contribución en especie, fondos protegidos, mandatos
en money) que necesitan superficie propia.

- **C1 Contribuciones in-kind con valuación**: warehouse case del
  doctrine `doctrine_in_kind_contributions`. Ledger `type =
  'contribution'`, no expense. UI distingue claramente.
- **C2 Subtipos de resources con detalle**:
  - Fund: balance histórico, in/out, protected flag.
  - Space: bookings (existe table), check-in.
  - Asset: valuation timeline, depreciación opcional.
- **C3 Pool charges admin UX**: `record_pool_charge` ya existe;
  agregar sheet "Crear cuota" desde tab Dinero.
- **C4 Mandates en money flows**: cuando hay mandato activo del
  caller, los sheets de gasto/settlement permiten "actuar en nombre
  de" + popular `mandate_id` en el RPC (doctrine
  `doctrine_mandate_in_money_rpcs`).

**Tamaño**: 4-5 sesiones.

### V2-D · Cross-app reach

**Por qué**: Apple platform es mucho más que el app icon. Widgets,
Live Activities, Shortcuts y Spotlight hacen que Ruul "viva" fuera
de la app.

- **D1 WidgetsExtension** (target nuevo): home screen + lock screen.
  - Pequeño: deudas tuyas pendientes (count).
  - Mediano: próximo ritual + decisiones abiertas.
  - Grande: feed del Inicio del grupo activo.
- **D2 LiveActivity / Dynamic Island** (target nuevo):
  - Deuda activa con CTA "Pagar".
  - Voto cerrando pronto (countdown).
  - Disputa en mediación.
- **D3 App Intents / Shortcuts** (target nuevo):
  - "Hey Siri, registra un gasto en [grupo]".
  - "Hey Siri, abre Inicio de [grupo]".
- **D4 Spotlight indexing**: indexar grupos, miembros, recursos,
  decisiones para que `cmd+space` los encuentre cross-app.
- **D5 Deep-link router robusto**: `ruul://group/X/decision/Y` ya
  existe parcial; agregar `ruul://sanction/Z`, `ruul://dispute/W`,
  `ruul://member/G/M`.

**Tamaño**: 3-4 sesiones (cada extension target es ~1 sesión).

### V2-E · App Store ready

**Por qué**: para shipping pública necesitamos i18n real, a11y,
legal y account deletion. Apple lo exige + es buen ciudadano.

- **E1 Localización real**: `.xcstrings` catalog generado desde
  `L10n` namespace. ES-MX primario, agregar EN como segundo.
- **E2 Accessibility audit**: VoiceOver labels en cada surface,
  Dynamic Type tests, color contrast WCAG AA, reduce motion respeto.
- **E3 Avatar real**: `PhotosPicker` + Supabase Storage upload
  en `EditProfileView`. Hoy `Profile.avatarURL` solo acepta URL externa.
- **E4 Phone/Email change**: verificar en device que
  `AccountSecurityView` + `startPhoneChange`/`startEmailChange`
  funcionan; cubrir error states.
- **E5 Account deletion**: requirement Apple (App Store Guideline
  5.1.1(v)). RPC `delete_my_account` + confirmación + grace period.
- **E6 Legal**: ToS + Privacy Policy hosteados (Vercel
  ruul.app/legal) + linkear en PersonalSettingsView.
- **E7 App Store assets**: screenshots (todos los tamaños iPhone),
  app preview video, metadata ES/EN, icon final.

**Tamaño**: 4 sesiones.

### V2-F · Operacional

**Por qué**: una vez la app está en manos de usuarios reales, el
founder necesita ver qué pasa.

- **F1 Sentry wired**: `Sentry` ya está en `Package.swift`; init
  en `RuulAppShell` con DSN + capture de errores no manejados +
  breadcrumbs por RPC + screenshot opcional en crashes.
- **F2 Analytics opt-in**: telemetría minimal sin PII (eventos
  agregados por screen + retención). Opt-in explícito en onboarding.
- **F3 Export del grupo**: RPC `export_group(group_id)` → JSON
  completo (members + history + money + decisions). Apple
  data portability + paz mental del founder.
- **F4 Backup automático**: snapshot diario de
  `decision_rules`/`settings` jsonb en `group_backups` table.
  Allows revert si algo se corrompe.
- **F5 Admin dashboard mini**: para founder solamente, página
  oculta con health del proyecto (groups activos, errores recientes,
  latencia RPC).

**Tamaño**: 2-3 sesiones.

---

## 3. Suma

| Fase | Sesiones |
|---|---|
| V1 close (5 slices polish) | 4-5 |
| V2-A Real-time + Push | 3-4 |
| V2-B Warmth | 3 |
| V2-C Money advanced | 4-5 |
| V2-D Cross-app | 3-4 |
| V2-E App Store ready | 4 |
| V2-F Operacional | 2-3 |
| **Total post-Foundation** | **~24-28 sesiones** |

A ritmo de 1-2 sesiones por día = 3-6 semanas calendario. Launch
realista: julio-agosto 2026.

---

## 4. Orden recomendado

| Sesión | Slice | Por qué este orden |
|---|---|---|
| 1 | V1.5 Proponer norma cultural | Más chico, calienta motor |
| 2 | V1.1 Apelación de sanción | Cierra loop sancionatorio |
| 3 | V1.2 Verify contribución | Cierra loop de aportes |
| 4 | V1.3 Transferir propiedad | Cierra loop de recursos |
| 5 | V1.4 Estados de membresía | Cierra loop social pesado |
| 6 | **V1 release tag** | Hito mental + smoke completo |
| 7-10 | V2-A Real-time + Push | ROI inmediato, app se siente viva |
| 11-13 | V2-B Warmth | Hace que el primer grupo no sea seco |
| 14-18 | V2-C Money advanced | Cierra los casos reales que vimos en dogfooding |
| 19-22 | V2-D Cross-app | Plataforma Apple completa |
| 23-26 | V2-E App Store ready | Pre-shipping requirement |
| 27-28 | V2-F Operacional | Telemetría/Sentry/Export antes de launch |
| 29+ | **Launch** | TestFlight → App Store |

---

## 5. Prompt sugerido para la próxima sesión

> Continuando Ruul post-Foundation. V1 está al ~85% — quedan 5
> slices de polish documentados en `Plans/Active/V2Plan.md §0`.
> Hoy arrancamos con **V1.5 Proponer norma cultural** (el más chico,
> 30 min — toolbar `+` en `CulturalNormsListView` que abre
> `EditCulturalNormView` en modo crear; `propose_cultural_norm`
> ya existe backend).
>
> Sigue las convenciones del UIBottomUpPlan.md §1 + V2Plan.md §1
> (commits prefijo `v2:` después de cerrar V1). Cierra cada slice con:
> build green + tests green + device install + commit + push +
> actualizar §6 tracking de V2Plan.md.

---

## 6. Tracking

### V1 close
- [ ] V1.1 Apelación de sanción (Primitiva 11)
- [ ] V1.2 Verify contribución (Primitiva 9)
- [ ] V1.3 Transferir propiedad (Primitiva 18)
- [ ] V1.4 Estados de membresía (Primitiva 2)
- [ ] V1.5 Proponer norma cultural (Primitiva 20)
- [ ] **V1 release tag** `v1.0.0-rc`

### V2-A · Real-time + Push
- [ ] A1 Real-time subscriptions (events / disputes / decisions)
- [ ] A2 APNs token registration + handlers de tap
- [ ] A3 Notification preferences en device
- [ ] A4 Notification handlers críticos (5 tipos)

### V2-B · Warmth
- [ ] B1 Templates de grupo (5 presets)
- [ ] B2 Tutorial primer grupo
- [ ] B3 Foundation hero tarjeta
- [ ] B4 Memoria narrativa editorial (notes)

### V2-C · Money advanced
- [ ] C1 Contribuciones in-kind con valuación
- [ ] C2 Subtipos de resources (fund/space/asset detail)
- [ ] C3 Pool charges admin UX
- [ ] C4 Mandates en money flows

### V2-D · Cross-app
- [ ] D1 WidgetsExtension
- [ ] D2 LiveActivity / Dynamic Island
- [ ] D3 App Intents / Shortcuts
- [ ] D4 Spotlight indexing
- [ ] D5 Deep-link router robusto

### V2-E · App Store ready
- [ ] E1 Localización real `.xcstrings`
- [ ] E2 Accessibility audit
- [ ] E3 Avatar real upload
- [ ] E4 Phone/Email change verificado
- [ ] E5 Account deletion
- [ ] E6 Legal (ToS + Privacy hosted)
- [ ] E7 App Store assets

### V2-F · Operacional
- [ ] F1 Sentry wired
- [ ] F2 Analytics opt-in
- [ ] F3 Export del grupo
- [ ] F4 Backup automático
- [ ] F5 Admin dashboard mini

### Launch
- [ ] TestFlight beta
- [ ] App Store submission
- [ ] **v1.0.0 production**

---

## 7. Fuera de scope de V2 (explícito)

Estas cosas NO entran en V2; se replanteam después del launch.

- Primitiva 7 Comunicación (chat/canales intra-grupo)
- Primitiva 10 Incentivos gamificados
- Primitiva 24 Cuidado/Mantenimiento como UI dedicada
- iPad/macOS layouts dedicados (responsive sí, pero no layouts custom)
- Internationalization más allá de ES + EN
- Monetización / pricing
- Marketing site / landing
- Integraciones third-party (Splitwise import, etc.)
- AI features (resumen automático, sugerencias)
