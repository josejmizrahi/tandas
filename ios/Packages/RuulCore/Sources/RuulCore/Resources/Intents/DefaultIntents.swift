import Foundation

/// Beta-1 catalog of universal intents. ~16 verbs that compose every
/// founder use case. Adding a new intent is one struct literal here
/// (and a `Destination` case if the routing surface is new).
///
/// Forbidden vocabulary in `humanLabel` / `summary` / `firstRunCopy` /
/// `emptyStateCopy` per 2026-05-18 doctrine: capability, atom,
/// projection, resource_type, rule shape, trigger, consequence,
/// **ledger**, module.
public enum DefaultIntents {
    public static let all: [ResourceIntent] = [
        // --- Post-create + universal verbs (original Beta-1 catalog) ---
        invitePeople,
        checkInAttendees,
        trackMoney,
        recordContribution,
        recordExpense,
        allowReservations,
        assignHolder,
        grantAccess,
        assignCustody,
        recordValuation,
        linkResource,
        addRules,
        createChildEvent,
        createChildSlot,
        definePriority,
        changeControl,
        viewHistory,
        viewBalance,
        // --- Toolbar `+` extensions (Phase 1: asset + fund) ---
        releaseCustody,
        checkOutAsset,
        markReturnedAsset,
        transferAsset,
        returnAssetToGroup,
        logMaintenance,
        reportDamage,
        createSlotHere,
        fundContribute,
        recordExpenseFromFund,
        lockFund,
        unlockFund,
        // --- Universal verbs the toolbar surfaces on every type ---
        shareResource,
        // --- ⚙️ Ajustes (isResourceSetting = true) ---
        editResource,
        archiveResource
    ]

    // MARK: - Event-focused

    public static let invitePeople = ResourceIntent(
        id: "invite_people",
        humanLabel: "Invitar gente",
        summary: "Manda invitaciones y pide confirmación.",
        icon: "person.crop.circle.badge.plus",
        resourceTypes: [.event],
        requiredCapabilities: [CapabilityID.rsvp],
        destination: .rsvpManager,
        firstRunCopy: "Elige a quiénes invitar.",
        emptyStateCopy: "Nadie invitado todavía."
    )

    public static let checkInAttendees = ResourceIntent(
        id: "check_in_attendees",
        humanLabel: "Pasar lista",
        summary: "Marca quién llegó al evento.",
        icon: "checkmark.circle",
        resourceTypes: [.event],
        requiredCapabilities: [CapabilityID.checkIn],
        destination: .checkInLauncher,
        firstRunCopy: "Empieza a registrar llegadas.",
        emptyStateCopy: "Nadie ha llegado todavía."
    )

    // MARK: - Money-focused (no CapabilityID.ledger in user copy)

    public static let trackMoney = ResourceIntent(
        id: "track_money",
        humanLabel: "Ver dinero",
        summary: "Aportes, gastos y balance del recurso.",
        icon: "dollarsign.circle",
        resourceTypes: [.event, .fund, .asset, .space, .slot],
        requiredCapabilities: [CapabilityID.ledger, CapabilityID.money],
        destination: .moneyTab,
        firstRunCopy: "Aquí verás todo el movimiento.",
        emptyStateCopy: "Sin movimientos todavía.",
        group: .money
    )

    public static let recordContribution = ResourceIntent(
        id: "record_contribution",
        humanLabel: "Registrar aportación",
        summary: "Alguien puso dinero al fondo.",
        icon: "arrow.down.circle",
        resourceTypes: [.fund, .event],
        requiredCapabilities: [CapabilityID.ledger, CapabilityID.money],
        destination: .ledgerEntryForm(prefill: .credit),
        firstRunCopy: "¿Quién aportó y cuánto?",
        emptyStateCopy: "Sin aportaciones todavía.",
        group: .money
    )

    public static let recordExpense = ResourceIntent(
        id: "record_expense",
        humanLabel: "Registrar gasto",
        summary: "Algo se pagó con dinero del recurso.",
        icon: "arrow.up.circle",
        resourceTypes: [.fund, .event, .asset, .space],
        requiredCapabilities: [CapabilityID.ledger, CapabilityID.money],
        destination: .ledgerEntryForm(prefill: .debit),
        firstRunCopy: "¿Qué se gastó y cuánto?",
        emptyStateCopy: "Sin gastos todavía.",
        group: .money
    )

