//
//  HeroSlot.swift
//  ResourceKit
//
//  Big-number hero block. Either `.display` (42pt — fund balances, fine
//  amounts) or `.title` (30pt — dates, status labels). Optional sub-row
//  underneath shows paired key/value chips ("Aportado · $0").
//

import SwiftUI
import RuulUI

// MARK: Hero

struct HeroSlot: View {
    let data: HeroData

    var body: some View {
        VStack(spacing: RuulSpacing.micro) {
            Text(data.value)
                .font(heroFont)
                .fontWeight(.bold)
                .contentTransition(.numericText())
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)

            Text(data.label)
                .font(.footnote)
                .foregroundStyle(Color.ruulTextSecondary)
                .multilineTextAlignment(.center)

            if let subRow = data.subRow, !subRow.isEmpty {
                HStack(spacing: RuulSpacing.s5) {
                    ForEach(subRow) { pair in
                        HStack(spacing: RuulSpacing.s1) {
                            Text(pair.label)
                                .foregroundStyle(Color.ruulTextSecondary)
                            Text(pair.value)
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, RuulSpacing.micro)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, RuulSpacing.s2)
    }

    /// Maps the hero `size` enum onto the app's native typography scale —
    /// no `.system(size:)` overrides, no `.fontDesign(.rounded)`. Dynamic
    /// Type and the system design just work.
    private var heroFont: Font {
        switch data.size {
        case .display: return .largeTitle
        case .title:   return .title
        }
    }
}
