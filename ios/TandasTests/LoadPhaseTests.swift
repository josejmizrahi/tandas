import Testing
import Foundation
@testable import RuulCore

/// Coverage para la primitiva de carga canónica (`LoadPhase<Value>`).
///
/// `LoadPhase` reemplaza el patrón disperso `isLoading + error + data`
/// con un enum rico que distingue 6 estados (idle/loading/refreshing/
/// loaded/empty/failed) y consume `AsyncContentView` en UI.
///
/// Los tests cubren las dos rutas más importantes:
/// 1. **Factory `fromCollection`** — la matriz de inputs (hasLoaded ×
///    isLoading × error × items.isEmpty) debe mapear al estado correcto.
///    Bugs aquí causan estados visuales contradictorios en producción
///    (e.g. mostrar spinner sobre lista vacía cuando deberíamos mostrar
///    EmptyStateView).
/// 2. **Helpers derivados** — `value`, `error`, `isInitialLoading`,
///    `isRefreshing`, `hasValue`. Usados por AsyncContentView para
///    decidir qué primitiva renderizar.
@Suite("LoadPhase")
struct LoadPhaseTests {
    // MARK: - fromCollection

    @Test("idle: nunca cargado, sin loading, sin error → .idle")
    func idleInitial() {
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [], hasLoaded: false, isLoading: false, error: nil
        )
        #expect(phase == .idle)
    }

    @Test("loading: primera carga sin data previa → .loading")
    func loadingInitial() {
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [], hasLoaded: false, isLoading: true, error: nil
        )
        #expect(phase == .loading)
    }

    @Test("refreshing: re-carga con data previa → .refreshing(value)")
    func refreshingWithPreviousData() {
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [1, 2, 3], hasLoaded: true, isLoading: true, error: nil
        )
        #expect(phase == .refreshing([1, 2, 3]))
    }

    @Test("loaded: data presente, no loading, no error → .loaded(value)")
    func loadedWithData() {
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [1, 2, 3], hasLoaded: true, isLoading: false, error: nil
        )
        #expect(phase == .loaded([1, 2, 3]))
    }

    @Test("empty: cargó pero array vacío → .empty (distinto de .loading)")
    func emptyAfterLoad() {
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [], hasLoaded: true, isLoading: false, error: nil
        )
        #expect(phase == .empty)
    }

    @Test("failed sin data previa → .failed(err, previous: nil)")
    func failedFresh() {
        let err = CoordinatorError(title: "Network", message: nil)
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [], hasLoaded: false, isLoading: false, error: err
        )
        #expect(phase == .failed(err, previous: nil))
    }

    @Test("failed con data previa → .failed(err, previous: value) [stale-on-error]")
    func failedWithStaleData() {
        let err = CoordinatorError(title: "Network", message: nil)
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [1, 2], hasLoaded: true, isLoading: false, error: err
        )
        #expect(phase == .failed(err, previous: [1, 2]))
    }

    @Test("failed durante refresh: el error gana sobre isLoading")
    func failedTakesPriorityOverLoading() {
        let err = CoordinatorError(title: "X", message: nil)
        let phase = LoadPhase<[Int]>.fromCollection(
            value: [1], hasLoaded: true, isLoading: true, error: err
        )
        if case .failed(let e, let prev) = phase {
            #expect(e == err)
            #expect(prev == [1])
        } else {
            Issue.record("expected .failed, got \(phase)")
        }
    }

    // MARK: - Helpers derivados

    @Test("isInitialLoading true solo para .loading puro")
    func isInitialLoadingDiscrimination() {
        #expect(LoadPhase<[Int]>.loading.isInitialLoading)
        #expect(!LoadPhase<[Int]>.refreshing([1]).isInitialLoading)
        #expect(!LoadPhase<[Int]>.loaded([1]).isInitialLoading)
        #expect(!LoadPhase<[Int]>.idle.isInitialLoading)
        #expect(!LoadPhase<[Int]>.empty.isInitialLoading)
    }

    @Test("isRefreshing true solo para .refreshing")
    func isRefreshingDiscrimination() {
        #expect(LoadPhase<[Int]>.refreshing([1]).isRefreshing)
        #expect(!LoadPhase<[Int]>.loading.isRefreshing)
        #expect(!LoadPhase<[Int]>.loaded([1]).isRefreshing)
    }

    @Test("isBusy true durante loading o refreshing")
    func isBusyCoverage() {
        #expect(LoadPhase<[Int]>.loading.isBusy)
        #expect(LoadPhase<[Int]>.refreshing([1]).isBusy)
        #expect(!LoadPhase<[Int]>.loaded([1]).isBusy)
        #expect(!LoadPhase<[Int]>.empty.isBusy)
        #expect(!LoadPhase<[Int]>.idle.isBusy)
    }

    @Test("value extrae payload de .loaded, .refreshing, y .failed-with-previous")
    func valueExtraction() {
        #expect(LoadPhase.loaded([1, 2]).value == [1, 2])
        #expect(LoadPhase.refreshing([3]).value == [3])
        let err = CoordinatorError(title: "x", message: nil)
        #expect(LoadPhase.failed(err, previous: [9]).value == [9])
        #expect(LoadPhase<[Int]>.failed(err, previous: nil).value == nil)
        #expect(LoadPhase<[Int]>.loading.value == nil)
        #expect(LoadPhase<[Int]>.idle.value == nil)
        #expect(LoadPhase<[Int]>.empty.value == nil)
    }

    @Test("error solo presente en .failed")
    func errorOnlyInFailed() {
        let err = CoordinatorError(title: "x", message: nil)
        #expect(LoadPhase<[Int]>.failed(err).error == err)
        #expect(LoadPhase<[Int]>.loaded([1]).error == nil)
        #expect(LoadPhase<[Int]>.loading.error == nil)
    }

    // MARK: - factory genérico (escalar)

    @Test("scalar from: value present sin loading → .loaded")
    func scalarLoaded() {
        let phase = LoadPhase.from(
            value: "hello", isLoading: false, error: nil
        )
        #expect(phase == .loaded("hello"))
    }

    @Test("scalar from: error con value previo → failed-with-previous")
    func scalarFailedWithPrevious() {
        let err = CoordinatorError(title: "x", message: nil)
        let phase = LoadPhase.from(
            value: "stale", isLoading: false, error: err
        )
        if case .failed(let e, let prev) = phase {
            #expect(e == err)
            #expect(prev == "stale")
        } else {
            Issue.record("expected .failed, got \(phase)")
        }
    }
}