    public static let viewBalance = ResourceIntent(
        id: "view_balance",
        humanLabel: "Ver balance",
        summary: "Cuánto hay y quién debe qué.",
        icon: "chart.bar.fill",
        resourceTypes: [.fund, .event, .asset, .space],
        requiredCapabilities: [CapabilityID.ledger, CapabilityID.money],
        destination: .moneyTab,
        firstRunCopy: "El balance se actualiza solo.",
        emptyStateCopy: "Sin balance todavía.",
        group: .money
    )

    // MARK: - Reservation / access / holder

    public static let allowReservations = ResourceIntent(
        id: "allow_reservations",
        humanLabel: "Permitir reservas",
        summary: "Deja que los miembros aparten este lugar.",
        icon: "calendar.badge.plus",
        resourceTypes: [.space, .slot, .asset],
        requiredCapabilities: [CapabilityID.booking],
        activation: .primerSheet(
            title: "Permitir reservas",
            body: "Otros miembros podrán apartar este lugar. Después podrás añadir reglas (cuánta anticipación, quién aprueba).",
            ctaLabel: "Activar"
        ),
        destination: .reservationSetup,
        firstRunCopy: "Define cómo se reserva.",
        emptyStateCopy: "Sin reservas todavía."
    )

    public static let grantAccess = ResourceIntent(
        id: "grant_access",
        humanLabel: "Dar acceso",
        summary: "Crear un acceso para una persona.",
        icon: "key",
        resourceTypes: [.space, .asset, .right],
        requiredCapabilities: [CapabilityID.access],
        activation: .primerSheet(
            title: "Dar acceso",
            body: "Vas a crear un acceso vinculado a este recurso. Después podrás definir vigencia y condiciones.",
            ctaLabel: "Continuar"
        ),
        destination: .rightCreationFlow,
        firstRunCopy: "¿A quién y bajo qué condiciones?",
        emptyStateCopy: "Sin accesos otorgados."
    )

    public static let assignHolder = ResourceIntent(
        id: "assign_holder",
        humanLabel: "Asignar titular",
        summary: "Define de quién es este derecho o turno.",
        icon: "person.fill.checkmark",
        resourceTypes: [.right, .slot],
        destination: .rightHolderForm,
        firstRunCopy: "Elige al titular.",
        emptyStateCopy: "Sin titular asignado."
    )

