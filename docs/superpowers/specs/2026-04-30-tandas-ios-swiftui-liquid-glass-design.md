# Tandas iOS — SwiftUI + Liquid Glass

**Date:** 2026-04-30
**Status:** Approved (design phase). Implementation plan to follow via writing-plans.
**Companion to:** `docs/superpowers/specs/2026-04-29-tandas-design.md` (web app spec)
**Repo:** `josejmizrahi/tandas` (monorepo, iOS lives in `apps/ios/`)

---

## 1. Overview

Tandas iOS es la app nativa SwiftUI complementaria de la PWA Tandas. La premisa: la PWA cubre administración (crear grupos, configurar reglas, gestionar miembros); la iOS es la **experiencia premium para los miembros del grupo** que viven el loop diario — ver mis grupos, recibir avisos del próximo evento, confirmar RSVP, pagar multas, ver mi turno.

La app abraza el lenguaje de diseño **Liquid Glass** de iOS 26 (WWDC 2025) — el primer rediseño visual transversal de Apple desde iOS 7. El target estético es "Apple Wallet meets Linear meets Things 3": premium, fintech-serio, oscuro, con Liquid Glass real en iOS 26+ y fallback `.ultraThinMaterial` para iOS 17–18.

### Loop principal en iOS

1. Login con Sign in with Apple (FaceID en 2 segundos) o phone OTP fallback.
2. Lista de mis grupos como cards estilo Wallet con glass.
3. Tap en un grupo → timeline cronológica de qué viene (eventos, multas, votos, turnos).
4. Tap en evento → sheet glass con detalle + RSVP (haptic `.success` post-confirmación).
5. Día del evento → Live Activity en Lock Screen + Dynamic Island con countdown y RSVPs en vivo.
6. Multa pendiente → tap → SPEI deep link al banco → marcar pagado → otro miembro confirma recepción.

### Outcomes

Quienes ya usan la web ganan velocidad y "feel" Apple. Quienes empiezan en iOS pueden hacer todo el loop diario sin tocar la web (sólo administración compleja queda allá). La app demuestra el alma de Tandas — un sistema que ejecuta las reglas del grupo solo — en una superficie tan pulida que se siente como app oficial de Apple.

---

## 2. Decisions Log

| # | Pregunta | Decisión | Razón |
|---|---|---|---|
| 1 | Scope MVP | Read + acciones críticas. Crear/configurar sigue en web. | Ship en 6–8 semanas, riesgo bajo, demuestra Liquid Glass donde más se ve. |
| 2 | iOS target | iOS 17+ con fallback, Liquid Glass real iOS 26+ | Cubre ~95% devices iPhone funcionales, glass real donde existe. |
| 3 | Backend / sync | Supabase REST con `supabase-swift` SDK | Reusa RLS+RPCs existentes, una fuente de verdad, web e iOS siempre alineados. SwiftData/CloudKit descartados (offline-first es v2). |
| 4 | Auth | Sign in with Apple primario + Phone OTP fallback | Login más Apple-ish posible; fallback para reusar cuentas phone existentes de la web. |
| 5 | Pago | SPEI deep link + marcar pagado + confirmación del receptor del pago | Apple Pay over-engineering para tandas mexicanas; SPEI es el flujo mental real. |
| 6 | Notificaciones | APNs + Live Activity día de evento | Live Activity = killer feature diferenciador vs PWA. Widget queda para v2. |
| 7 | Arquitectura UI | `@Observable` + feature folders (sin TCA, sin VM-less) | Sweet spot iOS 17+; TCA es overkill para 5–7 pantallas. |
| 8 | Navegación | TabView 4 tabs DENTRO del grupo. Lista de grupos = pantalla raíz. Cada grupo es una "card" estilo Wallet. | Patrón Wallet refleja "un grupo a la vez" mejor que tabs globales con switcher. |
| 9 | Identidad visual | Mesh gradient oscuro + glass premium (Stocks/Linear vibes) | Diferencia tonal de la web (light/papel) y maximiza el efecto Liquid Glass. |
| 10 | Pantalla del grupo | Hero compacto + timeline cronológica unificada (eventos/multas/votos/turnos en una secuencia) | Tandas no es solo ahorro — es vida del grupo. Timeline refleja el loop multi-dominio. |
| 11 | Approach | Vertical slice end-to-end. Slice 1 = login → grupos → timeline → RSVP. | Cada semana cierra algo shippeable, evita "demo que no funciona". |
| 12 | Dark mode | Dark only en MVP | Mesh gradient asume oscuro. Light en v2. |
| 13 | Idioma | es-MX único (heredado del spec web) | Mismo mercado. |
| 14 | Crear/admin | Sigue en la PWA, no migrar a iOS en v1 | Frecuencia baja, complejidad alta, lo hace el admin que ya conoce la web. |

