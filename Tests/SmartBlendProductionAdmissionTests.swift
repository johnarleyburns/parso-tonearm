import XCTest
import AVFoundation
@testable import TonearmCore

/// Drives the real AudioPlayer admission path (`mixDecksAdmission`), which every automatic,
/// preview, current-deck and incoming-deck load goes through. Removing the provider or
/// coordinator call from the player makes these fail.
@MainActor
final class SmartBlendProductionAdmissionTests: XCTestCase {
    private var dir: URL!
    private var dirName = ""
    private var coordinator: ResourceCoordinator!
    private var service: AudioAssetCapabilityService!
    private let src = Source(id: 1, kind: .iaItem, iaIdentifier: "x", originalURL: nil, title: "S",
                             addedAt: Date(), lastResolvedAt: nil, followUpdates: false,
                             licenseText: nil, memberCapHit: false)
    private lazy var album = Album(id: 1, sourceId: 1, title: "Album", artist: "Artist")

    override func setUp() async throws {
        try await super.setUp()
        // Managed (app-owned) files resolve against Application Support via the real resolver.
        dirName = "sb-\(UUID().uuidString)"
        dir = LocalAssetResolver.live.managedBase().appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        coordinator = ResourceCoordinator(availableMemory: { 6 * 1_024 * 1_024 * 1_024 }, pressureActive: { false })
        service = AudioAssetCapabilityService(provider: LocalAudioMetadataProvider())
    }

    override func tearDown() async throws {
        AudioPlayer.shared.queue = []
        AudioPlayer.shared.releaseSmartBlendReservation()
        AudioPlayer.shared.audioCapabilities = .shared
        AudioPlayer.shared.resourceCoordinator = .shared
        try? FileManager.default.removeItem(at: dir)
        try await super.tearDown()
    }

    // MARK: fixtures

    private func row(_ i: Int, file: URL) -> TrackRow {
        // DB claims stereo 44.1k/120s; the probe must override this, never the DB.
        let t = Track(id: Int64(i), albumId: 1, sourceId: 1, title: "Secret Title \(i)", trackNo: i, discNo: nil,
                      durationSec: 120, codec: nil, sampleRate: 44_100, bitDepthOrBitrate: nil, sortKey: "\(i)")
        let asset = Asset(id: Int64(i), trackId: Int64(i), kind: .managedCopy, bookmark: nil,
                          relPath: "\(dirName)/\(file.lastPathComponent)", remoteURL: nil, altRemoteURL: nil,
                          sizeBytes: nil, unsupportedReason: nil)
        return TrackRow(track: t, album: album, source: src, asset: asset)
    }

