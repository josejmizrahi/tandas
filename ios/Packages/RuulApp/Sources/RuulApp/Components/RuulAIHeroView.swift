import SwiftUI
import RuulCore

/// R.6.AI.8 — Hero AI reusable para todas las vistas Create de Ruul.
///
/// Founder firmó propagación del patrón AI-first (R.6.AI.6/7) a todas las
/// vistas de creación: Decision, Obligation, Event, Reservation, Resource.
/// Este componente centraliza estructura visual + estados (idle/loading/
/// failed/unavailable) + chips de ejemplos + card de "datos considerados".
///
/// La vista consumidora controla:
/// - el `service` (cada feature tiene el suyo con su `@Generable` shape)
/// - los strings (headline, subtitle, placeholder, cta, examples)
/// - el `onSuggest` callback (que llama al service + aplica al form)
///
/// Patrón de uso:
/// ```swift
/// RuulAIHeroView(
///     headline: "Pídele a Ruul",
///     subtitle: "Describe la decisión y la armamos por ti",
///     placeholder: "Ej: ¿Compramos el coche nuevo?",
///     ctaLabel: "Pensar decisión",
///     examples: ["¿Cambiamos de día?", "¿Compramos coche?", ...],
///     prompt: $aiPromptText,
///     considered: $lastConsidered,
///     phase: heroPhase,  // mapped de tu service phase
///     onSuggest: { await suggest() },
///     onReset: { resetPrompt() }
/// )
/// ```
public struct RuulAIHeroView: View {
    /// Estados que el hero presenta. La vista mapea el `Phase` del service
    /// concreto a este enum (cada service tiene su propio Phase pero las
    /// fases visibles son siempre estas 4).
    public enum HeroPhase: Equatable {
        case idle
        case loading
        case unavailable(reason: String)
        case failed(message: String)
    }

    let headline: String
    let subtitle: String
    let placeholder: String
    let ctaLabel: String
    let examples: [String]
    let footerWhenIdle: String
    let footerWhenLoaded: String
    @Binding var prompt: String
    @Binding var considered: [RuulAIContext.Considered]
    let phase: HeroPhase
    let onSuggest: () async -> Void
    let onReset: () -> Void

    public init(
        headline: String,
        subtitle: String,
        placeholder: String,
        ctaLabel: String,
        examples: [String],
        footerWhenIdle: String,
        footerWhenLoaded: String,
        prompt: Binding<String>,
        considered: Binding<[RuulAIContext.Considered]>,
        phase: HeroPhase,
        onSuggest: @escaping () async -> Void,
        onReset: @escaping () -> Void
    ) {
        self.headline = headline
        self.subtitle = subtitle
        self.placeholder = placeholder
        self.ctaLabel = ctaLabel
        self.examples = examples
        self.footerWhenIdle = footerWhenIdle
        self.footerWhenLoaded = footerWhenLoaded
        self._prompt = prompt
        self._considered = considered
        self.phase = phase
        self.onSuggest = onSuggest
        self.onReset = onReset
    }

    public var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                heroHeadline
                heroPromptField
                examplePromptsRow
                aiActionRow
                if !considered.isEmpty, phase == .idle {
                    consideredSection
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            .listRowSeparator(.hidden)
        } footer: {
            footerView
        }
    }

    @ViewBuilder
    private var heroHeadline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.Text.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var heroPromptField: some View {
        TextField(placeholder, text: $prompt, axis: .vertical)
            .lineLimit(2...5)
            .textInputAutocapitalization(.sentences)
            .disabled(isDisabledForInput)
            .padding(12)
            .background(Theme.Background.secondary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var examplePromptsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(examples, id: \.self) { example in
                    Button {
                        prompt = example
                    } label: {
                        Text(example)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Theme.Tint.primary.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.Tint.primary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabledForInput)
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var aiActionRow: some View {
        switch phase {
        case .idle:
            Button {
                Task { await onSuggest() }
            } label: {
                Label(ctaLabel, systemImage: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Pensando…")
                    .font(.callout)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)

        case .unavailable:
            EmptyView()

        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.critical)
                Button {
                    Task { await onSuggest() }
                } label: {
                    Label("Reintentar", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private var consideredSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Datos considerados")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Text.tertiary)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    onReset()
                } label: {
                    Label("Pensar otro", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.medium))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Tint.primary)
            }
            ForEach(considered) { item in
                consideredChip(item)
            }
        }
        .padding(12)
        .background(Theme.Tint.info.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func consideredChip(_ item: RuulAIContext.Considered) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.symbol(for: item.id))
                .font(.caption2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Theme.Tint.info)
                .frame(width: 16, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.Text.primary)
                Text(item.summary)
                    .font(.caption2)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var footerView: some View {
        switch phase {
        case .unavailable(let reason):
            Label(reason, systemImage: "sparkles.slash")
                .symbolRenderingMode(.hierarchical)
                .font(.caption)
                .foregroundStyle(.secondary)
        default:
            if !considered.isEmpty {
                Text(footerWhenLoaded)
            } else {
                Text(footerWhenIdle)
            }
        }
    }

    private var isDisabledForInput: Bool {
        switch phase {
        case .loading: return true
        case .unavailable: return true
        default: return false
        }
    }

    public static func symbol(for id: String) -> String {
        switch id {
        case "members":      return "person.2.fill"
        case "resources":    return "shippingbox.fill"
        case "activity":     return "clock.arrow.circlepath"
        case "rules":        return "ruler.fill"
        case "obligations":  return "creditcard.fill"
        case "events":       return "calendar"
        default:             return "circle.dotted"
        }
    }
}