---

## 3. Architecture

### Stack

| Capa | Tecnología |
|---|---|
| UI | SwiftUI 6 (iOS 17+, glass APIs `if #available(iOS 26, *)`) |
| State | `@Observable` macro + `@Environment` para DI |
| Data | `supabase-swift` (github.com/supabase/supabase-swift) — Auth + PostgrestClient + Realtime |
| Persistencia local | Solo Keychain (sesión Supabase). Sin SwiftData en MVP. |
| Auth | Sign in with Apple (`AuthenticationServices`) + Supabase `signInWithIdToken(provider: .apple)`; fallback Phone OTP via Supabase. |
| Push | APNs (Apple Push Notification service) + Edge Function Supabase para envío |
| Live Activity | `ActivityKit` (slice 3) |
| Tests | Swift Testing (`@Test`), swift-snapshot-testing, XCUITest |
| Build | `xcodebuild` + GitHub Actions macos-15 + iPhone 15 Pro simulator |
| Distribución | TestFlight desde slice 1 → App Store después de slice 5 |

### Monorepo layout

```
tandas/
├── apps/
│   ├── web/                    ← Next.js 16 (existente, mover desde root)
│   └── ios/                    ← NUEVO
│       ├── Tandas.xcodeproj
│       ├── Tandas/
│       │   ├── App/            ← TandasApp.swift, RootScreen, AuthGate, env keys
│       │   ├── Features/
│       │   │   ├── Auth/       ← AuthScreen, AuthViewModel
│       │   │   ├── Groups/     ← GroupsListScreen, GroupCard
│       │   │   ├── Timeline/   ← GroupTimelineScreen, TimelineRow
│       │   │   ├── Events/     ← EventDetailSheet, RSVPSegment
│       │   │   ├── Fines/      ← (slice 2) FinesScreen, FineDetailSheet, SPEILinkBuilder
│       │   │   └── Profile/
│       │   ├── DesignSystem/
│       │   │   ├── Tokens.swift
│       │   │   ├── AdaptiveGlass.swift
│       │   │   ├── MeshBackground.swift
│       │   │   └── Components/ ← GlassCard, GlassCapsuleButton, StatusDot, ProgressRing, RSVPSegment
│       │   ├── Data/
│       │   │   ├── SupabaseClient.swift
│       │   │   ├── Models/     ← Group, Event, Fine, Profile, etc. (Codable structs)
│       │   │   └── Repos/      ← actor-based repos por feature
│       │   └── Resources/      ← Assets.xcassets, Localizable.xcstrings
│       ├── TandasWidgets/      ← (v2)
│       ├── TandasLiveActivity/ ← (slice 3) ActivityKit extension
│       └── TandasTests/        ← unit + snapshot
├── supabase/                   ← compartido (migrations, tests SQL, Edge Functions)
├── docs/                       ← compartido (specs, plans)
└── package.json / etc.         ← web tooling
```

### Boundaries (forzadas por convención + code review)

