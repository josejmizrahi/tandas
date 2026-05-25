import SwiftUI
import RuulUI

/// Cold-start placeholder for the GroupSpace. V4 fix (2026-05-25):
/// reemplaza el `ProgressView` genérico del AsyncContentView con un
/// skeleton que insinúa la estructura real del home — header de
/// presence + 3 cluster cards. Apple Health / Luma pattern: el usuario
/// percibe "estoy entrando a un lugar específico" en vez de "estoy
/// esperando una API".
///
/// Usa `.redacted(reason: .placeholder)` para que SwiftUI aplique el
/// tratamiento canónico (shimmer en background, opacity reducida).
@MainActor
struct GroupSpaceSkeleton: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RuulSpacing.xl) {
                presenceHeaderShape
                ForEach(0..<3, id: \.self) { _ in
                    clusterCardShape
                }
            }
            .padding(.horizontal, RuulSpacing.lg)
            .padding(.top, RuulSpacing.lg)
        }
        .scrollDisabled(true)
        .redacted(reason: .placeholder)
        .accessibilityHidden(true)
    }

    private var presenceHeaderShape: some View {
        HStack(spacing: RuulSpacing.md) {
            Circle()
                .fill(Color(.tertiarySystemFill))
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: RuulSpacing.xs) {
                Text("Nombre del grupo")
                    .font(.title2.weight(.semibold))
                Text("8 personas")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
            }

            Spacer()
        }
    }

    private var clusterCardShape: some View {
        VStack(alignment: .leading, spacing: RuulSpacing.xs) {
            Text("Sección")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.leading, RuulSpacing.xxs)

            VStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { idx in
                    HStack(spacing: RuulSpacing.md) {
                        Circle()
                            .fill(Color(.tertiarySystemFill))
                            .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Línea principal de la fila")
                                .font(.subheadline.weight(.semibold))
                            Text("Línea secundaria")
                                .font(.caption)
                                .foregroundStyle(Color.secondary)
                        }
                        Spacer()
                    }
                    .padding(RuulSpacing.md)
                    if idx == 0 {
                        Divider()
                            .background(Color(.separator))
                            .padding(.leading, 64)
                    }
                }
            }
            .ruulCardSurface(.solid)
        }
    }
}
