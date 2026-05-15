import SwiftUI
import RuulUI
import RuulCore

/// Generic per-capability config editor. Reuses BuilderFieldRenderer —
/// the same component the wizard uses — so capability authors don't need
/// a new view per capability.
@MainActor
public struct EditCapabilityConfigSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let resourceId: UUID
    public let block: any CapabilityBlock
    public let initialConfig: JSONConfig
    public let onSaved: () -> Void

    /// BuilderFieldRenderer expects a Binding to `[String: JSONConfig]` keyed
    /// by `field.key`. We hold that as in-memory state and re-assemble back
    /// to a single JSONConfig (.object) on save.
    @State private var values: [String: JSONConfig]
    @State private var saving = false
    @State private var errorText: String?

    public init(
        resourceId: UUID,
        block: any CapabilityBlock,
        initialConfig: JSONConfig,
        onSaved: @escaping () -> Void
    ) {
        self.resourceId = resourceId
        self.block = block
        self.initialConfig = initialConfig
        self.onSaved = onSaved
        self._values = State(initialValue: Self.unpack(initialConfig))
    }

    private var fields: [BuilderField] {
        block.requiredFields + block.optionalFields
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                    Text(block.summary)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextSecondary)
                    if fields.isEmpty {
                        Text("Esta capability no tiene opciones.")
                            .ruulTextStyle(RuulTypography.body)
                            .foregroundStyle(Color.ruulTextTertiary)
                    } else {
                        VStack(spacing: RuulSpacing.md) {
                            ForEach(fields, id: \.key) { field in
                                BuilderFieldRenderer(field: field, values: $values)
                            }
                        }
                    }
                    if let errorText {
                        Text(errorText)
                            .ruulTextStyle(RuulTypography.footnote)
                            .foregroundStyle(Color.ruulNegative)
                    }
                }
                .padding(RuulSpacing.lg)
            }
            .background(Color.ruulBackground.ignoresSafeArea())
            .navigationTitle(block.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancelar") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(saving ? "Guardando…" : "Guardar") {
                        Task { await save() }
                    }
                    .disabled(saving)
                }
            }
        }
    }

    private func save() async {
        saving = true
        errorText = nil
        defer { saving = false }
        let packed = Self.pack(values)
        do {
            _ = try await app.resourceCapabilityRepo.updateConfig(
                blockId: block.id,
                on: resourceId,
                config: packed
            )
            onSaved()
            dismiss()
        } catch {
            errorText = "No pudimos guardar la configuración."
        }
    }

    /// Splits a `.object([:])` JSONConfig into per-key entries that
    /// BuilderFieldRenderer can bind to. Non-object configs reset to empty.
    private static func unpack(_ config: JSONConfig) -> [String: JSONConfig] {
        if case .object(let dict) = config { return dict }
        return [:]
    }

    /// Reassembles `[String: JSONConfig]` back into a single `.object(...)`
    /// JSONConfig payload for `updateConfig`.
    private static func pack(_ values: [String: JSONConfig]) -> JSONConfig {
        .object(values)
    }
}
