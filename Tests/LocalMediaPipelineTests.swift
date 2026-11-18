import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import TonearmCore

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func bump() { lock.withLock { n += 1 } }
}

@Suite struct LocalMediaPipelineTests {
    private func pngData(width: Int, height: Int) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    @Test func testLargeCoverIsDownsampledToBudget() throws {
        let art = try #require(EmbeddedArtworkDownsampler.downsample(pngData(width: 3000, height: 2000), maxPixel: 512))
        #expect(max(art.image.width, art.image.height) <= 512)
        #expect(art.sourceWidth == 3000)
    }

    @Test func testNormalCoverYieldsThumbnail() throws {
        let art = try #require(EmbeddedArtworkDownsampler.downsample(pngData(width: 300, height: 300)))
        #expect(art.image.width > 0)
    }

    @Test func testMalformedOrOverBudgetCoverRejected() {
        #expect(EmbeddedArtworkDownsampler.downsample(Data([1, 2, 3, 4])) == nil)
        #expect(EmbeddedArtworkDownsampler.downsample(pngData(width: 64, height: 64), maxSourcePixels: 100) == nil)
        #expect(EmbeddedArtworkDownsampler.downsample(pngData(width: 64, height: 64), maxEncodedBytes: 10) == nil)
    }

    @Test func testConcurrentConsumersShareOneLoad() async {
        let flights = SingleFlight<Int>()
        let runs = Box()
        await withTaskGroup(of: Int?.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    await flights.value(for: "a") {
                        runs.bump()
                        try? await Task.sleep(for: .milliseconds(100))
                        return 7
                    }
                }
            }
            for await v in group { #expect(v == 7) }
        }
        #expect(runs.count == 1)
        let active = await flights.activeCount
        #expect(active == 0)
    }

    @Test func testLastConsumerCancellingCancelsWork() async {
        let flights = SingleFlight<Int>()
        let cancelled = Box()
        let task = Task {
            await flights.value(for: "a") {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { cancelled.bump() }
                return nil
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value
        try? await Task.sleep(for: .milliseconds(100))
        #expect(cancelled.count == 1)
        let active = await flights.activeCount
        #expect(active == 0)
    }

    @Test func testDiagnosticsCarryStageAndOpaqueIDOnly() {
        let events = Box()
        let captured = LockedEvents()
        let diag = LocalPlaybackDiagnostics(clock: { 42 }, memorySampler: { 100 })
        diag.isEnabled = true
        diag.setSink { captured.append($0); events.bump() }
        let id = diag.makeLoadID()
        diag.record(.resolveStart, loadID: id)
        diag.record(.accessAcquired, loadID: id)
        let all = captured.all
        #expect(all.map(\.stage) == [.resolveStart, .accessAcquired])
        #expect(all.first?.loadID == id)
        #expect(all.first?.residentMegabytes == 100)
        diag.isEnabled = false
        diag.record(.itemBuilt, loadID: id)
        #expect(events.count == 2)
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LocalPlaybackDiagnostics.Event] = []
    func append(_ e: LocalPlaybackDiagnostics.Event) { lock.withLock { items.append(e) } }
    var all: [LocalPlaybackDiagnostics.Event] { lock.withLock { items } }
}