- `Features/A` no importa de `Features/B`. Compartido → sube a `Data/` o `DesignSystem/`.
- `DesignSystem/` y `Data/` no importan de `Features/` ni `App/`.
- `App/` solo composición (root, env wiring, navigation host).
- ViewModels (`@Observable`) son `internal` a su feature; solo Views son `public` cuando aplica.
- Repos en `Data/Repos/` son `actor` con protocol equivalente para mocking.

### Data flow

```
SwiftUI View
    │ lee state
    ▼
@Observable ViewModel  (state: ViewState<T>, métodos async)
    │ llama
    ▼
Repository (actor, protocol)
    │ usa
    ▼
SupabaseClient (singleton @Environment)
    │ HTTP REST + JWT del session
    ▼
Supabase Postgres + RLS + RPCs security definer
```

**Mutaciones** (RSVP, marcar multa pagada): ViewModel → repo → RPC `security definer` (los mismos que ya consume la web). Cero lógica de negocio en el cliente — el mismo `evaluate_event_rules`, `submit_rsvp`, `mark_fine_paid` que ya está en `supabase/migrations/`.

**Cache:** ninguna en MVP. SwiftUI cachea Views, no datos. Si en slice 3 hay lag visible, agregar cache en memoria del repo (TTL corto). SwiftData solo si offline-first se vuelve requisito real.

**Realtime:** fuera de slice 1. Slice 3 lo trae para `events` activos durante check-in (RSVPs en vivo en Live Activity).

### Auth flow detallado

```
TandasApp
  └─ AuthGate observa AuthRepository.session
       ├─ session == nil  → AuthScreen
       │                      ├─ "Continuar con Apple" → ASAuthorizationController
       │                      │                            → identityToken JWT
       │                      │                            → client.auth.signInWithIdToken(.apple, token)
       │                      │                            → session
       │                      └─ "Otro método" → PhoneOTPScreen → OTP → session
       └─ session != nil  → RootScreen (TabView 4 tabs)
```

`AuthRepository` escucha `client.auth.authStateChanges` y publica `Session?`. Sesión persiste en Keychain via Supabase SDK.

**Cuentas pre-existentes phone:** un usuario que ya se registró por phone en web NO se vincula automáticamente al hacer SiwA — Supabase los trata como cuentas separadas. Mitigación: en `AuthScreen`, si SiwA devuelve un email que matchea `profiles.email` de una cuenta phone existente, mostramos un sheet "¿Vincular esta cuenta?" → flujo de verificación phone OTP → merge.

### Errors

| Tipo | Tratamiento |
|---|---|
| Red (offline) | Empty state con retry button + ícono SF Symbol `.wifi.slash`. |
| 401 (token expired) | Cierra sesión, manda a AuthScreen con toast "Tu sesión expiró". |
| 403 (RLS) | Empty state "No tienes acceso a esto" (raro, indica bug). |
| 5xx | Toast con retry. |
| Decoding error | Log a console + fallback empty state. Indica drift de schema; flag para dev. |

---

## 4. Visual System (Liquid Glass)

### Mesh gradient base

```swift
struct MeshBackground: View {
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        MeshGradient(
            width: 3, height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5 + 0.05 * sin(phase)), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: Brand.meshColors
        )
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 18).repeatForever(autoreverses: true)) {
                phase = .pi
            }
        }
    }
}
```

### `.adaptiveGlass(...)` modifier (única autorizada)

```swift
extension View {
    @ViewBuilder
    func adaptiveGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26, *) {
            let style: GlassEffect = {
                let base: GlassEffect = tint.map { .tinted($0) } ?? .regular
                return interactive ? base.interactive() : base
            }()
            self.glassEffect(style, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        }
    }
}
```

**Regla:** ningún feature aplica `.glassEffect(...)` directo. Siempre `.adaptiveGlass(...)`. Forzado por code review.

### Tokens

`DesignSystem/Tokens.swift` — colores brand, status colors para timeline (`statusEvent` verde, `statusWarning` amarillo, `statusTurn` morado, `statusVote` cyan), radii (`card: 22`, `pill: 999`, `chip: 14`), spacing (4/8/12/16/24).

