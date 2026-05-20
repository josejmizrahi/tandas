import SwiftUI
import RuulCore
import RuulUI

/// Single sheet that hosts all six right-lifecycle operations
/// (`exercise`, `transfer`, `delegate`, `revoke`, `suspend`, `restore`).
/// The variant is selected at present-time so the dispatch in
/// `UniversalResourceDetailView` stays a one-liner per action.
///
/// Each variant collects only the inputs the matching RPC needs:
///   - exercise  → optional free-text context
///   - transfer  → recipient (active member, excludes current holder)
///                 + reason (free text)
///   - delegate  → delegate member + optional `until` + reason
///   - revoke    → reason (destructive confirm)
///   - suspend   → optional `until` + reason
///   - restore   → reason
///
/// The member picker uses the same inline-Picker pattern as
/// SettlementSheet (the wizard's `.memberPicker` field-kind is still
/// disabled — mig 00201 / Builder note). When `.memberPicker` ships,
/// this sheet swaps to the shared component without changing its call
/// signature.
@MainActor
public struct RightActionSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    public enum Action: Hashable, Identifiable {
        case exercise
        case transfer
        case delegate
        case revoke
        case suspend
        case restore

        public var id: Action { self }
    }

    public let action: Action
    public let rightId: UUID
    /// Active group members (already loaded by the detail screen).
    /// Used to render the recipient/delegate pickers; the sheet
    /// filters out non-active members + the current holder.
    public let members: [MemberWithProfile]
    /// Current holder's member id — excluded from the recipient list
    /// in `transfer` mode so a no-op self-transfer isn't even offered.
    public let holderMemberId: UUID?
    public let onCompleted: () -> Void

    // Inputs
    @State private var selectedMemberId: UUID?
    @State private var untilDate: Date = Date.now.addingTimeInterval(7 * 24 * 3_600)
    @State private var hasUntil: Bool = false
    @State private var reasonText: String = ""
    @State private var contextText: String = ""

    // Async
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    public init(
        action: Action,
        rightId: UUID,
        members: [MemberWithProfile],
        holderMemberId: UUID?,
        onCompleted: @escaping () -> Void
    ) {
        self.action = action
        self.rightId = rightId
        self.members = members
        self.holderMemberId = holderMemberId
        self.onCompleted = onCompleted
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(blurb)
                        .font(.footnote)
                        .foregroundStyle(Color.secondary)
                }

                if needsMember {
                    Section("Miembro") {
                        memberPicker
                    }
                }

                if hasUntilField {
                    Section("Vigencia") {
                        Toggle("Con fecha límite", isOn: $hasUntil)
                        if hasUntil {
                            DatePicker(
                                "Hasta",
                                selection: $untilDate,
                                in: Date.now...,
                                displayedComponents: [.date, .hourAndMinute]
                            )
                        }
                    }
                }

                if action == .exercise {
                    Section("Notas (opcional)") {
                        TextField(
                            "Para qué lo usaste",
                            text: $contextText,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    }
                } else {
                    Section("Razón (opcional)") {
                        TextField(
                            "Por qué \(verbForReason)",
                            text: $reasonText,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .ruulSheetToolbar(title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text(submitLabel)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    isDestructive ? Color.red : Color.ruulAccent
                                )
                        }
                    }
                    .disabled(!isValid || isSubmitting)
                }
            }
        }
    }

    // MARK: - Inputs

    @ViewBuilder
    private var memberPicker: some View {
        let candidates = members.filter { mwp in
            mwp.member.active && mwp.member.id != holderMemberId
        }
        if candidates.isEmpty {
            Text("Ningún otro miembro activo disponible.")
                .font(.footnote)
                .foregroundStyle(Color(.tertiaryLabel))
        } else {
            Picker("Miembro", selection: $selectedMemberId) {
                Text("Selecciona…").tag(Optional<UUID>(nil))
                ForEach(candidates) { mwp in
                    Text(mwp.displayName).tag(Optional(mwp.member.id))
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Variant config

    private var needsMember: Bool {
        action == .transfer || action == .delegate
    }
    private var hasUntilField: Bool {
        action == .delegate || action == .suspend
    }
    private var isDestructive: Bool {
        action == .revoke
    }
    private var title: String {
        switch action {
        case .exercise: return "Ejercer derecho"
        case .transfer: return "Transferir"
        case .delegate: return "Delegar"
        case .revoke:   return "Revocar"
        case .suspend:  return "Suspender"
        case .restore:  return "Restaurar"
        }
    }
    private var submitLabel: String {
        switch action {
        case .exercise: return "Ejercer"
        case .transfer: return "Transferir"
        case .delegate: return "Delegar"
        case .revoke:   return "Revocar"
        case .suspend:  return "Suspender"
        case .restore:  return "Restaurar"
        }
    }
    private var verbForReason: String {
        switch action {
        case .exercise: return "ejerces"   // unused — exercise uses contextText
        case .transfer: return "transfieres"
        case .delegate: return "delegas"
        case .revoke:   return "revocas"
        case .suspend:  return "suspendes"
        case .restore:  return "restauras"
        }
    }
    private var blurb: String {
        switch action {
        case .exercise: return "Registra que usaste este derecho hoy. Queda en el historial."
        case .transfer: return "Reasigna este derecho a otro miembro del grupo. El derecho debe ser transferible."
        case .delegate: return "Permite que otro miembro lo ejerza temporalmente sin que dejes de ser el titular."
        case .revoke:   return "Cambia el estado del derecho a `revocado`. Reversible con Restaurar."
        case .suspend:  return "Bloquea temporalmente el ejercicio. El derecho sigue activo y se puede restaurar."
        case .restore:  return "Limpia una suspensión o levanta una revocación previa."
        }
    }
    private var isValid: Bool {
        if needsMember && selectedMemberId == nil { return false }
        return true
    }

    // MARK: - Submit

    private func submit() async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        let until: Date? = hasUntil && hasUntilField ? untilDate : nil
        let reason: String? = reasonText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : reasonText.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch action {
            case .exercise:
                let trimmed = contextText.trimmingCharacters(in: .whitespacesAndNewlines)
                let ctx: JSONConfig = trimmed.isEmpty
                    ? .object([:])
                    : .object(["note": .string(trimmed)])
                try await app.rightRepo.exercise(rightId, context: ctx)
            case .transfer:
                guard let to = selectedMemberId else { return }
                try await app.rightRepo.transfer(rightId, to: to, reason: reason)
            case .delegate:
                guard let to = selectedMemberId else { return }
                try await app.rightRepo.delegate(rightId, to: to, until: until, reason: reason)
            case .revoke:
                try await app.rightRepo.revoke(rightId, reason: reason)
            case .suspend:
                try await app.rightRepo.suspend(rightId, until: until, reason: reason)
            case .restore:
                try await app.rightRepo.restore(rightId, reason: reason)
            }
            onCompleted()
            dismiss()
        } catch let e as RightError {
            errorMessage = e.errorDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
