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
                // FASE 3 D.4: state pill changes animan, no aparecen.
                // Cuando Fine flippa de "$X por pagar" a "Pagaste" /
                // "Pagada por X", el label morph debe sentirse alive,
                // no abrupto. `.opacity` cubre transitions textuales;
                // value mantiene `.numericText()` para morph numérico.
                .contentTransition(.opacity)

            if let subRow = data.subRow, !subRow.isEmpty {
                HStack(spacing: RuulSpacing.lg) {
                    ForEach(subRow) { pair in
                        HStack(spacing: RuulSpacing.xxs) {
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
        .padding(.vertical, RuulSpacing.xs)
        .animation(.snappy(duration: 0.28), value: data.label)
        .animation(.snappy(duration: 0.28), value: data.value)
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
