import SwiftUI
import RuulCore
import RuulUI

/// Edit-details form for a `right` resource. Calls
/// `update_right_metadata` (mig 00199) which whitelists the tuneable
/// knobs and rejects holder/delegate/status keys — those must go
/// through the dedicated lifecycle RPCs (transfer/delegate/revoke/etc.)
/// so their atoms emit correctly.
///
/// Surfaced from the ⋯ menu's "Editar detalles" entry (admin only,
/// slice 13). Fields default to the right's current metadata; the
/// patch sent on submit contains ONLY the keys the admin actually
/// changed, so unchanged knobs don't clobber concurrent edits.
@MainActor
public struct EditRightSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public let rightId: UUID
    /// The right's current metadata snapshot. Form fields seed from
    /// here; we don't re-fetch — the detail view already has the row.
    public let metadata: JSONConfig
    public let onCompleted: () -> Void

    // Inputs (seeded from metadata in init)
    @State private var name: String
    @State private var priority: Int
    @State private var exclusive: Bool
    @State private var transferable: Bool
    @State private var delegable: Bool
    @State private var divisible: Bool
    @State private var scope: String
    @State private var source: String
    @State private var targetCapability: String
    @State private var hasExpiry: Bool
    @State private var expiresAt: Date

    // Async
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    public init(
        rightId: UUID,
        metadata: JSONConfig,
        onCompleted: @escaping () -> Void
    ) {
        self.rightId = rightId
        self.metadata = metadata
        self.onCompleted = onCompleted

        // Seed every field from the current metadata. Defaults match
        // create_right's: priority=0, all bool flags false, scope='resource'.
        _name = State(initialValue: metadata["name"]?.stringValue ?? "")
        _priority = State(initialValue: metadata["priority"]?.intValue ?? 0)
        _exclusive = State(initialValue: metadata["exclusive"]?.boolValue ?? false)
        _transferable = State(initialValue: metadata["transferable"]?.boolValue ?? false)
        _delegable = State(initialValue: metadata["delegable"]?.boolValue ?? false)
        _divisible = State(initialValue: metadata["divisible"]?.boolValue ?? false)
        _scope = State(initialValue: metadata["scope"]?.stringValue ?? "resource")
        _source = State(initialValue: metadata["source"]?.stringValue ?? "")
        _targetCapability = State(initialValue: metadata["targetCapability"]?.stringValue
            ?? metadata["target_capability"]?.stringValue ?? "")

        // Expiration: nil-able. The toggle controls whether the
        // expires_at key participates in the patch at all — clearing
        // an expiration sends `expires_at: null` which the RPC
        // accepts (jsonb_object_keys + value=null overwrites the field).
        if let raw = metadata["expires_at"]?.stringValue, !raw.isEmpty,
           let date = ISO8601DateFormatter().date(from: raw) {
            _hasExpiry = State(initialValue: true)
            _expiresAt = State(initialValue: date)
        } else {
            _hasExpiry = State(initialValue: false)
            _expiresAt = State(initialValue: Date.now.addingTimeInterval(30 * 86_400))
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Identidad") {
                    TextField("Nombre", text: $name)
                }

                Section("Alcance") {
                    Picker("Aplica a", selection: $scope) {
                        Text("Grupo entero").tag("group")
                        Text("Un recurso").tag("resource")
                        Text("Una ocurrencia").tag("occurrence")
                    }
                    TextField(
                        "Función gobernada (opcional)",
                        text: $targetCapability,
                        prompt: Text("booking | voting | access | …")
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                }

                Section("Flags") {
                    Toggle("Exclusivo", isOn: $exclusive)
                    Toggle("Transferible", isOn: $transferable)
                    Toggle("Delegable", isOn: $delegable)
                    Toggle("Divisible", isOn: $divisible)
                    Stepper(
                        "Prioridad: \(priority)",
                        value: $priority,
                        in: 0...100
                    )
                }

                Section("Vigencia") {
                    Toggle("Con fecha de vencimiento", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker(
                            "Vence",
                            selection: $expiresAt,
                            in: Date.now...,
                            displayedComponents: [.date, .hourAndMinute]
                        )
                    }
                }

                Section("Procedencia (opcional)") {
                    TextField(
                        "Origen",
                        text: $source,
                        prompt: Text("ej: compra, herencia, voto 2026-05")
                    )
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .ruulSheetToolbar("Editar derecho")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Guardar")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.ruulAccent)
                        }
                    }
                    .disabled(!isValid || isSubmitting)
                }
            }
        }
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Build a diff patch: only the keys whose values actually changed
    /// from the original metadata. Keeps the patch tight so a
    /// concurrent admin editing a different field doesn't get clobbered.
    private func buildPatch() -> JSONConfig {
        var patch: [String: JSONConfig] = [:]

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedName != (metadata["name"]?.stringValue ?? "") {
            patch["name"] = .string(trimmedName)
        }
        if priority != (metadata["priority"]?.intValue ?? 0) {
            patch["priority"] = .int(priority)
        }
        if exclusive != (metadata["exclusive"]?.boolValue ?? false) {
            patch["exclusive"] = .bool(exclusive)
        }
        if transferable != (metadata["transferable"]?.boolValue ?? false) {
            patch["transferable"] = .bool(transferable)
        }
        if delegable != (metadata["delegable"]?.boolValue ?? false) {
            patch["delegable"] = .bool(delegable)
        }
        if divisible != (metadata["divisible"]?.boolValue ?? false) {
            patch["divisible"] = .bool(divisible)
        }
        if scope != (metadata["scope"]?.stringValue ?? "resource") {
            patch["scope"] = .string(scope)
        }
        let trimmedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalSource = metadata["source"]?.stringValue ?? ""
        if trimmedSource != originalSource {
            patch["source"] = trimmedSource.isEmpty ? .null : .string(trimmedSource)
        }
        let trimmedCap = targetCapability.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalCap = metadata["target_capability"]?.stringValue ?? ""
        if trimmedCap != originalCap {
            patch["target_capability"] = trimmedCap.isEmpty ? .null : .string(trimmedCap)
        }
        // Expiration diff: track both the toggle + the date. Clearing
        // the expiry sends `expires_at: null`; setting/changing it
        // sends the ISO string.
        let originalExpiresStr = metadata["expires_at"]?.stringValue
        let originalHadExpiry = originalExpiresStr != nil && !(originalExpiresStr?.isEmpty ?? true)
        if hasExpiry {
            let iso = ISO8601DateFormatter().string(from: expiresAt)
            if !originalHadExpiry || originalExpiresStr != iso {
                patch["expires_at"] = .string(iso)
            }
        } else if originalHadExpiry {
            patch["expires_at"] = .null
        }

        return .object(patch)
    }

    private func submit() async {
        guard !isSubmitting else { return }
        let patch = buildPatch()
        // No-op if nothing changed.
        if case .object(let dict) = patch, dict.isEmpty {
            dismiss()
            return
        }

        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await app.rightRepo.updateMetadata(rightId, patch: patch)
            onCompleted()
            dismiss()
        } catch let e as RightError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
