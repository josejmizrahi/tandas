import SwiftUI
import RuulUI
import RuulCore

/// Step 3 of the new ResourceCreationSheet. Asks only for the
/// builder's required identity fields — no capability toggles, no rule
/// pickers, no series pattern surface. Reuses `BuilderFieldRenderer`
/// so the date / picker / member-picker controls feel identical to the
/// legacy wizard for the few fields it does surface.
///
/// Doctrine 2026-05-18: "Minimal" is enforced by the variant's
/// `identityFields` (when non-empty) or falls back to the builder's
/// `requiredFields`. Anything else is deferred to a post-create intent.
struct MinimalIdentityForm: View {
    @Bindable var coordinator: ResourceCreationCoordinator
    let type: ResourceType
    let variant: ResourceVariant

    private var builder: (any ResourceBuilder)? {
        coordinator.builders.builder(for: type)
    }

    /// Fields surfaced in the form. The variant can curate a subset of
    /// the builder's required fields; empty `variant.identityFields`
    /// means "render all of builder.requiredFields".
    private var fields: [BuilderField] {
        if !variant.identityFields.isEmpty { return variant.identityFields }
        return builder?.requiredFields ?? []
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                heading
                fieldsStack
                if case .failed(let message) = coordinator.phase {
                    errorBanner(message)
                }
                createButton
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
            .padding(.bottom, RuulSpacing.xxl)
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: RuulSpacing.md) {
            iconBadge(variant.icon)
            VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
                Text(variant.humanName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.primary)
                Text("Lo esencial. El resto lo configuramos después.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var fieldsStack: some View {
        if fields.isEmpty {
            Text("Este tipo no necesita información extra para crearse.")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .padding(.vertical, RuulSpacing.md)
        } else {
            VStack(alignment: .leading, spacing: RuulSpacing.lg) {
                ForEach(fields, id: \.key) { field in
                    BuilderFieldRenderer(
                        field: field,
                        values: identityBinding
                    )
                }
            }
        }
    }

    private var createButton: some View {
        RuulButton(
            "Crear \(variant.humanName.lowercased())",
            style: .primary,
            size: .large,
            fillsWidth: true,
            action: {
                Task { await coordinator.create() }
            }
        )
        .disabled(!coordinator.canCreate || isCreating)
        .overlay(alignment: .trailing) {
            if isCreating {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, RuulSpacing.md)
            }
        }
        .padding(.top, RuulSpacing.md)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: RuulSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RuulSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: RuulRadius.medium, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
    }

    private func iconBadge(_ symbol: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.ruulAccent.opacity(0.15))
                .frame(width: 44, height: 44)
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(Color.ruulAccent)
        }
    }

    // MARK: - Helpers

    /// True while a create() call is in flight. Drives the trailing
    /// ProgressView + button disabled-state so the user can't double-tap.
    private var isCreating: Bool {
        if case .creating = coordinator.phase { return true }
        return false
    }

    /// Two-way binding bridging the coordinator's identityFields dict
    /// and BuilderFieldRenderer's expected `Binding<[String: JSONConfig]>`.
    /// The renderer writes back the full dict on every change; we route
    /// each write through `setIdentityField` so the coordinator keeps
    /// `canCreate` consistent.
    private var identityBinding: Binding<[String: JSONConfig]> {
        Binding(
            get: { coordinator.identityFields },
            set: { newValue in
                for (key, value) in newValue where coordinator.identityFields[key] != value {
                    coordinator.setIdentityField(key, value: value)
                }
                // Also drop any keys removed by the renderer (rare; the
                // renderer normally only sets, but mirror the semantics
                // so the dict stays a faithful copy).
                for key in coordinator.identityFields.keys where newValue[key] == nil {
                    coordinator.identityFields.removeValue(forKey: key)
                }
            }
        )
    }
}
