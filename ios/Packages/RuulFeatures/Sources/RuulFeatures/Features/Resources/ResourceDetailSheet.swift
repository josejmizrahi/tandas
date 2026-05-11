import SwiftUI
import RuulUI
import RuulCore

/// Polymorphic resource detail. Renders per `resource_type`:
///   - `.event` → defers to the legacy EventDetailCoordinator path via
///                MainTabView's existing routing (this sheet shouldn't
///                normally open for events).
///   - `.asset`, `.slot`, `.fund`, etc. → metadata + capabilities + history
///     placeholder. Phase 3+ replaces each placeholder with the type-
///     specific feature surface as it lands.
public struct ResourceDetailSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resource: ResourceRow
    @State private var capabilities: [ResourceCapability] = []

    public init(resource: ResourceRow) { self.resource = resource }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                    heroSection
                    metadataSection
                    capabilitiesSection
                    historyPlaceholder
                }
                .padding(.horizontal, RuulSpacing.lg)
                .padding(.top, RuulSpacing.lg)
                .padding(.bottom, RuulSpacing.xxl)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cerrar") { dismiss() }
                        .foregroundStyle(Color.ruulTextSecondary)
                }
                ToolbarItem(placement: .principal) {
                    Text(displayName)
                        .ruulTextStyle(RuulTypography.headline)
                        .foregroundStyle(Color.ruulTextPrimary)
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Color.ruulBackground, for: .navigationBar)
        }
        .task { await loadCapabilities() }
    }

    // MARK: - Sections

    private var heroSection: some View {
        VStack(alignment: .center, spacing: RuulSpacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.ruulAccent.opacity(0.15))
                    .frame(width: 72, height: 72)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundStyle(Color.ruulAccent)
            }
            VStack(spacing: 2) {
                Text(displayName)
                    .ruulTextStyle(RuulTypography.titleLarge)
                    .foregroundStyle(Color.ruulTextPrimary)
                Text(typeLabel)
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(RuulSpacing.xl)
        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.extraLarge))
        .overlay(
            RoundedRectangle(cornerRadius: RuulRadius.extraLarge)
                .stroke(Color.ruulSeparator, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private var metadataSection: some View {
        if case let .object(map) = resource.metadata, !map.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("DETALLES")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                VStack(spacing: 0) {
                    ForEach(map.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        metadataRow(key: key, value: stringify(value))
                        if key != map.keys.sorted().last {
                            Divider().padding(.leading, RuulSpacing.md)
                        }
                    }
                }
                .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
                .overlay(
                    RoundedRectangle(cornerRadius: RuulRadius.large)
                        .stroke(Color.ruulSeparator, lineWidth: 0.5)
                )
            }
        }
    }

    private func metadataRow(key: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(humanize(key))
                .ruulTextStyle(RuulTypography.callout)
                .foregroundStyle(Color.ruulTextSecondary)
            Spacer()
            Text(value)
                .ruulTextStyle(RuulTypography.body)
                .foregroundStyle(Color.ruulTextPrimary)
                .multilineTextAlignment(.trailing)
        }
        .padding(RuulSpacing.md)
    }

    @ViewBuilder
    private var capabilitiesSection: some View {
        if !capabilities.isEmpty {
            VStack(alignment: .leading, spacing: RuulSpacing.sm) {
                Text("CAPACIDADES")
                    .ruulTextStyle(RuulTypography.sectionLabel)
                    .foregroundStyle(Color.ruulTextTertiary)
                let catalog = CapabilityCatalog.v1
                VStack(spacing: RuulSpacing.xs) {
                    ForEach(capabilities, id: \.capabilityBlockId) { cap in
                        let block = catalog[cap.capabilityBlockId]
                        HStack(spacing: RuulSpacing.sm) {
                            Image(systemName: cap.enabled ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(cap.enabled ? Color.ruulAccent : Color.ruulTextTertiary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(block?.displayName ?? cap.capabilityBlockId)
                                    .ruulTextStyle(RuulTypography.body)
                                    .foregroundStyle(Color.ruulTextPrimary)
                                if let summary = block?.summary {
                                    Text(summary)
                                        .ruulTextStyle(RuulTypography.caption)
                                        .foregroundStyle(Color.ruulTextSecondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(RuulSpacing.md)
                        .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.medium))
                        .overlay(
                            RoundedRectangle(cornerRadius: RuulRadius.medium)
                                .stroke(Color.ruulSeparator, lineWidth: 0.5)
                        )
                    }
                }
            }
        }
    }

    private var historyPlaceholder: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.sm) {
            Text("HISTORIAL")
                .ruulTextStyle(RuulTypography.sectionLabel)
                .foregroundStyle(Color.ruulTextTertiary)
            VStack(spacing: RuulSpacing.xs) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.ruulTextTertiary)
                Text("Próximamente")
                    .ruulTextStyle(RuulTypography.body)
                    .foregroundStyle(Color.ruulTextSecondary)
                Text("Aquí verás los cambios y movimientos de este recurso.")
                    .ruulTextStyle(RuulTypography.caption)
                    .foregroundStyle(Color.ruulTextTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(RuulSpacing.xl)
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.large))
        }
    }

    // MARK: - Helpers

    private var displayName: String {
        if case let .string(name) = resource.metadata["name"]  { return name }
        if case let .string(title) = resource.metadata["title"] { return title }
        return typeLabel
    }

    private var typeLabel: String {
        switch resource.resourceType {
        case .event:        return "Evento"
        case .asset:        return "Activo"
        case .slot:         return "Slot"
        case .fund:         return "Fondo"
        case .booking:      return "Reserva"
        case .contribution: return "Aportación"
        case .position:     return "Posición"
        case .assignment:   return "Tarea"
        case .rotation:     return "Rotación"
        case .guestPass:    return "Invitado"
        case .proposal:     return "Propuesta"
        case .unknown(let raw): return raw
        }
    }

    private var icon: String {
        switch resource.resourceType {
        case .event:        return "calendar"
        case .asset:        return "key.fill"
        case .slot:         return "ticket"
        case .fund:         return "banknote"
        case .booking:      return "calendar.badge.checkmark"
        case .contribution: return "arrow.up.bin"
        default:            return "square.dashed"
        }
    }

    private func stringify(_ value: JSONConfig) -> String {
        switch value {
        case .null:                return "—"
        case .bool(let b):         return b ? "Sí" : "No"
        case .int(let i):          return String(i)
        case .double(let d):       return String(d)
        case .string(let s):       return s
        case .array(let items):    return items.map { stringify($0) }.joined(separator: ", ")
        case .object:              return "{…}"
        }
    }

    private func humanize(_ key: String) -> String {
        // capacity → Capacidad, host_id → Host id (simple)
        let mapping: [String: String] = [
            "capacity":   "Capacidad",
            "name":       "Nombre",
            "description": "Descripción",
            "location":   "Lugar",
            "starts_at":  "Empieza",
            "ends_at":    "Termina",
            "host_id":    "Host",
            "asset_id":   "Activo"
        ]
        return mapping[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
    }

    @MainActor
    private func loadCapabilities() async {
        do {
            capabilities = try await app.resourceCapabilityRepo.list(resourceId: resource.id)
        } catch {
            // silent — capabilities section just hides
        }
    }
}
