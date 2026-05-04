#if DEBUG
import SwiftUI

struct PrimitivesShowcaseView: View {
    @State private var name = "Jose"
    @State private var otp = ""
    @State private var otpError = false
    @State private var sliderValue = 0.4
    @State private var selectedSegment: String = "Eventos"
    @State private var toggleOn = true
    @State private var pickedCadence: String = "weekly"
    @State private var date = Date()
    @State private var sheetPresented = false
    @State private var coverPresented = false
    @State private var toast: RuulToastModel?
    @State private var pickedTemplate: String = "dinner"

    var body: some View {
        ScrollView {
            VStack(spacing: RuulSpacing.s4) {
                buttonsSection
                textFieldSection
                otpSection
                cardSection
                progressSection
                avatarSection
                chipSection
                segmentedSection
                toggleSection
                pickerSection
                datePickerSection
                iconBadgeSection
                meshSection
                presentationSection
                toastSection
                templatePickerSection
                actionCardSection
                metricCardSection
                timelineSection
            }
            .padding(RuulSpacing.s5)
        }
        .background(Color.ruulBackgroundCanvas)
        .ruulToast($toast)
    }

    private var buttonsSection: some View {
        ShowcaseSection("RuulButton", subtitle: "5 styles × 3 sizes + loading + disabled") {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack {
                    RuulButton("Primary", style: .primary) {}
                    RuulButton("Secondary", style: .secondary) {}
                    RuulButton("Glass", style: .glass) {}
                }
                HStack {
                    RuulButton("Destructive", style: .destructive) {}
                    RuulButton("Plain", style: .plain) {}
                }
                RuulButton("Loading", isLoading: true, fillsWidth: true) {}
                RuulButton("Disabled") {}.disabled(true)
            }
        }
    }

    private var textFieldSection: some View {
        ShowcaseSection("RuulTextField") {
            VStack(spacing: RuulSpacing.s3) {
                RuulTextField("Tu nombre", text: $name, label: "Nombre")
                RuulTextField("Buscar", text: .constant(""), style: .search)
                RuulTextField("Email", text: .constant("bad@"), label: "Email", style: .email, error: "Email inválido")
            }
        }
    }

    private var otpSection: some View {
        ShowcaseSection("RuulOTPInput") {
            VStack(spacing: RuulSpacing.s3) {
                RuulOTPInput(code: $otp, hasError: $otpError)
                RuulButton("Trigger error", style: .secondary, size: .small) { otpError = true }
            }
        }
    }

    private var cardSection: some View {
        ShowcaseSection("RuulCard") {
            VStack(spacing: RuulSpacing.s3) {
                RuulCard(.glass) { Text("Glass card").ruulTextStyle(RuulTypography.body) }
                RuulCard(.solid) { Text("Solid card").ruulTextStyle(RuulTypography.body) }
                RuulCard(.outlined) { Text("Outlined card").ruulTextStyle(RuulTypography.body) }
            }
        }
    }

    private var progressSection: some View {
        ShowcaseSection("RuulProgressBar") {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                RuulProgressBar(value: sliderValue)
                RuulProgressBar(value: sliderValue, style: .steps(5))
                Slider(value: $sliderValue, in: 0...1).tint(Color.ruulAccentPrimary)
            }
        }
    }

    private var avatarSection: some View {
        ShowcaseSection("RuulAvatar / RuulAvatarStack") {
            VStack(alignment: .leading, spacing: RuulSpacing.s3) {
                HStack {
                    RuulAvatar(name: "Jose", size: .small)
                    RuulAvatar(name: "Ana", size: .medium)
                    RuulAvatar(name: "Ben", size: .large)
                    RuulAvatar(name: "Carla", size: .hero)
                }
                let people = (1...8).map { RuulAvatarStack.Person(id: "\($0)", name: "P\($0)") }
                RuulAvatarStack(people: people, maxVisible: 5)
            }
        }
    }

    private var chipSection: some View {
        ShowcaseSection("RuulChip") {
            HStack {
                RuulChip("Selectable", style: .selectable(isSelected: true))
                RuulChip("Count", style: .count(4))
                RuulChip("Removable", style: .removable)
                RuulChip("Sugerencia", systemImage: "sparkles", style: .suggestion)
            }
        }
    }

    private var segmentedSection: some View {
        ShowcaseSection("RuulSegmentedControl") {
            RuulSegmentedControl(
                selection: $selectedSegment,
                segments: [("Eventos", "Eventos"), ("Reglas", "Reglas"), ("Multas", "Multas")]
            )
        }
    }

    private var toggleSection: some View {
        ShowcaseSection("RuulToggle") {
            VStack(spacing: RuulSpacing.s2) {
                RuulToggle("Notificaciones", isOn: $toggleOn)
                RuulToggle("Auto-RSVP", isOn: .constant(false), description: "Confirma automáticamente.")
            }
        }
    }

    private var pickerSection: some View {
        ShowcaseSection("RuulPicker") {
            RuulPicker(selection: $pickedCadence, options: [
                .init(value: "weekly", label: "Semanal", subtitle: "Cada miércoles"),
                .init(value: "biweekly", label: "Quincenal"),
                .init(value: "monthly", label: "Mensual")
            ])
        }
    }

    private var datePickerSection: some View {
        ShowcaseSection("RuulDatePicker") {
            VStack(spacing: RuulSpacing.s3) {
                RuulDatePicker("Fecha", date: $date)
                RuulDatePicker("Fecha y hora", date: $date, components: [.date, .hourAndMinute])
            }
        }
    }

    private var iconBadgeSection: some View {
        ShowcaseSection("RuulIconBadge") {
            HStack {
                RuulIconBadge("calendar", size: .small)
                RuulIconBadge("calendar", size: .medium)
                RuulIconBadge("calendar", size: .large)
                RuulIconBadge("checkmark", tint: .ruulSemanticSuccess)
                RuulIconBadge("xmark", tint: .ruulSemanticError)
            }
        }
    }

    private var meshSection: some View {
        ShowcaseSection("RuulMeshBackground", subtitle: "3 variants") {
            HStack(spacing: RuulSpacing.s3) {
                meshThumbnail(.cool, label: "cool")
                meshThumbnail(.violet, label: "violet")
                meshThumbnail(.aqua, label: "aqua")
            }
        }
    }

    private func meshThumbnail(_ variant: RuulMeshBackground.Variant, label: String) -> some View {
        VStack {
            ZStack {
                RuulMeshBackground(variant)
            }
            .frame(width: 100, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: RuulRadius.md))
            Text(label).ruulTextStyle(RuulTypography.caption).foregroundStyle(Color.ruulTextTertiary)
        }
    }

    private var presentationSection: some View {
        ShowcaseSection("RuulSheet / RuulFullScreenCover") {
            VStack(spacing: RuulSpacing.s2) {
                RuulButton("Show sheet", style: .secondary) { sheetPresented = true }
                RuulButton("Show full-screen cover", style: .secondary) { coverPresented = true }
            }
            .ruulSheet(isPresented: $sheetPresented) {
                ModalSheetTemplate(title: "Sheet", dismissAction: { sheetPresented = false }, primaryCTA: ("OK", { sheetPresented = false })) {
                    Text("Sheet content").ruulTextStyle(RuulTypography.body)
                }
            }
            .ruulFullScreenCover(isPresented: $coverPresented) {
                ZStack {
                    RuulMeshBackground(.violet)
                    VStack {
                        Text("Full screen").ruulTextStyle(RuulTypography.displayLarge).foregroundStyle(Color.ruulTextPrimary)
                        RuulButton("Close") { coverPresented = false }
                    }
                }
            }
        }
    }

    private var toastSection: some View {
        ShowcaseSection("RuulToast") {
            VStack(spacing: RuulSpacing.s2) {
                ForEach([RuulToast.Style.success, .warning, .error, .info], id: \.self) { style in
                    RuulButton("\(String(describing: style))", style: .secondary, size: .small) {
                        toast = .init("Toast", message: "\(String(describing: style)) example", style: style)
                    }
                }
            }
        }
    }

    // MARK: - Sprint 0 (platform-template DS adjustments)

    private var templatePickerSection: some View {
        ShowcaseSection("TemplatePickerCard", subtitle: "single-select template tile, supports coming-soon variant") {
            VStack(spacing: RuulSpacing.s3) {
                TemplatePickerCard(
                    icon: "fork.knife.circle.fill",
                    title: "Cena recurrente",
                    subtitle: "Cenas que se repiten con el mismo grupo",
                    bullets: ["Rotación de host", "RSVP + check-in", "Multas por reglas"],
                    isSelected: pickedTemplate == "dinner",
                    onSelect: { pickedTemplate = "dinner" }
                )
                TemplatePickerCard(
                    icon: "ticket.fill",
                    title: "Recurso compartido",
                    subtitle: "Palco, casa, suscripción",
                    bullets: ["Asignación rotativa"],
                    isComingSoon: true,
                    onSelect: {}
                )
            }
        }
    }

    private var actionCardSection: some View {
        ShowcaseSection("ActionCard", subtitle: "inbox row — type icon + priority dot + time-remaining") {
            VStack(spacing: RuulSpacing.s3) {
                ActionCard(
                    icon: "exclamationmark.triangle.fill",
                    title: "Multa pendiente: $300",
                    subtitle: "No-show en cena del 12 de mayo",
                    priority: .urgent,
                    timeRemaining: "VENCE EN 3 D",
                    onTap: {}
                )
                ActionCard(
                    icon: "hand.raised.fill",
                    title: "Vota una apelación",
                    subtitle: "María apeló su multa",
                    priority: .high,
                    timeRemaining: "12 H",
                    onTap: {}
                )
                ActionCard(
                    icon: "bell.fill",
                    title: "Recordatorio de pago",
                    priority: .low,
                    onTap: {}
                )
            }
        }
    }

    private var metricCardSection: some View {
        ShowcaseSection("RuulMetricCard", subtitle: "stat tile — compact / regular / hero with trend deltas") {
            VStack(spacing: RuulSpacing.s3) {
                RuulMetricCard(
                    label: "ASISTENCIA PROMEDIO",
                    value: "87",
                    unitSuffix: "%",
                    trend: .up("+5% vs mes pasado"),
                    size: .hero
                )
                HStack(spacing: RuulSpacing.s3) {
                    RuulMetricCard(label: "MULTAS DEL MES", value: "1240", unitPrefix: "$", trend: .down("-15%"), size: .compact)
                    RuulMetricCard(label: "EVENTOS", value: "4", trend: .flat("igual"), size: .compact)
                }
            }
        }
    }

    private var timelineSection: some View {
        ShowcaseSection("RuulTimelineItem", subtitle: "vertical history rail — first / middle / last variants") {
            VStack(spacing: 0) {
                RuulTimelineItem(
                    icon: "checkmark",
                    title: "Cerraste la cena del jueves",
                    subtitle: "12 confirmados, 9 llegaron",
                    timestamp: "HOY · 22:14",
                    tone: .positive,
                    isFirst: true
                )
                RuulTimelineItem(
                    icon: "hand.raised.fill",
                    title: "María apeló su multa de $300",
                    timestamp: "HOY · 19:02",
                    tone: .warning
                )
                RuulTimelineItem(
                    icon: "person.fill.badge.plus",
                    title: "Juan se unió al grupo",
                    timestamp: "LUN · 10:12",
                    tone: .info,
                    isLast: true
                )
            }
        }
    }
}
#endif