### Tipografía

- **SF Pro Rounded** — montos, headers principales (`tandaHero 28pt bold rounded`, `tandaAmount 24pt bold rounded monospacedDigit`).
- **SF Pro** — todo lo demás (`tandaTitle 18pt semibold`, `tandaBody 15pt regular`, `tandaCaption 11pt medium monospacedDigit`).
- **`.monospacedDigit()`** obligatorio para dinero, cuentas regresivas, fechas en filas tabulares.

### Componentes reusables

| Componente | Uso |
|---|---|
| `MeshBackground` | Fondo full-screen animado (reduce-motion aware). |
| `GlassCard<Content>` | Card glass con padding+radius estándar (radius 22, padding 16-20). |
| `GlassCapsuleButton` | Botón pill `.tinted(.accent).interactive()` para CTAs. |
| `StatusDot` | Punto 6pt con glow opcional (timeline rows). |
| `TimelineRow` | Row de timeline (StatusDot + título + caption + chevron + day-tag). |
| `ProgressRing` | `Gauge` anular con gradient morado→rosa para ronda actual. |
| `RSVPSegment` | Segmented capsule "Voy / Tal vez / No voy" con haptic `.selection`. |

### SF Symbols 7

- Animaciones: `.symbolEffect(.bounce, value: …)`, `.symbolEffect(.variableColor.iterative, isActive: isLoading)`.
- Variable color para estados de carga (anillo progresivo en `arrow.clockwise.circle`).
- Palette mode (`.symbolRenderingMode(.palette)`) para íconos brand-tinted.

### Accesibilidad obligatoria

- `@Environment(\.accessibilityReduceTransparency)` → `adaptiveGlass` cae a `Color(.secondarySystemBackground)` opaco.
- `@Environment(\.accessibilityReduceMotion)` → `MeshBackground` no anima; transitions glass usan `.identity` en vez de `.matchedGeometry`.
- `@Environment(\.colorSchemeContrast)` → `contrast == .increased` sube border alpha 0.12 → 0.45 y oscurece tints.
- VoiceOver labels en cada `GlassCard` interactivo (`.accessibilityLabel(...)`, `.accessibilityHint(...)`).
- Dynamic Type — todas las fonts usan `.system(...)` (no fixed-size); cards crecen en alto con `Layout` semánticos (HStack/VStack), no frames hardcoded.

### Haptics

| Trigger | Tipo |
|---|---|
| Cambio de RSVP, scroll-snap entre grupos | `.selection` |
| Tap en card de grupo | `.impact(.medium)` |
| Confirmación backend (RSVP guardado, multa pagada) | `.success` |
| Error de mutación | `.error` |

`.success` y `.error` SOLO después de la respuesta del servidor — no optimistas. Apple HIG es estricta y se nota la diferencia en feel.

### Dark mode

**Dark only en MVP.** El mesh gradient asume oscuro, los tokens están calibrados para fondo oscuro, glass refracta sobre oscuro. Light mode requiere un mesh alterno y recalibración de tokens — v2.

---

## 5. Slice 1 — Vertical Scope (Detail)

### Pantallas (5)

#### 1. Launch + Auth

- Splash con `MeshBackground` + logo grande SF Pro Rounded "Tandas".
- Botón principal `SignInWithAppleButton` (system component, glass automático en iOS 26).
- Botón secundario "Otro método" → push `PhoneOTPScreen`.
- `PhoneOTPScreen`: input phone + país (default +52 MX), `client.auth.signInWithOTP(phone:)`, OTP de 6 dígitos con `input-otp` equivalente nativo (`SecureField` + auto-fill `.oneTimeCode`).

#### 2. Lista de grupos (root)

