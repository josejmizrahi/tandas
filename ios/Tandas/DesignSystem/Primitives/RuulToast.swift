import SwiftUI
import RuulUI

/// Lightweight toast notification. Aparece desde top con glass effect,
/// auto-dismisses configurable.
public struct RuulToast: View {
    public enum Style: Sendable, Hashable { case success, warning, error, info }

    private let title: String
    private let message: String?
    private let style: Style

    public init(_ title: String, message: String? = nil, style: Style = .info) {
        self.title = title
        self.message = message
        self.style = style
    }

    public var body: some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ruulTextStyle(RuulTypography.headline)
                    .foregroundStyle(Color.ruulTextPrimary)
                if let message {
                    Text(message)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(RuulSpacing.md)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.large, style: .continuous),
            material: .thick,
            tint: tint.opacity(0.10)
        )
        .ruulElevation(.lg)
    }

    private var iconName: String {
        switch style {
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error:   return "xmark.circle.fill"
        case .info:    return "info.circle.fill"
        }
    }

    private var tint: Color {
        switch style {
        case .success: return .ruulPositive
        case .warning: return .ruulWarning
        case .error:   return .ruulNegative
        case .info:    return .ruulInfo
        }
    }
}

// MARK: - Toast presentation modifier

public struct RuulToastModel: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let message: String?
    public let style: RuulToast.Style

    public init(_ title: String, message: String? = nil, style: RuulToast.Style = .info) {
        self.id = UUID()
        self.title = title
        self.message = message
        self.style = style
    }
}

public extension View {
    /// Present a toast that slides down from the top safe area and auto-dismisses
    /// after `autoDismiss` seconds (default 3.0).
    func ruulToast(
        _ binding: Binding<RuulToastModel?>,
        autoDismiss: TimeInterval = 3.0
    ) -> some View {
        modifier(ToastPresenter(model: binding, autoDismiss: autoDismiss))
    }
}

private struct ToastPresenter: ViewModifier {
    @Binding var model: RuulToastModel?
    let autoDismiss: TimeInterval

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let model {
                    RuulToast(model.title, message: model.message, style: model.style)
                        .padding(.horizontal, RuulSpacing.lg)
                        .padding(.top, RuulSpacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(model.id)
                        .task {
                            try? await Task.sleep(for: .seconds(autoDismiss))
                            withAnimation(.ruulSmooth) {
                                self.model = nil
                            }
                        }
                }
            }
            .animation(.ruulSmooth, value: model)
    }
}

#if DEBUG
private struct RuulToastPreview: View {
    @State var toast: RuulToastModel?

    var body: some View {
        VStack(spacing: RuulSpacing.md) {
            RuulToast("Inline static")
            RuulToast("Success", message: "Listo, tu RSVP fue confirmado.", style: .success)
            RuulToast("Warning", message: "Quedan 30 min antes del checkin.", style: .warning)
            RuulToast("Error", message: "No se pudo enviar el código.", style: .error)
            Divider()
            RuulButton("Show toast") {
                toast = .init("Pago recibido", message: "Tu multa quedó saldada.", style: .success)
            }
        }
        .padding(RuulSpacing.lg)
        .background(Color.ruulBackground)
        .ruulToast($toast)
    }
}

#Preview("RuulToast") {
    RuulToastPreview()
}
#endif
