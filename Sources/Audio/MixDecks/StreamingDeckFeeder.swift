#if !os(watchOS)
import Foundation

/// Off-render-thread owner of one bounded deck's decode work.  The mixer only
/// reads `BoundedDeckBuffer`; all source access, allocation and error handling
/// stay here. A retarget changes the buffer generation, making any late chunk
/// harmless.
actor StreamingDeckFeeder {
    enum State: Sendable, Equatable { case idle, filling, stalled, failed(String), stopped }

    private let buffer: BoundedDeckBuffer
    private let source: any AsyncDeckChunkSource
    private let maxChunkFrames: Int
    private(set) var state: State = .idle
    private var fillTask: Task<Void, Never>?

    init(buffer: BoundedDeckBuffer, source: any AsyncDeckChunkSource, maxChunkFrames: Int = 8_192) {
        self.buffer = buffer; self.source = source; self.maxChunkFrames = maxChunkFrames
    }

    init(buffer: BoundedDeckBuffer, source: any DeckChunkSource, maxChunkFrames: Int = 8_192) {
        self.init(buffer: buffer, source: SynchronousDeckChunkSource(source), maxChunkFrames: maxChunkFrames)
    }

    func requestFill() {
        guard fillTask == nil, state != .stopped else { return }
        state = .filling
        fillTask = Task { [weak self] in await self?.fill() }
    }

    func stop() { fillTask?.cancel(); fillTask = nil; state = .stopped }

    private func fill() async {
        defer { fillTask = nil }
        while !Task.isCancelled {
            let request = buffer.nextRequest()
            guard request.wanted > 0 else { state = .idle; return }
            do {
                let channels = try await source.read(startFrame: request.startFrame,
                                                      count: min(request.wanted, maxChunkFrames))
                guard !(channels.first?.isEmpty ?? true) else { state = .stalled; return }
                switch buffer.write(DeckChunk(generation: request.generation, startFrame: request.startFrame,
                                               channels: channels)) {
                case .accepted: continue
                case .stale, .finished: state = .idle; return
                case .full: state = .idle; return
                case .discontinuous: state = .stalled; return
                }
            } catch is CancellationError { return
            } catch { state = .failed(error.localizedDescription); return }
        }
    }
}

/// Remote assets have to await their sparse range loader; local seekable files
/// remain synchronous through this adapter. Both feed the same bounded deck.
protocol AsyncDeckChunkSource: Sendable {
    func read(startFrame: Int64, count: Int) async throws -> [[Float]]
}

private struct SynchronousDeckChunkSource: AsyncDeckChunkSource {
    let source: any DeckChunkSource
    init(_ source: any DeckChunkSource) { self.source = source }
    func read(startFrame: Int64, count: Int) async throws -> [[Float]] {
        try source.read(startFrame: startFrame, count: count)
    }
}
#endif
