import Testing
import Foundation
@testable import RuulCore

/// Tests de decoding contra fixtures que replican byte-a-byte los shapes
/// que emiten los RPCs MVP2 (jsonb_build_object / to_jsonb / PostgREST).
@Suite("Decoding del contrato MVP2")
struct DecodingTests {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.ruul.decode(T.self, from: Data(json.utf8))
    }

    // MARK: - Fechas

    @Test("timestamps de Postgres con y sin microsegundos")
    func postgresTimestamps() throws {
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30.123456+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30.5Z") != nil)
        #expect(PostgresTimestamp.parse("2026-06-03T18:15:30Z") != nil)
        #expect(PostgresTimestamp.parse("no es fecha") == nil)
    }

    // MARK: - Identity

    @Test("ensure_person_actor")
    func ensurePersonActor() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "actor": {
            "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "slug": null,
            "status": "active",
            "visibility": "private",
            "metadata": {},
            "created_by_actor_id": null,
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00",
            "archived_at": null
          },
          "profile": {
            "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "auth_user_id": "11111111-c51c-4bf4-9960-e1c80e27aba1",
            "full_name": "José Mizrahi",
            "preferred_name": null,
            "phone": "+5215555550001",
            "email": null,
            "avatar_url": null,
            "metadata": {},
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00"
          }
        }
        """
        let current = try decode(CurrentActor.self, json)
        #expect(current.displayName == "José")
        #expect(current.actor.actorKind == .person)
        #expect(current.profile?.phone == "+5215555550001")
    }

    // MARK: - Contexts

    @Test("context_candidates")
    func contextCandidates() throws {
        let json = """
        {
          "personal_context": {
            "id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "status": "active",
            "visibility": "private",
            "created_at": "2026-06-02T20:06:31.733651+00:00"
          },
          "contexts": [
            {
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Cena Semanal",
              "actor_kind": "collective",
              "actor_subtype": "friend_group",
              "visibility": "private",
              "membership_type": "founder",
              "member_count": 5,
              "roles": ["admin"]
            },
            {
              "context_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Familia Mizrahi",
              "actor_kind": "collective",
              "actor_subtype": "family",
              "visibility": "private",
              "membership_type": "member",
              "member_count": 3,
              "roles": []
            }
          ]
        }
        """
        let candidates = try decode(ContextCandidates.self, json)
        #expect(candidates.personalContext.displayName == "José")
        #expect(candidates.contexts.count == 2)
        #expect(candidates.contexts[0].roles == ["admin"])
        #expect(candidates.contexts[0].memberCount == 5)
        // appContexts: persona primero + 2 colectivos
        let appContexts = candidates.appContexts
        #expect(appContexts.count == 3)
        #expect(appContexts[0].isPersonal)
        #expect(appContexts[1].isAdmin)
        #expect(!appContexts[2].isAdmin)
    }

    @Test("context_summary completo")
    func contextSummary() throws {
        let json = """
        {
          "context": {
            "id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
            "actor_kind": "collective",
            "actor_subtype": "friend_group",
            "display_name": "Cena Semanal",
            "status": "active",
            "visibility": "private",
            "created_at": "2026-06-02T20:06:31.733651+00:00"
          },
          "as_of": "2026-06-03T10:00:00.123456+00:00",
          "members_count": 5,
          "resources_count": 1,
          "pending_decisions": 2,
          "open_obligations": 3,
          "members": [
            {
              "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "display_name": "José",
              "membership_type": "founder",
              "joined_at": "2026-06-02T20:06:31.733651+00:00",
              "roles": ["admin"]
            },
            {
              "actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
              "display_name": "David",
              "membership_type": "member",
              "joined_at": "2026-06-02T21:06:31.733651+00:00",
              "roles": ["member"]
            }
          ],
          "my_permissions": ["context.view", "money.record", "decisions.vote"],
          "resources": [
            {
              "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Fondo común",
              "resource_type": "cash_pool",
              "estimated_value": 2500.50,
              "currency": "MXN"
            }
          ],
          "upcoming_events": [
            {
              "event_id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "Cena de los jueves",
              "event_type": "dinner",
              "starts_at": "2026-06-05T01:00:00+00:00",
              "host_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "status": "scheduled"
            }
          ],
          "open_decisions": [
            {
              "decision_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "¿Cambiamos de restaurante?",
              "decision_type": "generic",
              "payload": {},
              "created_at": "2026-06-03T09:00:00.5+00:00"
            }
          ],
          "money": {
            "open_obligations": [
              {
                "obligation_id": "f8098c1a-f86e-11da-bd1a-00112444be1e",
                "debtor_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
                "creditor_actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
                "obligation_type": "expense_share",
                "amount": 325,
                "currency": "MXN"
              }
            ],
            "my_balance": -325
          },
          "active_rules": [
            {
              "rule_id": "a1098c1a-f86e-11da-bd1a-00112444be1e",
              "title": "Multa por llegar tarde",
              "trigger_event_type": "event.checked_in"
            }
          ],
          "recent_activity": [
            {
              "event_type": "expense.recorded",
              "actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1",
              "payload": {"amount": 1300, "currency": "MXN"},
              "occurred_at": "2026-06-03T08:00:00.999999+00:00"
            }
          ]
        }
        """
        let summary = try decode(ContextSummary.self, json)
        #expect(summary.context.displayName == "Cena Semanal")
        #expect(summary.membersCount == 5)
        #expect(summary.members.count == 2)
        #expect(summary.members[0].isAdmin)
        #expect(summary.members[0].isFounder)
        #expect(summary.myPermissions.contains("money.record"))
        #expect(summary.can("money.record"))
        #expect(!summary.can("members.manage"))
        #expect(summary.resources[0].estimatedValue == 2500.50)
        #expect(summary.upcomingEvents[0].title == "Cena de los jueves")
        #expect(summary.openDecisions.count == 1)
        #expect(summary.money.myBalance == -325)
        #expect(summary.money.openObligations[0].amount == 325)
        #expect(summary.activeRules[0].triggerEventType == "event.checked_in")
        #expect(summary.recentActivity[0].payload?["amount"]?.numberValue == 1300)
        // Resolución de nombres
        #expect(summary.displayName(for: summary.members[1].actorId) == "David")
        #expect(summary.displayName(for: summary.context.id) == "Cena Semanal")
        #expect(summary.displayName(for: nil) == "—")
    }

    @Test("context_summary con secciones vacías")
    func contextSummaryEmpty() throws {
        let json = """
        {
          "context": {
            "id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
            "actor_kind": "person",
            "actor_subtype": "person",
            "display_name": "José",
            "status": "active",
            "visibility": "private"
          },
          "as_of": "2026-06-03T10:00:00.123456+00:00",
          "members_count": 0,
          "resources_count": 0,
          "pending_decisions": 0,
          "open_obligations": 0,
          "members": [],
          "my_permissions": [],
          "resources": [],
          "upcoming_events": [],
          "open_decisions": [],
          "money": {"open_obligations": [], "my_balance": 0},
          "active_rules": [],
          "recent_activity": []
        }
        """
        let summary = try decode(ContextSummary.self, json)
        #expect(summary.members.isEmpty)
        // Contexto personal: autoridad total aunque my_permissions venga vacío.
        #expect(summary.can("money.record"))
    }

    @Test("my_world")
    func myWorld() throws {
        let json = """
        {
          "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "contexts": [
            {
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Cena Semanal",
              "actor_kind": "collective",
              "actor_subtype": "friend_group",
              "membership_type": "founder"
            }
          ],
          "resources": [
            {
              "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
              "display_name": "Casa Valle",
              "resource_type": "house",
              "reasons": ["USE", "GOVERN via Familia Mizrahi"]
            }
          ],
          "open_obligations": [
            {
              "obligation_id": "f8098c1a-f86e-11da-bd1a-00112444be1e",
              "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
              "context_name": "Cena Semanal",
              "role": "debtor",
              "obligation_type": "expense_share",
              "amount": 325,
              "currency": "MXN"
            }
          ]
        }
        """
        let world = try decode(MyWorld.self, json)
        #expect(world.contexts.count == 1)
        #expect(world.resources[0].reasons.count == 2)
        #expect(world.resources[0].reasons.contains("USE"))
        #expect(world.openObligations[0].iOwe)
    }

    // MARK: - Resources

    @Test("resource_detail con rights")
    func resourceDetail() throws {
        let json = """
        {
          "resource": {
            "id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
            "resource_type": "house",
            "display_name": "Casa Valle",
            "description": "Casa familiar",
            "status": "active",
            "estimated_value": 4500000,
            "currency": "MXN",
            "created_by_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
            "canonical_owner_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
            "metadata": {},
            "client_id": null,
            "created_at": "2026-06-02T20:06:31.733651+00:00",
            "updated_at": "2026-06-02T20:06:31.733651+00:00",
            "archived_at": null
          },
          "rights": [
            {
              "right_id": "11111111-f86e-11da-bd1a-00112444be1e",
              "holder_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
              "holder_display_name": "Familia Mizrahi",
              "right_kind": "OWN",
              "percent": 100,
              "scope": null,
              "starts_at": null,
              "ends_at": null
            },
            {
              "right_id": "22222222-f86e-11da-bd1a-00112444be1e",
              "holder_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "holder_display_name": "José",
              "right_kind": "USE",
              "percent": null,
              "scope": null,
              "starts_at": null,
              "ends_at": null
            }
          ]
        }
        """
        let detail = try decode(ResourceDetail.self, json)
        #expect(detail.resource.displayName == "Casa Valle")
        #expect(detail.resource.type == .house)
        #expect(detail.rights.count == 2)
        #expect(detail.rights[0].kind == .own)
        #expect(detail.rights[0].percent == 100)
        let joseId = UUID(uuidString: "0e984725-c51c-4bf4-9960-e1c80e27aba1")!
        #expect(detail.reasons(for: joseId).map(\.rightKind) == ["USE"])
    }

    @Test("list_context_resources")
    func listContextResources() throws {
        let json = """
        [
          {
            "resource_id": "c8098c1a-f86e-11da-bd1a-00112444be1e",
            "resource_type": "house",
            "display_name": "Casa Valle",
            "status": "active",
            "estimated_value": null,
            "currency": null,
            "canonical_owner_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
            "rights": [
              {
                "right_id": "11111111-f86e-11da-bd1a-00112444be1e",
                "holder_actor_id": "b8098c1a-f86e-11da-bd1a-00112444be1e",
                "right_kind": "OWN",
                "percent": 100
              }
            ]
          }
        ]
        """
        let resources = try decode([ContextResource].self, json)
        #expect(resources.count == 1)
        #expect(resources[0].rights.count == 1)
        #expect(resources[0].type == .house)
    }

    // MARK: - Events

    @Test("fila de calendar_events (PostgREST)")
    func calendarEventRow() throws {
        let json = """
        {
          "id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
          "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
          "title": "Cena de los jueves",
          "description": null,
          "event_type": "dinner",
          "starts_at": "2026-06-05T01:00:00.482113+00:00",
          "ends_at": null,
          "timezone": "America/Mexico_City",
          "location_text": "Casa de José",
          "location_metadata": {},
          "recurrence_rule": "weekly",
          "host_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "status": "scheduled",
          "metadata": {},
          "client_id": null,
          "created_by_actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
          "created_at": "2026-06-02T20:06:31.733651+00:00",
          "updated_at": "2026-06-02T20:06:31.733651+00:00",
          "cancelled_at": null
        }
        """
        let event = try decode(CalendarEvent.self, json)
        #expect(event.title == "Cena de los jueves")
        #expect(event.type == .dinner)
        #expect(event.isRecurring)
        #expect(event.isScheduled)
    }

    @Test("check_in_participant tarde")
    func checkInLate() throws {
        let json = """
        {
          "participant_id": "11111111-f86e-11da-bd1a-00112444be1e",
          "status": "late",
          "checked_in_at": "2026-06-05T01:31:00.482113+00:00",
          "minutes_late": 31.0,
          "rules": {"rules_matched": 1, "obligations_created": [{"obligation_id": "22222222-f86e-11da-bd1a-00112444be1e", "amount": 100}]}
        }
        """
        let result = try decode(CheckInResult.self, json)
        #expect(result.isLate)
        #expect(result.minutesLate == 31.0)
        #expect(!result.alreadyCheckedIn)
    }

    @Test("cancel_participation mismo día")
    func cancelSameDay() throws {
        let json = """
        {
          "participant_id": "11111111-f86e-11da-bd1a-00112444be1e",
          "status": "cancelled",
          "cancelled_at": "2026-06-05T00:00:00+00:00",
          "same_day_cancellation": true,
          "rules": {"rules_matched": 1}
        }
        """
        let result = try decode(CancelParticipationResult.self, json)
        #expect(result.sameDayCancellation)
    }

    @Test("close_event con rotación de host")
    func closeEvent() throws {
        let json = """
        {
          "event_id": "d8098c1a-f86e-11da-bd1a-00112444be1e",
          "status": "completed",
          "no_shows": 2,
          "next_event_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
          "next_host_actor_id": "1e984725-c51c-4bf4-9960-e1c80e27aba1"
        }
        """
        let result = try decode(CloseEventResult.self, json)
        #expect(result.noShows == 2)
        #expect(result.nextEventId != nil)
        #expect(!result.alreadyClosed)
    }

    // MARK: - Money

    @Test("record_expense con obligations")
    func recordExpense() throws {
        let json = """
        {
          "transaction_id": "33333333-f86e-11da-bd1a-00112444be1e",
          "share_per_person": 325.00,
          "split_method": "equal",
          "obligations": [
            {"obligation_id": "44444444-f86e-11da-bd1a-00112444be1e", "debtor": "0e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 325.00},
            {"obligation_id": "55555555-f86e-11da-bd1a-00112444be1e", "debtor": "1e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 325.00}
          ]
        }
        """
        let result = try decode(ExpenseResult.self, json)
        #expect(result.sharePerPerson == 325)
        #expect(result.obligations.count == 2)
        #expect(!result.idempotentReplay)
    }

    @Test("generate_settlement_batch con items")
    func settlementBatch() throws {
        let json = """
        {
          "batch_id": "66666666-f86e-11da-bd1a-00112444be1e",
          "items": [
            {"from": "0e984725-c51c-4bf4-9960-e1c80e27aba1", "to": "1e984725-c51c-4bf4-9960-e1c80e27aba1", "amount": 400.00}
          ],
          "obligations_netted": 3
        }
        """
        let result = try decode(SettlementBatchResult.self, json)
        #expect(result.batchId != nil)
        #expect(result.items.count == 1)
        #expect(result.items[0].amount == 400)
        #expect(result.obligationsNetted == 3)
    }

    @Test("generate_settlement_batch cuando todo netea a cero")
    func settlementNetsToZero() throws {
        let json = """
        {
          "batch_id": null,
          "items": [],
          "message": "all obligations net to zero — settled directly",
          "obligations_settled": 2
        }
        """
        let result = try decode(SettlementBatchResult.self, json)
        #expect(result.batchId == nil)
        #expect(result.items.isEmpty)
        #expect(result.message != nil)
    }

    @Test("mark_settlement_paid")
    func markPaid() throws {
        let json = """
        {
          "item_id": "77777777-f86e-11da-bd1a-00112444be1e",
          "transaction_id": "88888888-f86e-11da-bd1a-00112444be1e",
          "batch_finalized": true,
          "obligations_closed": 3
        }
        """
        let result = try decode(MarkPaidResult.self, json)
        #expect(result.batchFinalized)
        #expect(result.obligationsClosed == 3)
        #expect(!result.alreadyPaid)
    }

    // MARK: - Decisions

    @Test("vote_decision con tally")
    func voteDecision() throws {
        let json = """
        {
          "decision_id": "e8098c1a-f86e-11da-bd1a-00112444be1e",
          "my_vote": "approve",
          "my_option": null,
          "status": "approved",
          "tally": {"approve": 3, "reject": 1, "members": 5}
        }
        """
        let result = try decode(VoteResult.self, json)
        #expect(result.status == "approved")
        #expect(result.tally?.approve == 3)
        #expect(result.tally?.members == 5)
    }

    // MARK: - Activity

    @Test("list_activity")
    func listActivity() throws {
        let json = """
        {
          "context_actor_id": "a8098c1a-f86e-11da-bd1a-00112444be1e",
          "limit": 50,
          "activity": [
            {
              "id": "99999999-f86e-11da-bd1a-00112444be1e",
              "event_type": "fine.created",
              "actor_id": "0e984725-c51c-4bf4-9960-e1c80e27aba1",
              "subject_type": "obligation",
              "subject_id": "44444444-f86e-11da-bd1a-00112444be1e",
              "payload": {"system": true, "amount": 100},
              "resource_id": null,
              "decision_id": null,
              "obligation_id": "44444444-f86e-11da-bd1a-00112444be1e",
              "occurred_at": "2026-06-03T08:00:00.999999+00:00"
            }
          ]
        }
        """
        let page = try decode(ActivityPage.self, json)
        #expect(page.activity.count == 1)
        #expect(page.activity[0].isSystemGenerated)
        #expect(page.activity[0].typeLabel == "Multa generada")
        #expect(page.activity[0].domain == "fine")
    }

    // MARK: - Reglas legibles

    @Test("descripción legible de reglas")
    func ruleDescriptions() throws {
        let lateRule = Rule(
            id: UUID(),
            contextActorId: UUID(),
            title: "Multa por tarde",
            triggerEventType: RuleTrigger.checkedIn.rawValue,
            conditionTree: RuleConditionBuilder.lateMoreThan(minutes: 15),
            consequences: RuleConsequenceBuilder.fine(amount: 100, currency: "MXN")
        )
        #expect(lateRule.conditionDescription.contains("minutos tarde"))
        #expect(lateRule.conditionDescription.contains("mayor a"))
        #expect(lateRule.consequenceDescription.contains("Multa"))
        #expect(lateRule.consequenceDescription.contains("MXN"))

        let alwaysRule = Rule(id: UUID(), contextActorId: UUID(), title: "Sin condición")
        #expect(alwaysRule.conditionDescription == "Siempre aplica")
    }
}
