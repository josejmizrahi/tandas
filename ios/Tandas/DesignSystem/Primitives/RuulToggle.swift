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
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let description {
                    Text(description)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
        }
        .tint(Color.ruulAccentPrimary)
        .ruulHaptic(.selection, trigger: isOn)
    }
}

#if DEBUG
private struct RuulTogglePreview: View {
    @State var notif = true
    @State var auto = false
    @State var detail = true

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            RuulToggle("Notificaciones", isOn: $notif)
            RuulToggle("Auto-RSVP", isOn: $auto, description: "Confirma asistencia automáticamente.")
            RuulToggle("Mostrar detalles", isOn: $detail, description: "Sumas, miembros activos, etc.")
        }
        .padding(RuulSpacing.s5)
        .background(Color.ruulBackgroundCanvas)
    }
}

#Preview("RuulToggle") {
    RuulTogglePreview()
}
#endif
