# V3 Plan — Ruul Quality / Launch (post-V2)

> **Plan complementario activo.** Hermano de `Plans/Active/V2Plan.md`
> (depth/engine/integrations). V3 es la capa final antes del launch
> público: real-time, push, warmth, accesibilidad, App Store
> compliance, observabilidad.
>
> Acordado 2026-05-27.
>
> Doctrina vigente:
> - V2 contesta: *"¿las primitivas trabajan juntas?"* → engine activo,
>   votos completos, multas conectadas a dinero, decisiones mutan estado.
> - **V3 contesta: *"¿se siente vivo, claro y confiable a diario,
>   y está listo para shipping público?"***
> - V3 NO agrega primitivas ni handlers nuevos — es capa transversal
>   sobre lo que V2 entrega.
> - Slices chicos, mergeables, instalables en device por sesión.
> - Prefijo commit durante V3: `v3:` (después de `v2.0.0-rc` tag).

---

## 1. Convenciones

Las mismas de `UIBottomUpPlan.md §1` + `V2Plan.md §1`. Suma:

- **Apple Human Interface Guidelines** vinculantes: cualquier
  superficie nueva pasa por audit HIG antes de cerrar el slice.
- **WCAG AA** como floor de accesibilidad (contraste 4.5:1, focus
  visible, hit targets ≥44pt).
- **Privacy by design**: ningún dato sale del backend sin opt-in
  explícito (analytics, crash reports, etc.).
- **App Store reviewable**: cada slice se evalúa contra el
  guideline relevante (5.1.1 privacy, 5.1.1(v) account deletion,
  etc.).

---

## 2. V3 — Épicas

### V3-A · Sensación de vivo (Real-time + Push)

**Por qué**: hoy todo requiere pull-to-refresh. Una app que coordina
gente real necesita reaccionar a eventos remotos. Después de V2 el
engine genera muchas más consecuencias automáticas — todas deben
notificarse.

- **A1 Real-time subscriptions** — Supabase Realtime para:
  - `group_events` → `EventsStore` actualiza in-place.
  - `group_disputes` → `DisputesStore` refresca al cambiar estado.
  - `group_decisions` + `group_votes` → countdown en vivo.
  - `group_obligations` → balances actualizados sin refresh.
- **A2 APNs token registration** — device token → tabla
  `notification_tokens` (existe). Deep-link handlers de tap routean
  a `DeepLinkRouter` ya wired.
- **A3 Notification preferences en device** — surface
  `notification_preferences` (tabla existe) en
  `NotificationSettingsView` con opt-in granular por categoría:
  - Disputas que me involucran
  - Sanciones contra mí
  - Votos donde puedo votar
  - Recordatorios de deuda
  - Mandates por vencer
  - Decisiones del grupo (read-only)
- **A4 Handlers críticos** — cada uno con copy ES-MX + sound +
  payload con deep-link:
  - `dispute.opened` contra ti
  - `sanction.issued` contra ti
  - `decision.opened` donde puedes votar
  - `obligation.overdue` recordatorio
  - `mandate.expiring_in_24h`
  - `member.joined` (silenciable)

**Tamaño**: 3-4 sesiones.

### V3-B · Warmth / Onboarding

**Por qué**: hoy crear un grupo desde cero es seco. Después de V2
hay muchas piezas — un primer-grupo debería poblar lo más posible
con presets sensatos.

- **B1 Templates de grupo** — sheet de creación con presets que
  pre-pueblan propósito + reglas iniciales + decision_rules +
  módulos activos:
  - **Casa familiar** — money compartido, decisión consensus,
    sin sanciones por default, fund común.
  - **Departamento compartido** — money split-friendly, suspensión
    posible, decision majority + quórum.
  - **Viaje con amigos** — temporal, fund común, sin sanciones,
    auto-dissolución al cerrar viaje.
  - **Equipo de trabajo** — roles + mandates pre-creados, decision
    supermajority, sanciones formales.
  - **Comunidad** — cultural_norms + ritual_meaning sugeridos,
    decision consent.
- **B2 Tutorial primer grupo** — 3 pantallas onboarding skippable:
  qué es Ruul, cómo se crea un grupo, primeros pasos.
- **B3 Foundation hero card** — cuando `group_foundation_status =
  ready`, mostrar hero "Tu grupo está listo" con 3 CTAs sugeridos
  por template.
- **B4 Memoria narrativa editorial** — campo `note` opcional en
  `record_system_event` (mig chico) + UI para anotar el "por qué"
  en eventos clave (sanción, disolución, gasto grande, decisión
  importante).

**Tamaño**: 3 sesiones.

### V3-C · Cross-app reach (Apple platform completa)

**Por qué**: Apple es widgets + LiveActivity + Shortcuts + Spotlight,
no solo el app icon. Después de V2 hay datos ricos para exponer.

- **C1 WidgetsExtension** (target nuevo):
  - Pequeño: tus deudas pendientes (count + monto total).
  - Mediano: próximo ritual + decisiones abiertas que puedes votar.
  - Grande: feed del Inicio del grupo activo (últimos 4 eventos).
  - Configurable: elegir qué grupo mostrar.
