//
//  ActivityStates.swift
//  ResourceKit
//
//  Empty / Error / Skeleton states for the activity timeline. All three
//  share the same `ruulSurface` rounded-rect wrapper so they snap into
//  the same visual slot regardless of phase.
//

import SwiftUI
import RuulUI

struct ActivityEmptyView: View {
    var body: some View {
        ContentUnavailableView(
            "Sin actividad aún",
            systemImage: "clock.arrow.circlepath",
            description: Text("Las acciones aparecerán aquí.")
        )
        .frame(maxWidth: .infinity)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }
}

struct ActivityErrorView: View {
    let message: String
    let accent: Color
    let retry: () -> Void

    var body: some View {
        VStack(spacing: RuulSpacing.s4) {
            ContentUnavailableView(
                "No pudimos cargar la actividad",
                systemImage: "exclamationmark.triangle.fill",
                description: Text(message)
            )

            Button(action: retry) {
                Label("Reintentar", systemImage: "arrow.clockwise")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.glass)
            .tint(accent)
            .padding(.bottom, RuulSpacing.s6)
        }
        .frame(maxWidth: .infinity)
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
    }
}

struct ActivitySkeletonView: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        VStack(spacing: RuulSpacing.s0) {
            ForEach(0..<3, id: \.self) { i in
                HStack(spacing: RuulSpacing.s3) {
                    Circle().fill(Color.ruulSurfaceGlassThin).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: RuulSpacing.micro) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ruulSurfaceGlassThin)
                            .frame(height: 12).frame(maxWidth: 180)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.ruulSurfaceGlassThin)
                            .frame(height: 9).frame(maxWidth: 80)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, RuulSpacing.s3)
                if i < 2 { Divider().padding(.leading, 36) }
            }
        }
        .background(Color.ruulSurface)
        .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md, style: .continuous))
        .redacted(reason: .placeholder)
    }
}
