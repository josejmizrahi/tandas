import SwiftUI
import RuulUI
import RuulCore

// MARK: - Convenience inits sobre `RuulCore.Group`
//
// DS v3 §3.11/3.12/3.13: los componentes multi-group toman params explícitos
// para que funcionen en V1 antes que el backend (00036) los populate. Ahora
// que `RuulCore.Group` tiene `category`/`initials`/`avatarURL`, exponemos inits que
// aceptan `RuulCore.Group` directo.

extension RuulGroupAvatar {
    init(group: RuulCore.Group, size: Size = .md) {
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
    init(group: RuulCore.Group) {
        self.init(
            groupName: group.name,
            initials: group.initials,
            category: group.category
        )
    }
}

extension RuulGroupSwitcher {
    init(activeGroup: RuulCore.Group, onTap: @escaping () -> Void) {
        self.init(
            activeGroupName: activeGroup.name,
            activeCategory: activeGroup.category,
            activeInitials: activeGroup.initials,
            onTap: onTap
        )
    }
}

extension RuulGroupSwitcherSheet.GroupItem {
    init(group: RuulCore.Group) {
        self.init(
            id: group.id,
            name: group.name,
            initials: group.initials,
            category: group.category,
            imageURL: group.avatarURL
        )
    }
}
