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
                    ("ruulTextPrimary", .primary),
                    ("ruulTextSecondary", .secondary),
                    ("ruulTextTertiary", Color(.tertiaryLabel)),
                    ("ruulTextAccent", .ruulTextAccent)
                ])
                colorGroup("Accent", entries: [
                    ("ruulAccent", .ruulAccent),
                    ("ruulAccentSecondary", .ruulAccentSecondary),
                    ("ruulAccentMuted", .ruulAccentMuted)
                ])
                colorGroup("Semantic", entries: [
                    ("ruulPositive", .green),
                    ("ruulWarning", .orange),
                    ("ruulNegative", .red),
                    ("ruulInfo", .blue)
                ])
                colorGroup("Borders", entries: [
                    ("ruulSeparator", Color(.separator)),
                    ("ruulSeparatorOpaque", Color(.separator)),
                    ("ruulBorderStrong", .ruulBorderStrong),
                    ("ruulBorderGlass", .ruulBorderGlass)
                ])
            }
        }
    }

    private func colorGroup(_ title: String, entries: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(title).font(.footnote).foregroundStyle(Color(.tertiaryLabel))
            VStack(spacing: 4) {
                ForEach(entries, id: \.0) { entry in
                    Button { UIPasteboard.general.string = entry.0 } label: {
                        HStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(entry.1)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(.separator), lineWidth: 0.5))
                                .frame(width: 32, height: 32)
                            Text(entry.0)
                                .font(.footnote)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(.tertiaryLabel))
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
                typographyRow("largeTitle", font: .largeTitle.weight(.bold))
                typographyRow("title", font: .title.weight(.semibold))
                typographyRow("title2", font: .title2.weight(.semibold))
                typographyRow("title3", font: .title3)
                typographyRow("headline", font: .headline)
                typographyRow("body", font: .body)
                typographyRow("subheadline", font: .subheadline)
                typographyRow("footnote", font: .footnote)
                typographyRow("caption", font: .caption)
                typographyRow("caption2", font: .caption2)
                typographyRow("mono body", font: .body.monospaced(), sample: "0123456789")
                typographyRow("mono title2", font: .title2.monospaced().weight(.semibold), sample: "0123456789")
            }
        }
    }

    private func typographyRow(_ label: String, font: Font, sample: String = "The quick brown fox") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(Color(.tertiaryLabel))
            Text(sample).font(font).foregroundStyle(Color.primary)
        }
    }

    private var spacing: some View {
        ShowcaseSection("Spacing", subtitle: "4pt grid") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach([("xxs", RuulSpacing.xxs), ("xs", RuulSpacing.xs), ("sm", RuulSpacing.sm), ("md", RuulSpacing.md), ("lg", RuulSpacing.lg), ("xl", RuulSpacing.xl), ("xxl", RuulSpacing.xxl), ("s8", RuulSpacing.s8), ("xxxl", RuulSpacing.xxxl), ("s10", RuulSpacing.s10)], id: \.0) { item in
                    HStack {
                        Text(item.0).font(.caption).frame(width: 36, alignment: .leading)
                        Rectangle()
                            .fill(Color.ruulAccent.opacity(0.7))
                            .frame(width: item.1, height: 8)
                        Text("\(Int(item.1))pt").font(.caption).foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }
        }
    }

    private var radius: some View {
        ShowcaseSection("Radius") {
            HStack(spacing: RuulSpacing.sm) {
                ForEach([("small", RuulRadius.sm), ("medium", RuulRadius.md), ("large", RuulRadius.lg), ("extraLarge", RuulRadius.xl)], id: \.0) { item in
                    VStack {
                        RoundedRectangle(cornerRadius: item.1)
                            .fill(Color.ruulAccentMuted)
                            .frame(width: 60, height: 60)
                        Text(item.0).font(.caption).foregroundStyle(Color(.tertiaryLabel))
                    }
                }
            }
        }
    }

    private var motion: some View {
        ShowcaseSection("Motion") {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                MotionDemo(label: ".smooth", animation: .smooth)
                MotionDemo(label: ".default", animation: .default)
                MotionDemo(label: ".bouncy", animation: .bouncy)
                MotionDemo(label: ".snappy", animation: .snappy)
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
            Text(label).font(.footnote).frame(width: 110, alignment: .leading)
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
            Text("\(String(describing: haptic))").font(.footnote).frame(width: 110, alignment: .leading)
            Spacer()
            RuulButton("Trigger", style: .secondary, size: .small) { trigger &+= 1 }
        }
        .ruulHaptic(haptic, trigger: trigger)
    }
}

extension RuulHaptic: Hashable {}
#endif
