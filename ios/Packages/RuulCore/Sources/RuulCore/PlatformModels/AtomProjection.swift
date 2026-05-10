import Foundation

/// Marker protocol identifying a model as an **Atom**: an append-only,
/// authoritative record of a fact that happened. Atoms are written
/// once and never edited or deleted — the source of truth for the
/// system's history.
///
/// Examples (Plans/Active/AtomProjection.md): `SystemEvent`,
/// `VoteCast`, future `LedgerEntry`, future `Contribution`,
/// future `Payout`.
///
/// **Rules for atoms** (enforced by code review, not the type system):
/// - Persisted in a table that has *no* `UPDATE` trigger that mutates
///   business fields. Append-only. `id` and `created_at` are stable.
/// - Written via `record_*` SECURITY DEFINER functions OR through
///   triggers from other writes — never directly by user CRUD.
/// - The rule engine + projections are the only consumers; UI never
///   reads atoms directly.
///
/// `AtomTableName` is the SQL table name where the atom is persisted.
/// Used only as documentation today; future tooling may consume it
/// for codegen or audits.
public protocol Atom: Sendable, Codable, Identifiable {
    /// Underlying SQL table name. Lowercase snake_case.
    static var atomTableName: String { get }
}

/// Marker protocol identifying a model as a **Projection**: a derived
/// read-side view of one or more atoms. Projections are
/// recomputable, cacheable, and disposable — they exist to serve UI
/// or analytics queries efficiently.
///
/// Examples: `events_view` (projection of `events` + recurrence
/// resolution), `vote_counts_view` (projection of `vote_casts`),
/// `group_members_with_founder` (projection of `group_members` +
/// `groups.created_by`), future `Balance` (projection of
/// `LedgerEntry`).
///
/// **Rules for projections** (enforced by code review):
/// - Persisted in a SQL view, materialized view, or computed at read
///   time. Never a mutable table that's updated independently of the
///   source atom.
/// - Reading a projection that's stale or missing is recoverable —
///   re-running the projection against the atom is the canonical
///   recovery path.
/// - Mutations land in the atom; the projection updates reactively
///   (or on next read).
public protocol Projection: Sendable, Codable {
    /// SQL view / materialized view this projection reads from.
    static var projectionViewName: String { get }
}