- **C2 LiveActivity / Dynamic Island** (target nuevo):
  - Deuda activa con CTA "Pagar" inline.
  - Voto cerrando pronto (countdown live).
  - Disputa en mediación contigo.
- **C3 App Intents / Shortcuts** (target nuevo):
  - "Hey Siri, registra un gasto de $X en [grupo]"
  - "Hey Siri, abre Inicio de [grupo]"
  - "Hey Siri, paga mi multa"
  - Shortcuts personalizados que el usuario puede armar.
- **C4 Spotlight indexing** — indexar grupos, miembros, recursos,
  decisiones abiertas para que `cmd+space` los encuentre.
- **C5 Deep-link robusto** — `ruul://group/X/decision/Y` ya parcial;
  agregar `ruul://sanction/Z`, `ruul://dispute/W`,
  `ruul://member/G/M`, `ruul://pay/sanction/Z`.

**Tamaño**: 3-4 sesiones (cada extension target ~1 sesión).

### V3-D · App Store ready

**Por qué**: pre-shipping bar. Apple lo exige.

- **D1 Localización real** — `.xcstrings` catalog generado desde
  `L10n` namespace. ES-MX primario, EN secundario. Auto-traducción
  base + revisión manual de casos sensibles ("sanción"/"sanction"
  no son idénticos en tono).
- **D2 Accessibility audit** — exhaustivo:
  - VoiceOver labels en cada surface (no solo derivados).
  - Dynamic Type hasta xxxLarge sin truncate.
  - Color contrast WCAG AA en glass surfaces.
  - Reduce motion respeto (sin animaciones forzadas).
  - Hit targets ≥44pt en todos los buttons.
- **D3 Avatar real upload** — `PhotosPicker` + Supabase Storage en
  `EditProfileView`. Hoy `Profile.avatarURL` solo acepta URL externo.
  Storage bucket policy + image resize edge function.
- **D4 Phone/Email change verificado** — `AccountSecurityView` +
  `AuthService.startPhoneChange`/`startEmailChange` deben funcionar
  end-to-end en device con OTP. Error states cubiertos.
- **D5 Account deletion** — Apple Guideline 5.1.1(v): debe haber
  forma de borrar la cuenta in-app, no solo soporte. RPC
  `delete_my_account()` SECURITY DEFINER + confirmación + grace
  period de 30 días + email confirmación.
- **D6 Legal hosted** — ToS + Privacy Policy en `ruul.app/legal`
  (Vercel landing). Linkear en `PersonalSettingsView` + onboarding.
