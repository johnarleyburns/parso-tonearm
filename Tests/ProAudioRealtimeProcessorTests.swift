#if !os(watchOS)
import XCTest
import AVFoundation
@testable import TonearmCore

/// Phase 4 (audio-engine unification): the Pro Audio chain now runs behind the
/// shared `EQTapInstaller` via `ProAudioRealtimeProcessor`. These prove the
/// processor matches the offline kernel and picks up a published kernel swap.
final class ProAudioRealtimeProcessorTests: XCTestCase {

    private func stereoBuffer(frames: Int, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            let l = Float(0.5 * sin(2 * .pi * 1_000 * t))
            let r = Float(0.4 * sin(2 * .pi * 2_500 * t))
            buffer.floatChannelData![0][i] = l
            buffer.floatChannelData![1][i] = r
        }
        return buffer
    }

    private func kernel(eqGains: [Double], replayGain: Double = 1) -> ProAudioKernel {
        ProAudioKernel(eqGains: eqGains, eqBypassed: eqGains.allSatisfy { $0 == 0 },
                       settings: .default, replayGain: replayGain, sampleRate: 48_000)
    }

    func testTransparentKernelPassesThrough() throws {
        let processor = ProAudioRealtimeProcessor(kernel: kernel(eqGains: Array(repeating: 0, count: 10)))
        let buffer = stereoBuffer(frames: 2048)
        let original = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 2048))

        processor.prepareRealtime()
        processor.processRealtime(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                                  frameCount: 2048)

        for i in 0..<2048 {
            XCTAssertEqual(buffer.floatChannelData![0][i], original[i], accuracy: 1e-6)
        }
    }

    func testActiveKernelChangesTheSignalLikeTheOfflineMath() throws {
        var offline = kernel(eqGains: [6, 0, 0, 0, 0, 0, 0, 0, 0, -6])
        let buffer = stereoBuffer(frames: 4096)
        let inputL = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: 4096))
        let inputR = Array(UnsafeBufferPointer(start: buffer.floatChannelData![1], count: 4096))
        let expected = offline.renderStereo(zip(inputL, inputR).map { (Double($0), Double($1)) })

        let processor = ProAudioRealtimeProcessor(kernel: kernel(eqGains: [6, 0, 0, 0, 0, 0, 0, 0, 0, -6]))
        processor.prepareRealtime()
        processor.processRealtime(UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                                  frameCount: 4096)

        var maxDelta = 0.0
        for i in 0..<4096 {
            maxDelta = max(maxDelta, abs(Double(buffer.floatChannelData![0][i]) - expected[i].0))
        }
        XCTAssertGreaterThan(maxDelta, 0, "an active EQ must change the signal")
        XCTAssertLessThan(maxDelta, 1e-4, "realtime path must match the offline kernel")
    }

    func testPublishedKernelIsAdoptedOnNextProcess() throws {
        let processor = ProAudioRealtimeProcessor(kernel: kernel(eqGains: Array(repeating: 0, count: 10)))
        processor.prepareRealtime()

        // Transparent: pass-through.
        let b1 = stereoBuffer(frames: 1024)
        let o1 = Array(UnsafeBufferPointer(start: b1.floatChannelData![0], count: 1024))
        processor.processRealtime(UnsafeMutableAudioBufferListPointer(b1.mutableAudioBufferList), frameCount: 1024)
        XCTAssertEqual(b1.floatChannelData![0][512], o1[512], accuracy: 1e-6)

        // Publish an active kernel; the next process cycle must adopt it.
        processor.publish(kernel(eqGains: [10, 0, 0, 0, 0, 0, 0, 0, 0, 0]))
        let b2 = stereoBuffer(frames: 1024)
        let o2 = Array(UnsafeBufferPointer(start: b2.floatChannelData![0], count: 1024))
        processor.processRealtime(UnsafeMutableAudioBufferListPointer(b2.mutableAudioBufferList), frameCount: 1024)

        var changed = false
        for i in 0..<1024 where abs(b2.floatChannelData![0][i] - o2[i]) > 1e-5 { changed = true; break }
        XCTAssertTrue(changed, "the published active kernel must take effect")
    }
}
#endif