- `MeshBackground` de fondo.
- Header: "Mis grupos" label + "Hola, [nombre]" SF Pro Rounded 28pt.
- ScrollView con cards estilo Wallet — cada card glass tinted con un color **derivado deterministicamente de `groups.id`** (hash → HSL paleta curada de 12 colores brand-friendly), mostrando nombre, ronda actual o "Próximo evento", y monto/CTA si aplica. La paleta vive en `DesignSystem/Tokens.swift` como `Brand.groupPalette: [Color]`. Override por grupo (campo `color_hex` en `groups`) queda para v2.
- Pull-to-refresh con `.refreshable { await vm.refresh() }`.
- Empty state: card glass "No tienes grupos. Únete con código" + input.
- Tap en card → `NavigationLink` push `GroupTimelineScreen` con animación matched-geometry (`.glassEffectID` + `@Namespace`) en iOS 26.

#### 3. Timeline del grupo

- Top bar custom: chevron back + nombre del grupo centrado + menú "···" (acciones: salir del grupo, etc — slice 4+).
- Hero compacto card glass: "Tu turno" label + monto + barra de progreso lineal de la ronda.
- Sección "Próximos" label.
- Lista vertical de `TimelineRow`s. Cada row tiene un `StatusDot` (verde/amarillo/morado/cyan según tipo), título, caption, day-tag a la derecha.
- TabBar inferior glass (4 tabs: **Resumen** activo, **Eventos** slice 1, **Multas** slice 2, **Más**).
- Tap en row de evento → presenta `EventDetailSheet`.

#### 4. Detalle de evento (sheet)

- `.sheet(item: $selectedEvent)` con `.presentationDetents([.medium, .large])` + `.presentationBackground(.adaptiveGlass(...))`.
- Header sheet: nombre del evento, fecha completa formato es-MX (`vie 6 may, 8:00 PM`).
- Sección "Anfitrión": avatar + nombre.
- Sección "Asistentes": grid de avatares con badges (`.checkmark` verde / `.xmark` rojo / `.questionmark` gris).
- `RSVPSegment` "Voy / Tal vez / No voy" — selección actual highlighted glass tinted.
- Botón secundario "Compartir invitación" (`ShareLink` con texto + `wa.me` deep link, igual que web).

#### 5. Profile mínimo

- Avatar (placeholder gradient con iniciales, foto en v2).
- Nombre + email + phone (read-only, edit en web).
- Toggle "Notificaciones" (sin efecto en slice 1, hookeado en slice 3).
- Botón "Cerrar sesión" → confirmation alert → `client.auth.signOut()`.

### Repos (slice 1)

```swift
protocol AuthRepository: Actor {
    var session: Session? { get async }
    func signInWithApple(idToken: String) async throws -> Session
    func signInWithPhone(phone: String) async throws  // envía OTP
    func verifyPhone(phone: String, code: String) async throws -> Session
    func signOut() async throws
}

protocol GroupsRepository: Actor {
    func listMyGroups() async throws -> [Group]
    func joinByCode(_ code: String) async throws -> Group
}

protocol TimelineRepository: Actor {
    func loadTimeline(groupId: UUID) async throws -> Timeline
    // Timeline = struct { hero: HeroData, items: [TimelineItem] }
}

protocol EventsRepository: Actor {
    func loadEvent(_ id: UUID) async throws -> EventDetail
    func submitRSVP(eventId: UUID, status: RSVPStatus) async throws
}
```

### Models (slice 1)

```swift
struct Group: Identifiable, Codable, Sendable {
    let id: UUID
    let name: String
    // color: NO viene del backend — derivado de `id` con `Brand.groupPalette[hash(id) % palette.count]`
    let myRole: MemberRole         // owner | admin | member
    let nextEventAt: Date?
    let myUpcomingTurn: TurnSummary?
}

struct TimelineItem: Identifiable, Codable, Sendable {
    let id: UUID
    let kind: Kind                 // event | fine | vote | turn
    let title: String
    let caption: String
    let happensAt: Date
    let routeTo: Route             // .event(UUID), .fine(UUID), etc.
}

struct EventDetail: Codable, Sendable {
    let id: UUID
    let title: String
    let startsAt: Date
    let host: ProfileSummary
    let rsvps: [RSVP]
    let myStatus: RSVPStatus?
}
```

