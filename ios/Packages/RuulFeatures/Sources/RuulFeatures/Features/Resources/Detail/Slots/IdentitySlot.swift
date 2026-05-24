//
//  IdentitySlot.swift
//  ResourceKit
//
//  Identity ribbon at the top of every resource detail: icon tile, title,
//  subtitle (typeLabel + metadata joined by " · "), optional badge.
//

import SwiftUI
import RuulUI

// MARK: Identity

struct IdentitySlot: View {
    let data: IdentityData
    let accent: Color

    var body: some View {
        HStack(spacing: RuulSpacing.sm) {
            RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous)
                .fill(accent.opacity(0.15))
                .frame(width: 56, height: 56)
                .overlay(
                    Image(systemName: data.iconSystemName)
                        .font(.title.weight(.medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(data.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)

                HStack(spacing: RuulSpacing.micro) {
                    Text(subtitleSegments.joined(separator: " · "))
                        .font(.footnote)
                        .foregroundStyle(Color.ruulTextSecondary)
                        .lineLimit(1)

                    if let badge = data.badge {
                        BadgeView(badge: badge)
                    }
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Joins `[typeLabel] + metadata` while filtering out any metadata
    /// entry that already equals `typeLabel` (case-insensitive). Prevents
    /// the "Fondo · Fondo" duplication seen when block builders push the
    /// resource family label into `subtitleSegments`.
    private var subtitleSegments: [String] {
        let label = data.typeLabel.trimmingCharacters(in: .whitespaces)
        let extras = data.metadata.filter {
            !$0.trimmingCharacters(in: .whitespaces)
                .caseInsensitiveEquivalent(label)
        }
        return label.isEmpty ? extras : [label] + extras
    }
}

private extension String {
    func caseInsensitiveEquivalent(_ other: String) -> Bool {
        compare(other, options: .caseInsensitive) == .orderedSame
    }
}

struct BadgeView: View {
    let badge: ResourceBadge

    var body: some View {
        Text(badge.text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(badge.color)
            .padding(.horizontal, RuulSpacing.xs)
            .padding(.vertical, RuulSpacing.s0_5)
            .background(badge.color.opacity(0.15), in: Capsule())
    }
}
