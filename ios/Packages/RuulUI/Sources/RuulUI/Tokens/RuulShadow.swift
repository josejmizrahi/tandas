import SwiftUI

// Shadow helpers live on `RuulElevation` now — see `RuulElevation.swift`.
// The previous `ruulShadowSubtle/Medium/Elevated` helpers were
// hardcoded `.black.opacity(...)` (didn't adapt to dark mode) and had
// zero callers. Deleted 2026-05-15. Use `.ruulElevation(.sm/.md/.lg)`
// — those drive their color through `RuulColors.default.shadowSm/Md/
// Lg`, which is theme-adaptive (slate-tinted in light, deeper black
// in dark, plus high-contrast bumps).
