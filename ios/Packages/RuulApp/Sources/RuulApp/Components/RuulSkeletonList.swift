import SwiftUI

/// P2.2 — skeleton de carga para listas: filas placeholder con `redacted` y
/// shimmer sutil vía opacidad pulsante. Drop-in para el branch `.loading`
/// de las pantallas calientes (en vez del spinner centrado, el usuario ve
/// la silueta del contenido que viene).
public struct RuulSkeletonList: View {
    let rows: Int

    @State private var pulse = false

    public init(rows: Int = 6) {
        self.rows = rows
    }

    public var body: some View {
        List {
            Section {
                ForEach(0..<rows, id: \.self) { _ in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color(uiColor: .systemGray4))
                            .frame(width: 36, height: 36)
                        VStack(alignment: .leading, spacing: 6) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(uiColor: .systemGray4))
                                .frame(width: 180, height: 12)
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color(uiColor: .systemGray5))
                                .frame(width: 110, height: 9)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .listStyle(.insetGrouped)
        .redacted(reason: .placeholder)
        .opacity(pulse ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
        .accessibilityLabel("Cargando…")
        .allowsHitTesting(false)
    }
}

#Preview("Skeleton") {
    RuulSkeletonList()
}
