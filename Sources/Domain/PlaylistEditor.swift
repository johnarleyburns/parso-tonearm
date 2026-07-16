import Foundation

public enum PlaylistEditor {
    public static func normalized(_ items: [PlaylistItem]) -> [PlaylistItem] {
        renumber(
            items.enumerated().sorted { lhs, rhs in
                if lhs.element.position != rhs.element.position {
                    return lhs.element.position < rhs.element.position
                }
                switch (lhs.element.id, rhs.element.id) {
                case let (.some(left), .some(right)) where left != right:
                    return left < right
                default:
                    return lhs.offset < rhs.offset
                }
            }.map(\.element))
    }

    public static func move(_ items: [PlaylistItem], from source: Int, to destination: Int) -> [PlaylistItem] {
        var ordered = normalized(items)
        guard ordered.indices.contains(source), ordered.count > 1 else { return ordered }
        let target = min(max(destination, 0), ordered.count - 1)
        guard source != target else { return ordered }

        let item = ordered.remove(at: source)
        ordered.insert(item, at: target)
        return renumber(ordered)
    }

    public static func move(
        _ items: [PlaylistItem],
        fromOffsets offsets: IndexSet,
        toOffset destination: Int
    ) -> [PlaylistItem] {
        var ordered = normalized(items)
        let validOffsets = offsets.filter { ordered.indices.contains($0) }
        guard !validOffsets.isEmpty else { return ordered }

        let moved = validOffsets.map { ordered[$0] }
        for index in validOffsets.sorted(by: >) {
            ordered.remove(at: index)
        }

        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), ordered.count)
        ordered.insert(contentsOf: moved, at: insertionIndex)
        return renumber(ordered)
    }

    public static func remove(_ items: [PlaylistItem], at index: Int) -> [PlaylistItem] {
        var ordered = normalized(items)
        guard ordered.indices.contains(index) else { return ordered }
        ordered.remove(at: index)
        return renumber(ordered)
    }

    public static func remove(_ items: [PlaylistItem], atOffsets offsets: IndexSet) -> [PlaylistItem] {
        var ordered = normalized(items)
        for index in offsets.filter({ ordered.indices.contains($0) }).sorted(by: >) {
            ordered.remove(at: index)
        }
        return renumber(ordered)
    }

    private static func renumber(_ items: [PlaylistItem]) -> [PlaylistItem] {
        items.enumerated().map { position, item in
            var updated = item
            updated.position = position
            return updated
        }
    }
}
