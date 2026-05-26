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
        // 2026-05-25 v3 (founder ref 2 form-label style): small footnote
        // in secondary gray, title case (NOT uppercase), no chrome. Matches
        // iOS form labels — "Nombre", "Frecuencia", "Día", "Hora" — sitting
        // quietly above their content pill. Previous `.subheadline secondary`
        // read too prominent against the new translucent card chrome.
        Text(title)
            .font(.footnote)
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, RuulSpacing.xxs)
            .padding(.bottom, RuulSpacing.xxs)
    }
}
