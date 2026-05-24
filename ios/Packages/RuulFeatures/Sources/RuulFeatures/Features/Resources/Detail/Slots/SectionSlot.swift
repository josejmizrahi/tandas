//
//  SectionSlot.swift
//  ResourceKit
//
//  Dispatcher view that renders a `ResourceSection` enum case to its
//  concrete view (RowsSection / MapSection / AvatarsSection / EmptySection
//  / CustomSection). Plus the inline rows section + row view since they're
//  the most common section type and rarely used without each other.
//

import SwiftUI
import RuulUI

// MARK: Section dispatcher

struct SectionSlot: View {
    let section: ResourceSection
    let accent: Color

    var body: some View {
        switch section {
        case .rows(let title, let items):
            RowsSection(title: title, items: items, accent: accent)
        case .map(let title, let location):
            MapSection(title: title, location: location, accent: accent)
        case .avatars(let title, let people, let emptyText, let onTapMore):
            AvatarsSection(title: title, people: people, emptyText: emptyText, accent: accent, onTapMore: onTapMore)
        case .empty(let title, let icon, let message, let description):
            EmptySection(title: title, icon: icon, message: message, description: description)
        case .custom(_, let title, let content):
            CustomSection(title: title, content: content)
        }
    }
}

// MARK: Rows

struct RowsSection: View {
    let title: String
    let items: [RowItem]
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            SectionHeader(title: title)

            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    RowView(item: item, accent: accent)
                    if index < items.count - 1 {
                        Divider().padding(.leading, item.icon != nil ? 46 : 14)
                    }
                }
            }
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

struct RowView: View {
    let item: RowItem
    let accent: Color

    var body: some View {
        Button(action: { item.onTap?() }) {
            HStack(spacing: 10) {
                if let icon = item.icon {
                    Image(systemName: icon)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(accent)
                        .frame(width: 22)
                }

                Text(item.label)
                    .font(.subheadline)
                    .foregroundStyle(Color.ruulTextPrimary)

                Spacer(minLength: 8)

                switch item.value {
                case .text(let value):
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                case .link(let value):
                    HStack(spacing: RuulSpacing.xxs) {
                        Text(value)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(accent)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                case .toggle(let binding):
                    Toggle(item.label, isOn: binding)
                        .labelsHidden()
                        .tint(accent)
                        .accessibilityLabel(item.label)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, RuulSpacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(item.onTap == nil && !isInteractive)
    }

    private var isInteractive: Bool {
        if case .toggle = item.value { return true }
        if case .link = item.value { return true }
        return false
    }
}
