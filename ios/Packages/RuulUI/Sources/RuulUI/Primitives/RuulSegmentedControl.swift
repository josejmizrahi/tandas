import SwiftUI

/// Glass pill container with segmented selection. Animates the highlight
/// capsule between segments with a spring.
///
/// Display modes (set via the icon-capable init):
///   - `.label`         — text only (default; backward-compat shape).
///   - `.icon`          — SF Symbol only; the `label` becomes the
///                        accessibilityLabel so VoiceOver still reads it.
///                        Use when segment count or label length would
///                        cause cramping on iPhone width.
///   - `.iconAndLabel`  — icon over label, stacked vertically. Most
///                        discoverable; needs a bit more vertical room.
public struct RuulSegmentedControl<Value: Hashable & Sendable>: View {
    public enum DisplayMode: Sendable {
        case label
        case icon
        case iconAndLabel
    }

    private struct Segment {
        let value: Value
        let label: String
        let icon: String?
    }

    private let segments: [Segment]
    private let displayMode: DisplayMode
    @Binding private var selection: Value

    /// Backward-compat init — text-label segments. Existing call sites
    /// (PrimitivesShowcaseView, the legacy preview) stay on this shape.
    public init(selection: Binding<Value>, segments: [(Value, String)]) {
        self._selection = selection
        self.segments = segments.map { Segment(value: $0.0, label: $0.1, icon: nil) }
        self.displayMode = .label
    }

    /// Icon-capable init. Pass `(value, label, icon)` tuples — `label`
    /// becomes the accessibilityLabel when `displayMode == .icon`.
    public init(
        selection: Binding<Value>,
        segments: [(value: Value, label: String, icon: String)],
        displayMode: DisplayMode = .iconAndLabel
    ) {
        self._selection = selection
        self.segments = segments.map { Segment(value: $0.value, label: $0.label, icon: $0.icon) }
        self.displayMode = displayMode
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(.ruulSnappy) { selection = segment.value }
                } label: {
                    segmentContent(for: segment, isSelected: isSelected)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, segmentVerticalPadding)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.ruulAccent)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(segment.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(RuulSpacing.xxs)
        .ruulGlass(Capsule(), material: .regular)
        .ruulHaptic(.selection, trigger: selection)
    }

    /// Per-mode content. Icon mode hides the text but the parent
    /// `.accessibilityLabel(segment.label)` keeps VoiceOver legible.
    @ViewBuilder
    private func segmentContent(for segment: Segment, isSelected: Bool) -> some View {
        let color = isSelected ? Color.ruulTextInverse : Color.ruulTextPrimary
        switch displayMode {
        case .label:
            Text(segment.label)
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(color)
        case .icon:
            if let icon = segment.icon {
                Image(systemName: icon)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(color)
            } else {
                // Defensive fallback: icon was somehow missing — render
                // the label instead of an empty segment.
                Text(segment.label)
                    .ruulTextStyle(RuulTypography.callout)
                    .foregroundStyle(color)
            }
        case .iconAndLabel:
            VStack(spacing: 2) {
                if let icon = segment.icon {
                    Image(systemName: icon)
                        .ruulTextStyle(RuulTypography.subheadSemibold)
                        .foregroundStyle(color)
                }
                Text(segment.label)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    /// Icon-only mode keeps the existing pill height; iconAndLabel needs
    /// a hair more vertical room so the label isn't pressed against the
    /// icon. Label-only matches the original padding.
    private var segmentVerticalPadding: CGFloat {
        switch displayMode {
        case .label:        return RuulSpacing.xs
        case .icon:         return RuulSpacing.xs
        case .iconAndLabel: return RuulSpacing.xxs
        }
    }

    @Namespace private var namespace
}

#if DEBUG
private struct RuulSegmentedControlPreview: View {
    enum Tab: String, CaseIterable, Hashable { case events = "Eventos", rules = "Reglas", fines = "Multas" }
    @State var sel: Tab = .events
    @State var iconSel: Tab = .events

    var body: some View {
        VStack(spacing: RuulSpacing.lg) {
            // Label-only (legacy)
            RuulSegmentedControl(
                selection: $sel,
                segments: Tab.allCases.map { ($0, $0.rawValue) }
            )
            // Icon-only
            RuulSegmentedControl(
                selection: $iconSel,
                segments: [
                    (.events, "Eventos", "calendar"),
                    (.rules,  "Reglas",  "list.bullet.clipboard"),
                    (.fines,  "Multas",  "exclamationmark.triangle"),
                ],
                displayMode: .icon
            )
            // Icon + label
            RuulSegmentedControl(
                selection: $iconSel,
                segments: [
                    (.events, "Eventos", "calendar"),
                    (.rules,  "Reglas",  "list.bullet.clipboard"),
                    (.fines,  "Multas",  "exclamationmark.triangle"),
                ],
                displayMode: .iconAndLabel
            )
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulSegmentedControl") {
    RuulSegmentedControlPreview()
}
#endif
