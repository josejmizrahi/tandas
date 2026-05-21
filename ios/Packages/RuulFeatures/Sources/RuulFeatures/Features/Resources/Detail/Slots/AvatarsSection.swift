//
//  AvatarsSection.swift
//  ResourceKit
//
//  Horizontal stack of overlapping avatars + total count. Empty state
//  shows three placeholder circles with a "+". Tapping opens the full
//  participant directory.
//

import SwiftUI
import RuulUI

// MARK: Avatars

struct AvatarsSection: View {
    let title: String
    let people: [Person]
    let emptyText: String?
    let accent: Color
    let onTapMore: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.s2) {
            SectionHeader(title: title)

            Button(action: { onTapMore?() }) {
                HStack(spacing: RuulSpacing.s3) {
                    if people.isEmpty {
                        HStack(spacing: -10) {
                            ForEach(0..<3, id: \.self) { _ in
                                Circle()
                                    .fill(Color.ruulSurfaceGlassThin)
                                    .frame(width: 30, height: 30)
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(Color.ruulTextTertiary)
                                    )
                                    .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                            }
                        }
                        Text(emptyText ?? "Aún nadie")
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextSecondary)
                    } else {
                        HStack(spacing: -10) {
                            ForEach(people.prefix(3)) { person in
                                AvatarView(person: person)
                            }
                            if people.count > 3 {
                                Circle()
                                    .fill(Color.ruulSurfaceGlassThin)
                                    .frame(width: 30, height: 30)
                                    .overlay(Text("+\(people.count - 3)").font(.caption2.weight(.bold)).foregroundStyle(Color.ruulTextSecondary))
                                    .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
                            }
                        }
                        Text("\(people.count) \(people.count == 1 ? "persona" : "personas")")
                            .font(.subheadline)
                            .foregroundStyle(Color.ruulTextSecondary)
                    }

                    Spacer(minLength: 8)

                    if onTapMore != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.ruulTextTertiary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, RuulSpacing.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onTapMore == nil)
            .background(Color.ruulSurface)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        }
    }
}

struct AvatarView: View {
    let person: Person

    var body: some View {
        Group {
            if let url = person.imageURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 30, height: 30)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.ruulSurface, lineWidth: 2))
    }

    private var fallback: some View {
        person.color
            .overlay(
                Text(person.initials)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
            )
    }
}
