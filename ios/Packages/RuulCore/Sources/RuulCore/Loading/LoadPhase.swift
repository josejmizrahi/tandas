import Foundation

/// Canonical load-state enum for coordinator-driven views.
///
/// Reemplaza el patrón disperso `isLoading: Bool + error: CoordinatorError? + data: T`
/// que cada coordinator reinventaba. Las vistas pasan un `LoadPhase` a
/// `AsyncContentView` y la primitiva renderiza el estado correcto.
///
/// Distingue 6 estados — la diferencia clave vs un `Result?` simple es
/// `refreshing(Value)`: cuando el usuario hace pull-to-refresh teniendo
/// datos previos, la vista debe seguir mostrando la lista (con un indicador
/// discreto) en vez de regresar al spinner full-screen.
///
/// `failed(error, previous:)` permite degradar de forma elegante cuando
/// un refresh falla pero teníamos datos buenos — el usuario sigue viendo
/// la última snapshot con un banner de error en vez de quedarse a
/// oscuras.
public enum LoadPhase<Value: Sendable>: Sendable {
    /// Estado inicial — el coordinator aún no disparó la primera carga.
    /// Renderiza placeholder neutral; nunca debería verse en producción.
    case idle

    /// Primera carga (sin datos previos). UI muestra spinner full-screen
    /// con debounce de 250ms para evitar flash en cargas rápidas.
    case loading

    /// Re-carga con datos previos visibles. UI muestra la lista anterior
    /// + indicador inline (top progress bar). Garantiza continuidad
    /// visual en pull-to-refresh y refresh programático.
    case refreshing(Value)

    /// Carga exitosa con datos.
    case loaded(Value)

    /// Carga exitosa pero sin items. UI muestra `EmptyStateView` con CTAs
    /// opcionales. Distinto de `.loading` para que la vista pueda saber
    /// si está esperando o si genuinamente no hay nada.
    case empty

    /// Carga fallida. Si `previous` está presente, la vista degrada
    /// mostrando los datos anteriores + banner de error; si no, full
    /// `ErrorStateView` con retry.
    case failed(CoordinatorError, previous: Value? = nil)
}

public extension LoadPhase {
    /// Valor actual visible al usuario (incluye stale data durante
    /// `refreshing` y `failed-with-previous`). nil cuando no hay nada
    /// que mostrar.
    var value: Value? {
        switch self {
        case .loaded(let v), .refreshing(let v): return v
        case .failed(_, let prev): return prev
        case .idle, .loading, .empty: return nil
        }
    }

    /// Error actual — solo presente en `.failed`. No incluye errores
    /// silenciosos best-effort (esos se loguean en el coordinator).
    var error: CoordinatorError? {
        if case .failed(let err, _) = self { return err }
        return nil
    }

    /// True solo durante la primera carga sin datos. Usar para mostrar
    /// spinner full-screen; durante refresh con datos previos preferí
    /// `isRefreshing` + indicador discreto.
    var isInitialLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// True durante re-carga con datos previos visibles. Usar para
    /// mostrar indicadores inline (top progress bar) sin tapar el
    /// contenido.
    var isRefreshing: Bool {
        if case .refreshing = self { return true }
        return false
    }

    /// True cuando hay cualquier actividad de red en curso
    /// (`loading` o `refreshing`). Útil para deshabilitar botones de
    /// retry o pull-to-refresh nested.
    var isBusy: Bool { isInitialLoading || isRefreshing }

    /// True si la fase actual está exponiendo datos (loaded, refreshing,
    /// o failed-with-previous). False para idle, loading, empty,
    /// failed-without-previous.
    var hasValue: Bool { value != nil }
}

public extension LoadPhase {
    /// Adapter desde el patrón legacy `isLoading + error + value` que
    /// usan todos los coordinators actuales. Permite migración
    /// incremental: el coordinator mantiene sus campos `@Observable` y
    /// solo expone un computed property `phase` que delega aquí.
    ///
    /// `isEmpty` se evalúa solo cuando `value` está presente y no hay
    /// error/loading; default false (escalar). Para listas pasar
    /// `\.isEmpty` o `{ $0.isEmpty }`.
    ///
    /// Reglas de precedencia (de mayor a menor):
    /// 1. Si hay `error` y `value` → `.failed(error, previous: value)`
    ///    (degradar elegantemente, mostrar stale data + banner)
    /// 2. Si hay `error` sin `value` → `.failed(error)` (full error UI)
    /// 3. Si `isLoading` y hay `value` → `.refreshing(value)`
    /// 4. Si `isLoading` sin `value` → `.loading`
    /// 5. Si hay `value` y `isEmpty(value)` → `.empty`
    /// 6. Si hay `value` → `.loaded(value)`
    /// 7. Estado inicial sin pedir nada → `.idle`
    static func from(
        value: Value?,
        isLoading: Bool,
        error: CoordinatorError?,
        isEmpty: (Value) -> Bool = { _ in false }
    ) -> LoadPhase<Value> {
        if let error {
            return .failed(error, previous: value)
        }
        if let value {
            if isLoading { return .refreshing(value) }
            if isEmpty(value) { return .empty }
            return .loaded(value)
        }
        return isLoading ? .loading : .idle
    }
}

public extension LoadPhase where Value: Collection {
    /// Adapter para coordinators que exponen su data como colección
    /// no-opcional (e.g. `var rules: [GroupRule] = []`). El parámetro
    /// `hasLoaded` distingue entre "nunca cargué" (array vacío default)
    /// y "cargué y confirmé vacío" — ambos se ven como `[]` pero
    /// tienen UX distinto (`.loading` vs `.empty`).
    ///
    /// Reglas:
    /// - `error != nil` → `.failed(err, previous: hasLoaded ? value : nil)`
    /// - `isLoading && !hasLoaded` → `.loading`
    /// - `isLoading && hasLoaded` → `.refreshing(value)`
    /// - `!hasLoaded` → `.idle`
    /// - `hasLoaded && value.isEmpty` → `.empty`
    /// - `hasLoaded && !value.isEmpty` → `.loaded(value)`
    static func fromCollection(
        value: Value,
        hasLoaded: Bool,
        isLoading: Bool,
        error: CoordinatorError?
    ) -> LoadPhase<Value> {
        if let error {
            return .failed(error, previous: hasLoaded ? value : nil)
        }
        if isLoading {
            return hasLoaded ? .refreshing(value) : .loading
        }
        if !hasLoaded { return .idle }
        return value.isEmpty ? .empty : .loaded(value)
    }
}

extension LoadPhase: Equatable where Value: Equatable {
    public static func == (lhs: LoadPhase<Value>, rhs: LoadPhase<Value>) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.empty, .empty):
            return true
        case (.loaded(let a), .loaded(let b)),
             (.refreshing(let a), .refreshing(let b)):
            return a == b
        case (.failed(let ea, let pa), .failed(let eb, let pb)):
            return ea == eb && pa == pb
        default:
            return false
        }
    }
}
