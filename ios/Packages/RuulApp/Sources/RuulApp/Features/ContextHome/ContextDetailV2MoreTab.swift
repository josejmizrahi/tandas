import SwiftUI
import RuulCore

// MARK: - More tab

struct ContextDetailV2MoreTab: View {
    let descriptor: ContextDetailDescriptor
    /// Section keys del tab "Más" (`Tab.more.sectionKeys` del padre).
    let moreSectionKeys: Set<String>
    let context: AppContext
    let container: DependencyContainer

    var body: some View {
        let d = descriptor
        if !d.pendingInvitationsPreview.isEmpty {
            Section {
                ForEach(d.pendingInvitationsPreview) { inv in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .foregroundStyle(Theme.Tint.info)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inv.code)
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(Theme.Text.primary)
                            Text(inviteUsageLabel(inv))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                        Spacer()
                        if let exp = inv.expiresAt {
                            Text(exp.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
            } header: {
                Text("Invitaciones activas (\(d.pendingInvitationsPreview.count))")
            }
        }

        let moreSections = d.sections.filter {
            $0.visible && moreSectionKeys.contains($0.sectionKey)
        }
        Section {
            if moreSections.isEmpty {
                Label("Sin más secciones", systemImage: "ellipsis.circle")
                    .foregroundStyle(Theme.Text.secondary)
            } else {
                ForEach(moreSections) { section in
                    NavigationLink {
                        moreSectionDestination(section.sectionKey)
                    } label: {
                        Label(section.displayName, systemImage: section.icon ?? "circle")
                    }
                }
            }
        } header: {
            Text("Secciones")
        }

        if !d.permissions.isEmpty {
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(d.permissions, id: \.self) { p in
                            chipBadge(p, tint: .purple)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } header: {
                Text("Mis permisos (\(d.permissions.count))")
            }
        }
    }

    private func inviteUsageLabel(_ inv: ContextInvitePreview) -> String {
        if let max = inv.maxUses {
            return "\(inv.usedCount) / \(max) usos"
        }
        return "\(inv.usedCount) usos · ilimitado"
    }

    @ViewBuilder
    private func moreSectionDestination(_ sectionKey: String) -> some View {
        switch sectionKey {
        case "calendar":   ContextCalendarView(context: context, container: container)
        case "governance": DecisionsListView(context: context, container: container)
        case "documents":  ContextDocumentsListView(context: context, container: container)
        case "activity":   ActivityFeedView(context: context, container: container)
        case "settings":   ContextSettingsView(context: context, container: container)
        default:           ActivityFeedView(context: context, container: container)
        }
    }

    // MARK: - Chips (helper compartido)

    @ViewBuilder
    private func chipBadge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 2)
            .background(tint.opacity(0.15), in: Capsule())
    }
}
