import SwiftUI
import RuulUI
import RuulCore

/// "Ajustes del grupo" — unified settings surface, pushed from the
/// `GroupSpaceView` toolbar "⋯" menu.
///
/// Reglas del grupo (behavioral WHEN/IF/THEN) live in the **Decisiones**
/// tile, not here. This view groups settings into 4 buckets:
///
///   1. Identidad — name, photo, description.
///   2. Roles y decisiones — qué rol tiene cada miembro y cómo se
///      aprueban los votos.
///   3. Configuración — moneda + zona horaria.
///   4. Avanzado — funciones activas (qué tipo de coordinación tiene
///      el grupo), rotar código, archivar grupo.
///
/// `Plantillas de reglas` (rule templates catalog) is intentionally
/// NOT here — its canonical entry is inside Reglas (RulesView's
/// gallery composer) where adding a rule is the natural verb.
///
/// Doctrine note: there is no "Permisos por rol" matrix surface. The
/// role × permission grid (banned per identity-context doctrine) was
/// removed; the catalog editor inside "Tipos de rol" carries all the
/// granular detail an admin needs without flattening the group into a
/// permissions table.
@MainActor
public struct GroupAjustesView: View {
    public let group: RuulCore.Group
    public let activeModulesCount: Int

    public var onEditIdentity: () -> Void
    public var onPickCurrency: () -> Void
    public var onPickTimezone: () -> Void
    public var onPickModules: () -> Void
    public var onOpenRoles: () -> Void
    public var onOpenDecisiones: () -> Void
    public var onOpenGovernance: () -> Void
    public var onOpenReglas: () -> Void
    public var onRotateCode: () -> Void
    public var onArchiveGroup: () -> Void
    public var onLeaveGroup: () -> Void

    public init(
        group: RuulCore.Group,
        activeModulesCount: Int,
        onEditIdentity: @escaping () -> Void,
        onPickCurrency: @escaping () -> Void,
        onPickTimezone: @escaping () -> Void,
        onPickModules: @escaping () -> Void,
        onOpenRoles: @escaping () -> Void,
        onOpenDecisiones: @escaping () -> Void,
        onOpenGovernance: @escaping () -> Void,
        onOpenReglas: @escaping () -> Void,
        onRotateCode: @escaping () -> Void,
        onArchiveGroup: @escaping () -> Void,
        onLeaveGroup: @escaping () -> Void
    ) {
        self.group = group
        self.activeModulesCount = activeModulesCount
        self.onEditIdentity = onEditIdentity
        self.onPickCurrency = onPickCurrency
        self.onPickTimezone = onPickTimezone
        self.onPickModules = onPickModules
        self.onOpenRoles = onOpenRoles
        self.onOpenDecisiones = onOpenDecisiones
        self.onOpenGovernance = onOpenGovernance
        self.onOpenReglas = onOpenReglas
        self.onRotateCode = onRotateCode
        self.onArchiveGroup = onArchiveGroup
        self.onLeaveGroup = onLeaveGroup
    }

    public var body: some View {
        List {
            Section("Identidad") {
                row(
                    icon: "pencil",
                    label: "Nombre y foto",
                    action: onEditIdentity
                )
            }

            Section {
                row(
                    icon: "checkmark.bubble",
                    label: "Decisiones del grupo",
                    detail: "Ver y participar en las votaciones abiertas",
                    action: onOpenDecisiones
                )
                row(
                    icon: "person.text.rectangle",
                    label: "Roles del grupo",
                    detail: "Qué rol tiene cada miembro",
                    action: onOpenRoles
                )
                row(
                    icon: "scale.3d",
                    label: "Cómo se aprueban votos",
                    detail: "Quórum mínimo y mayoría para que un voto pase",
                    action: onOpenGovernance
                )
            } header: {
                Text("Roles y decisiones")
            }

            Section {
                row(
                    icon: "scroll",
                    label: "Reglas vigentes",
                    detail: "Acuerdos WHEN/IF/THEN que impactan cada recurso",
                    action: onOpenReglas
                )
            } header: {
                Text("Reglas")
            }

            Section {
                row(
                    icon: "dollarsign.circle",
                    label: "Moneda",
                    trailing: group.currency,
                    action: onPickCurrency
                )
                row(
                    icon: "clock",
                    label: "Zona horaria",
                    trailing: group.timezone ?? "—",
                    action: onPickTimezone
                )
            } header: {
                Text("Configuración")
            }

            Section {
                row(
                    icon: "puzzlepiece",
                    label: "Características del grupo",
                    detail: "Qué tipo de coordinación tiene activa (multas, eventos, fondo…)",
                    trailing: "\(activeModulesCount)",
                    action: onPickModules
                )
                row(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Rotar código de invitación",
                    action: onRotateCode
                )
                row(
                    icon: "archivebox",
                    label: "Archivar grupo",
                    destructive: true,
                    action: onArchiveGroup
                )
            } header: {
                Text("Avanzado")
            }

            Section {
                row(
                    icon: "rectangle.portrait.and.arrow.right",
                    label: "Salir del grupo",
                    destructive: true,
                    action: onLeaveGroup
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Ajustes del grupo")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func row(
        icon: String,
        label: String,
        detail: String? = nil,
        trailing: String? = nil,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: RuulSpacing.sm) {
                Image(systemName: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(destructive ? Color.ruulNegative : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(destructive ? Color.ruulNegative : Color.primary)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                }
                if !destructive {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
