import SwiftUI

/// Chip mostrado dentro de un `RuulDetailHero`. Rico lo suficiente para todos
/// los heros de la app: texto simple, símbolo SF opcional, tint opcional por
/// chip (si es `nil` hereda el tint del hero) y una cuenta regresiva viva
/// opcional (`Text(_:style:.relative)` se auto-actualiza sin timers).
///
/// `ExpressibleByStringLiteral` → los call sites existentes pueden seguir
/// pasando `chips: ["3 miembros", "Admin"]` sin cambios.
public struct RuulHeroChip {
    public var text: String
    public var symbol: String?
    public var tint: Color?
    public var countdownTo: Date?

    public init(
        _ text: String,
        symbol: String? = nil,
        tint: Color? = nil,
        countdownTo: Date? = nil
    ) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.countdownTo = countdownTo
    }
}

extension RuulHeroChip: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// R.5V.2 — **El componente más reusado de Ruul.** Single source para el top
/// de TODA Detail View (Context, Resource, Document, Decision, Event, Obligation,
/// Rule, Actor).
///
/// Founder firma 2026-06-07: *"Context/Resource/Document/Decision Detail van
/// a terminar necesitando el mismo encabezado."*
///
/// **R.17 (founder 2026-07-09)** — hero PLANO, mismo lenguaje que el hero de
/// Dinero: sin card/glass flotante, el tint vive sólo en el icon badge, la
/// jerarquía la carga la tipografía sobre el fondo agrupado.
///
/// Doctrina UX §0.2 Patrón Detail: Hero es la PRIMERA sección visual
/// (antes de Attention/Widgets/Sections/Actions/Activity).
///
/// Best practices Apple (HIG) aplicadas:
/// - Icono como *symbol badge*: círculo de 56pt con símbolo ~26pt renderizado
///   `.hierarchical` (proporción ~46% que Apple usa en sus badges — el símbolo
///   respira dentro del círculo, no lo desborda).
/// - `.title2.bold` para el título (peso de encabezado consistente).
/// - Chips heredan el tint del hero salvo override explícito.
///
/// Estructura (`alignment: .leading`, default):
/// ```
/// [icon]  Title                          [status]
///         Subtitle · Subtitle
///         [chip] [chip] [chip]
///         <accessory>
/// ```
/// Con `alignment: .center` (p.ej. Decision) el bloque se apila y centra.
public struct RuulDetailHero<Accessory: View>: View {
    public let title: String
    public let subtitle: String?
    public let systemImage: String
    public let tint: Color
    public let status: RuulStatusBadge.State?
    public let chips: [RuulHeroChip]
    public let alignment: HorizontalAlignment
    @ViewBuilder public let accessory: () -> Accessory

    public init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = Theme.Tint.primary,
        status: RuulStatusBadge.State? = nil,
        chips: [RuulHeroChip] = [],
        alignment: HorizontalAlignment = .leading,
        @ViewBuilder accessory: @escaping () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.status = status
        self.chips = chips
        self.alignment = alignment
        self.accessory = accessory
    }

    public var body: some View {
        VStack(alignment: alignment, spacing: Theme.Spacing.md) {
            header
            if !chips.isEmpty {
                chipRow
            }
            accessory()
        }
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }

    // MARK: - Icon badge (symbol badge, Apple HIG)

    private var iconBadge: some View {
        Image(systemName: systemImage)
            .font(.system(size: 26, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .background(tint.badgeFill, in: Circle())
    }

    // MARK: - Header (leading vs centered)

    @ViewBuilder
    private var header: some View {
        if alignment == .center {
            VStack(spacing: Theme.Spacing.sm) {
                iconBadge
                Text(title)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Theme.Text.primary)
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.Text.secondary)
                        .multilineTextAlignment(.center)
                }
                if let status {
                    RuulStatusBadge(status)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                iconBadge
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(2)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let status {
                    RuulStatusBadge(status)
                }
            }
        }
    }

    // MARK: - Chips

    @ViewBuilder
    private var chipRow: some View {
        if alignment == .center {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(chips.enumerated()), id: \.offset) { chipView($0.element) }
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { chipView($0.element) }
                }
            }
        }
    }

    private func chipView(_ chip: RuulHeroChip) -> some View {
        let chipTint = chip.tint ?? tint
        return HStack(spacing: Theme.Spacing.xs) {
            if let symbol = chip.symbol {
                Image(systemName: symbol)
                    .font(.caption.weight(.semibold))
            }
            if let date = chip.countdownTo {
                let prefix = chip.text.isEmpty ? "" : "\(chip.text) "
                Text("\(prefix)\(date, style: .relative)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                Text(chip.text)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(chipTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipTint.badgeFillSubtle, in: Capsule())
    }
}

// MARK: - Hero row treatment

public extension View {
    /// R.17.1 (founder 2026-07-09: *"no me gusta cómo se ve así plano"*) — fila
    /// de List para un `RuulDetailHero`. Usa la **celda agrupada nativa**
    /// (fondo `secondarySystemGrouped`, la tarjeta redondeada de una List
    /// `.insetGrouped`) con los insets por defecto del sistema: es el patrón de
    /// Ajustes/Contactos de Apple — le da cuerpo y profundidad sin glass custom.
    ///
    /// Clave: **NO** fija `listRowBackground` (por eso aparece la tarjeta) ni
    /// aplasta los insets — deja respirar el contenido como cualquier celda
    /// nativa.
    func ruulHeroRow() -> some View {
        self.listRowSeparator(.hidden)
    }
}

// MARK: - Convenience init (sin accessory)

public extension RuulDetailHero where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = Theme.Tint.primary,
        status: RuulStatusBadge.State? = nil,
        chips: [RuulHeroChip] = [],
        alignment: HorizontalAlignment = .leading
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage,
            tint: tint,
            status: status,
            chips: chips,
            alignment: alignment,
            accessory: { EmptyView() }
        )
    }
}

#Preview {
    List {
        Section {
            RuulDetailHero(
                title: "Casa Valle",
                subtitle: "Vacation Home · Familia Mizrahi",
                systemImage: "house.fill",
                tint: Theme.Tint.success,
                status: .active,
                chips: ["Reservable", "Asegurable", "Documentable"]
            )
            .ruulHeroRow()
        }
        Section {
            RuulDetailHero(
                title: "Contrato de arrendamiento",
                subtitle: "Recibo · Subido hace 3 días",
                systemImage: "doc.text.fill",
                tint: Theme.Tint.info,
                status: .archived
            )
            .ruulHeroRow()
        }
        Section {
            RuulDetailHero(
                title: "Cambiar la fecha del viaje",
                subtitle: "¿Movemos la salida a diciembre?",
                systemImage: "checkmark.seal.fill",
                tint: Theme.Tint.primary,
                chips: [
                    RuulHeroChip("Abierta", symbol: "clock.fill", tint: .yellow),
                    RuulHeroChip("Cierra", symbol: "clock", tint: .orange, countdownTo: Date().addingTimeInterval(3600)),
                    RuulHeroChip("2 de 4 votos", symbol: "person.badge.clock", tint: .blue)
                ],
                alignment: .center
            )
            .ruulHeroRow()
        }
    }
    .listStyle(.insetGrouped)
}
