import SwiftUI

/// Wrapper around `Toggle` with ruul styling: accent tint when active,
/// optional inline label + description.
public struct RuulToggle: View {
    private let title: String
    private let description: String?
    @Binding private var isOn: Bool

    public init(_ title: String, isOn: Binding<Bool>, description: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.description = description
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let description {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
        .tint(Color.ruulAccent)
        .ruulHaptic(.selection, trigger: isOn)
    }
}

#if DEBUG
private struct RuulTogglePreview: View {
    @State var notif = true
    @State var auto = false
    @State var detail = true

    var body: some View {
        VStack(spacing: RuulSpacing.md) {
            RuulToggle("Notificaciones", isOn: $notif)
            RuulToggle("Auto-RSVP", isOn: $auto, description: "Confirma asistencia automáticamente.")
            RuulToggle("Mostrar detalles", isOn: $detail, description: "Sumas, miembros activos, etc.")
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
    }
}

#Preview("RuulToggle") {
    RuulTogglePreview()
}
#endif