    public static let assignCustody = ResourceIntent(
        id: "assign_custody",
        humanLabel: "Asignar custodia",
        summary: "Quién tiene el activo físicamente.",
        icon: "person.text.rectangle",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.custody],
        destination: .custodyAssignment,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿Quién lo trae?",
        emptyStateCopy: "Sin custodio actual.",
        group: .actions
    )

    public static let recordValuation = ResourceIntent(
        id: "record_valuation",
        humanLabel: "Registrar valor",
        summary: "Cuánto vale hoy.",
        icon: "chart.line.uptrend.xyaxis",
        resourceTypes: [.asset, .fund, .right],
        requiredCapabilities: [CapabilityID.valuation],
        destination: .valuationForm,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿En cuánto se valúa hoy?",
        emptyStateCopy: "Sin valuaciones registradas.",
        group: .money
    )

    // MARK: - Connections / rules / governance

    public static let linkResource = ResourceIntent(
        id: "link_resource",
        humanLabel: "Conectar con otra cosa",
        summary: "Vincula este recurso a otro del grupo.",
        icon: "link",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .linkPicker(kindHint: nil),
        firstRunCopy: "¿Con qué se relaciona?",
        emptyStateCopy: "Sin conexiones todavía.",
        group: .coordination
    )

    public static let addRules = ResourceIntent(
        id: "add_rules",
        humanLabel: "Añadir reglas",
        summary: "Define qué pasa cuando algo sucede.",
        icon: "list.bullet.clipboard",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .ruleTemplatePicker(category: nil),
        firstRunCopy: "Elige una regla para empezar.",
        emptyStateCopy: "Sin reglas todavía.",
        group: .coordination
    )

    public static let definePriority = ResourceIntent(
        id: "define_priority",
        humanLabel: "Definir prioridad",
        summary: "Quién tiene preferencia y cuándo.",
        icon: "list.number",
        resourceTypes: [.slot, .right, .space],
        destination: .ruleTemplatePicker(category: .priority),
        firstRunCopy: "Elige cómo se ordena la prioridad.",
        emptyStateCopy: "Sin reglas de prioridad.",
        group: .coordination
    )

    public static let changeControl = ResourceIntent(
        id: "change_control",
        humanLabel: "Cambiar reglas del grupo",
        summary: "Modificar cómo se gobierna esto.",
        icon: "slider.horizontal.3",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        activation: .primerSheet(
            title: "Cambiar reglas",
            body: "Vas a entrar al editor de gobernanza. Los cambios pueden necesitar aprobación del grupo.",
            ctaLabel: "Continuar"
        ),
        destination: .governanceRuleEditor,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "Edita las reglas del grupo.",
        emptyStateCopy: "Sin cambios pendientes.",
        group: .governance
    )

    // MARK: - Children & history

    public static let createChildEvent = ResourceIntent(
        id: "create_child_event",
        humanLabel: "Crear evento aquí",
        summary: "Algo que pasa dentro de este lugar o recurso.",
        icon: "calendar.badge.plus",
        resourceTypes: [.space, .asset],
        destination: .childResourceWizard(prefilledType: .event),
        firstRunCopy: "Crea el primer evento aquí.",
        emptyStateCopy: "Sin eventos todavía.",
        group: .coordination
    )

    public static let createChildSlot = ResourceIntent(
        id: "create_child_slot",
        humanLabel: "Crear turno o asiento",
        summary: "Asigna unidades dentro de este recurso.",
        icon: "rectangle.split.3x1",
        resourceTypes: [.space, .asset],
        destination: .childResourceWizard(prefilledType: .slot),
        firstRunCopy: "Crea el primer turno.",
        emptyStateCopy: "Sin turnos todavía.",
        group: .coordination
    )

    public static let viewHistory = ResourceIntent(
        id: "view_history",
        humanLabel: "Ver historial",
        summary: "Todo lo que ha pasado con este recurso.",
        icon: "clock.arrow.circlepath",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .historyTab,
        firstRunCopy: "Aquí queda registro de todo.",
        emptyStateCopy: "Sin actividad todavía.",
        group: .history
    )

    // MARK: - Toolbar Phase 1: Asset custody (additional to assignCustody above)

    public static let releaseCustody = ResourceIntent(
        id: "release_custody",
        humanLabel: "Liberar custodia",
        summary: "Devolver el activo al grupo (sin custodio).",
        icon: "person.crop.rectangle.badge.xmark",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.custody],
        destination: .releaseCustodyConfirm,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .actions,
        isDestructive: true
    )

    public static let checkOutAsset = ResourceIntent(
        id: "checkout_asset",
        humanLabel: "Prestar (checkout)",
        summary: "Marcar que alguien se lo llevó temporalmente.",
        icon: "arrow.up.right.square",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.custody],
        destination: .checkoutAssetSheet,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿Quién se lo lleva y hasta cuándo?",
        emptyStateCopy: "",
        group: .actions
    )

    public static let markReturnedAsset = ResourceIntent(
        id: "mark_returned_asset",
        humanLabel: "Marcar devuelto",
        summary: "El activo volvió.",
        icon: "arrow.down.left.square",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.custody],
        destination: .markReturnedConfirm,
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .actions
    )

    // MARK: - Toolbar Phase 1: Asset ownership

    public static let transferAsset = ResourceIntent(
        id: "transfer_asset",
        humanLabel: "Transferir propiedad",
        summary: "Pasar el activo a otra persona.",
        icon: "arrow.left.arrow.right",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.transfer],
        destination: .transferAssetPicker,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿A quién se transfiere?",
        emptyStateCopy: "",
        group: .actions
    )

    public static let returnAssetToGroup = ResourceIntent(
        id: "return_asset_to_group",
        humanLabel: "Devolver al grupo",
        summary: "Quitar dueño individual: queda del grupo.",
        icon: "person.3",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.transfer],
        destination: .returnAssetToGroupConfirm,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .actions,
        isDestructive: true
    )

    // MARK: - Toolbar Phase 1: Asset maintenance

    public static let logMaintenance = ResourceIntent(
        id: "log_maintenance",
        humanLabel: "Registrar mantenimiento",
        summary: "Anota un service o arreglo.",
        icon: "wrench.and.screwdriver",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.maintenance],
        destination: .logMaintenanceSheet,
        firstRunCopy: "¿Qué se hizo y cuánto costó?",
        emptyStateCopy: "Sin mantenimiento registrado.",
        group: .actions
    )

    public static let reportDamage = ResourceIntent(
        id: "report_damage",
        humanLabel: "Reportar daño",
        summary: "Algo se rompió.",
        icon: "exclamationmark.triangle",
        resourceTypes: [.asset],
        requiredCapabilities: [CapabilityID.maintenance],
        destination: .reportDamageSheet,
        firstRunCopy: "Describe el daño.",
        emptyStateCopy: "",
        group: .actions,
        isDestructive: true
    )

    // MARK: - Toolbar Phase 1: Bookings (slot child under asset)

    public static let createSlotHere = ResourceIntent(
        id: "create_slot_here",
        humanLabel: "Crear cupo",
        summary: "Abre un turno reservable para este activo.",
        icon: "plus.rectangle.on.rectangle",
        resourceTypes: [.asset, .space],
        requiredCapabilities: [CapabilityID.booking],
        destination: .createSlotUnderAssetSheet,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿Cuándo y por cuánto?",
        emptyStateCopy: "Sin cupos creados.",
        group: .coordination
    )

    // MARK: - Toolbar Phase 1: Fund

    public static let fundContribute = ResourceIntent(
        id: "fund_contribute",
        humanLabel: "Aportar",
        summary: "Sumar dinero al fondo.",
        icon: "plus.circle",
        resourceTypes: [.fund],
        requiredCapabilities: [CapabilityID.money],
        destination: .fundContributeSheet,
        firstRunCopy: "¿Cuánto aportas?",
        emptyStateCopy: "Sin aportaciones todavía.",
        group: .money
    )

    public static let recordExpenseFromFund = ResourceIntent(
        id: "record_expense_from_fund",
        humanLabel: "Registrar gasto",
        summary: "Algo se pagó con dinero del fondo.",
        icon: "arrow.up.circle",
        resourceTypes: [.fund],
        requiredCapabilities: [CapabilityID.money],
        destination: .fundRecordExpenseSheet,
        permissionsRequired: [.fundWithdraw],
        firstRunCopy: "¿Qué se pagó y a quién?",
        emptyStateCopy: "Sin gastos registrados.",
        group: .money
    )

    public static let lockFund = ResourceIntent(
        id: "lock_fund",
        humanLabel: "Bloquear fondo",
        summary: "Pausa nuevas aportaciones y gastos.",
        icon: "lock",
        resourceTypes: [.fund],
        requiredCapabilities: [CapabilityID.money],
        destination: .fundLockSheet,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "¿Por qué se bloquea?",
        emptyStateCopy: "",
        group: .actions
    )

    public static let unlockFund = ResourceIntent(
        id: "unlock_fund",
        humanLabel: "Desbloquear fondo",
        summary: "Vuelve a permitir aportes y gastos.",
        icon: "lock.open",
        resourceTypes: [.fund],
        requiredCapabilities: [CapabilityID.money],
        destination: .fundUnlockConfirm,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .actions
    )

    // MARK: - Universal toolbar verbs

    public static let shareResource = ResourceIntent(
        id: "share_resource",
        humanLabel: "Compartir",
        summary: "Manda el link a alguien.",
        icon: "square.and.arrow.up",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .systemShareSheet,
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .coordination
    )

    // MARK: - ⚙️ Ajustes (isResourceSetting = true)
    // Doctrine: ⚙️ stays minimal. Only `edit_resource` + `archive_resource`
    // live here. Future configuration (notifications, deletion, advanced
    // governance) goes inside an "Avanzado" sub-sheet rather than expanding
    // the top-level ⚙️ menu.

    public static let editResource = ResourceIntent(
        id: "edit_resource",
        humanLabel: "Editar detalles",
        summary: "Cambia nombre, descripción y otros campos.",
        icon: "pencil",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .editResourceSheet,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .governance,
        isResourceSetting: true
    )

    public static let archiveResource = ResourceIntent(
        id: "archive_resource",
        humanLabel: "Archivar",
        summary: "Sácalo del feed activo. Queda en historial.",
        icon: "archivebox",
        resourceTypes: [.event, .fund, .asset, .space, .slot, .right],
        destination: .archiveResourceConfirm,
        permissionsRequired: [.modifyGovernance],
        firstRunCopy: "",
        emptyStateCopy: "",
        group: .governance,
        isDestructive: true,
        isResourceSetting: true
    )
}
