import Foundation

public struct SwitcherMRUOrderingContext: Equatable, Sendable {
    public let orderedItemIDs: [String]
    public let currentItemID: String?
    public let sourceDescription: String
    public let fallbackReason: String?

    public init(
        orderedItemIDs: [String],
        currentItemID: String? = nil,
        sourceDescription: String,
        fallbackReason: String? = nil
    ) {
        self.orderedItemIDs = orderedItemIDs
        self.currentItemID = currentItemID
        self.sourceDescription = sourceDescription
        self.fallbackReason = fallbackReason
    }

    public static func fallback(reason: String) -> SwitcherMRUOrderingContext {
        SwitcherMRUOrderingContext(
            orderedItemIDs: [],
            sourceDescription: "fallback",
            fallbackReason: reason
        )
    }

    public var isFallback: Bool {
        orderedItemIDs.isEmpty || fallbackReason != nil
    }
}

public protocol SwitcherMRUOrderingProviding: AnyObject {
    func orderingContext(for mode: SwitcherMode, items: [SwitcherItem]) -> SwitcherMRUOrderingContext
}

public protocol SwitcherMRUHistoryRecording: AnyObject {
    func recordActivatedItem(_ item: SwitcherItem)
    func recordActivatedApp(_ app: AppIdentity)
}

public protocol SwitcherMRUTracking: AnyObject {
    func startTracking()
    func stopTracking()
}

public enum SwitcherMRUOrderer {
    public struct Diagnostics: Equatable, Sendable {
        public let matchedItemCount: Int
        public let unmatchedItemCount: Int
        public let partialFallbackReason: String?
    }

    public static func order(
        items: [SwitcherItem],
        context: SwitcherMRUOrderingContext
    ) -> [SwitcherItem] {
        let titleSortedItems = items.sortedForSwitcher()
        guard !titleSortedItems.isEmpty else { return [] }
        guard !context.orderedItemIDs.isEmpty else { return titleSortedItems }

        let itemsByID = Dictionary(grouping: titleSortedItems, by: \.id)
        let knownIDs = uniqueIDs(context.orderedItemIDs).filter { itemsByID[$0] != nil }
        guard !knownIDs.isEmpty else { return titleSortedItems }

        let mruCandidateIDs = currentFirstIDs(knownIDs: knownIDs, currentItemID: context.currentItemID)
        let knownIDSet = Set(mruCandidateIDs)
        let knownItems = mruCandidateIDs.flatMap { itemsByID[$0] ?? [] }
        let unknownItems = titleSortedItems.filter { !knownIDSet.contains($0.id) }

        return knownItems + unknownItems
    }

    public static func defaultSelectedIndex(
        orderedItems: [SwitcherItem],
        context: SwitcherMRUOrderingContext
    ) -> Int {
        guard orderedItems.count > 1,
              !context.isFallback,
              let currentItemID = context.currentItemID,
              orderedItems.first?.id == currentItemID
        else { return 0 }

        return 1
    }

    public static func diagnostics(
        items: [SwitcherItem],
        context: SwitcherMRUOrderingContext
    ) -> Diagnostics {
        let itemIDs = Set(items.map(\.id))
        guard !itemIDs.isEmpty else {
            return Diagnostics(matchedItemCount: 0, unmatchedItemCount: 0, partialFallbackReason: nil)
        }
        guard !context.isFallback else {
            return Diagnostics(matchedItemCount: 0, unmatchedItemCount: itemIDs.count, partialFallbackReason: nil)
        }

        let matchedItemIDs = Set(uniqueIDs(context.orderedItemIDs)).intersection(itemIDs)
        let unmatchedItemCount = itemIDs.subtracting(matchedItemIDs).count
        return Diagnostics(
            matchedItemCount: matchedItemIDs.count,
            unmatchedItemCount: unmatchedItemCount,
            partialFallbackReason: unmatchedItemCount > 0 ? "title-sort-unmatched-items" : nil
        )
    }

    private static func uniqueIDs(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    private static func currentFirstIDs(
        knownIDs: [String],
        currentItemID: String?
    ) -> [String] {
        guard let currentItemID,
              let currentIndex = knownIDs.firstIndex(of: currentItemID)
        else { return knownIDs }

        var ids = knownIDs
        ids.remove(at: currentIndex)
        ids.insert(currentItemID, at: 0)
        return ids
    }
}
