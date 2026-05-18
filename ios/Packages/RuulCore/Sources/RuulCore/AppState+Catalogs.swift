import Foundation

/// Cold-load + server-refresh of the three platform catalogs:
/// `moduleRegistry`, `ruleShapeRegistry`, `ruleTemplates`. Each loader
/// is silent on error — the cold-start fallback or last-good catalog
/// stays usable so a transient network blip never degrades UX.
///
/// Extracted from `AppState.swift` 2026-05-18 per
/// Plans/Active/CleanupAudit_2026-05-18/01_architecture.md §2.1
/// (god-object split). The corresponding `*Loader` / `*Repo` stored
/// properties live on the class declaration since class extensions
/// can't add stored state.
public extension AppState {

    /// Refreshes `moduleRegistry` from the server-side `public.modules`
    /// catalog (mig 00060). Falls back to the existing registry on error
    /// — the cold-start `v1Fallback` is always good enough for the V1
    /// surface, so a transient network blip doesn't degrade UX.
    func loadModuleRegistry() async {
        guard let loader = moduleRegistryLoader else { return }
        do {
            self.moduleRegistry = try await loader.load()
        } catch {
            // Keep current (fallback or last-good) registry. Server drift
            // is checked by tests + CI parity, not by runtime.
        }
    }

    /// Refreshes `ruleShapeRegistry` from `list_rule_shapes` (mig 00084).
    /// Same resilience contract as `loadModuleRegistry`: silent on error,
    /// previously-loaded (or fallback) registry stays usable.
    func loadRuleShapeRegistry() async {
        guard let repo = ruleShapeRepo else { return }
        do {
            self.ruleShapeRegistry = try await repo.load()
        } catch {
            // Keep v1Fallback / last-good registry on failure.
        }
    }

    /// Refreshes `ruleTemplates` from `list_rule_templates` (mig 00182).
    /// Same resilience contract: silent on error, last-good catalog stays.
    func loadRuleTemplates() async {
        guard let repo = ruleTemplateRepo else { return }
        do {
            self.ruleTemplates = try await repo.loadTemplates()
        } catch {
            // Keep seed catalog on failure.
        }
    }
}
