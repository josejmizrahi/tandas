import SwiftUI

// MARK: - Convenience inits sobre `Group`
//
// DS v3 §3.11/3.12/3.13: los componentes multi-group toman params explícitos
// para que funcionen en V1 antes que el backend (00036) los populate. Ahora
// que `Group` tiene `category`/`initials`/`avatarURL`, exponemos inits que
// aceptan `Group` directo.

extension RuulGroupAvatar {
    init(group: Group, size: Size = .md) {
        self.init(
            groupName: group.name,
            initials: group.initials,
            category: group.category,
            imageURL: group.avatarURL,
            size: size
        )
    }
}

extension RuulOriginTag {
    init(group: Group) {
        self.init(
            groupName: group.name,
            initials: group.initials,
            category: group.category
        )
    }
}

extension RuulGroupSwitcher {
    init(activeGroup: Group, onTap: @escaping () -> Void) {
        self.init(
            activeGroupName: activeGroup.name,
            activeCategory: activeGroup.category,
            activeInitials: activeGroup.initials,
            onTap: onTap
        )
    }
}

extension RuulGroupSwitcherSheet.GroupItem {
    init(group: Group) {
        self.init(
            id: group.id,
            name: group.name,
            initials: group.initials,
            category: group.category,
            imageURL: group.avatarURL
        )
    }
}
