import SwiftUI
import RuulUI
import RuulCore

/// "Características del grupo" — toggle list of group modules
/// (`basic_fines`, `rotating_host`, `rsvp`, `check_in`,
/// `appeal_voting`, `slot_assignment`, `common_fund`, etc.). Pushed
/// from Ajustes → "Características del grupo" → here.
///
/// Apple Settings pattern: `Form` of `Section`s, one row per module
/// with a native `Toggle`. Blocked rows surface a footer with a
/// human sentence — never the slug graph (no "Conflictúa con: X" /
/// "Requiere: Y"; we use the module's display name and prose).
@MainActor
public struct ModulesPickerView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    public let groupId: UUID

    @State private var saving: Set<String> = []
    @State private var error: String?

    public init(groupId: UUID) { self.groupId = groupId }

    private var current: RuulCore.Group? { app.groups.first(where: { $0.id == groupId }) }
    private var activeSlugs: Set<String> { Set(current?.activeModules ?? []) }

    public var body: some View {
        Form {
            Section {
                ForEach(ModuleRegistry.v1Fallback.modules, id: \.id) { module in
                    moduleRow(module)
                }
            } footer: {
                if let error {
                    Text(error)
                        .foregroundStyle(Color.ruulNegative)
                }
            }
        }
        .navigationTitle("Características del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func moduleRow(_ module: GroupModule) -> some View {
        let enabled = activeSlugs.contains(module.id)
        let isSaving = saving.contains(module.id)
        let conflicts = module.conflictsWith.filter(activeSlugs.contains)
        let unsatisfiedDeps = module.dependencies.filter { !activeSlugs.contains($0) }
        let blocked = !enabled && (!conflicts.isEmpty || !unsatisfiedDeps.isEmpty)

        VStack(alignment: .leading, spacing: RuulSpacing.xxs) {
            Toggle(isOn: Binding(
                get: { enabled },
                set: { newVal in Task { await toggle(module.id, newVal) } }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name)
                        .foregroundStyle(blocked ? Color.secondary : Color.primary)
                    Text(module.description)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(2)
                }
            }
            .disabled(isSaving || blocked)

            if blocked, let reason = blockedSentence(
                conflicts: conflicts,
                unsatisfiedDeps: unsatisfiedDeps
            ) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(!conflicts.isEmpty ? Color.ruulWarning : Color(.tertiaryLabel))
            }
        }
    }

    /// Renders the block reason as a human sentence using module display
    /// names. Never exposes the slug graph — users see "No se puede
    /// activar mientras «Multas básicas» esté activa." instead of
    /// "Conflictúa con: basic_fines".
    private func blockedSentence(conflicts: [String], unsatisfiedDeps: [String]) -> String? {
        if !conflicts.isEmpty {
            let names = conflicts.map(humanName(forSlug:))
            let list = quotedList(names)
            return names.count == 1
                ? "No se puede activar mientras \(list) esté activa."
                : "No se puede activar mientras \(list) estén activas."
        }
        if !unsatisfiedDeps.isEmpty {
            let names = unsatisfiedDeps.map(humanName(forSlug:))
            let list = quotedList(names)
            return "Necesita \(list) para funcionar."
        }
        return nil
    }

    private func humanName(forSlug slug: String) -> String {
        ModuleRegistry.v1Fallback.modules.first(where: { $0.id == slug })?.name ?? slug
    }

    private func quotedList(_ names: [String]) -> String {
        switch names.count {
        case 0:  return ""
        case 1:  return "«\(names[0])»"
        case 2:  return "«\(names[0])» y «\(names[1])»"
        default:
            let head = names.dropLast().map { "«\($0)»" }.joined(separator: ", ")
            return "\(head) y «\(names.last ?? "")»"
        }
    }

    private func toggle(_ slug: String, _ newValue: Bool) async {
        saving.insert(slug)
        defer { saving.remove(slug) }
        do {
            _ = try await app.groupsRepo.setModule(groupId: groupId, slug: slug, enabled: newValue)
            await app.refreshProfileAndGroups()
        } catch {
            self.error = "No pudimos cambiar la función."
        }
    }
}