### Acceptance criteria slice 1

- [ ] Build verde en CI.
- [ ] App abre splash, login con SiwA exitoso → llega a lista de grupos con datos reales de Supabase.
- [ ] Tap en grupo carga timeline real desde Supabase.
- [ ] Tap en evento abre sheet glass con datos reales.
- [ ] Cambiar RSVP llama RPC, devuelve éxito, refleja en UI con haptic `.success`.
- [ ] `Reduce Transparency` activado → cards opacas, app sigue legible.
- [ ] Snapshot tests verdes para los 4 estados de cada pantalla (loading, loaded, empty, error).
- [ ] 1 XCUITest happy path verde.
- [ ] TestFlight build #1 instalado en device del usuario.
- [ ] FPS ≥ 55 en iPhone 12 (probado manual con Instruments).

---

## 6. Slices Roadmap

| Slice | Sem | Entrega |
|---|---|---|
| **0** Setup | 0.5 | Xcode project, SPM (`supabase-swift`, `swift-snapshot-testing`), monorepo move (`tandas/` → `tandas/apps/{web,ios}/`), CI workflow `ios-ci.yml`, App ID `com.quimibond.tandas` (a confirmar), provisioning, signing. |
| **1** Vertical slice | 1.5 | Auth (SiwA + phone fallback), lista grupos cards Wallet, timeline grupo, detalle evento sheet glass, RSVP. TestFlight #1. |
| **2** Multas + pago | 1 | Tab Multas, lista, detalle, **SPEI deep link** builder (genera URL `spei://...` o copia CLABE al clipboard + abre app banco), marcar pagado, confirmación cruzada. TestFlight #2. |
| **3** Live Activity + push | 1 | Certificados APNs en Apple Developer + Supabase Edge Function envía push, ActivityKit extension, Live Activity día evento (countdown + RSVPs en vivo + monto), Realtime suscripción `events` activos. TestFlight #3. |
| **4** Votos + reglas | 1 | Tab Votos (lectura + emitir voto), tab Reglas (lectura). Crear regla sigue en web. TestFlight #4. |
| **5** Balance | 1 | Sección "Balance" en perfil del grupo: read-only del balance neto. Pots/splitwise solo lectura. TestFlight #5. |
| **Ship** | 0.5 | App Store submission (screenshots, descripción, privacy labels, ASO es-MX). |

**Total:** 6.5 semanas nominal, **8 semanas con buffer** realista.

---

## 7. Testing

| Nivel | Herramienta | Cubre |
|---|---|---|
| Unit | Swift Testing (`@Test`) | Mappers Codable, formatters MXN/es-MX, lógica presentational en VMs (estados loading/error). |
| Integration | Swift Testing + Supabase local | Repos contra Supabase local con seed mínimo. Verifica RLS, shape JSON ↔ Decodable, RPCs mutaciones. |
| Snapshot UI | swift-snapshot-testing | Pantallas críticas en 4 estados (loaded/loading/empty/error), iPhone 15 Pro + iPad. |
| E2E | XCUITest | 1 happy path por slice. Slice 1: launch → SiwA mock → grupos → timeline → RSVP. |

**No se testea automated:**
- Shader de glass — solo visualmente en device.
- Live Activity en CI — manual en device.
- RLS Supabase — ya tiene tests SQL en `supabase/tests/`, no duplicar.

**Mocks:** Repos protocolados, `MockGroupsRepository` etc. Para `#Preview` y snapshot tests. Cada View tiene preview en 3 estados.

**CI:** `.github/workflows/ios-ci.yml` corre `xcodebuild test` en macos-15 + iPhone 15 Pro simulator. Snapshots fail PR si difieren (re-record con flag manual). TestFlight automático en merge a `main` desde slice 2.

