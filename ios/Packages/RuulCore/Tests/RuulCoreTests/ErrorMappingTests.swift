import Testing
import Foundation
@testable import RuulCore

@Suite("Mapeo de errores del backend MVP2")
struct ErrorMappingTests {

    @Test("unauthenticated")
    func unauthenticated() {
        let error = RPCErrorMapper.parse(message: "unauthenticated", code: "28000")
        #expect(error == .unauthenticated)
    }

    @Test("not a member of context")
    func notAMember() {
        let error = RPCErrorMapper.parse(
            message: "not a member of context a8098c1a-f86e-11da-bd1a-00112444be1e",
            code: "42501"
        )
        #expect(error == .notAMember)
    }

    @Test("missing permission")
    func missingPermission() {
        let error = RPCErrorMapper.parse(message: "missing permission events.create", code: "42501")
        #expect(error == .missingPermission(key: "events.create"))
    }

    @Test("not authorized genérico → missingPermission")
    func notAuthorized() {
        let error = RPCErrorMapper.parse(
            message: "not authorized to record money in context a8098c1a-f86e-11da-bd1a-00112444be1e",
            code: "42501"
        )
        if case .missingPermission = error {
            // ok
        } else {
            Issue.record("Se esperaba missingPermission, fue \(error)")
        }
    }

    @Test("validaciones 22023")
    func validation() {
        #expect(RPCErrorMapper.parse(message: "amount must be positive", code: "22023")
            == .validation(message: "amount must be positive"))
        #expect(RPCErrorMapper.parse(message: "splits must sum to amount (500 vs 600)", code: "22023")
            == .validation(message: "splits must sum to amount (500 vs 600)"))
    }

    @Test("overlap de reservaciones (EXCLUDE 23P01)")
    func reservationOverlap() {
        let error = RPCErrorMapper.parse(
            message: "conflicting key value violates exclusion constraint \"resource_reservations_no_overlap\"",
            code: "23P01"
        )
        #expect(error == .reservationOverlap)
    }

    @Test("invite inválido")
    func invalidInvite() {
        let error = RPCErrorMapper.parse(message: "invite not found or revoked", code: "22023")
        if case .invalidInvite = error {
            // ok
        } else {
            Issue.record("Se esperaba invalidInvite, fue \(error)")
        }
    }

    @Test("mensaje desconocido cae a unknown")
    func unknown() {
        let error = RPCErrorMapper.parse(message: "algo totalmente nuevo", code: nil)
        #expect(error == .unknown(message: "algo totalmente nuevo"))
    }

    @Test("not_implemented por código 0A000 (R.5A.B.8 dispatcher)")
    func notImplementedByCode() {
        let error = RPCErrorMapper.parse(message: "not_implemented", code: "0A000")
        #expect(error == .notImplemented(actionKey: nil))
    }

    @Test("not_implemented por mensaje aunque code sea nil")
    func notImplementedByMessage() {
        let error = RPCErrorMapper.parse(message: "not_implemented", code: nil)
        #expect(error == .notImplemented(actionKey: nil))
    }

    @Test("not_implemented extrae action_key entre comillas simples")
    func notImplementedExtractsQuotedActionKey() {
        let error = RPCErrorMapper.parse(
            message: "action 'record_contribution' not_implemented",
            code: "0A000"
        )
        #expect(error == .notImplemented(actionKey: "record_contribution"))
    }

    @Test("action_not_wired también mapea a notImplemented")
    func actionNotWired() {
        let error = RPCErrorMapper.parse(message: "action_not_wired: convert_to_settlement", code: "0A000")
        #expect(error == .notImplemented(actionKey: "convert_to_settlement"))
    }

    @Test("not_implemented copy oficial founder-signed (R.5X.fix.A)")
    func notImplementedUserCopy() {
        let ufe = UserFacingError.from(BackendError.notImplemented(actionKey: "record_contribution"))
        #expect(ufe.title == "Próximamente")
        #expect(ufe.message == "Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible.")
    }

    @Test("not_implemented sin action_key reusa la misma copia")
    func notImplementedNilActionKeyCopy() {
        let ufe = UserFacingError.from(BackendError.notImplemented(actionKey: nil))
        #expect(ufe.title == "Próximamente")
        #expect(ufe.message == "Esta funcionalidad ya está modelada en Ruul, pero todavía no está disponible.")
    }

    @Test("not_implemented no se traga validaciones con 'invalid' en el mensaje")
    func notImplementedDoesNotShadowValidation() {
        // El parser tiene un check de "invalid" para .validation. Confirma que
        // un mensaje con "invalid" + sin not_implemented sigue cayendo en validation.
        let error = RPCErrorMapper.parse(message: "amount is invalid", code: "22023")
        if case .validation = error { /* ok */ } else {
            Issue.record("Se esperaba validation, fue \(error)")
        }
    }

    @Test("copy en español para UI")
    func userFacingCopy() {
        #expect(UserFacingError.from(BackendError.unauthenticated).title == "Inicia sesión")
        #expect(UserFacingError.from(BackendError.reservationOverlap).title == "Fechas ocupadas")
        let validation = UserFacingError.from(BackendError.validation(message: "amount must be positive"))
        #expect(validation.message == "El monto debe ser mayor a cero.")
        let splitError = UserFacingError.from(BackendError.validation(message: "splits must sum to amount (500 vs 600)"))
        #expect(splitError.message == "El reparto no suma el total del gasto.")
    }
}
