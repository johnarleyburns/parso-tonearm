import Foundation

public enum QueueEditor {
    public struct State<Element> {
        var queue: [Element]
        var currentIndex: Int

        var normalized: State<Element> {
            guard !queue.isEmpty else { return State(queue: [], currentIndex: 0) }
            return State(queue: queue, currentIndex: min(max(currentIndex, 0), queue.count - 1))
        }
    }

    public static func move<Element>(from source: Int, to destination: Int, in state: State<Element>) -> State<Element> {
        var state = state.normalized
        guard state.queue.indices.contains(source), state.queue.count > 1 else { return state }
        let target = min(max(destination, 0), state.queue.count - 1)
        guard source != target else { return state }

        let moved = state.queue.remove(at: source)
        state.queue.insert(moved, at: target)

        if source == state.currentIndex {
            state.currentIndex = target
        } else {
            var current = state.currentIndex
            if source < current { current -= 1 }
            if target <= current { current += 1 }
            state.currentIndex = current
        }
        return state.normalized
    }

    public static func remove<Element>(at index: Int, in state: State<Element>) -> State<Element> {
        var state = state.normalized
        guard state.queue.indices.contains(index) else { return state }
        state.queue.remove(at: index)
        guard !state.queue.isEmpty else { return State(queue: [], currentIndex: 0) }

        if index < state.currentIndex {
            state.currentIndex -= 1
        } else if index == state.currentIndex {
            state.currentIndex = min(index, state.queue.count - 1)
        }
        return state.normalized
    }

    public static func insertNext<Element>(_ element: Element, in state: State<Element>) -> State<Element> {
        var state = state.normalized
        guard !state.queue.isEmpty else { return State(queue: [element], currentIndex: 0) }
        let insertionIndex = min(state.currentIndex + 1, state.queue.count)
        state.queue.insert(element, at: insertionIndex)
        return state.normalized
    }

    public static func append<Element>(_ element: Element, in state: State<Element>) -> State<Element> {
        var state = state.normalized
        state.queue.append(element)
        if state.queue.count == 1 { state.currentIndex = 0 }
        return state.normalized
    }
}

extension QueueEditor.State: Equatable where Element: Equatable {}
