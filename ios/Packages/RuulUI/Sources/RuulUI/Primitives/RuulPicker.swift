import SwiftUI

/// List-style picker rendered as a stack of glass rows with a leading radio
/// indicator. Used when the segmented control isn't enough (long lists).
public struct RuulPicker<Value: Hashable & Sendable>: View {
    public struct Option: Identifiable, Sendable {
        public let value: Value
        public let label: String
        public let subtitle: String?

        public var id: Value { value }

        public init(value: Value, label: String, subtitle: String? = nil) {
            self.value = value
            self.label = label
            self.subtitle = subtitle
        }
    }

    private let options: [Option]
    @Binding private var selection: Value

    public init(selection: Binding<Value>, options: [Option]) {
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        VStack(spacing: RuulSpacing.xs) {
            ForEach(options) { option in
                row(for: option)
            }
        }
    }

    private func row(for option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            withAnimation(.smooth) { selection = option.value }
        } label: {
            HStack(spacing: RuulSpacing.sm) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.ruulAccent : Color(.separator), lineWidth: 2)
                        .frame(width: 22, height: 22)
                    if isSelected {
                        Circle()
                            .fill(Color.ruulAccent)
                            .frame(width: 12, height: 12)
                            .transition(.scale)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline)
                        .foregroundStyle(Color.primary)
                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                    }
                }
                Spacer()
            }
            .padding(RuulSpacing.md)
            .ruulGlass(
                RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous),
                material: .regular,
                tint: isSelected ? Color.ruulAccentMuted : nil
            )
        }
        .buttonStyle(.ruulPress)
        .ruulHaptic(.selection, trigger: isSelected)
    }
}

#if DEBUG
private struct RuulPickerPreview: View {
    enum Cadence: String, Hashable { case weekly, biweekly, monthly }
    @State var cadence: Cadence = .weekly

    var body: some View {
        VStack(spacing: RuulSpacing.lg) {
            RuulPicker(selection: $cadence, options: [
                .init(value: .weekly, label: "Semanal", subtitle: "Cada miércoles"),
                .init(value: .biweekly, label: "Quincenal", subtitle: "Cada 2 semanas"),
                .init(value: .monthly, label: "Mensual", subtitle: "Una vez al mes")
            ])
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulPicker") {
    RuulPickerPreview()
}
#endif
