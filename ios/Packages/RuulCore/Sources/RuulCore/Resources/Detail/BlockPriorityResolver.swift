import Foundation

/// Pure ordering function. Given a list of CapabilityBlocks produced
/// by a builder (in their natural builder order), return them in the
/// order they should render on screen.
///
/// Three buckets, stable-sort within each:
///   1. Viewer obligations (isViewerObligation == true)
///   2. Active (non-empty) blocks
///   3. Empty prompts (layoutKind == .emptyPrompt)
///
/// `isViewerObligation` takes precedence over `.emptyPrompt`: a block
/// that is BOTH an obligation AND an empty prompt lands in bucket 1.
/// Rationale — an unmet obligation that has no data yet (e.g. "you
/// haven't RSVP'd, the response list is empty") still needs to be
/// surfaced prominently, not sunk to the bottom.
public enum BlockPriorityResolver {
    public static func order(_ blocks: [CapabilityBlock]) -> [CapabilityBlock] {
        var obligations: [CapabilityBlock] = []
        var active: [CapabilityBlock] = []
        var empty: [CapabilityBlock] = []

        for b in blocks {
            if b.isViewerObligation { obligations.append(b) }
            else if b.layoutKind == .emptyPrompt { empty.append(b) }
            else { active.append(b) }
        }

        return obligations + active + empty
    }
}
