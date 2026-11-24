import Foundation
import Testing
import AVFoundation
import TonearmWatchCore
import TonearmWatchProtocol
@testable import TonearmCore

/// Exercises the real AVPlayerItem state machine on the host. AVAudioSession itself is an iOS/watchOS
/// service and is therefore exercised by WatchSmokeUITests plus the on-device audio pass.
///
/// Serialized deliberately: these are the one suite that must use real
/// AVFoundation/CoreAudio media services (`AVAssetReader`/`AVAssetWriter` and
/// `AVPlayerItem`). Concurrent real encodes deadlock inside MediaToolbox
/// (`FigSemaphoreWaitRelative` while several `copyNextSampleBuffer` calls run),
/// which is a genuine process-wide shared resource, not something a fake can
/// replace without deleting what the test asserts.
@MainActor
@Suite(.serialized) struct WatchAVPlayerItemTests {
    @Test func testJamendoQueryOnlyCachedMP3ConvertsToPlayableWatchAAC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(Bundle.module.url(forResource: "cc0-ocean-jamendo", withExtension: "mp3", subdirectory: "Fixtures"))
        let cached = root.appendingPathComponent(String(repeating: "b", count: 64) + "-")
        try FileManager.default.copyItem(at: source, to: cached)
        let url = try #require(URL(string: "https://prod-1.storage.jamendo.com/?trackid=1&format=mp32"))
        let mime = PhoneWatchAudioPreparation.sourceMIMEType(for: url)
        #expect(mime == "audio/mpeg")
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: cached,
            directory: root.appendingPathComponent("prepared"), sourceMIMEType: mime)
        let audio = try AVAudioFile(forReading: prepared)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(audio.length > 0)
        let item = AVPlayerItem(url: prepared)
        let tracks = try await item.asset.loadTracks(withMediaType: .audio)
        #expect(!tracks.isEmpty)
    }

    @Test func testJamendoFormatHintsAndBottomAccessoryAndRetryWiring() throws {
        for format in ["mp3", "mp31", "mp32"] {
            #expect(PhoneWatchAudioPreparation.sourceMIMEType(for: URL(string: "https://example.com/audio?format=\(format)")!) == "audio/mpeg")
        }
        #expect(PhoneWatchAudioPreparation.sourceMIMEType(for: URL(string: "https://example.com/audio?format=json&audioformat=mp32")!) == "audio/mpeg")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/Features/RootView.swift"), encoding: .utf8)
        let chrome = try String(contentsOf: root.appendingPathComponent("Sources/Features/RootTabChrome.swift"), encoding: .utf8)
        #expect(chrome.contains(".safeAreaInset(edge: .bottom, spacing: 0)"))
        let music = try String(contentsOf: root.appendingPathComponent("Sources/Features/MyMusic/MyMusicView.swift"), encoding: .utf8)
        #expect(music.contains(".buttonStyle(.borderless)"))
        let now = try String(contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"), encoding: .utf8)
        #expect(now.contains("submittingWatchDownload = true"))
        #expect(now.contains("appState.watchGlyphState(forTrackID: id)"))
        let resolver = try String(contentsOf: root.appendingPathComponent("Sources/App/Watch/PhoneWatchDownloadAdapter.swift"), encoding: .utf8)
        #expect(resolver.contains("AudioCache.key(for: $0) == source.lastPathComponent"))
        #expect(resolver.contains("sourceMIMEType: origin.flatMap"))
        let accessory = try String(contentsOf: root.appendingPathComponent("Sources/Features/Chrome/PlayerAccessory.swift"), encoding: .utf8)
        #expect(accessory.contains(".contentShape(Rectangle())"))
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("Button(\"Done\") { dismiss() }.accessibilityIdentifier(\"settings.done\")"))
        let jamendo = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/JamendoBrowseView.swift"), encoding: .utf8)
        #expect(jamendo.contains("JamendoBrowseGenrePicker { genre in"))
        #expect(jamendo.contains("NavigationLink(node.name, value: node)"))
        #expect(jamendo.contains("loadGeneration == generation"))
    }
    @Test func testWatchCrownControlsVolumeThroughTransientCenteredHUD() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchNowPlayingView.swift"), encoding: .utf8)
        #expect(view.contains(".digitalCrownRotation("))
        #expect(view.contains("$player.volume"))
        #expect(view.contains("if showsVolume { volumeOverlay }"),
                "the volume HUD must not occupy the now-playing layout permanently")
        #expect(view.contains("showsVolume = false"),
                "the HUD fades out after the crown stops moving")
        #expect(view.contains(".frame(maxWidth: 200)"),
                "the HUD floats large in the middle of now playing")
        #expect(!view.contains("WKInterfaceVolumeControl(origin: .local)"),
                "an always-focused system control is what left the volume popup on screen")
        let output = try String(contentsOf: root.appendingPathComponent("WatchApp/AVPlayerOutput.swift"), encoding: .utf8)
        #expect(output.contains("private var currentVolume: Float = 1.0"))
        let player = try String(contentsOf: root.appendingPathComponent("WatchApp/WatchPlayer.swift"), encoding: .utf8)
        #expect(player.contains("var volume: Double = 1.0"))
        let runtime = try String(contentsOf: root.appendingPathComponent("Sources/App/Watch/PhoneWatchRuntime.swift"), encoding: .utf8)
        #expect(!runtime.contains("return await negotiatedCapabilities.supports(.artworkAssets)"))
    }
    @Test func testLocalWatchBrowsingAndSearchPromptAndJamendoWatchMenuAreWired() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchRootView.swift"), encoding: .utf8)
        #expect(home.contains("HomeDoor(nav: .songs, title: \"Songs\""))
        #expect(!home.contains("HomeDoor(nav: .artists"), "Artists is not useful on the watch home")
        #expect(!home.contains("HomeDoor(nav: .genres"), "Genres is not useful on the watch home")
        #expect(!home.contains("HomeDoor(nav: .albums"), "Albums is not useful on the watch home")
        let groups = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchCollectionViews.swift"), encoding: .utf8)
        #expect(groups.contains("model.tracks.filter(\\.isReady)"))
        let search = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchSearchView.swift"), encoding: .utf8)
        #expect(search.contains("controller.presentTextInputController(withSuggestions: nil, allowedInputMode: .plain)"))
        #expect(search.contains("WatchNav.artist(row.title)"))
        let jamendo = try String(contentsOf: root.appendingPathComponent("Sources/Features/Sources/JamendoBrowseView.swift"), encoding: .utf8)
        #expect(jamendo.contains(".contextMenu"))
        #expect(jamendo.contains("Download to Apple Watch"))
        #expect(jamendo.contains("await appState.downloadToWatch(rows: [row])"))
    }
    @Test func testStartupSyncIsVisibleAndConnectionToastIsTransitionBased() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let watchApp = try String(contentsOf: root.appendingPathComponent("WatchApp/PlatterheadWatchApp.swift"), encoding: .utf8)
        #expect(!watchApp.contains(".task { await WatchAppAssembly.shared.requestSyncStatus() }"))
        let home = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchRootView.swift"), encoding: .utf8)
        #expect(home.contains("WatchHomeStatusPolicy.status("),
                      "sync status must stay visible, driven by real state, not hardcoded")
        let assembly = try String(contentsOf: root.appendingPathComponent("WatchApp/App/WatchAppAssembly.swift"), encoding: .utf8)
        #expect(assembly.contains("let deadline = Task { @MainActor in"))
        #expect(assembly.contains("requestID: requestID"))
        #expect(assembly.contains("phonePushOnly: true"))
        #expect(home.contains(".disabled(state.isSyncing || !state.phoneReachable)"))
        let phone = try String(contentsOf: root.appendingPathComponent("Sources/App/AppState+Watch.swift"), encoding: .utf8)
        #expect(phone.contains("if !wasReachable && watchSessionState == .reachable"))
        #expect(phone.contains("Apple Watch connected"))
        #expect(phone.contains("watchSessionState == .reachable"))
        let runtime = try String(contentsOf: root.appendingPathComponent("Sources/App/Watch/PhoneWatchRuntime.swift"), encoding: .utf8)
        #expect(runtime.contains("guard force || content != lastPublishedStatusContent"))
        #expect(runtime.contains("mirrorLive: Bool = false"))
        #expect(!assembly.contains("await syncActor?.publishPeriodicStatus()"))
    }
    /// Real report: the connection/sync status (then a full-width, multi-line `Section`) sat above
    /// `WatchHomeHero`, so the first thing Home showed was "iPhone connected"/"Sync Now available…"
    /// rather than Now Playing — "this seems wrong as a home view". Home's own doc comment already
    /// said status should be "a quiet chip at the end"; the code just never matched it.
    @Test func testHomeLeadsWithNowPlayingAndKeepsConnectionStatusAsAnEndOfListChip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchRootView.swift"), encoding: .utf8)
        let heroRange = try #require(home.range(of: "WatchHomeHero()"), "Home must still show Now Playing")
        let chipRange = try #require(home.range(of: "statusChip"),
                                      "Home must have a status chip, not the old multi-line Section")
        #expect(heroRange.lowerBound < chipRange.lowerBound,
                          "Now Playing must render before the connection/sync status chip")
        #expect(home.contains("\"watch.syncStatus\""),
                      "Sync Status must stay reachable by its existing identifier")
    }
    @Test func testAdHocWatchDownloadsPersistBeforeQueueingAndSettingsOpenDirectly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let app = try String(contentsOf: root.appendingPathComponent("Sources/App/AppState+Watch.swift"), encoding: .utf8)
        let persist = try #require(app.range(of: "await persistRemoteTrack(row)"))
        let queue = try #require(app.range(of: "try await watchRuntime.downloadTracks(savedRows)"))
        #expect(persist.lowerBound < queue.lowerBound)
        #expect(app.contains("Couldn't queue the Apple Watch download"))
        let downloads = try String(contentsOf: root.appendingPathComponent("Sources/App/AppState+Downloads.swift"), encoding: .utf8)
        #expect(downloads.contains("if source.id == nil"))
        #expect(downloads.contains("await store.insertSource(source)"))
        let settings = try String(contentsOf: root.appendingPathComponent("Sources/Features/Settings/SettingsView.swift"), encoding: .utf8)
        #expect(settings.contains("settingsSection(\"Apple Watch\""))
        #expect(!settings.contains("collapsibleSection(\"Advanced\""))
        #expect(!settings.contains("DisclosureGroup(title"), "Expanded cards must not inherit one-sided disclosure indentation")
        #expect(!settings.contains("expanded.wrappedValue"),
                       "Settings sections are flat/always-expanded now, matching parso-voxglass's layout")
        #expect(settings.contains("func settingsSection"))
        #expect(settings.contains("VStack(alignment: .leading, spacing: 16) { content() }"))
        #expect(settings.contains(".padding(.horizontal, 18)"))
        let nowPlaying = try String(contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"), encoding: .utf8)
        #expect(nowPlaying.contains("guard let row = watchConfirmationTarget, let action = watchConfirmation"))
    }
    @Test func testCachedAudioWithoutDottedExtensionConvertsToWatchAAC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let ext = try #require(WatchAudioFileMetadata.fileExtension(for: source))
        let cached = root.appendingPathComponent(String(repeating: "a", count: 64) + "-" + ext)
        try FileManager.default.copyItem(at: source, to: cached)
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: cached, directory: root.appendingPathComponent("prepared"))
        let audio = try AVAudioFile(forReading: prepared)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(audio.length > 0)
    }

    @Test func testMetadataNeverUsesNativeFileTransferAndControlsRequireConfirmation() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let coordinator = try String(contentsOf: root.appendingPathComponent("Sources/WatchSync/PhoneWatchProtocolCoordinator.swift"), encoding: .utf8)
        #expect(!coordinator.contains("transferFile("))
        #expect(coordinator.contains("await transport.transferUserInfo(data)"))
        let transport = try String(contentsOf: root.appendingPathComponent("Sources/WatchProtocol/Connectivity/WatchSessionTransport.swift"), encoding: .utf8)
        #expect(transport.contains("guard WatchArtworkFileMetadata(dictionary: metadata) != nil"))
        #expect(transport.contains("?.codec == \"aac\""))
        let view = try String(contentsOf: root.appendingPathComponent("Sources/Features/NowPlaying/NowPlayingView.swift"), encoding: .utf8)
        #expect(view.contains("arrow.down.circle.fill"))
        #expect(view.contains("phoneDownloadIsRemoval ? \"Remove downloaded audio?\" : \"Download this track?\""))
        let watch = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchRootView.swift"), encoding: .utf8)
        #expect(watch.contains("watch.sync.diagnostics"))
        #expect(!watch.contains("watch.about.diagnostics"))
    }
    @Test func testProductionWatchIsLocalOnlyAndPhoneOwnsTransferCommands() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let assembly = try String(contentsOf: root.appendingPathComponent("WatchApp/App/WatchAppAssembly.swift"), encoding: .utf8)
        let model = try String(contentsOf: root.appendingPathComponent("WatchApp/App/WatchLibraryModel.swift"), encoding: .utf8)
        #expect(assembly.contains("localDownloadsOnly: true"))
        #expect(!assembly.contains(".watchInitiatedDownload"))
        #expect(!assembly.contains("func requestDownloads"))
        #expect(!assembly.contains("func controlDownloads"))
        #expect(!model.contains("readyOnly: false"))
        let phone = try String(contentsOf: root.appendingPathComponent("Sources/App/Watch/PhoneWatchRuntime.swift"), encoding: .utf8)
        #expect(phone.contains("allowsWatchDownloadCommands: false"))
        #expect(phone.contains("trackIDs: ids, playlistIDs: playlists"))
        #expect(phone.contains("keepsPlaylistsLive: false"))
        let diagnostics = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchDiagnosticsView.swift"), encoding: .utf8)
        #expect(diagnostics.contains("$0.category == .installResult && !$0.stateCode.hasPrefix(\"artwork\")"),
            "Artwork events must not replace the latest audio receipt")
        #expect(diagnostics.contains("Text(\"Artwork receipt\")"))
    }
    @Test func testInboxSaveFailureReportsCurrentAttemptWithoutClaimingInstalledAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"), stagingDirectory: root.appendingPathComponent("stage"))
        let sync = WatchSyncActor(repository: repository, installer: installer, requiresNormalizedAAC: true)
        let fanout = WatchFanoutObserver([sync])
        defer { withExtendedLifetime(fanout) {} }
        let transport = WholeAACRecordingTransport()
        let coordinator = WatchConnectivityCoordinator(transport: transport, observer: fanout)
        await sync.setCoordinator(coordinator)
        let metadata = WatchAudioFileMetadata(trackID: "failed", expectedBytes: 100, codec: "aac", fileExtension: "m4a", transferID: "current-attempt")
        await coordinator.receiveFileFailure(metadata: metadata.dictionary, code: .installationFailed)
        let reports = await transport.reportedManifests
        #expect(reports.last?.audioDownloadFailures["failed"] == .installationFailed)
        #expect(reports.last?.audioFailureTransferIDs["failed"] == "current-attempt")
        #expect(reports.last?.readyTrackIDs == [])
        #expect(reports.last?.installedBytes == 0)
    }
    @Test func testProductionAssembliesUseWholeAACRouteAndNeverInstantiateChunkActors() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let phone = try String(contentsOf: repository.appendingPathComponent("Sources/App/Watch/PhoneWatchRuntime.swift"), encoding: .utf8)
        let watch = try String(contentsOf: repository.appendingPathComponent("WatchApp/App/WatchAppAssembly.swift"), encoding: .utf8)
        let facade = try String(contentsOf: repository.appendingPathComponent("Sources/App/Watch/PhoneWatchDownloadAdapter.swift"), encoding: .utf8)
        #expect(!phone.contains("PhoneWatchResumableAudioTransfer("))
        #expect(!watch.contains("WatchAudioChunkAssembler("))
        #expect(!watch.contains(".resumableAudioChunks"))
        #expect(watch.contains("observer: fan"), "A file delivered at activation must already have a receiver")
        let activation = try #require(phone.range(of: "func activate() async"))
        let activationBody = String(phone[activation.lowerBound...])
        let receiver = try #require(activationBody.range(of: "await inbound.connect(self)"))
        let native = try #require(activationBody.range(of: "protocolAdapter.activate()"))
        #expect(receiver.lowerBound < native.lowerBound,
            "Early metadata and file callbacks must not arrive before the phone receiver is connected")
        #expect(watch.contains("requiresNormalizedAAC: true"))
        #expect(facade.contains("PhoneWatchAudioPreparation.transferWholeFile("))
        #expect(!facade.contains("chunkSender"))
    }

    @Test func testBundledWatchSimulatorFixtureIsRealAAC128() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let fixture = repository.appendingPathComponent("Resources/Audio/ambient-ocean-watch-aac128.m4a")
        let audio = try AVAudioFile(forReading: fixture)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        let tracks = try await AVURLAsset(url: fixture).loadTracks(withMediaType: .audio)
        let track = try #require(tracks.first)
        let rate = try await track.load(.estimatedDataRate)
        #expect(abs(Double(rate) - 128_000) <= 8_000)
        #expect(audio.length > 44_100 * 20, "The real fixture must be long enough for advancing/pause assertions")
    }
    @Test func testDocumentAccessCoversCopyAndBackgroundSnapshotSurvivesRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let external = root.appendingPathComponent("document.wav")
        let bundled = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let prepared = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: external, directory: root.appendingPathComponent("owned"),
            startAccess: { url in
                // Model a provider that exposes bytes only while document access is held.
                try? FileManager.default.copyItem(at: bundled, to: url)
                return true
            },
            stopAccess: { url in try? FileManager.default.removeItem(at: url) })
        #expect(!FileManager.default.fileExists(atPath: external.path))
        #expect(FileManager.default.fileExists(atPath: prepared.path))
        let expected = try WatchFileDigest.measure(bundled)
        let actual = try WatchFileDigest.measure(prepared)
        #expect(actual.bytes < expected.bytes)
        #expect(actual.sha256 != expected.sha256)
        #expect(prepared.pathExtension == "m4a")
        let encoded = try AVAudioFile(forReading: prepared)
        let format = encoded.fileFormat
        #expect(format.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test func testWholeAAC128UsesOneTransferFileAndPlaysRealCC0Audio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: original, directory: root.appendingPathComponent("phone"))
        #expect(PhoneWatchAudioPreparation.bitRate == 128_000)
        let decoded = try AVAudioFile(forReading: prepared)
        #expect(decoded.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(decoded.fileFormat.channelCount == 2)
        #expect(decoded.fileFormat.sampleRate == 44_100)
        let encodedTracks = try await AVURLAsset(url: prepared).loadTracks(withMediaType: .audio)
        let encodedTrack = try #require(encodedTracks.first)
        let rate = try await encodedTrack.load(.estimatedDataRate)
        #expect(abs(Double(rate) - 128_000) <= 8_000)
        let digest = try WatchFileDigest.measure(prepared)
        let transport = WholeAACRecordingTransport()
        let metadata = WatchAudioFileMetadata(trackID: "cc0-ocean", expectedBytes: digest.bytes,
            sha256: digest.sha256, codec: "aac", fileExtension: "m4a")
        try await PhoneWatchAudioPreparation.transferWholeFile(prepared, metadata: metadata, transport: transport)
        let files = await transport.files
        #expect(files.count == 1)
        #expect(files.first?.0 == prepared)
        #expect(files.first?.1 == metadata.dictionary)
        #expect(WatchAudioChunkMetadata(dictionary: metadata.dictionary) == nil)
        let nonFileSends = await transport.nonFileSends
        #expect(nonFileSends == 0)
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"),
            stagingDirectory: root.appendingPathComponent("stage"))
        try await repository.upsertTrack(.init(trackID: "cc0-ocean", title: "Ocean — Nox_Sound (CC0)"))
        let incoming = root.appendingPathComponent("incoming.m4a")
        try FileManager.default.copyItem(at: prepared, to: incoming)
        let sync = WatchSyncActor(repository: repository, installer: installer, requiresNormalizedAAC: true)
        let fanout = WatchFanoutObserver([sync])
        defer { withExtendedLifetime(fanout) {} }
        let link = WatchFakeDuplexLink()
        await link.setReachable(false)
        let coordinator = WatchConnectivityCoordinator(transport: link.transport(for: .watch), observer: fanout)
        await sync.setCoordinator(coordinator)
        // Deliver before activation, reproducing the background-startup timing edge.
        await coordinator.receiveFile(incoming, metadata: metadata.dictionary)
        let snapshot = try await repository.tracks(readyOnly: true).first
        let installed = root.appendingPathComponent("watch").appendingPathComponent(try #require(snapshot?.localFilename))
        let item = AVPlayerItem(url: installed)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        #expect(status == .readyToPlay)
        #expect(item.duration.seconds > 0)
        player.pause()
        if let output = ProcessInfo.processInfo.environment["WATCH_AAC_FIXTURE_OUTPUT"] {
            try FileManager.default.copyItem(at: prepared, to: URL(fileURLWithPath: output))
        }
    }

    @Test func testProductionWatchRejectsUnconvertedLegacyWholeAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        let incoming = root.appendingPathComponent("legacy.wav")
        try FileManager.default.copyItem(at: source, to: incoming)
        let digest = try WatchFileDigest.measure(incoming)
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(), audioDirectory: root.appendingPathComponent("watch"))
        try await repository.upsertTrack(.init(trackID: "legacy", title: "Legacy"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: root.appendingPathComponent("watch"),
            stagingDirectory: root.appendingPathComponent("stage"))
        let diagnostics = WatchDiagnosticsRecorder()
        let sync = WatchSyncActor(repository: repository, installer: installer,
            requiresNormalizedAAC: true, diagnostics: diagnostics)
        await sync.didReceiveAudioFile(at: incoming, metadata: WatchAudioFileMetadata(trackID: "legacy", expectedBytes: digest.bytes,
            sha256: digest.sha256, codec: "wav", fileExtension: "wav").dictionary)
        let installed = try await repository.tracks(readyOnly: true)
        #expect(installed.isEmpty)
        let events = await diagnostics.events()
        #expect(events.last?.stateCode == "unsupportedAudio")
    }

    @Test func testDocumentAccessIsReleasedWhenPreparationFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let releaseMarker = root.appendingPathComponent("released")
        do {
            _ = try await PhoneWatchAudioPreparation.prepare(
                sourceURL: root.appendingPathComponent("missing.wav"), directory: root,
                startAccess: { _ in true },
                stopAccess: { _ in try? Data().write(to: releaseMarker) })
            Issue.record("Missing document must fail preparation")
        } catch {
            #expect(FileManager.default.fileExists(atPath: releaseMarker.path))
        }
    }

    @Test func testFLACIsConvertedToPlayableWatchAAC() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("imported.flac")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.1 }
        do {
            let file = try AVAudioFile(forWriting: source, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderBitDepthHintKey: 16])
            try file.write(from: buffer)
        }
        let prepared = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: source, directory: root.appendingPathComponent("owned"))
        #expect(prepared.pathExtension == "m4a")
        let decoded = try AVAudioFile(forReading: prepared)
        #expect(decoded.length > 0)
        let item = AVPlayerItem(url: prepared)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        #expect(status == .readyToPlay)
        #expect(item.duration.seconds > 0)
        player.pause()
        // Re-preparing unchanged content must preserve the background transfer's snapshot.
        let again = try await PhoneWatchAudioPreparation.prepare(
            sourceURL: source, directory: root.appendingPathComponent("owned"))
        #expect(again == prepared)
    }

    @Test func testFortyEightKHzMonoSourceIsNormalizedToStereoAAC128() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("48k-mono.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try #require(buffer.floatChannelData?[0])
        for i in 0..<24_000 { samples[i] = Float(sin(Double(i) * 2 * .pi * 440 / 48_000)) * 0.1 }
        do {
            let writer = try AVAudioFile(forWriting: source, settings: format.settings)
            try writer.write(from: buffer)
        }
        let prepared = try await PhoneWatchAudioPreparation.prepare(sourceURL: source, directory: root.appendingPathComponent("prepared"))
        let audio = try AVAudioFile(forReading: prepared)
        #expect(audio.fileFormat.sampleRate == 44_100)
        #expect(audio.fileFormat.channelCount == 2)
        #expect(audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(abs(Double(audio.length) / 44_100 - 0.5) <= 0.15)
    }

    @Test func testRealCachedAudioDefersInstallsAndPlaysOffline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-cache-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Match the production stream-cache blob name, which has no dotted extension.
        let cacheBlob = root.appendingPathComponent(String(repeating: "a", count: 64) + "-wav")
        let source = try #require(BuiltInContentProvider.bundledAudioURL(forChannelId: "ambient-ocean"))
        try FileManager.default.copyItem(at: source, to: cacheBlob)
        let audio = root.appendingPathComponent("audio")
        let repository = WatchLibraryRepository(container: try WatchStoreBootstrap.inMemory(),
            audioDirectory: audio, artworkDirectory: root.appendingPathComponent("artwork"))
        let installer = WatchFileInstaller(repository: repository, audioDirectory: audio,
            stagingDirectory: root.appendingPathComponent("staging"))
        let measured = try WatchFileDigest.measure(cacheBlob)
        let metadata = WatchAudioFileMetadata(trackID: "cached", expectedBytes: measured.bytes,
            sha256: measured.sha256, fileExtension: WatchAudioFileMetadata.fileExtension(for: cacheBlob))
        let deferred = await installer.install(stagedURL: cacheBlob, metadata: metadata.dictionary)
        #expect(deferred == .deferredAwaitingMetadata(trackID: "cached"))
        try await repository.upsertTrack(.init(trackID: "cached", title: "Cached"))
        _ = await installer.retryDeferred()
        let readyTracks = try await repository.tracks(readyOnly: true)
        let track = try #require(readyTracks.first)
        let installed = audio.appendingPathComponent(try #require(track.localFilename))
        let item = AVPlayerItem(url: installed)
        let player = AVPlayer(playerItem: item)
        player.play()
        let status = await waitForStatus(of: item)
        #expect(status == .readyToPlay)
        #expect(item.duration.seconds > 0)
        player.pause()
    }

    @Test func testRealAVPlayerItemReachesReadyToPlayForRemuxedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let opus = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("tone_mono", ext: "opus").write(to: opus)
        let caf = try await OpusRemuxer().remux(opusFileURL: opus, cacheKey: "watch-av-item")
        let item = AVPlayerItem(url: caf)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        #expect(status == .readyToPlay)
        let duration = item.duration
        #expect(duration.seconds.isFinite)
        #expect(duration.seconds > 0)
    }

    @Test func testRealAVPlayerItemReportsFailureForMalformedWatchAudio() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watch-av-item-bad-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let malformed = root.appendingPathComponent("fixture.opus")
        try Fixtures.data("corrupt_notogg", ext: "opus").write(to: malformed)
        let item = AVPlayerItem(url: malformed)
        let player = AVPlayer(playerItem: item)
        player.play()

        let status = await waitForStatus(of: item)

        #expect(status == .failed)
        #expect(item.error != nil)
    }

    /// Field report: a standalone "Apple Watch" pill sat on Now Playing forever. The output chip is
    /// only useful when it names a real route ("Apple Watch · AirPods Pro").
    @Test func testNowPlayingHidesBareAppleWatchTargetChip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchNowPlayingView.swift"), encoding: .utf8)
        #expect(view.contains("if let output = player.outputName"))
        #expect(!view.contains("?? String(localized: \"Apple Watch\")"),
                "no output route means no persistent Apple Watch chip")
    }

    /// Field report: the no-route card titled itself "Connect Headphones" and then repeated
    /// "Connect headphones or a speaker to play audio" underneath. The title now carries the whole
    /// instruction and the redundant body is gone.
    @Test func testNoRouteProblemCardSaysHeadphonesOrSpeakerWithoutRepeatingBody() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchNowPlayingView.swift"), encoding: .utf8)
        #expect(view.contains("title: \"Connect Headphones or Speaker\""))
        #expect(view.contains("message: nil"))
        #expect(!view.contains("title: \"Connect Headphones\""),
                "the title must not stop at headphones when a speaker is equally valid")
    }

    /// Field report: Now Playing repeated the track title in the subtitle, and the vertical gaps
    /// under the subtitle/times were too large. A subtitle that only restates the title is dropped.
    @Test func testNowPlayingSubtitleDropsRepeatedTitleAndTightensVerticalSpacing() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchNowPlayingView.swift"), encoding: .utf8)
        #expect(view.contains("artist.caseInsensitiveCompare(title) != .orderedSame"))
        #expect(view.contains("album.caseInsensitiveCompare(title) != .orderedSame"))
        #expect(view.contains("VStack(spacing: 2)"))
        #expect(view.contains(".padding(.top, 2)"))
        #expect(view.contains(".padding(.top, 0)"))
        let progress = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/Kit/WatchProgressViews.swift"), encoding: .utf8)
        #expect(progress.contains("VStack(spacing: 1)"))
        #expect(progress.contains("onSeek == nil ? 3 : 12"))
    }

    /// Field report: "iPhone connected" lived on Home forever; connection changes belong in a
    /// transient toast. The same pass removes the equally meaningless launch toast on the phone.
    @Test func testConnectionChangesAreEphemeralToastsNotPersistentHomeChrome() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let home = try String(contentsOf: root.appendingPathComponent("WatchApp/Views/WatchRootView.swift"), encoding: .utf8)
        #expect(home.contains("chrome.disconnectPulse"))
        #expect(home.contains("chrome.reconnectPulse"))
        #expect(home.contains("showConnectionToast(String(localized: \"iPhone connected\"))"))
        #expect(home.contains("watch.connection.toast"))
        #expect(home.contains("String(localized: \"Sync Status\") : status.title"),
                "Home must not render a persistent 'iPhone connected' label")
        let phoneRoot = try String(contentsOf: root.appendingPathComponent("Sources/Features/RootView.swift"), encoding: .utf8)
        #expect(!phoneRoot.contains("announceWatchConnection"))
        #expect(!phoneRoot.contains("Connecting to Apple Watch…"))
    }

    /// Field report: On My Watch should add music through a "+" search sheet, and its failure
    /// notice must dismiss in place instead of navigating to Settings.
    @Test func testOnMyWatchAddsBySearchAndDismissesFailureNoticeInPlace() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let myMusic = try String(contentsOf: root.appendingPathComponent("Sources/Features/MyMusic/MyMusicView.swift"), encoding: .utf8)
        let picker = try String(contentsOf: root.appendingPathComponent("Sources/Features/MyMusic/WatchAddMusicView.swift"), encoding: .utf8)
        #expect(myMusic.contains("mymusic.watch.add"))
        #expect(myMusic.contains("WatchAddMusicView"))
        #expect(picker.contains("confirmationDialog(\"Download to watch?\""))
        #expect(picker.contains("await appState.downloadToWatch(rows: [row])"))
        #expect(myMusic.contains("dismissedFailureCount"))
        #expect(!myMusic.contains("appState.showWatchSettings = true"))
        #expect(!myMusic.contains("Last watch report:"))
        #expect(!myMusic.contains("Choose music elsewhere in My Music"))
        let presenter = try String(contentsOf: root.appendingPathComponent("Sources/WatchSync/PhoneWatchManagementPresenter.swift"), encoding: .utf8)
        #expect(presenter.contains("Go to the track below and try again"))
    }

    /// Field report: every Sound Index job failed with a Core ML ML Program prediction error. The
    /// shipped encoders output 128-D (not the upstream 512-D metadata width), and the app must use
    /// the synchronous prediction path rather than the OS 27-failing async overload.
    @Test func testSoundIndexUses128DOutputAndSynchronousPrediction() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let manager = try String(contentsOf: root.appendingPathComponent("Sources/Discovery/ModelManager.swift"), encoding: .utf8)
        #expect(manager.contains("outputSpec.dimensions = EmbeddingSpace.current.dimensions"))
        #expect(manager.contains("SynchronousCoreMLSemanticModel("))
        #expect(manager.contains("model.prediction(from: provider, options: MLPredictionOptions())"))
        #expect(manager.contains("forceRecompile: true"))
        #expect(!manager.contains("try await box.model.prediction(from: provider)"))
        let cache = try String(contentsOf: root.appendingPathComponent("Sources/StarterGeneratorSupport/CompiledModelCache.swift"), encoding: .utf8)
        #expect(cache.contains("os-\\(version.majorVersion)"))
    }

    private func waitForStatus(of item: AVPlayerItem) async -> AVPlayerItem.Status {
        // Keep this a bounded readiness assertion, but leave room for the
        // host suite's Core ML and media tests to contend for AVFoundation.
        let deadline = ContinuousClock.now + .seconds(60)
        while ContinuousClock.now < deadline {
            if item.status != .unknown { return item.status }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return item.status
    }
}

private actor WholeAACRecordingTransport: WatchProtocolTransport {
    var files: [(URL, [String: String])] = []
    var nonFileSends = 0
    var reportedManifests: [WatchManifestPayload] = []
    func isReachable() -> Bool { false }
    func sendImmediate(_ data: Data) throws -> Data { nonFileSends += 1; throw WatchProtocolFault(code: .phoneUnavailable) }
    func updateApplicationContext(_ data: Data) { nonFileSends += 1 }
    func transferUserInfo(_ data: Data) {
        nonFileSends += 1
        if let envelope = try? WatchProtocolEnvelope.decode(data).get(), envelope.kind == .watchManifest,
           let manifest = try? envelope.decodePayload(WatchManifestPayload.self) {
            reportedManifests.append(manifest)
        }
    }
    func transferFile(_ url: URL, metadata: [String: String]) { files.append((url, metadata)) }
}