**DoD por PR del slice iOS:**
- `xcodebuild build` ✓
- `xcodebuild test -scheme Tandas` ✓
- Snapshots verdes ✓
- Si toca SQL → tests SQL existentes verdes ✓
- Si toca UI → screenshot/video en el PR.

---

## 8. Signing & Distribution

- **Bundle ID:** `com.quimibond.tandas` (asumiendo Apple Developer team de Quimibond — **a confirmar con el usuario antes de slice 0**).
- **Capabilities:**
  - Sign in with Apple
  - Push Notifications (slice 3)
  - App Groups `group.com.quimibond.tandas` (compartir state app ↔ Live Activity, slice 3)
  - Associated Domains `applinks:tandas.app` (Universal Link de magic link Supabase)
- **TestFlight:** desde slice 1 build #1.
- **App Store:** después de slice 5. **No someter antes** — riesgo de rejection por "minimum functionality" si la app es solo read-only.
- **Privacy nutrition labels:** tracking = no, data collection = email + name (Apple) + phone (opcional Supabase). Cero analytics third-party en MVP.
- **App Review notes:** explicar SPEI deep link (no es Apple Pay, es transfer P2P bancario), explicar grupos privados que requieren login (test account incluida).

---

## 9. Risks & Mitigations

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Apple Review rechaza por "minimum functionality" si la app es muy read-only. | Slice 2 (pago SPEI + marcar pagado) sube valor antes del Ship. No someter App Store antes del slice 2. |
| R2 | SiwA + cuenta phone preexistente no se vinculan. | En `AuthScreen`, si SiwA email matchea `profiles.email` de cuenta phone, sheet "¿Vincular cuenta?" → verify phone OTP → merge. Implementado en slice 1. |
| R3 | APNs en prod requiere certificado emitido manual. | Usuario emite cert en Apple Developer Portal antes de slice 3 (~30 min). Documentado. |
| R4 | Live Activity tiene rate limits (5min mín entre updates). | UX no depende de updates instantáneos — countdown + cambios de RSVP solo en hitos (mitad, 5min, start). |
| R5 | MeshGradient + glass juntos pesados en iPhone XS/11. | Slice 1 incluye perf check Instruments en iPhone 12. Si <55fps, `MeshGradient` cae a `LinearGradient` en chip < A14. |
| R6 | Supabase RLS rompe edge case en cliente Swift no probado. | Integration tests slice 1 cubren mismas queries que la web ya tiene; reuso de RPCs reduce superficie nueva. |
| R7 | iCloud sync de Keychain entre devices del mismo Apple ID puede leakear sesión vieja. | Supabase SDK por default no marca Keychain como `kSecAttrSynchronizable` — verificar en slice 1. |

---

## 10. Out of scope (explicit non-goals)

- Crear/configurar grupos (sigue en web).
- Crear/proponer reglas (sigue en web).
- Gestionar miembros / invitaciones complejas (sigue en web).
- Apple Pay como método de pago.
- Fotos / recibos / comprobantes.
- watchOS companion app.
- iPad layout específico (funciona pero no diseñado).
- Widget de Home Screen (v2).
- Light mode (v2).
- Idiomas distintos a es-MX (v3+).
- Offline-first / SwiftData / sync layer (v2 si aparece dolor real).
- TCA / arquitectura más compleja que `@Observable`.
- Notificaciones push para votos o cambios de regla en MVP (solo evento próximo en slice 3).

---

## 11. Open questions (a resolver antes de slice 0)

1. **Apple Developer team:** ¿el bundle id va bajo Quimibond o cuenta personal? Confirmar antes de App ID provisioning.
2. **Universal Link domain:** ¿`tandas.app`, `tandas.quimibond.com`, otro? Necesario para magic link Supabase y compartir invitaciones.
3. **APNs cert:** producción + sandbox separados — ¿quién genera? (usuario en Developer Portal).
4. **Logo / app icon:** ¿existe? Si no, slice 0 incluye placeholder y v2 trae final.
