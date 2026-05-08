import RuulUI
#if DEBUG
import SwiftUI

struct TokensShowcaseView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.md) {
                colors
                typography
                spacing
                radius
                elevation
                motion
                haptics
            }
            .padding(RuulSpacing.lg)
        }
        .background(Color.ruulBackground)
    }

    private var colors: some View {
        ShowcaseSection("Colors", subtitle: "Tap any swatch to copy its name to clipboard") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                colorGroup("Backgrounds", entries: [
                    ("ruulBackground", .ruulBackground),
                    ("ruulSurface", .ruulSurface),
                    ("ruulBackgroundRecessed", .ruulBackgroundRecessed)
                ])
                colorGroup("Text", entries: [
                    ("ruulTextPrimary", .ruulTextPrimary),
                    ("ruulTextSecondary", .ruulTextSecondary),
                    ("ruulTextTertiary", .ruulTextTertiary),
                    ("ruulTextAccent", .ruulTextAccent)
                ])
                colorGroup("Accent", entries: [
                    ("ruulAccent", .ruulAccent),
                    ("ruulAccentSecondary", .ruulAccentSecondary),
                    ("ruulAccentMuted", .ruulAccentMuted)
                ])
                colorGroup("Semantic", entries: [
                    ("ruulPositive", .ruulPositive),
                    ("ruulWarning", .ruulWarning),
                    ("ruulNegative", .ruulNegative),
                    ("ruulInfo", .ruulInfo)
                ])
                colorGroup("Borders", entries: [
                    ("ruulSeparator", .ruulSeparator),
                    ("ruulSeparatorOpaque", .ruulSeparatorOpaque),
                    ("ruulBorderStrong", .ruulBorderStrong),
                    ("ruulBorderGlass", .ruulBorderGlass)
                ])
            }
        }
    }

    private func colorGroup(_ title: String, entries: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: 4) {
                ForEach(entries, id: \.0) { entry in
                    Button { UIPasteboard.general.string = entry.0 } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(entry.1)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.ruulSeparator, lineWidth: 0.5))
                                .frame(width: 32, height: 32)
                            Text(entry.0)
                                .ruulTextStyle(RuulTypography.callout)
                                .foregroundStyle(Color.ruulTextPrimary)
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.ruulTextTertiary)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var typography: some View {
        ShowcaseSection("Typography") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                typographyRow("displayHero", style: RuulTypography.displayHero)
                typographyRow("displayLarge", style: RuulTypography.displayLarge)
                typographyRow("displayMedium", style: RuulTypography.displayMedium)
                typographyRow("titleLarge", style: RuulTypography.titleLarge)
                typographyRow("title", style: RuulTypography.title)
                typographyRow("headline", style: RuulTypography.headline)
                typographyRow("bodyLarge", style: RuulTypography.bodyLarge)
                typographyRow("body", style: RuulTypography.body)
                typographyRow("callout", style: RuulTypography.callout)
                typographyRow("caption", style: RuulTypography.caption)
                typographyRow("footnote", style: RuulTypography.footnote)
                typographyRow("mono", style: RuulTypography.mono, sample: "0123456789")
                typographyRow("monoLarge", style: RuulTypography.monoLarge, sample: "0123456789")
            }
        }
    }

    private func typographyRow(_ label: String, style: RuulTextStyle, sample: String = "The quick brown fox") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).ruulTextStyle(RuulTypography.footnote).foregroundStyle(Color.ruulTextTertiary)
            Text(sample).ruulTextStyle(style).foregroundStyle(Color.ruulTextPrimary)
        }
    }

    private var spacing: some View {
        ShowcaseSection("Spacing", subtitle: "4pt grid") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([("xxs", RuulSpacing.xxs), ("xs", RuulSpacing.xs), ("sm", RuulSpacing.sm), ("md", RuulSpacing.md), ("lg", RuulSpacing.lg), ("xl", RuulSpacing.xl), ("xxl", RuulSpacing.xxl), ("s8", RuulSpacing.s8), ("xxxl", RuulSpacing.xxxl), ("s10", RuulSpacing.s10)], id: \.0) { item in
                    HStack {
                        Text(item.0).ruulTextStyle(RuulTypography.caption).frame(width: 36, alignment: .leading)
                        Rectangle()
                            .fill(Color.ruulAccent.opacity(0.7))
                            .frame(width: item.1, height: 8)
                        Text("\(Int(item.1))pt").ruulTextStyle(RuulTypography.caption).foregroundStyle(Color.ruulTextTertiary)
                    }
                }
            }
        }
    }

    private var radius: some View {
        ShowcaseSection("Radius") {
            HStack(spacing: RuulSpacing.sm) {
                ForEach([("small", RuulRadius.small), ("medium", RuulRadius.medium), ("large", RuulRadius.large), ("extraLarge", RuulRadius.extraLarge)], id: \.0) { item in
                    VStack {
                        RoundedRectangle(cornerRadius: item.1)
                            .fill(Color.ruulAccentMuted)
                            .frame(width: 60, height: 60)
                        Text(item.0).ruulTextStyle(RuulTypography.caption).foregroundStyle(Color.ruulTextTertiary)
                    }
                }
            }
        }
    }

    private var elevation: some View {
        ShowcaseSection("Elevation") {
            HStack(spacing: RuulSpacing.md) {
                elevationCard("none", level: .none)
                elevationCard("sm", level: .sm)
                elevationCard("md", level: .md)
                elevationCard("lg", level: .lg)
            }
        }
    }

    private func elevationCard(_ label: String, level: RuulElevation) -> some View {
        VStack {
            RoundedRectangle(cornerRadius: RuulRadius.medium)
                .fill(Color.ruulSurface)
                .frame(width: 60, height: 60)
                .ruulElevation(level)
            Text(label).ruulTextStyle(RuulTypography.caption).foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private var motion: some View {
        ShowcaseSection("Motion") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                MotionDemo(label: "ruulSnappy", animation: .ruulSnappy)
                MotionDemo(label: "ruulSmooth", animation: .ruulSmooth)
                MotionDemo(label: "ruulBouncy", animation: .ruulBouncy)
                MotionDemo(label: "ruulMorph", animation: .ruulMorph)
            }
        }
    }

    private var haptics: some View {
        ShowcaseSection("Haptics") {
            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                ForEach([RuulHaptic.selection, .soft, .light, .medium, .heavy, .success, .warning, .error], id: \.self) { haptic in
                    HapticDemo(haptic: haptic)
                }
            }
        }
    }
}

private struct MotionDemo: View {
    let label: String
    let animation: Animation
    @State private var toggled = false

    var body: some View {
        HStack {
            Text(label).ruulTextStyle(RuulTypography.callout).frame(width: 110, alignment: .leading)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.ruulBackgroundRecessed).frame(width: 200, height: 32)
                Capsule().fill(Color.ruulAccent).frame(width: 32, height: 32)
                    .offset(x: toggled ? 168 : 0)
            }
            Spacer()
            RuulButton("Play", style: .secondary, size: .small) {
                withAnimation(animation) { toggled.toggle() }
            }
        }
    }
}

private struct HapticDemo: View {
    let haptic: RuulHaptic
    @State private var trigger = 0

    var body: some View {
        HStack {
            Text("\(String(describing: haptic))").ruulTextStyle(RuulTypography.callout).frame(width: 110, alignment: .leading)
            Spacer()
            RuulButton("Trigger", style: .secondary, size: .small) { trigger &+= 1 }
        }
        .ruulHaptic(haptic, trigger: trigger)
    }
}

extension RuulHaptic: Hashable {}
#endif
