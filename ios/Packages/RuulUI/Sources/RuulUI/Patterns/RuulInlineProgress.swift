import SwiftUI
import RuulCore

/// Thin indeterminate progress bar — discreet refresh indicator overlay.
///
/// Se renderiza arriba de una lista existente cuando el usuario hace
/// pull-to-refresh o el coordinator dispara un refresh programático.
/// La data anterior permanece visible debajo; solo el bar comunica
/// "trabajando".
///
/// Diseño: 2pt de alto, accent color, animación slide L→R infinita.
/// Respeta safe area top (la barra aparece debajo del status bar).
public struct RuulInlineProgress: View {
    @State private var phase: CGFloat = -1

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.ruulAccent.opacity(0.12))
                Rectangle()
                    .fill(Color.ruulAccent)
                    .frame(width: width * 0.30)
                    .offset(x: width * phase)
            }
        }
        .frame(height: 2)
        .clipped()
        .accessibilityLabel("Actualizando")
        .accessibilityAddTraits(.updatesFrequently)
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }
}

/// Banner compacto mostrado arriba de `loaded(value)` cuando un refresh
/// falla pero todavía tenemos datos previos visibles. Comunica el error
/// sin tapar el contenido. Tap → retry.
public struct ErrorBanner: View {
    private let error: CoordinatorError
    private let retry: (() -> Void)?

    public init(error: CoordinatorError, retry: (() -> Void)? = nil) {
        self.error = error
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            Image(systemName: error.isRetryable ? "exclamationmark.triangle.fill" : "exclamationmark.octagon.fill")
                .foregroundStyle(Color.red)
                .font(.caption.weight(.bold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(error.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.primary)
                if let message = error.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let retry, error.isRetryable {
                Button(action: retry) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.ruulAccent)
                        .padding(RuulSpacing.xs)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Reintentar")
            }
        }
        .padding(.horizontal, RuulSpacing.md)
        .padding(.vertical, RuulSpacing.sm)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .stroke(Color(.separator), lineWidth: 0.5)
        )
        .padding(.horizontal, RuulSpacing.md)
        .padding(.top, RuulSpacing.sm)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

#if DEBUG
#Preview("RuulInlineProgress") {
    VStack(spacing: RuulSpacing.xl) {
        RuulInlineProgress()
            .frame(width: 320)
        Text("Lista de ejemplo")
            .font(.subheadline)
    }
    .padding()
    .background(Color.ruulBackground)
}

#Preview("ErrorBanner") {
    VStack(spacing: RuulSpacing.lg) {
        ErrorBanner(
            error: CoordinatorError(title: "Sin conexión", message: "Verifica tu internet y vuelve a intentar.", isRetryable: true),
            retry: { }
        )
        ErrorBanner(
            error: CoordinatorError(title: "Permiso denegado", message: nil, isRetryable: false)
        )
    }
    .padding()
    .background(Color.ruulBackground)
}
#endif
