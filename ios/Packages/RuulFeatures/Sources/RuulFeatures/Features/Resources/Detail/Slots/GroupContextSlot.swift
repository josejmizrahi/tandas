//
//  GroupContextSlot.swift
//  ResourceKit
//
//  Subtle Liquid Glass card rendered under the identity ribbon so the
//  viewer always sees which group originated the resource ("En {Group} ·
//  Propuesto por {x}"). Drives the Founder doctrine "no orphan resource".
//

import SwiftUI
import RuulUI

// MARK: GroupContextSlot

/// Subtle Liquid Glass card showing the parent group + provenance.
/// Drives the "no orphan resource" doctrine: tapping lifts the viewer
/// out of the resource and into the group surface that owns it.
///
/// Visual treatment is **fase 1 doctrine** — `.ruulGlass(.thin)` for the
/// blur+depth surface (auto fallback to `ruulSurface` under reduce-
/// transparency) and design system color tokens for every fill / text
/// (no hardcoded `.indigo` / `.purple` / `.primary` / `.tertiary`).
struct GroupContextSlot: View {
    let data: GroupContextData

    @State private var tapTick: Int = 0

    var body: some View {
        Button(action: {
            tapTick &+= 1
            data.onTapGroup()
        }) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.ruulAccentMuted)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(data.groupInitials)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.ruulAccent)
                    )

                contextText
                    .font(.footnote)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.ruulTextTertiary)
            }
            .padding(.horizontal, RuulSpacing.sm)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .ruulGlass(
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous),
            material: .thin,
            interactive: true
        )
        .sensoryFeedback(.selection, trigger: tapTick)
    }

    private var contextText: Text {
        var t = Text("En ").foregroundColor(Color.ruulTextSecondary)
            + Text(data.groupName).fontWeight(.semibold).foregroundColor(Color.ruulTextPrimary)
        if let by = data.proposedBy {
            t = t
                + Text(" · Propuesto por ").foregroundColor(Color.ruulTextSecondary)
                + Text(by).fontWeight(.semibold).foregroundColor(Color.ruulTextPrimary)
        }
        if let at = data.proposedAt {
            t = t
                + Text(" ").foregroundColor(Color.ruulTextSecondary)
                + Text(at, style: .relative).foregroundColor(Color.ruulTextTertiary)
        }
        return t
    }
}
