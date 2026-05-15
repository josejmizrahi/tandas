import SwiftUI
import RuulUI
import RuulCore

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
        ScrollView {
            VStack(spacing: 0) {
                ForEach(ModuleRegistry.v1Fallback.modules, id: \.id) { module in
                    moduleRow(module)
                    if module.id != ModuleRegistry.v1Fallback.modules.last?.id {
                        Divider().background(Color.ruulSeparator).padding(.leading, RuulSpacing.md)
                    }
                }
            }
            .background(Color.ruulSurface, in: RoundedRectangle(cornerRadius: RuulRadius.lg))
            .padding(RuulSpacing.lg)

            if let error {
                Text(error)
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulNegative)
                    .padding(.horizontal, RuulSpacing.lg)
            }
        }
        .background(Color.ruulBackground.ignoresSafeArea())
        .navigationTitle("Módulos")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func moduleRow(_ module: GroupModule) -> some View {
        let enabled = activeSlugs.contains(module.id)
        let isSaving = saving.contains(module.id)
        let conflicts = module.conflictsWith.filter(activeSlugs.contains)
        let unsatisfiedDeps = module.dependencies.filter { !activeSlugs.contains($0) }
        let blocked = !enabled && (!conflicts.isEmpty || !unsatisfiedDeps.isEmpty)

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(module.name)
                        .ruulTextStyle(RuulTypography.body)
                        .foregroundStyle(Color.ruulTextPrimary)
                    Text(module.description)
                        .ruulTextStyle(RuulTypography.caption)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(2)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { enabled },
                    set: { newVal in Task { await toggle(module.id, newVal) } }
                ))
                .labelsHidden()
                .disabled(isSaving || blocked)
            }
            if blocked && !conflicts.isEmpty {
                Text("Conflictúa con: \(conflicts.joined(separator: ", "))")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulWarning)
            }
            if blocked && !unsatisfiedDeps.isEmpty {
                Text("Requiere: \(unsatisfiedDeps.joined(separator: ", "))")
                    .ruulTextStyle(RuulTypography.footnote)
                    .foregroundStyle(Color.ruulTextTertiary)
            }
        }
        .padding(RuulSpacing.md)
    }

    private func toggle(_ slug: String, _ newValue: Bool) async {
        saving.insert(slug)
        defer { saving.remove(slug) }
        do {
            _ = try await app.groupsRepo.setModule(groupId: groupId, slug: slug, enabled: newValue)
            await app.refreshProfileAndGroups()
        } catch {
            self.error = "No pudimos cambiar el módulo."
        }
    }
}