- **D7 App Store assets** — screenshots todos los tamaños iPhone
  (6.7" / 6.5" / 5.5"), app preview video 30s, metadata bilingüe,
  icon final + dark variant, marketing copy.

**Tamaño**: 4-5 sesiones.

### V3-E · Operacional

**Por qué**: una vez la app está en manos reales, founder necesita
ver qué pasa sin entrar a Supabase.

- **E1 Sentry wired** — `Sentry` ya en `Package.swift`. Init en
  `RuulAppShell` con DSN + capture de errores no manejados +
  breadcrumbs por RPC + screenshot opcional en crashes. Source
  maps cargados en CI.
- **E2 Analytics opt-in** — telemetría minimal sin PII (events
  agregados por screen + retención + funnel de onboarding).
  Opt-in explícito en onboarding step 3.
- **E3 Export del grupo** — RPC `export_group(group_id)` →
  JSON + PDF. Apple data portability + paz mental del founder.
  Surface en `GroupSettingsView` → Zona destructiva.
- **E4 Backup automático** — snapshot diario de `decision_rules` /
  `settings` / `roles_catalog` jsonb a tabla `group_backups`.
  Permite revert si admin corrompe accidentalmente.
- **E5 Admin dashboard founder** — página oculta detrás de feature
  flag, accesible solo al founder (`auth.uid()` check hard-coded
  en una RPC `is_founder()`):
  - Grupos activos / archivados / dissolved.
  - Errores recientes (últimos 100 desde Sentry).
  - Latencia RPC p50/p95.
  - Usuarios activos diarios / semanales.

**Tamaño**: 2-3 sesiones.

---

## 3. Suma

| Épica | Sesiones |
|---|---|
| V3-A Real-time + Push | 3-4 |
| V3-B Warmth | 3 |
| V3-C Cross-app reach | 3-4 |
| V3-D App Store ready | 4-5 |
| V3-E Operacional | 2-3 |
| **Total V3** | **~15-19 sesiones** |

A ritmo 1-2 sesiones/día = 2-3 semanas calendario después de cerrar V2.

---

## 4. Orden recomendado

V3 no es estrictamente secuencial — se puede paralelizar. Sugerido:

| Orden | Slice | Por qué |
|---|---|---|
| 1-4 | V3-A Real-time + Push | ROI inmediato, app se siente viva |
| 5-7 | V3-B Warmth | Hace que el primer grupo no sea seco |
| 8 | V3-E1 Sentry wired | Antes de cualquier device test masivo |
| 9-13 | V3-D App Store ready | Pre-shipping requirement |
| 14-17 | V3-C Cross-app reach | Diferenciador Apple, después de stable |
| 18-19 | V3-E2-E5 Operacional resto | Founder visibility post-launch |
| 20 | TestFlight beta | Hito |
| 21 | App Store submission | Hito |
| 22 | **v1.0.0 production** | 🎉 |

---

## 5. Launch checklist

Antes de submit a App Store, todos estos deben ser verde:

### Funcional
- [ ] Suite RuulCore tests verde 100%
- [ ] Device smoke completo de 22 primitivas V1 + 9 V2-G slices
- [ ] Real-time + push verificado con 2 devices reales
- [ ] Templates de grupo crean grupos coherentes
- [ ] Export del grupo produce JSON válido

### Apple compliance
- [ ] HIG audit (navegación, gestos, toolbars)
- [ ] WCAG AA verde (Accessibility Inspector)
- [ ] Account deletion in-app funciona
- [ ] Privacy nutrition labels llenadas
- [ ] App Tracking Transparency prompt (si analytics opt-in)

### Legal
- [ ] ToS hosted + linkeado
- [ ] Privacy Policy hosted + linkeado
- [ ] Crash reporting opt-in explícito
- [ ] Account deletion grace period documentado

### Marketing
- [ ] Screenshots todos los tamaños
- [ ] App preview video 30s
- [ ] Metadata bilingüe ES-MX / EN
- [ ] Icon final + dark variant
- [ ] What's New copy primera versión

### Operacional
- [ ] Sentry recibe crashes desde TestFlight
- [ ] Backup diario corriendo
- [ ] Admin dashboard accesible al founder
- [ ] Rollback plan documentado

---

## 6. Prompt sugerido para la próxima sesión

> Continuando Ruul. V2 ya en progreso (engine + integrations) según
> `Plans/Active/V2Plan.md`. Cuando V2 cierre (`v2.0.0-rc` tag),
> arrancar V3 según `Plans/Active/V3Plan.md`. Primer slice
> recomendado: **V3-A1 Real-time subscriptions** — wire Supabase
> Realtime para `group_events`, `group_disputes`, `group_decisions`,
> `group_obligations`. Cada store relevante actualiza in-place.
>
> Sigue convenciones de `UIBottomUpPlan.md §1` + `V2Plan.md §1` +
> `V3Plan.md §1`. Commits con prefijo `v3:` después de `v2.0.0-rc`.

---

## 7. Tracking

### V3-A Real-time + Push
- [ ] A1 Real-time subscriptions (events / disputes / decisions / obligations)
- [ ] A2 APNs token registration + deep-link handlers
- [ ] A3 Notification preferences UI
- [ ] A4 Handlers críticos (6 tipos)

### V3-B Warmth / Onboarding
- [ ] B1 Templates de grupo (5 presets)
- [ ] B2 Tutorial primer grupo
- [ ] B3 Foundation hero card
- [ ] B4 Memoria narrativa editorial (notes)

### V3-C Cross-app reach
- [ ] C1 WidgetsExtension
- [ ] C2 LiveActivity / Dynamic Island
- [ ] C3 App Intents / Shortcuts
- [ ] C4 Spotlight indexing
- [ ] C5 Deep-link robusto

### V3-D App Store ready
- [ ] D1 Localización `.xcstrings`
- [ ] D2 Accessibility audit
- [ ] D3 Avatar real upload
- [ ] D4 Phone/Email change verificado
- [ ] D5 Account deletion in-app
- [ ] D6 Legal hosted
- [ ] D7 App Store assets

### V3-E Operacional
- [ ] E1 Sentry wired
- [ ] E2 Analytics opt-in
- [ ] E3 Export del grupo
- [ ] E4 Backup automático
- [ ] E5 Admin dashboard founder

### Launch
- [ ] TestFlight beta cerrada (founder + 5 testers)
- [ ] TestFlight beta abierta (100 testers)
- [ ] App Store submission
- [ ] **v1.0.0 production** 🎉

---

## 8. Fuera de scope (post-launch)

Estas cosas NO entran en V3 — se replanteam después del launch
público con feedback real.

- Primitiva 7 Comunicación (chat / canales intra-grupo)
- Primitiva 10 Incentivos gamificados
- Primitiva 24 Cuidado/Mantenimiento como UI dedicada
- iPad / macOS layouts custom (responsive sí, dedicados no)
- Internationalization más allá de ES + EN
- Pricing / monetización (modelo freemium pendiente)
- Marketing site / landing page completo
- Integraciones third-party (Splitwise import, Plaid, etc.)
- AI features (resumen automático, sugerencias contextuales,
  conflict mediation assistant)
- Web companion app (read-only del grupo)
- Multi-currency real (hoy solo MXN; agregar conversión)
