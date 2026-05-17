import SwiftUI
import RuulUI
import RuulCore

// MARK: - recurrence

public struct RecurrenceSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "recurrence",
        priority: 110,
        isEnabledFor: { caps in caps.contains("recurrence") },
        render: { ctx in AnyView(RecurrenceSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "RECURRENCIA") {
            if let rule {
                StubMetadataRow(label: "Cada", value: rule)
            } else {
                StubPlaceholderRow(
                    symbol: "repeat",
                    subtitle: "El recurso no tiene regla de recurrencia configurada."
                )
            }
        }
    }

    private var rule: String? {
        if let label = context.resource.metadata["recurrence_label"]?.stringValue { return label }
        return context.resource.metadata["recurrence_rule"]?.stringValue
    }
}

// MARK: - deadline

public struct DeadlineSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "deadline",
        priority: 120,
        isEnabledFor: { caps in caps.contains("deadline") },
        render: { ctx in AnyView(DeadlineSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "FECHA LÍMITE") {
            if let raw = deadlineRaw {
                StubMetadataRow(label: "Vence", value: TimingDate.short(raw))
            } else {
                StubPlaceholderRow(
                    symbol: "hourglass",
                    subtitle: "No hay fecha límite definida."
                )
            }
        }
    }

    private var deadlineRaw: String? {
        context.resource.metadata["deadline_at"]?.stringValue
            ?? context.resource.metadata["due_at"]?.stringValue
    }
}

// MARK: - expiration

public struct ExpirationSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "expiration",
        priority: 130,
        isEnabledFor: { caps in caps.contains("expiration") },
        render: { ctx in AnyView(ExpirationSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "EXPIRACIÓN") {
            if let raw = expiresRaw {
                StubMetadataRow(label: "Expira", value: TimingDate.short(raw))
            } else {
                StubPlaceholderRow(
                    symbol: "calendar.badge.exclamationmark",
                    subtitle: "Sin fecha de expiración."
                )
            }
        }
    }

    private var expiresRaw: String? {
        context.resource.metadata["expires_at"]?.stringValue
            ?? context.resource.metadata["expiration_date"]?.stringValue
    }
}

// MARK: - reminder

public struct ReminderSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "reminder",
        priority: 770,
        isEnabledFor: { caps in caps.contains("reminder") },
        render: { ctx in AnyView(ReminderSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "RECORDATORIOS") {
            StubPlaceholderRow(
                symbol: "bell",
                subtitle: "Configurar recordatorios manuales en una próxima versión."
            )
        }
    }
}

// MARK: - cancellation

public struct CancellationSectionView: View {
    public let context: ResourceDetailContext

    public static let definition = CapabilitySection(
        id: "cancellation",
        priority: 760,
        isEnabledFor: { caps in caps.contains("cancellation") },
        render: { ctx in AnyView(CancellationSectionView(context: ctx)) }
    )

    public init(context: ResourceDetailContext) { self.context = context }

    public var body: some View {
        CapabilityStubCard(label: "CANCELACIÓN") {
            if context.resource.status.lowercased().contains("cancel") {
                StubMetadataRow(label: "Estado", value: "Cancelado")
            } else {
                StubPlaceholderRow(
                    symbol: "xmark.circle",
                    subtitle: "La acción de cancelar vive en el menú ⋯ del recurso."
                )
            }
        }
    }
}

// MARK: - shared formatter

/// ISO-8601-leaning short date formatter for `metadata["*_at"]` fields.
/// Strips the time portion when present; returns the raw string when not
/// parseable so the UI never blanks a real value.
enum TimingDate {
    static func short(_ raw: String) -> String {
        let isoSeconds = ISO8601DateFormatter()
        isoSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoSeconds.date(from: raw) {
            return formatter.string(from: d)
        }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) {
            return formatter.string(from: d)
        }
        let dateOnly = DateFormatter()
        dateOnly.dateFormat = "yyyy-MM-dd"
        if let d = dateOnly.date(from: raw) {
            return formatter.string(from: d)
        }
        return raw
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
