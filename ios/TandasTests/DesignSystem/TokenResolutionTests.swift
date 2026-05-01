import Testing
import SwiftUI
@testable import Tandas

@Suite("Design system token resolution")
struct TokenResolutionTests {
    @Test("RuulColors.default initializes all tokens")
    func defaultPaletteIsComplete() {
        // Just access every property — this catches any nil crash if a token
        // forgot a code path.
        let c = RuulColors.default
        _ = c.backgroundCanvas
        _ = c.backgroundElevated
        _ = c.backgroundRecessed
        _ = c.surfaceGlassThin
        _ = c.surfaceGlassRegular
        _ = c.surfaceGlassThick
        _ = c.textPrimary
        _ = c.textSecondary
        _ = c.textTertiary
        _ = c.textInverse
        _ = c.textAccent
        _ = c.accentPrimary
        _ = c.accentSecondary
        _ = c.accentSubtle
        _ = c.semanticSuccess
        _ = c.semanticWarning
        _ = c.semanticError
        _ = c.semanticInfo
        _ = c.borderSubtle
        _ = c.borderDefault
        _ = c.borderStrong
        _ = c.borderGlass
        _ = c.shadowSm
        _ = c.shadowMd
        _ = c.shadowLg
    }

    @Test("Mesh sets have at least 9 colors (3x3 grid)")
    func meshSetsAreCorrectlySized() {
        let c = RuulColors.default
        #expect(c.meshCool.count >= 9)
        #expect(c.meshViolet.count >= 9)
        #expect(c.meshAqua.count >= 9)
    }

    @Test("Spacing follows 4pt grid")
    func spacingIsOnGrid() {
        let values: [CGFloat] = [
            RuulSpacing.s0, RuulSpacing.s1, RuulSpacing.s2, RuulSpacing.s3,
            RuulSpacing.s4, RuulSpacing.s5, RuulSpacing.s6, RuulSpacing.s7,
            RuulSpacing.s8, RuulSpacing.s9, RuulSpacing.s10, RuulSpacing.s11,
            RuulSpacing.s12
        ]
        for v in values {
            #expect(v.truncatingRemainder(dividingBy: 4) == 0)
        }
    }

    @Test("Spacing min touch target is 44pt per Apple HIG")
    func minTouchTargetIsHIGCompliant() {
        #expect(RuulSpacing.minTouchTarget == 44)
    }

    @Test("Radius scale is monotonically increasing")
    func radiusIsOrdered() {
        #expect(RuulRadius.none < RuulRadius.sm)
        #expect(RuulRadius.sm < RuulRadius.md)
        #expect(RuulRadius.md < RuulRadius.lg)
        #expect(RuulRadius.lg < RuulRadius.xl)
        #expect(RuulRadius.xl < RuulRadius.pill)
        #expect(RuulRadius.pill < RuulRadius.circle)
    }

    @Test("Typography styles all have positive line height")
    func typographyHasValidLineHeights() {
        let styles = [
            RuulTypography.displayHero, RuulTypography.displayLarge, RuulTypography.displayMedium,
            RuulTypography.titleLarge, RuulTypography.title, RuulTypography.headline,
            RuulTypography.bodyLarge, RuulTypography.body, RuulTypography.callout,
            RuulTypography.caption, RuulTypography.footnote,
            RuulTypography.mono, RuulTypography.monoLarge
        ]
        for style in styles {
            #expect(style.lineHeight > 0)
        }
    }

    @Test("RuulSchemeOverride covers all 4 modes")
    func schemeOverrideHasAllCases() {
        #expect(RuulSchemeOverride.allCases.count == 4)
    }

    @Test("Hex initializer parses values correctly")
    func hexParsesCorrectly() {
        // Spot-check a few primary brand colors render to the right sRGB.
        let accent = Color(hex: 0x5B6CFF)
        // Round-trip via UIColor to confirm the conversion path doesn't
        // throw away information.
        let ui = UIColor(accent)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #expect(abs(r - (0x5B / 255.0)) < 0.01)
        #expect(abs(g - (0x6C / 255.0)) < 0.01)
        #expect(abs(b - (0xFF / 255.0)) < 0.01)
    }
}
