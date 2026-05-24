//
//  EmptySection.swift
//  ResourceKit
//
//  Three small pieces that travel together: the in-section empty state
//  (built on `ContentUnavailableView`), the `.custom(AnyView)` escape
//  hatch, and the shared `SectionHeader` used by every section type.
//

import SwiftUI
import RuulUI

// MARK: Empty (within section)

struct EmptySection: View {
    let title: String
    let icon: String
    let message: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            SectionHeader(title: title)

            ContentUnavailableView(
                message,
                systemImage: icon,
                description: Text(description)
            )
            .frame(maxWidth: .infinity)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

// MARK: Custom (escape hatch)

struct CustomSection: View {
    let title: String?
    let content: AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            if let title { SectionHeader(title: title) }
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.ruulSurface)
                .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

// MARK: Section header (reusable)

struct SectionHeader: View {
    let title: String
    var body: some View {
        // V2 cherry-pick: iOS-26-native grouped-list header — title case,
        // subheadline, secondary. Replaces the older all-caps + tracking
        // variant which read as a print convention rather than as Apple's
        // native section style.
        Text(title)
            .font(.subheadline)
            .foregroundStyle(Color.ruulTextSecondary)
            .padding(.horizontal, RuulSpacing.xxs)
    }
}
