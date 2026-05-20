import SwiftUI

/// Glass pill container with segmented selection. Animates the highlight
/// capsule between segments with a spring.
public struct RuulSegmentedControl<Value: Hashable & Sendable>: View {
    private let segments: [(value: Value, label: String)]
    @Binding private var selection: Value

    public init(selection: Binding<Value>, segments: [(Value, String)]) {
        self._selection = selection
        self.segments = segments
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(segments, id: \.value) { segment in
                let isSelected = segment.value == selection
                Button {
                    withAnimation(.ruulSnappy) { selection = segment.value }
                } label: {
                    Text(segment.label)
                        .font(.footnote)
                        .foregroundStyle(isSelected ? Color.ruulTextInverse : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, RuulSpacing.xs)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(Color.ruulAccent)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(RuulSpacing.xxs)
        .ruulGlass(Capsule(), material: .regular)
        .ruulHaptic(.selection, trigger: selection)
    }

    @Namespace private var namespace
}

#if DEBUG
private struct RuulSegmentedControlPreview: View {
    enum Tab: String, CaseIterable, Hashable { case events = "Eventos", rules = "Reglas", fines = "Multas" }
    @State var sel: Tab = .events

    var body: some View {
        VStack(spacing: RuulSpacing.lg) {
            RuulSegmentedControl(
                selection: $sel,
                segments: Tab.allCases.map { ($0, $0.rawValue) }
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
