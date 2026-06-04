import SwiftUI
import RuulCore

// MARK: - Loading

public struct LoadingStateView: View {
    let title: String

    public init(title: String = "Cargando…") {
        self.title = title
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Error

public struct ErrorStateView: View {
    let title: String
    let message: String
    let retry: (() -> Void)?

    public init(title: String = "Algo salió mal", message: String, retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Theme.IconSize.lg))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xl)
            if let retry {
                Button("Reintentar", action: retry)
                    .buttonStyle(.glassProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Empty

public struct EmptyStateView: View {
    let symbolName: String
    let title: String
    let message: String

    public init(symbolName: String, title: String, message: String) {
        self.symbolName = symbolName
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbolName)
                .font(.system(size: Theme.IconSize.lg))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xxl + Theme.Spacing.sm)
    }
}

// MARK: - Acciones con error

/// Estado de una acción async lanzada desde una vista (crear, votar, pagar…).
/// Las vistas lo usan con `runAction` para mostrar errores del backend
/// de forma consistente.
@MainActor
@Observable
public final class ActionRunner {
    public var isRunning = false
    public var error: UserFacingError?

    public init() {}

    /// Ejecuta la acción; captura cualquier error como `UserFacingError`.
    /// Devuelve `true` si la acción terminó sin error.
    @discardableResult
    public func run(_ action: () async throws -> Void) async -> Bool {
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            try await action()
            return true
        } catch {
            self.error = UserFacingError.from(error)
            return false
        }
    }
}

public extension View {
    /// Alert estándar para errores de `ActionRunner`.
    func actionErrorAlert(_ runner: ActionRunner) -> some View {
        alert(
            runner.error?.title ?? "Error",
            isPresented: Binding(
                get: { runner.error != nil },
                set: { if !$0 { runner.error = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(runner.error?.message ?? "")
        }
    }

    /// Recarga datos cuando la vista REAPARECE (al volver de una pantalla hija
    /// que pudo modificar datos — p.ej. marcar pagos en Settlement y regresar a
    /// Dinero). Solo corre si ya había datos (`isLoaded`); la carga inicial la
    /// hace `.task` como siempre.
    func refreshOnReappear(if isLoaded: Bool, _ action: @escaping () async -> Void) -> some View {
        onAppear {
            guard isLoaded else { return }
            Task { await action() }
        }
    }
}

// MARK: - Filas reutilizables

/// Fila genérica icono + título + subtítulo + valor para listas.
public struct InfoRow: View {
    let symbolName: String
    let title: String
    let subtitle: String?
    let value: String?
    var tint: Color = .accentColor

    public init(symbolName: String, title: String, subtitle: String? = nil, value: String? = nil, tint: Color = .accentColor) {
        self.symbolName = symbolName
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.tint = tint
    }

    public var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: symbolName)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: Theme.IconSize.sm)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            if let value {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// Badge de estado con color semántico.
public struct StatusBadge: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 3)
            .background(color.badgeFill, in: Capsule())
            .foregroundStyle(color)
    }
}

/// Círculo con iniciales para actores sin avatar.
public struct ActorInitialsView: View {
    let name: String
    var size: CGFloat = 36

    public init(name: String, size: CGFloat = 36) {
        self.name = name
        self.size = size
    }

    private var initials: String {
        let parts = name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)) }.joined().uppercased()
    }

    public var body: some View {
        Text(initials.isEmpty ? "?" : initials)
            .font(.system(size: size * 0.4, weight: .semibold))
            .frame(width: size, height: size)
            .background(Color.accentColor.badgeFill, in: Circle())
            .foregroundStyle(Color.accentColor)
    }
}