    private func pcmFile(_ name: String, channels: AVAudioChannelCount, rate: Double = 44_100,
                         seconds: Double = 1, settings: [String: Any]? = nil) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) { for f in 0..<Int(frames) { buffer.floatChannelData![c][f] = sinf(Float(f) * 0.05) * 0.2 } }
        let file = try AVAudioFile(forWriting: url, settings: settings ?? format.settings)
        try file.write(from: buffer)
        return url
    }

    private func flac(_ name: String, rate: Int = 44_100, channels: Int = 2, frames: Int64 = 44_100,
                      seekTable: Bool) throws -> URL {
        var info = [UInt8](repeating: 0, count: 34)
        info[10] = UInt8(rate >> 12 & 0xFF); info[11] = UInt8(rate >> 4 & 0xFF)
        info[12] = UInt8((rate & 0xF) << 4) | UInt8((channels - 1) << 1) | 0
        info[13] = UInt8(15 << 4) | UInt8((frames >> 32) & 0xF)
        for (i, shift) in [24, 16, 8, 0].enumerated() { info[14 + i] = UInt8((frames >> Int64(shift)) & 0xFF) }
        var data = Data("fLaC".utf8)
        data.append(contentsOf: [seekTable ? 0x00 : 0x80, 0, 0, 34]); data.append(contentsOf: info)
        if seekTable { data.append(contentsOf: [0x83, 0, 0, 18]); data.append(Data(repeating: 0, count: 18)) }
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// Calls the player's real admission until the background probe has answered.
    private func admit(_ player: AudioPlayer, index: Int, outgoing: Int? = nil) async -> TransitionAdmissionDecision {
        var decision = player.mixDecksAdmission(index: index, outgoing: outgoing)
        for _ in 0..<200 where decision == .defer(reason: .preparingDetails) {
            try? await Task.sleep(for: .milliseconds(25))
            decision = player.mixDecksAdmission(index: index, outgoing: outgoing)
        }
        return decision
    }

    private func makePlayer(_ files: [URL]) -> AudioPlayer {
        let player = AudioPlayer.shared
        player.audioCapabilities = service
        player.resourceCoordinator = coordinator
        player.queue = files.enumerated().map { row($0.offset + 1, file: $0.element) }
        return player
    }

    // MARK: tests

    func testProductionAdmissionProbesThenReservesOncePerRequest() async throws {
        let wav = try pcmFile("a.wav", channels: 2)
        let player = makePlayer([wav])
        XCTAssertEqual(player.mixDecksAdmission(index: 0, outgoing: nil), .defer(reason: .preparingDetails))
        XCTAssertTrue(coordinator.snapshot().reservations.isEmpty, "nothing reserved before details are known")
        let decision = await admit(player, index: 0)
        XCTAssertEqual(decision, .allowLiveMix)
        XCTAssertGreaterThan(service.lookupCount, 0)
        XCTAssertEqual(coordinator.snapshot().reservations.count, 1)
        XCTAssertEqual(coordinator.snapshot().reservations.first?.kind, .blendPreparation)
        // duplicate request replaces, never stacks
        _ = player.mixDecksAdmission(index: 0, outgoing: nil)
        _ = player.mixDecksAdmission(index: 0, outgoing: nil)
        XCTAssertEqual(coordinator.snapshot().reservations.count, 1)
        player.stopMixDecks()
        XCTAssertTrue(coordinator.snapshot().reservations.isEmpty)
        player.stopMixDecks()   // route replacement / second release is harmless
        XCTAssertTrue(coordinator.snapshot().reservations.isEmpty)
    }

    func testIncomingAndOutgoingPairUsesBothProbedFiles() async throws {
        let player = makePlayer([try pcmFile("a.wav", channels: 2), try pcmFile("b.aiff", channels: 2)])
        _ = await admit(player, index: 0)
        let decision = await admit(player, index: 1, outgoing: 0)
        XCTAssertEqual(decision, .allowLiveMix)
        XCTAssertEqual(coordinator.snapshot().reservations.count, 1)
        let peak = coordinator.snapshot().totalBytes
        XCTAssertGreaterThan(peak, 96 * 1_024 * 1_024)   // measured peak includes the safety reserve
    }

    func testMonoChannelCountComesFromProbeNotStereoDefault() async throws {
        let player = makePlayer([try pcmFile("mono.wav", channels: 1)])
        _ = await admit(player, index: 0)
        let caps = player.smartBlendCapabilities(at: 0)
        XCTAssertEqual(caps.channelCount, 1)
        XCTAssertEqual(caps.availability, .available)
        XCTAssertEqual(caps.provenance, .headerProbe)
    }

    func testMissingChannelCountNeverDefaultsToStereo() {
        let caps = AudioAssetCapabilities.unresolved("x", .available)
        XCTAssertNil(caps.admissionMetadata.channels)
        XCTAssertFalse(caps.admissionMetadata.isValid)
        XCTAssertNil(AudioAssetCapabilityService.reservationBytes(outgoing: nil, incoming: caps))
    }

    func testFormatsAndTypedOutcomes() async throws {
        let m4a = try pcmFile("c.m4a", channels: 2, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                              AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2])
        let garbage = dir.appendingPathComponent("bad.mp3"); try Data(repeating: 7, count: 4_096).write(to: garbage)
        let missing = dir.appendingPathComponent("gone.flac")
        let player = makePlayer([m4a, try flac("s.flac", seekTable: true), try flac("n.flac", seekTable: false),
                                 garbage, missing])
        for i in 0..<3 {
            let decision = await admit(player, index: i)
            XCTAssertEqual(decision, .allowLiveMix, "index \(i)")
            XCTAssertFalse(player.smartBlendCapabilities(at: i).boundedRandomAccessActive,
                           "a SEEKTABLE is not the capability decision")
        }
        let corrupt = await admit(player, index: 3)
        XCTAssertEqual(corrupt, .gaplessFallback(reason: .unsupportedFormat))
        let gone = await admit(player, index: 4)
        XCTAssertEqual(gone, .defer(reason: .temporarilyUnreadable))
        XCTAssertTrue(coordinator.snapshot().reservations.isEmpty, "denied requests hold no reservation")
    }

    func testCachedSourceIsProbedByFileAdapter() async throws {
        let cached = try pcmFile("cache-file", channels: 2)
        let service = self.service!
        let target = AudioAssetCapabilityService.Target.file(cached, key: "cache-x")
        var caps = service.capabilities(for: target)
        for _ in 0..<200 where caps.availability == .preparing {
            try await Task.sleep(for: .milliseconds(25)); caps = service.capabilities(for: target)
        }
        XCTAssertEqual(caps.availability, .available)
        XCTAssertEqual(caps.channelCount, 2)
        XCTAssertEqual(service.capabilities(for: .remoteUncached(key: "r")).availability, .preparing)
    }

    func testConservativeBudgetDeniesUnsafeLongTrackAndPlayerReservesNothing() async throws {
        // 3 hours of 96k 8ch FLAC header: whole-file PCM estimate is far over the absolute cap.
        let long = try flac("long.flac", rate: 96_000, channels: 8, frames: 96_000 * 3 * 3600, seekTable: true)
        let player = makePlayer([long])
        let decision = await admit(player, index: 0)
        XCTAssertEqual(decision, .gaplessFallback(reason: .decodedMemoryBudget))
        XCTAssertTrue(coordinator.snapshot().reservations.isEmpty)
    }

    func testBoundedReservationOnlyWhenBoundedDecoderActive() {
        func caps(active: Bool) -> AudioAssetCapabilities {
            AudioAssetCapabilities(sourceID: "x", durationSeconds: 10_000, sampleRate: 44_100, channelCount: 2,
                                   container: "flac", boundedRandomAccessActive: active,
                                   measuredBoundedWorkingSetBytes: 8 << 20, provenance: .headerProbe,
                                   checkedAt: Date(), availability: .available)
        }
        XCTAssertEqual(AudioAssetCapabilityService.reservationBytes(outgoing: nil, incoming: caps(active: true)), 8 << 20)
        let conservative = AudioAssetCapabilityService.reservationBytes(outgoing: nil, incoming: caps(active: false))
        XCTAssertGreaterThan(conservative ?? 0, 768 * 1_024 * 1_024)
    }

    func testCoordinatorDenialIsReportedAndNotPlanned() async throws {
        let tight = ResourceCoordinator(availableMemory: { 64 * 1_024 * 1_024 }, pressureActive: { false })
        let player = makePlayer([try pcmFile("a.wav", channels: 2)])
        player.resourceCoordinator = tight
        let decision = await admit(player, index: 0)
        XCTAssertEqual(decision, .gaplessFallback(reason: .memoryPressure))
        XCTAssertNil(player.smartBlendReservation)
        XCTAssertTrue(tight.snapshot().reservations.isEmpty)
    }

    func testDiagnosticsAndReasonsCarryNoSourceIdentity() async throws {
        let wav = try pcmFile("Private Name.wav", channels: 2)
        let player = makePlayer([wav])
        _ = await admit(player, index: 0)
        let caps = player.smartBlendCapabilities(at: 0)
        for text in [caps.sourceID, String(describing: caps), "\(TransitionFallbackStatus(decision: .defer(reason: .preparingDetails)).message)"] {
            XCTAssertFalse(text.contains("Private Name"))
            XCTAssertFalse(text.contains(dir.path))
            XCTAssertFalse(text.contains("Secret Title"))
        }
    }
}
