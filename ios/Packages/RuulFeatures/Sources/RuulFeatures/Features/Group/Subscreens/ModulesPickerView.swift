import SwiftUI
import RuulUI
import RuulCore

/// "Características del grupo" — toggle list of group modules
/// (`basic_fines`, `rotating_host`, `rsvp`, `check_in`,
/// `appeal_voting`, `slot_assignment`, `common_fund`, etc.). Pushed
/// from Ajustes → "Características del grupo" → here.
///
/// Apple Settings pattern: `Form` of `Section`s, one row per module
/// with a native `Toggle`. Blocked rows surface a footer explaining
/// the conflict or unmet dependency.
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

            if blocked && !conflicts.isEmpty {
                Text("Conflictúa con: \(conflicts.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Color.ruulWarning)
            }
            if blocked && !unsatisfiedDeps.isEmpty {
                Text("Requiere: \(unsatisfiedDeps.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Color(.tertiaryLabel))
            }
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
