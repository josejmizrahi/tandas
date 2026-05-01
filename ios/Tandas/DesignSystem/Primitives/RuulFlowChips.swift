import SwiftUI

/// Flow-wrapping chip group with single-select + optional "other" escape hatch.
///
/// Generic over a `Hashable & Sendable` value type. Use a custom enum or
/// String for the values.
public struct RuulFlowChips<Value: Hashable & Sendable>: View {
    public struct Option: Identifiable, Sendable {
        public let value: Value
        public let label: String

        public var id: Value { value }

        public init(value: Value, label: String) {
            self.value = value
            self.label = label
        }
    }

    @Binding private var selection: Value?
    @Binding private var customValue: String
    private let options: [Option]
    private let allowOther: Bool
    private let otherSentinel: Value?

    public init(
        selection: Binding<Value?>,
        options: [Option],
        allowOther: Bool = false,
        otherSentinel: Value? = nil,
        customValue: Binding<String> = .constant("")
    ) {
        self._selection = selection
        self._customValue = customValue
        self.options = options
        self.allowOther = allowOther
        self.otherSentinel = otherSentinel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s3) {
            FlowLayout(spacing: RuulSpacing.s2) {
                ForEach(options) { option in
                    chip(label: option.label, isSelected: selection == option.value) {
                        selection = option.value
                    }
                }
                if allowOther, let other = otherSentinel {
                    chip(label: "Otro", isSelected: selection == other) {
                        selection = other
                    }
                }
            }
            if allowOther, let other = otherSentinel, selection == other {
                RuulTextField("Escribe el nombre", text: $customValue, label: "Otro")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.ruulSnappy, value: selection)
    }

    private func chip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        RuulChip(label, style: .selectable(isSelected: isSelected), action: action)
    }
}

/// Native flow layout (iOS 16+ Layout protocol). Wraps children to next line
/// when they exceed available width.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        var rows: [[(view: LayoutSubview, size: CGSize)]] = [[]]
        var currentX: CGFloat = 0
        var currentRow = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if currentX + size.width > width, !rows[currentRow].isEmpty {
                rows.append([])
                currentRow += 1
                currentX = 0
            }
            rows[currentRow].append((view, size))
            currentX += size.width + spacing
        }

        let height = rows.reduce(0) { acc, row in
            let rowHeight = row.map(\.size.height).max() ?? 0
            return acc + rowHeight + (acc > 0 ? spacing : 0)
        }
        return CGSize(width: width.isFinite ? width : 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let width = bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            _ = width  // silence unused
        }
    }
}

#if DEBUG
private struct RuulFlowChipsPreview: View {
    enum Vocab: Hashable, Sendable { case cena, junta, ronda, sesion, reunion, encuentro, other }
    @State var selection: Vocab? = .cena
    @State var custom: String = ""

    var body: some View {
        VStack(spacing: RuulSpacing.s5) {
            RuulFlowChips(
                selection: $selection,
                options: [
                    .init(value: .cena, label: "Cena"),
                    .init(value: .junta, label: "Junta"),
                    .init(value: .ronda, label: "Ronda"),
                    .init(value: .sesion, label: "Sesión"),
                    .init(value: .reunion, label: "Reunión"),
                    .init(value: .encuentro, label: "Encuentro")
                ],
                allowOther: true,
                otherSentinel: .other,
                customValue: $custom
            )
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulFlowChips") {
    RuulFlowChipsPreview()
}
#endif
