import SwiftUI
import RuulCore

/// R.10.F.10.d — Capabilities como Section dedicada (movido del Hero).
///
/// Hasta F.10.c las capabilities vivían en un `ScrollView` horizontal dentro
/// del Hero, ocupando ~50pt de altura prominente para info que es esencialmente
/// metadata ("qué puede hacer este recurso"). El audit R.10.F.0 D2 lo marcó
/// como density debt.
///
/// Mejor práctica iOS (App Store / Apple Music): la identidad del recurso vive
/// en el Hero (icon + nombre + 1 chip subtype + status badge). El detalle de
/// features queda en una Section dedicada accesible vía scroll.
///
/// Cada row es Button → alerta con descripción (existing UX behavior — sólo
/// cambia el layout, no la interacción).
struct ResourceDetailV2CapabilitiesSection: View {
    let capabilities: [String]
    @Binding var explainedCapability: String?

    var body: some View {
        if !capabilities.isEmpty {
            Section {
                ForEach(capabilities, id: \.self) { cap in
                    Button {
                        explainedCapability = cap
                    } label: {
                        HStack {
                            Text(ResourceDetailV2CapabilityCatalog.displayName(cap))
                                .foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Image(systemName: "info.circle")
                                .font(.caption)
                                .foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
            } header: {
                Text("Capacidades")
            }
        }
    }
}
