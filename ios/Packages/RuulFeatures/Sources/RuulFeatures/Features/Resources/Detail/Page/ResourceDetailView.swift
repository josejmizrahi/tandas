//
//  ResourceDetailView.swift
//  ResourceKit
//
//  Sistema universal para mostrar el detalle de cualquier recurso
//  (Evento, Fondo, Espacio, Documento, Votación, etc.) con UI consistente
//  siguiendo las prácticas de Apple iOS 26 (Liquid Glass, jerarquía clara,
//  empty states correctos, paginación nativa).
//
//  ARQUITECTURA
//  ────────────
//  Tres niveles:
//
//  1. Shell universal (toolbar, scroll, fondo, padding) → NUNCA se reimplementa
//  2. Slots estándar (Identity, Hero, Actions, Sections, Activity) → 90% de casos
//  3. Escape hatch .custom(AnyView) → 10% de casos especiales
//
//  Cada tipo de recurso declara UNA función estática que devuelve un
//  `ResourceConfig`. El componente universal renderiza esa config.
//
//  USO BÁSICO
//  ──────────
//  ResourceDetailView(config: .event(myEvent))
//  ResourceDetailView(config: .fund(myFund))
//  ResourceDetailView(config: .space(mySpace))
//
//  PARA AGREGAR UN RECURSO NUEVO
//  ─────────────────────────────
//  1. Definí el modelo (struct MyResource) en `Factories/ResourceConfig+MyResource.swift`.
//  2. Agregá `static func myResource(_ r: MyResource) -> ResourceConfig`
//     en `extension ResourceConfig` en el mismo archivo.
//  3. Si necesitás un slot que no existe, usá .custom(AnyView(...)).
//  4. Si el .custom se repite en 3+ recursos, promovelo a slot estándar
//     agregando un caso al enum ResourceSection en `Models/ResourceConfig.swift`
//     y un nuevo archivo en `Slots/`.
//
//  ESTRUCTURA DEL MÓDULO
//  ─────────────────────
//  Detail/
//    Page/ResourceDetailView.swift     ← este archivo (shell)
//    Models/ResourceConfig.swift       ← API pública
//    Slots/                            ← Identity, GroupContext, Hero, Actions,
//                                        SectionSlot (+ Rows), Map, Avatars,
//                                        Empty (+ Custom + SectionHeader)
//    Activity/                         ← Slot, ViewModel, GroupedTimeline,
//                                        ActivityStates (Empty/Error/Skeleton)
//    Factories/                        ← ResourceConfig+Event/Fund/Vote/Fine/Space
//    Previews/                         ← #Preview blocks
//

import SwiftUI
import RuulUI

// MARK: ════════════════════════════════════════════════════════════════════
// MARK: SHELL UNIVERSAL
// MARK: ════════════════════════════════════════════════════════════════════

public struct ResourceDetailView: View {
    let config: ResourceConfig

    @Environment(\.dismiss) private var dismiss

    public init(config: ResourceConfig) {
        self.config = config
    }

    public var body: some View {
        NavigationStack {
            ResourceDetailContent(config: config)
                .navigationTitle(config.identity.typeLabel)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cerrar") { dismiss() }
                    }
                    if !config.toolbarMenu.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                ForEach(config.toolbarMenu) { item in
                                    Button(role: item.role, action: item.handler) {
                                        Label(item.label, systemImage: item.icon)
                                    }
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                        }
                    }
                }
        }
    }
}

/// Embeddable body — same content as `ResourceDetailView` but without the
/// NavigationStack/toolbar wrapper. Use when the host already owns the
/// navigation chrome (e.g. `EventDetailHost` wraps in its own `.ruulSheetToolbar`).
public struct ResourceDetailContent: View {
    let config: ResourceConfig

    public init(config: ResourceConfig) {
        self.config = config
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.s0) {
                IdentitySlot(data: config.identity, accent: config.accent)
                    .padding(.horizontal, RuulSpacing.s5)
                    .padding(.top, RuulSpacing.s2)

                if let ctx = config.groupContext {
                    GroupContextSlot(data: ctx)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s3)
                }

                if let hero = config.hero {
                    HeroSlot(data: hero)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s3)
                }

                if !config.actions.isEmpty {
                    ActionsSlot(actions: config.actions, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s4)
                }

                ForEach(config.sections) { section in
                    SectionSlot(section: section, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                }

                if let moneyCtx = config.moneyContext {
                    ResourceMoneySlot(context: moneyCtx)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                }

                if let activity = config.activity {
                    ActivitySlot(source: activity, accent: config.accent)
                        .padding(.horizontal, RuulSpacing.s5)
                        .padding(.top, RuulSpacing.s5)
                }

                Color.clear.frame(height: 32)
            }
        }
        .background(Color.ruulBackgroundRecessed)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .tint(config.accent)
    }
}
