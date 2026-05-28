import Foundation
import Testing
@testable import RuulCore

@MainActor
@Suite("RulesStore")
struct RulesStoreTests {

    private let groupId = UUID()

    private func rule(_ title: String, severity: Int = 1, type: GroupRuleType = .norm) -> GroupRule {
        GroupRule(
            id: UUID(), currentVersionId: UUID(), groupId: groupId,
            title: title, body: "body", ruleType: type, severity: severity,
            executionMode: .text, status: "active"
        )
    }

    private func makeStore(seed: [GroupRule]) async -> (RulesStore, MockRuulRPCClient) {
        let mock = MockRuulRPCClient()
        await mock.setGroupRulesActiveStub(.success(seed))
        let repo = CanonicalRulesRepository(rpc: mock)
        return (RulesStore(repository: repo), mock)
    }

    @Test("refresh loads rules and lands on .loaded")
    func refreshHappyPath() async {
        let (store, mock) = await makeStore(seed: [rule("A")])
        await store.refresh(groupId: groupId)
        #expect(store.rules.count == 1)
        #expect(store.phase == .loaded)
        let recorded = await mock.recorded
        #expect(recorded.contains(.groupRulesActive(groupId: groupId)))
    }

    @Test("createDraft rejects empty title")
    func rejectsEmptyTitle() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "  "
        store.draftBody = "Some body"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
        #expect(store.isCreatePresented)
    }

    @Test("createDraft rejects empty body")
    func rejectsEmptyBody() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "Title"
        store.draftBody = "   "
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
        #expect(store.errorMessage != nil)
    }

    @Test("createDraft rejects invalid severity")
    func rejectsInvalidSeverity() async {
        let (store, _) = await makeStore(seed: [])
        store.beginCreating()
        store.draftTitle = "Title"
        store.draftBody = "Body"
        store.draftSeverity = 9
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok == false)
    }

    @Test("createDraft success refreshes and dismisses sheet")
    func createSuccess() async {
        let (store, mock) = await makeStore(seed: [])
        await mock.setCreateTextRuleStub(.success(.init(ruleId: UUID(), versionId: UUID())))
        await mock.setGroupRulesActiveStub(.success([rule("Created")]))

        store.beginCreating()
        store.draftTitle = "Created"
        store.draftBody = "Body"
        let ok = await store.createDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)
        #expect(store.rules.count == 1)
    }

    @Test("archive removes rule locally on success")
    func archiveRemoves() async {
        let toArchive = rule("Archive me")
        let (store, mock) = await makeStore(seed: [toArchive])
        await mock.setArchiveRuleStub(.success(()))
        await store.refresh(groupId: groupId)

        let ok = await store.archive(ruleId: toArchive.id, reason: nil, groupId: groupId)
        #expect(ok)
        #expect(store.rules.isEmpty)
        let recorded = await mock.recorded
        #expect(recorded.contains(.archiveRule(input: ArchiveRuleInput(pRuleId: toArchive.id, pReason: nil))))
    }

    @Test("topRules returns first 3 sorted by backend order")
    func topRulesLimit() async {
        let seed = [rule("A", severity: 3), rule("B", severity: 2),
                    rule("C", severity: 2), rule("D", severity: 1)]
        let (store, _) = await makeStore(seed: seed)
        await store.refresh(groupId: groupId)
        #expect(store.topRules.count == 3)
    }

    // MARK: - Engine draft (V2-G3.1)

    private func triggerShape() -> RuleShape {
        RuleShape(
            shapeKey: "trigger.money.expense_recorded",
            category: .trigger,
            displayName: "Cuando se registra un gasto",
            description: nil,
            schema: RuleShapeSchema(
                eventType: "money.expense_recorded",
                payloadKeys: ["amount", "currency"],
                compatibleConditions: ["condition.amount_above"],
                compatibleConsequences: ["consequence.issue_sanction"],
                scope: .group,
                kind: nil, action: nil, execution: nil,
                authorityRequired: nil, fields: nil
            ),
            resourceTypes: [],
            metadata: nil
        )
    }

    private func conditionShape() -> RuleShape {
        RuleShape(
            shapeKey: "condition.amount_above",
            category: .condition,
            displayName: "Monto supera umbral",
            description: nil,
            schema: RuleShapeSchema(
                eventType: nil, payloadKeys: nil,
                compatibleConditions: nil, compatibleConsequences: nil,
                scope: nil, kind: "amount_above", action: nil,
                execution: nil, authorityRequired: nil,
                fields: [
                    RuleShapeField(key: "amount", type: "number", required: true,
                                   label: "Monto", min: 0, max: nil,
                                   default: nil, enum: nil),
                    RuleShapeField(key: "currency", type: "string", required: true,
                                   label: "Moneda", min: nil, max: nil,
                                   default: .string("MXN"), enum: nil)
                ]
            ),
            resourceTypes: [],
            metadata: nil
        )
    }

    private func consequenceShape() -> RuleShape {
        RuleShape(
            shapeKey: "consequence.issue_sanction",
            category: .consequence,
            displayName: "Emitir sanción",
            description: nil,
            schema: RuleShapeSchema(
                eventType: nil, payloadKeys: nil,
                compatibleConditions: nil, compatibleConsequences: nil,
                scope: nil, kind: nil, action: "issue_sanction",
                execution: .sync, authorityRequired: "sanctions.create",
                fields: [
                    RuleShapeField(key: "severity", type: "integer", required: true,
                                   label: "Severidad", min: 1, max: 5,
                                   default: nil, enum: nil),
                    RuleShapeField(key: "reason", type: "string", required: true,
                                   label: "Razón", min: nil, max: nil,
                                   default: nil, enum: nil)
                ]
            ),
            resourceTypes: [],
            metadata: nil
        )
    }

    private func makeEngineStore() async -> (RulesStore, MockRuulRPCClient) {
        let (store, mock) = await makeStore(seed: [])
        await mock.setListRuleShapesStub(.success(
            [triggerShape(), conditionShape(), consequenceShape()]
        ))
        return (store, mock)
    }

    @Test("loadShapesIfNeeded caches the catalog")
    func loadsShapesOnce() async {
        let (store, mock) = await makeEngineStore()
        await store.loadShapesIfNeeded()
        await store.loadShapesIfNeeded() // second call: no extra RPC.
        #expect(store.availableShapes.count == 3)
        let recorded = await mock.recorded
        let calls = recorded.filter {
            if case .listRuleShapes = $0 { return true }
            return false
        }
        #expect(calls.count == 1)
    }

    @Test("selectTrigger filters compatible conditions + consequences")
    func filtersByCompatibility() async {
        let (store, _) = await makeEngineStore()
        await store.loadShapesIfNeeded()
        store.selectTrigger(key: "trigger.money.expense_recorded")
        #expect(store.compatibleConditions.map(\.shapeKey) == ["condition.amount_above"])
        #expect(store.compatibleConsequences.map(\.shapeKey) == ["consequence.issue_sanction"])
    }

    @Test("selectCondition seeds default field values")
    func seedsConditionDefaults() async {
        let (store, _) = await makeEngineStore()
        await store.loadShapesIfNeeded()
        store.selectTrigger(key: "trigger.money.expense_recorded")
        store.selectCondition(key: "condition.amount_above")
        // 'currency' has a default; 'amount' does not.
        #expect(store.draftConditionFields["currency"] == .string("MXN"))
        #expect(store.draftConditionFields["amount"] == nil)
    }

    @Test("currentEngineDraftPayload is nil until trigger + consequence are set")
    func payloadIncomplete() async {
        let (store, _) = await makeEngineStore()
        await store.loadShapesIfNeeded()
        store.draftMode = .engine
        #expect(store.currentEngineDraftPayload() == nil)
        store.selectTrigger(key: "trigger.money.expense_recorded")
        #expect(store.currentEngineDraftPayload() == nil)
        store.selectConsequence(key: "consequence.issue_sanction")
        #expect(store.currentEngineDraftPayload() != nil)
    }

    @Test("dryRunValidate calls validate_rule_shape and stores the result")
    func dryRunWiresValidator() async {
        let (store, mock) = await makeEngineStore()
        await mock.setValidateRuleShapeStub(.success(RuleShapeValidationResult(
            valid: false,
            errors: [RuleShapeValidationError(path: "consequences[0].fields.reason",
                                              code: "required", message: "razón requerida")],
            shapeKey: "trigger.money.expense_recorded",
            triggerEventType: "money.expense_recorded"
        )))
        await store.loadShapesIfNeeded()
        store.draftMode = .engine
        store.selectTrigger(key: "trigger.money.expense_recorded")
        store.selectConsequence(key: "consequence.issue_sanction")
        let result = await store.dryRunValidate()
        #expect(result?.valid == false)
        #expect(store.draftValidation?.errors.count == 1)
    }

    @Test("createDraft in engine mode calls create_engine_rule")
    func createEngineDraftWiresRpc() async {
        let (store, mock) = await makeEngineStore()
        await mock.setCreateEngineRuleStub(.success(.init(ruleId: UUID(), versionId: UUID())))
        await store.loadShapesIfNeeded()

        store.beginCreating(mode: .engine)
        store.draftTitle = "Excede tope"
        store.selectTrigger(key: "trigger.money.expense_recorded")
        store.selectConsequence(key: "consequence.issue_sanction")
        store.setConsequenceField("severity", .number(2))
        store.setConsequenceField("reason", .string("Excede tope"))

        let ok = await store.createDraft(groupId: groupId)
        #expect(ok)
        #expect(store.isCreatePresented == false)

        let recorded = await mock.recorded
        let createCall = recorded.first { call in
            if case .createEngineRule = call { return true }
            return false
        }
        #expect(createCall != nil)
        if case .createEngineRule(let input)? = createCall {
            #expect(input.pTitle == "Excede tope")
            #expect(input.pShapeKey == "trigger.money.expense_recorded")
            #expect(input.pConsequences.count == 1)
            #expect(input.pConsequences.first?.kind == "consequence.issue_sanction")
        }
    }

    @Test("canSaveDraft in engine mode requires trigger + consequence")
    func canSaveDraftEngineRequiresAtoms() async {
        let (store, _) = await makeEngineStore()
        await store.loadShapesIfNeeded()
        store.beginCreating(mode: .engine)
        store.draftTitle = "Title"
        #expect(store.canSaveDraft == false)
        store.selectTrigger(key: "trigger.money.expense_recorded")
        #expect(store.canSaveDraft == false)
        store.selectConsequence(key: "consequence.issue_sanction")
        #expect(store.canSaveDraft == true)
    }
}
