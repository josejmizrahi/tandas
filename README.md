# Tandas

App nativa iOS para administrar la "vida en grupo" de amigos: tandas de ahorro, cenas semanales, pots de poker, gastos compartidos. Reglas custom (escritas y votadas por el grupo) que la app ejecuta automáticamente.

> SwiftUI + Supabase. iOS 26+ (Liquid Glass).

## Estructura del repo

```
ios/                   # Xcode project (SwiftUI app)
supabase/migrations/   # 9 migrations versionadas, fuente única
docs/superpowers/      # specs y plans de las phases del MVP
web-deprecated/        # Next.js 16 app (deprecada 2026-04-30, preservada por referencia)
```

## Backend (no cambia)

Supabase project `fpfvlrwcskhgsjuhrjpz`. 14 tablas + RLS + ~22 RPCs cubriendo:
- Auth (Phone OTP + Email OTP)
- Groups + members (con tipología)
- Events + RSVP + check-in + auto-recurrence
- Rules + propose + votes (con quorum/threshold per grupo)
- Fines (auto via rule engine + manual + apelación + amnistía)
- Anti-tirania (grace period + monthly cap + rule snapshots)

Ver `supabase/migrations/` para esquema completo.

## Setup local (iOS)

1. **Xcode 16+** (App Store)
2. **iOS 26+ device o simulator** para probar Liquid Glass real
3. **Apple Developer Account** ($99/año) para distribuir
4. Abrir `ios/Tandas.xcodeproj`
5. Build + Run

## Deploy

- **TestFlight** vía Xcode → Archive → Distribute
- **App Store Connect** para submission
- **Fastlane** (TBD) para automatizar builds + screenshots

## Decisión arquitectónica: por qué SwiftUI nativo

Después de 4 phases shipped en Next.js (auth, eventos, reglas+votos, multas, anti-tirania, tipología) decidimos pivotar a iOS nativo porque:

1. **Liquid Glass real** requiere acceso a Metal (no posible en navegador)
2. Push notifications nativas via APNs son menores fricción que web-push
3. App Store distribution > "abre en navegador"
4. Performance superior en mobile
5. SwiftUI + Supabase Swift SDK = stack consistente

El backend (Supabase) se mantiene idéntico — la iOS app es solo un cliente nuevo. La web app está preservada en `web-deprecated/` por si se decide retomar como landing.

## Phases del MVP (referencia del roadmap web — re-implementar en SwiftUI)

| Phase | Web | iOS |
|---|---|---|
| 1 — Auth + grupos | ✅ shipped | ⏳ pending |
| 2 — Eventos + RSVP | ✅ shipped | ⏳ pending |
| 3 — Reglas + votos | ✅ shipped | ⏳ pending |
| 4 — Multas | ✅ shipped | ⏳ pending |
| 4.5 — Anti-tiranía | ✅ shipped | ⏳ pending |
| 4.6 — Tipología + welcome | ✅ shipped | ⏳ pending |
| 5 — Pots | deferred | deferred |
| 6 — Expenses + Splitwise | deferred | deferred |
| 7 — Push notifs (APNs) | — | ⏳ pending |
| 8 — App Store submission | — | ⏳ pending |

## Co-Authored-By

`claude-flow <ruv@ruv.net>` — generación de código vía Claude Code.
