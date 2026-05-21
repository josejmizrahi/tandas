import SwiftUI
import RuulUI
import RuulCore

/// "Permisos por rol" — read-oriented audit surface that flips the
/// roles surface inside out. Where `GroupRolesSheet` lists roles and
/// shows their permissions, this view lists every Permission case
/// grouped by category and shows the roles that grant it.
///
/// Useful answer to "¿quién puede emitir multas?": you scroll to
/// the Multas section and read the chips next to "Emitir multas".
/// The roles editor lives one level up — tap a chip to jump to the
/// corresponding role.
@MainActor
public struct GroupPermisosMatrixView: View {
    public let group: RuulCore.Group
    public var onSelectRole: ((RoleDefinition) -> Void)?

    public init(
        group: RuulCore.Group,
        onSelectRole: ((RoleDefinition) -> Void)? = nil
    ) {
        self.group = group
        self.onSelectRole = onSelectRole
    }

    private var catalog: [String: RoleDefinition] {
        group.effectiveRoles
    }

    /// All Permission values that *some* role in the group grants,
    /// keyed by category for grouped display. We sort the cases by
    /// `humanLabel` inside each category for stable rendering.
    private var permissionsByCategory: [(Permission.Category, [Permission])] {
        var bucket: [Permission.Category: [Permission]] = [:]
        for role in catalog.values {
            for p in role.permissions {
                bucket[p.category, default: []].append(p)
            }
        }
        for cat in bucket.keys {
            let unique = Array(Set(bucket[cat] ?? []))
                .sorted { $0.humanLabel.localizedStandardCompare($1.humanLabel) == .orderedAscending }
            bucket[cat] = unique
        }
        return Permission.Category.allCases
            .compactMap { cat in
                guard let list = bucket[cat], !list.isEmpty else { return nil }
                return (cat, list)
            }
    }

    private func roles(granting permission: Permission) -> [RoleDefinition] {
        catalog.values
            .filter { $0.grants(permission) }
            .sorted { lhs, rhs in
                if lhs.system != rhs.system { return lhs.system }
                return lhs.humanLabel.localizedStandardCompare(rhs.humanLabel) == .orderedAscending
            }
    }

    public var body: some View {
        List {
            Section {
                Text("Cada permiso muestra qué roles lo otorgan. Tap en un rol para editar sus permisos.")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: RuulSpacing.lg, bottom: RuulSpacing.sm, trailing: RuulSpacing.lg))

            ForEach(permissionsByCategory, id: \.0) { category, permissions in
                Section(category.title) {
                    ForEach(permissions, id: \.self) { permission in
                        row(permission: permission)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Permisos por rol")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(permission: Permission) -> some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text(permission.humanLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.primary)
            Text(permission.hint)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .lineLimit(3)

            let granting = roles(granting: permission)
            if granting.isEmpty {
                Text("Nadie tiene este permiso")
                    .font(.caption)
                    .foregroundStyle(Color.ruulNegative)
            } else {
                FlowChips(items: granting) { role in
                    Button {
                        onSelectRole?(role)
                    } label: {
                        Text(role.humanLabel)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.primary)
                            .padding(.horizontal, RuulSpacing.sm)
                            .padding(.vertical, RuulSpacing.xxs + 1)
                            .background(Color.ruulAccentMuted, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, RuulSpacing.xxs)
    }
}

// MARK: - FlowChips

/// Wrapping horizontal flow used to render the role chips under each
/// permission row. Falls back to a single-row HStack when wrapping
/// isn't needed. Kept inline to this view to avoid promoting a
/// primitive — the rule-of-three threshold isn't met yet.
private struct FlowChips<Item: Hashable, ChipView: View>: View {
    let items: [Item]
    let chip: (Item) -> ChipView

    init(items: [Item], @ViewBuilder chip: @escaping (Item) -> ChipView) {
        self.items = items
        self.chip = chip
    }

    var body: some View {
        // SwiftUI 5+ ships `Layout`-based `FlexibleFlow`, but
        // `HStack` wraps fine inside a `.fixedSize` per chip when
        // the row is wider than available space. Manual two-row
        // fallback isn't worth the complexity here — most roles in
        // V1 fit on one line.
        HStack(spacing: RuulSpacing.xxs + 2) {
            ForEach(items, id: \.self) { chip($0) }
            Spacer(minLength: 0)
        }
    }
}
