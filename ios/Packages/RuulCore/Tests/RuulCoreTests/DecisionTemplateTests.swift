import Testing
import Foundation
@testable import RuulCore

/// R.4B — plantillas de decisión: decoding del catálogo, clasificación de
/// `execution_kind` (ejecutable / coming_soon / reservation_award) y herencia
/// del voting model en el mock.
@Suite("R.4B — Plantillas de decisión")
struct DecisionTemplateTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.ruul.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    @Test("decodifica una fila del catálogo con payload_schema + notes")
    func decodesRowWithSchema() throws {
        let json = """
        {
          "template_key": "grant_resource_right",
          "decision_type": "resources",
          "display_name": "Otorgar derecho sobre recurso",
          "description": "Crear un right activo sobre un recurso.",
          "default_voting_model": "yes_no_abstain",
          "default_quorum": 0.5,
          "default_approval_threshold": 0.5,
          "execution_kind": "grant_resource_right",
          "payload_schema": {
            "notes": "ojo",
            "fields": [
              {"name": "resource_id", "type": "uuid", "required": true},
              {"name": "percent", "type": "numeric", "required": false}
            ]
          },
          "metadata": {}
        }
        """
        let t = try decode(DecisionTemplate.self, json)
        #expect(t.templateKey == "grant_resource_right")
        #expect(t.decisionType == "resources")
        #expect(t.voting == .yesNoAbstain)
        #expect(t.payloadSchema.notes == "ojo")
        #expect(t.payloadSchema.fields.count == 2)
        #expect(t.payloadSchema.fields.first?.kind == .uuid)
        #expect(t.payloadSchema.fields.first?.required == true)
        #expect(t.payloadSchema.fields.last?.kind == .numeric)
        #expect(t.isExecutable)
        #expect(t.hasPayloadForm)
        #expect(!t.isComingSoon)
    }

    @Test("decodifica payload_schema vacío ({}) como sin campos")
    func decodesEmptySchema() throws {
        let json = """
        {
          "template_key": "generic",
          "decision_type": "generic",
          "display_name": "Decisión genérica",
          "description": null,
          "default_voting_model": "yes_no_abstain",
          "default_quorum": 0.5,
          "default_approval_threshold": 0.5,
          "execution_kind": "noop",
          "payload_schema": {},
          "metadata": {}
        }
        """
        let t = try decode(DecisionTemplate.self, json)
        #expect(t.payloadSchema.fields.isEmpty)
        #expect(t.isExecutable)         // noop sí ejecuta
        #expect(!t.hasPayloadForm)      // pero no lleva form
        #expect(!t.isComingSoon)
    }

    // MARK: - Clasificación de execution_kind

    @Test("clasifica los execution_kind: ejecutable / coming_soon / reservation_award")
    func classification() {
        func tpl(_ kind: String) -> DecisionTemplate {
            DecisionTemplate(templateKey: kind, decisionType: "x", displayName: kind, executionKind: kind)
        }
        for kind in ["noop", "archive_resource", "archive_rule", "grant_resource_right"] {
            #expect(tpl(kind).isExecutable, "\(kind) debería ser ejecutable")
            #expect(!tpl(kind).isComingSoon)
        }
        for kind in ["activate_membership", "create_expense", "create_payout",
                     "mark_resource_approved", "set_membership_banned",
                     "upsert_rule", "set_membership_removed"] {
            #expect(tpl(kind).isComingSoon, "\(kind) debería ser coming_soon")
            #expect(!tpl(kind).isExecutable)
        }
        #expect(tpl("reservation_award").isReservationAward)
        #expect(!tpl("reservation_award").isExecutable)
        #expect(!tpl("reservation_award").isComingSoon)
    }

    // MARK: - Validación de campos requeridos

    @Test("missingRequiredFields detecta los required ausentes")
    func missingRequired() {
        let t = DecisionTemplate(
            templateKey: "grant_resource_right", decisionType: "resources",
            displayName: "Otorgar derecho",
            payloadSchema: .init(fields: [
                .init(name: "resource_id", type: "uuid", required: true),
                .init(name: "holder_actor_id", type: "uuid", required: true),
                .init(name: "right_kind", type: "text", required: true),
                .init(name: "percent", type: "numeric", required: false)
            ]),
            executionKind: "grant_resource_right"
        )
        // Vacío → faltan los 3 required.
        #expect(Set(t.missingRequiredFields(in: [:]))
            == ["resource_id", "holder_actor_id", "right_kind"])
        // Sólo opcional presente → siguen faltando los 3.
        #expect(t.missingRequiredFields(in: ["percent": .number(50)]).count == 3)
        // Todos los required presentes → ninguno falta (el opcional no importa).
        let full: [String: JSONValue] = [
            "resource_id": .string("r"), "holder_actor_id": .string("h"), "right_kind": .string("USE")
        ]
        #expect(t.missingRequiredFields(in: full).isEmpty)
    }

    // MARK: - Mock

    @Test("el mock expone el catálogo con plantillas ejecutables y coming_soon")
    func mockCatalog() async throws {
        let client = MockRuulRPCClient.demo()
        let templates = try await client.listDecisionTemplates()
        #expect(!templates.isEmpty)
        #expect(templates.contains { $0.templateKey == "generic" && $0.isExecutable })
        #expect(templates.contains { $0.templateKey == "archive_resource" && $0.isExecutable })
        #expect(templates.contains { $0.templateKey == "remove_member" && $0.isComingSoon })
        // reservation_award no se ofrece en el catálogo del picker.
        #expect(!templates.contains { $0.isReservationAward })
    }

    @Test("createDecision con plantilla hereda el voting model y manda el decision_type crudo")
    func createWithTemplateInheritsVoting() async throws {
        let client = MockRuulRPCClient.demo()
        let contextId = MockRuulRPCClient.DemoIds.cenaSemanal
        let input = CreateDecisionInput(
            contextId: contextId,
            decisionType: .generic,
            title: "Archivar la mesa de ping pong",
            payload: .object(["resource_id": .string(UUID().uuidString)]),
            clientId: UUID().uuidString,
            votingModel: nil,
            templateKey: "archive_resource",
            decisionTypeRaw: "resources"
        )
        let decision = try await client.createDecision(input)
        #expect(decision.votingModel == "yes_no_abstain")
        #expect(decision.decisionType == "resources")
    }
}
