import SwiftUI
import ParsoAudioAnalysis
import TonearmCore

struct DJV2Surface: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let onInfo: () -> Void
    let onLoad: (DJDeckID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width > proxy.size.height
            let side = landscape ? max(proxy.safeAreaInsets.leading, proxy.safeAreaInsets.trailing) + 8 : 6
            let titleHeight: CGFloat = landscape ? 0 : 44
            let bottom = landscape ? 0 : proxy.safeAreaInsets.bottom
            VStack(spacing: 0) {
                if !landscape {
                    DJV2TitleBar(model: model, onBack: onBack, onInfo: onInfo)
                }
                DJV2Grid(model: model, landscape: landscape, sideInset: side,
                         availableHeight: max(0, proxy.size.height - titleHeight - bottom),
                         onBack: onBack, onInfo: onInfo, onLoad: onLoad)
            }
            .padding(.bottom, bottom)
            .background(Palette.bg)
        }
    }
}

private struct DJV2TitleBar: View {
    @ObservedObject var model: DJPerformanceModel
    let onBack: () -> Void
    let onInfo: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Label("Platterhead DJ", systemImage: "chevron.down")
                    .font(.system(size: 17, weight: .bold))
            }
            .accessibilityLabel("Close DJ")
            Spacer(minLength: 4)
            Button(action: model.toggleRecording) {
                Label(model.recording ? "REC" : "REC", systemImage: "record.circle")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(model.recording ? .white : Palette.ink2)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(model.recording ? Color.red : Color.white.opacity(0.08), in: Capsule())
            }
            .accessibilityLabel(model.recording ? "Stop recording" : "Record the mix")
            Button(action: onInfo) {
                Image(systemName: "info.circle")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("DJ gestures and help")
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.ultraThinMaterial)
    }
}

private struct DJV2Grid: View {
    @ObservedObject var model: DJPerformanceModel
    let landscape: Bool
    let sideInset: CGFloat
    let availableHeight: CGFloat
    let onBack: () -> Void
    let onInfo: () -> Void
    let onLoad: (DJDeckID) -> Void

    var body: some View {
        GeometryReader { proxy in
            let columns = landscape ? 15 : 8
            let rows = 11
            let width = max(0, proxy.size.width - sideInset * 2)
            let layout = DJGridLayout(size: CGSize(width: width, height: availableHeight),
                                      columns: columns, rows: landscape ? 8 : rows, gap: 4)
            ZStack(alignment: .topLeading) {
                DJV2DeckZone(layout: layout, active: model.activeDeck, landscape: landscape)
                if landscape { landscapeContent(layout) } else { portraitContent(layout) }
            }
            .frame(width: width, height: availableHeight, alignment: .topLeading)
            .padding(.horizontal, sideInset)
            .clipped()
        }
    }

    @ViewBuilder
    private func portraitContent(_ l: DJGridLayout) -> some View {
        cell(l, 0, 0, 4) { DJV2TrackCell(deck: model.deckA, active: model.activeDeck == .a, loadPhase: model.loadPhases[.a], onSelect: { model.selectDeck(.a) }, onLoad: { onLoad(.a) }, onClear: { model.clearHotCues(.a) }) }
        cell(l, 4, 0, 1) { DJV2LoadButton(deck: .a, onAir: model.deckIsOnAir(.a), onLoad: { onLoad(.a) }) }
        cell(l, 5, 0, 1) { DJV2LoadButton(deck: .b, onAir: model.deckIsOnAir(.b), onLoad: { onLoad(.b) }) }
        cell(l, 6, 0, 2) { DJV2TrackCell(deck: model.deckB, active: model.activeDeck == .b, loadPhase: model.loadPhases[.b], onSelect: { model.selectDeck(.b) }, onLoad: { onLoad(.b) }, onClear: { model.clearHotCues(.b) }) }
        cell(l, 0, 1, 8) { DJV2WaveCell(deck: model.deckA, model: model, active: model.activeDeck == .a) }
        cell(l, 0, 2, 8) { DJV2WaveCell(deck: model.deckB, model: model, active: model.activeDeck == .b) }
        cell(l, 0, 3, 4, 4) { DJV2Jog(deck: model.activeDeckState, model: model) }
        cell(l, 0, 3) { DJV2Button(title: "VINYL", active: model.activeDeckState.vinyl, color: .white) { model.toggleDeckMode(model.activeDeck, .vinyl) } }
        cell(l, 3, 3) { DJV2Button(title: "SLIP", active: model.activeDeckState.slip, color: .white) { model.toggleDeckMode(model.activeDeck, .slip) } }
        cell(l, 0, 6) { DJV2Button(title: "REV", active: model.activeDeckState.reverse, color: .white) { model.toggleDeckMode(model.activeDeck, .reverse) } }
        cell(l, 3, 6) { DJV2Button(title: "Q", active: model.activeDeckState.quantize, color: .white) { model.toggleDeckMode(model.activeDeck, .quantize) } }
        cell(l, 4, 3) { DJV2ModeRow(model: model) }
        cell(l, 4, 4, 4, 2) { DJV2Pads(model: model) }
        cell(l, 4, 6) { DJV2Button(title: "CUE", active: model.activeDeckState.cuePoint != nil, color: model.activeDeckState.accent, gesture: DJV2CueGesture(model: model, deck: model.activeDeck)) }
        cell(l, 5, 6) { DJV2Button(title: model.activeDeckState.isPlaying ? "PAUSE" : "PLAY", active: model.activeDeckState.isPlaying, color: model.activeDeckState.accent) { model.toggle(model.activeDeck) } }
        cell(l, 6, 6) { DJV2Button(title: "SYNC", active: model.activeDeckState.syncEnabled, color: model.activeDeckState.accent) { model.toggleSync(model.activeDeck) }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.makeMaster(model.activeDeck) }) }
        cell(l, 7, 6) { DJV2Button(title: "KEY", active: model.activeDeckState.keySync, color: model.activeDeckState.accent) { model.activeDeckState.keySync.toggle() }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.setPadMode(model.activeDeck, mode: .keyShift) }) }
        cell(l, 0, 7, 4) { DJV2TempoFader(deck: model.activeDeckState, model: model) }
        cell(l, 4, 7) { DJV2Button(title: "RANGE", second: "±\(Int(model.activeDeckState.tempoRange))%", active: false, color: .white) { model.cycleTempoRange(model.activeDeck) } }
        cell(l, 5, 7) { DJV2Button(title: "RESET", active: false, color: .white) { model.resetTempo(model.activeDeck) } }
        cell(l, 6, 7) { DJV2Button(title: "MT", active: model.activeDeckState.masterTempo, color: .white) { model.activeDeckState.masterTempo.toggle() } }
        cell(l, 7, 7) { DJV2Button(title: "TAP", active: false, color: .white) { model.tapTempo(model.activeDeck) }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.setPadMode(model.activeDeck, mode: .grid) }) }
        cell(l, 0, 8) { DJV2Knob(label: "HI", value: model.activeDeckState.eqHigh, valueText: DJKnobMapping.display(model.activeDeckState.eqHigh), color: model.activeDeckState.accent) { model.setEQ(model.activeDeck, high: $0) } }
        cell(l, 1, 8) { DJV2Knob(label: "MID", value: model.activeDeckState.eqMid, valueText: DJKnobMapping.display(model.activeDeckState.eqMid), color: model.activeDeckState.accent) { model.setEQ(model.activeDeck, mid: $0) } }
        cell(l, 2, 8) { DJV2Knob(label: "LOW", value: model.activeDeckState.eqLow, valueText: DJKnobMapping.display(model.activeDeckState.eqLow), color: model.activeDeckState.accent) { model.setEQ(model.activeDeck, low: $0) } }
        cell(l, 3, 8) { DJV2Knob(label: "CFX", value: model.activeDeckState.colorFX, valueText: DJKnobMapping.cfxLabel(model.activeDeckState.colorFX), color: model.activeDeckState.accent) { model.setColorFX(model.activeDeck, value: $0) } }
        cell(l, 0, 9, 4) { DJV2HorizontalFader(label: "BASS", value: model.bassFader, left: "A BASS", right: "B BASS") { model.setBass($0) } }
        cell(l, 0, 10, 4) { DJV2HorizontalFader(label: "X-FADE", value: model.crossfader, left: "A", right: "B") { model.setCrossfader($0) } }
        cell(l, 4, 8, 1, 3) { DJV2VerticalFader(deck: model.deckA, model: model) }
        cell(l, 5, 8) { DJV2Button(title: "CUE", second: "A", active: model.cueA, color: model.deckA.accent) { model.toggleCue(.a) } }
        cell(l, 6, 8) { DJV2Button(title: "CUE", second: "B", active: model.cueB, color: model.deckB.accent) { model.toggleCue(.b) } }
        cell(l, 7, 8, 1, 3) { DJV2VerticalFader(deck: model.deckB, model: model) }
        cell(l, 5, 9) { DJV2Knob(label: "VOL", value: model.masterLevel, valueText: "\(Int(model.masterLevel * 100))%", color: .white) { model.setMasterLevel($0) } }
        cell(l, 6, 9) { DJV2Knob(label: "PHONES", value: model.headphoneLevel, valueText: "\(Int(model.headphoneLevel * 100))%", color: .white) { model.setHeadphoneLevel($0) } }
        cell(l, 5, 10) { DJV2Knob(label: "CUE/MST", value: model.cueMasterMix, valueText: "\(Int(model.cueMasterMix * 100))%", color: .white) { model.setCueMasterMix($0) } }
        cell(l, 6, 10) { DJV2Button(title: model.outputMode.rawValue, active: false, color: .white) { model.cycleOutput() } }
    }

    @ViewBuilder
    private func landscapeContent(_ l: DJGridLayout) -> some View {
        cell(l, 0, 0, 4) { DJV2LandscapeTitle(onBack: onBack, onInfo: onInfo) }
        cell(l, 4, 0, 4) { DJV2TrackCell(deck: model.deckA, active: model.activeDeck == .a, loadPhase: model.loadPhases[.a], onSelect: { model.selectDeck(.a) }, onLoad: { onLoad(.a) }, onClear: { model.clearHotCues(.a) }) }
        cell(l, 8, 0) { DJV2LoadButton(deck: .a, onAir: model.deckIsOnAir(.a), onLoad: { onLoad(.a) }) }
        cell(l, 9, 0) { DJV2LoadButton(deck: .b, onAir: model.deckIsOnAir(.b), onLoad: { onLoad(.b) }) }
        cell(l, 10, 0, 4) { DJV2TrackCell(deck: model.deckB, active: model.activeDeck == .b, loadPhase: model.loadPhases[.b], onSelect: { model.selectDeck(.b) }, onLoad: { onLoad(.b) }, onClear: { model.clearHotCues(.b) }) }
        cell(l, 14, 0) { DJV2InfoButton(action: onInfo) }
        cell(l, 4, 1, 11) { DJV2WaveCell(deck: model.deckA, model: model, active: model.activeDeck == .a) }
        cell(l, 4, 2, 11) { DJV2WaveCell(deck: model.deckB, model: model, active: model.activeDeck == .b) }
        cell(l, 0, 1) { DJV2Button(title: "VINYL", active: model.activeDeckState.vinyl, color: .white) { model.toggleDeckMode(model.activeDeck, .vinyl) } }
        cell(l, 1, 1) { DJV2Button(title: "SLIP", active: model.activeDeckState.slip, color: .white) { model.toggleDeckMode(model.activeDeck, .slip) } }
        cell(l, 2, 1) { DJV2Button(title: "REV", active: model.activeDeckState.reverse, color: .white) { model.toggleDeckMode(model.activeDeck, .reverse) } }
        cell(l, 3, 1) { DJV2Button(title: "Q", active: model.activeDeckState.quantize, color: .white) { model.toggleDeckMode(model.activeDeck, .quantize) } }
        cell(l, 0, 2, 4, 5) { DJV2Jog(deck: model.activeDeckState, model: model) }
        cell(l, 0, 7) { DJV2Button(title: "CUE", active: model.activeDeckState.cuePoint != nil, color: model.activeDeckState.accent, gesture: DJV2CueGesture(model: model, deck: model.activeDeck)) }
        cell(l, 1, 7) { DJV2Button(title: model.activeDeckState.isPlaying ? "PAUSE" : "PLAY", active: model.activeDeckState.isPlaying, color: model.activeDeckState.accent) { model.toggle(model.activeDeck) } }
        cell(l, 2, 7) { DJV2Button(title: "SYNC", active: model.activeDeckState.syncEnabled, color: model.activeDeckState.accent) { model.toggleSync(model.activeDeck) }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.makeMaster(model.activeDeck) }) }
        cell(l, 3, 7) { DJV2Button(title: "KEY", active: model.activeDeckState.keySync, color: model.activeDeckState.accent) { model.activeDeckState.keySync.toggle() }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.setPadMode(model.activeDeck, mode: .keyShift) }) }
        cell(l, 4, 3, 4) { DJV2ModeRow(model: model) }
        cell(l, 4, 4, 4, 2) { DJV2Pads(model: model) }
        cell(l, 4, 6, 4) { DJV2TempoFader(deck: model.activeDeckState, model: model) }
        cell(l, 4, 7) { DJV2Button(title: "RANGE", second: "±\(Int(model.activeDeckState.tempoRange))%", active: false, color: .white) { model.cycleTempoRange(model.activeDeck) } }
        cell(l, 5, 7) { DJV2Button(title: "RESET", active: false, color: .white) { model.resetTempo(model.activeDeck) } }
        cell(l, 6, 7) { DJV2Button(title: "MT", active: model.activeDeckState.masterTempo, color: .white) { model.activeDeckState.masterTempo.toggle() } }
        cell(l, 7, 7) { DJV2Button(title: "TAP", active: false, color: .white) { model.tapTempo(model.activeDeck) }.simultaneousGesture(LongPressGesture(minimumDuration: 0.6).onEnded { _ in model.setPadMode(model.activeDeck, mode: .grid) }) }
        landscapeMixer(l)
    }

    @ViewBuilder
    private func landscapeMixer(_ l: DJGridLayout) -> some View {
        ForEach(Array(["HI", "MID", "LOW", "CFX"].enumerated()), id: \.offset) { item in
            DJV2GridCell(frame: l.frame(col: 8 + item.offset, row: 3)) { landscapeEQKnob(deck: .a, index: item.offset, label: item.element) }
            DJV2GridCell(frame: l.frame(col: 8 + item.offset, row: 4)) { landscapeEQKnob(deck: .b, index: item.offset, label: item.element) }
        }
        DJV2GridCell(frame: l.frame(col: 8, row: 5)) { DJV2Knob(label: "PHONES", value: model.headphoneLevel, valueText: "\(Int(model.headphoneLevel * 100))%", color: .white) { model.setHeadphoneLevel($0) } }
        DJV2GridCell(frame: l.frame(col: 9, row: 5)) { DJV2Knob(label: "CUE/MST", value: model.cueMasterMix, valueText: "\(Int(model.cueMasterMix * 100))%", color: .white) { model.setCueMasterMix($0) } }
        DJV2GridCell(frame: l.frame(col: 10, row: 5)) { DJV2Button(title: model.outputMode.rawValue, active: false, color: .white) { model.cycleOutput() } }
        DJV2GridCell(frame: l.frame(col: 11, row: 5)) { DJV2Button(title: "REC", active: model.recording, color: .red) { model.toggleRecording() } }
        DJV2GridCell(frame: l.frame(col: 8, row: 6, colSpan: 4)) { DJV2HorizontalFader(label: "BASS", value: model.bassFader, left: "A", right: "B") { model.setBass($0) } }
        DJV2GridCell(frame: l.frame(col: 8, row: 7, colSpan: 4)) { DJV2HorizontalFader(label: "X-FADE", value: model.crossfader, left: "A", right: "B") { model.setCrossfader($0) } }
        DJV2GridCell(frame: l.frame(col: 12, row: 3)) { DJV2Button(title: "CUE", second: "A", active: model.cueA, color: model.deckA.accent) { model.toggleCue(.a) } }
        DJV2GridCell(frame: l.frame(col: 13, row: 3)) { DJV2Knob(label: "VOL", value: model.masterLevel, valueText: "\(Int(model.masterLevel * 100))%", color: .white) { model.setMasterLevel($0) } }
        DJV2GridCell(frame: l.frame(col: 14, row: 3)) { DJV2Button(title: "CUE", second: "B", active: model.cueB, color: model.deckB.accent) { model.toggleCue(.b) } }
        DJV2GridCell(frame: l.frame(col: 12, row: 4, rowSpan: 4)) { DJV2VerticalFader(deck: model.deckA, model: model) }
        DJV2GridCell(frame: l.frame(col: 13, row: 4, rowSpan: 4)) { DJV2MasterMeter(model: model) }
        DJV2GridCell(frame: l.frame(col: 14, row: 4, rowSpan: 4)) { DJV2VerticalFader(deck: model.deckB, model: model) }
    }

    @ViewBuilder
    private func landscapeEQKnob(deck id: DJDeckID, index: Int, label: String) -> some View {
        let state = model.deck(id)
        switch index {
        case 0:
            DJV2Knob(label: "\(id.rawValue) \(label)", value: state.eqHigh, valueText: DJKnobMapping.display(state.eqHigh), color: state.accent) { model.setEQ(id, high: $0) }
        case 1:
            DJV2Knob(label: "\(id.rawValue) \(label)", value: state.eqMid, valueText: DJKnobMapping.display(state.eqMid), color: state.accent) { model.setEQ(id, mid: $0) }
        case 2:
            DJV2Knob(label: "\(id.rawValue) \(label)", value: state.eqLow, valueText: DJKnobMapping.display(state.eqLow), color: state.accent) { model.setEQ(id, low: $0) }
        default:
            DJV2Knob(label: "\(id.rawValue) \(label)", value: state.colorFX, valueText: DJKnobMapping.cfxLabel(state.colorFX), color: state.accent) { model.setColorFX(id, value: $0) }
        }
    }

    private func cell<Content: View>(_ l: DJGridLayout, _ col: Int, _ row: Int, _ colSpan: Int = 1, _ rowSpan: Int = 1, @ViewBuilder content: @escaping () -> Content) -> some View {
        DJV2GridCell(frame: l.frame(col: col, row: row, colSpan: colSpan, rowSpan: rowSpan), content: content)
    }
}

private extension DJPerformanceModel {
    var activeDeckState: DJDeckState { deck(activeDeck) }
    func cycleOutput() { setOutputMode(DJOutputMode.allCases[(DJOutputMode.allCases.firstIndex(of: outputMode)! + 1) % DJOutputMode.allCases.count]) }
}

private struct DJV2DeckZone: View {
    let layout: DJGridLayout
    let active: DJDeckID
    let landscape: Bool
    var body: some View {
        let rect = landscape ? layout.frame(col: 0, row: 1, colSpan: 4, rowSpan: 7).union(layout.frame(col: 4, row: 3, colSpan: 4, rowSpan: 5)) : layout.frame(col: 0, row: 3, colSpan: 8, rowSpan: 5)
        RoundedRectangle(cornerRadius: 10).strokeBorder(active == .a ? Palette.brass.opacity(0.6) : Color.blue.opacity(0.65), lineWidth: 1.5)
            .frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }
}

private struct DJV2GridCell<Content: View>: View {
    let frame: CGRect
    let content: () -> Content
    init(frame: CGRect, @ViewBuilder content: @escaping () -> Content) { self.frame = frame; self.content = content }
    var body: some View { content().frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY) }
}

private struct DJV2Button: View {
    let title: String
    var second: String? = nil
    var active = false
    var color: Color = Palette.ink
    var gesture: AnyGesture<Void>? = nil
    let action: () -> Void
    init(title: String, second: String? = nil, active: Bool = false, color: Color = Palette.ink, action: @escaping () -> Void) {
        self.title = title; self.second = second; self.active = active; self.color = color; self.action = action
    }
    init(title: String, active: Bool, color: Color, gesture: some Gesture) {
        self.title = title; self.active = active; self.color = color; self.gesture = AnyGesture(gesture.map { _ in () }); self.action = {}
    }
    var body: some View {
        let button = Button(action: action) {
            VStack(spacing: 1) { Text(title).minimumScaleFactor(0.55); if let second { Text(second).font(.system(size: 9, weight: .bold, design: .monospaced)) } }
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundStyle(active ? Palette.bg : Palette.ink2)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? color : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(active ? color : Color.white.opacity(0.13)))
        }.buttonStyle(.plain).contentShape(Rectangle())
        if let gesture { button.simultaneousGesture(gesture) } else { button }
    }
}

private struct DJV2InfoButton: View {
    let action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: "info.circle").font(.system(size: 20)).frame(maxWidth: .infinity, maxHeight: .infinity) }.buttonStyle(.plain).accessibilityLabel("DJ gestures and help") }
}

private struct DJV2LandscapeTitle: View {
    let onBack: () -> Void
    let onInfo: () -> Void
    var body: some View { HStack { Button(action: onBack) { Label("Platterhead DJ", systemImage: "chevron.down").font(.system(size: 15, weight: .bold)) }.buttonStyle(.plain); Spacer(); Button(action: onInfo) { Image(systemName: "info.circle") }.buttonStyle(.plain) }.foregroundStyle(Palette.ink).padding(.horizontal, 6) }
}

private struct DJV2TrackCell: View {
    @ObservedObject var deck: DJDeckState
    let active: Bool
    let loadPhase: DJLoadPhase?
    let onSelect: () -> Void
    let onLoad: () -> Void
    let onClear: () -> Void
    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(deck.id.rawValue).font(.system(size: 12, weight: .black, design: .monospaced)).foregroundStyle(deck.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(deck.row == nil ? "LOAD TRACK \(deck.id.rawValue)" : deck.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(deck.artist.isEmpty ? "Tap to load" : deck.artist).font(.system(size: 10)).foregroundStyle(Palette.ink2).lineLimit(1)
                    if !deck.album.isEmpty { Text(deck.album).font(.system(size: 9)).foregroundStyle(Palette.ink3).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if let loadPhase { Text(loadPhase.label).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink3) }
            }.padding(.horizontal, 6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(active ? deck.accent.opacity(0.13) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? deck.accent.opacity(0.7) : Color.white.opacity(0.1), lineWidth: active ? 1.5 : 1))
        }.buttonStyle(.plain).contextMenu {
            Button("Re-analyze track", action: onLoad)
            Button("Clear hot cues", role: .destructive, action: onClear)
        }.accessibilityLabel("Deck \(deck.id.rawValue), \(deck.title). Tap to select; load from the load button.")
    }
}

private struct DJV2LoadButton: View {
    let deck: DJDeckID
    let onAir: Bool
    let onLoad: () -> Void
    var body: some View {
        DJV2Button(title: "LOAD", second: deck.rawValue, active: onAir, color: .red) { if !onAir { onLoad() } }
            .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in if onAir { onLoad() } })
            .accessibilityLabel(onAir ? "Load deck \(deck.rawValue), hold for one second" : "Load deck \(deck.rawValue)")
    }
}

private struct DJV2WaveCell: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    let active: Bool
    @State private var elapsed = false
    @State private var window = 4.0
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                DJV2WaveCanvas(deck: deck, window: window)
                Rectangle().fill(deck.accent).frame(width: 1.5).allowsHitTesting(false)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text("\(deck.bpm.map { String(format: "%.1f", $0) } ?? "—") BPM")
                        Text("\(deck.tempoPercent >= 0 ? "+" : "")\(String(format: "%.1f", deck.tempoPercent))%")
                        Text("KEY \(DJKeyFormatter.shifted(deck.key, semitones: deck.keyShiftSemitones))")
                        if model.deckIsOnAir(deck.id) { Text("ON AIR").foregroundStyle(.red) }
                        if deck.syncEnabled { Text("SYNC") }
                        if deck.masterTempo { Text("MT") }
                        Spacer()
                        Button(elapsed ? time(deck.position) : "−\(time(max(0, deck.duration - deck.position)))") { elapsed.toggle() }.buttonStyle(.plain)
                    }.font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(deck.accent)
                    Spacer()
                    HStack(spacing: 3) { ForEach(0..<4, id: \.self) { i in Rectangle().fill(phase(deck) == i ? deck.accent : Color.white.opacity(0.18)).frame(width: 9, height: 3) } }
                    DJV2OverviewBand(deck: deck, model: model)
                }.padding(6).allowsHitTesting(true)
                if let phase = model.loadPhases[deck.id] { DJV2LoadBadge(phase: phase) }
            }.background(Color.white.opacity(active ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(active ? deck.accent : Color.white.opacity(0.1), lineWidth: active ? 1.5 : 1))
                .contentShape(Rectangle())
                .onTapGesture { model.selectDeck(deck.id) }
                .simultaneousGesture(MagnificationGesture().onChanged { value in window = max(2, min(16, 4 / value)) })
        }
    }
    private func time(_ value: Double) -> String { String(format: "%d:%02d", Int(max(0, value)) / 60, Int(max(0, value)) % 60) }
    private func phase(_ deck: DJDeckState) -> Int { guard let bpm = deck.bpm, bpm > 0 else { return 0 }; return max(0, Int((deck.position * bpm / 60).rounded()) % 4) }
}

private struct DJV2LoadBadge: View {
    let phase: DJLoadPhase
    var body: some View {
        Text(phase == .decoding ? "DECODING…" : phase == .analyzing ? "ANALYZING…" : "LOADING…")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.black.opacity(0.85), in: Capsule()).foregroundStyle(Palette.ink)
    }
}

private struct DJV2WaveCanvas: View {
    @ObservedObject var deck: DJDeckState
    let window: Double
    var body: some View {
        Canvas { context, size in
            let count = max(1, deck.waveform.count), secondsPerBin = deck.duration > 0 ? deck.duration / Double(count) : window
            let first = deck.duration > 0 ? max(0, Int(floor((deck.position - window / 2) / secondsPerBin)) - 1) : 0
            let last = deck.duration > 0 ? min(count - 1, Int(ceil((deck.position + window / 2) / secondsPerBin)) + 1) : count - 1
            for i in first...max(first, last) {
                let bin = deck.waveform.isEmpty ? WaveformBin(min: -0.1, max: 0.1, rms: 0.1) : deck.waveform[i]
                let t = (Double(i) + 0.5) * secondsPerBin
                let x = size.width / 2 + CGFloat((t - deck.position) / window) * size.width
                let h = max(3, CGFloat(max(abs(bin.min), abs(bin.max))) * size.height * 0.8)
                var path = Path(); path.move(to: CGPoint(x: x, y: size.height / 2 - h / 2)); path.addLine(to: CGPoint(x: x, y: size.height / 2 + h / 2))
                context.stroke(path, with: .color(deck.accent.opacity(deck.isPlaying ? 0.95 : 0.62)), lineWidth: max(1, size.width / CGFloat(count) * 4))
            }
            if deck.duration > 0 {
                let visibleBeats = deck.beatPositions.isEmpty
                    ? fallbackBeats(bpm: deck.bpm ?? 120, position: deck.position, window: window)
                    : deck.beatPositions.filter { abs($0 - deck.position) <= window * 0.6 }
                for (index, time) in visibleBeats.enumerated() {
                    let x = size.width / 2 + CGFloat((time - deck.position) / window) * size.width
                    let downbeat = deck.downbeatPositions.contains { abs($0 - time) < 0.01 } || index.isMultiple(of: 4)
                    var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height * 0.7))
                    context.stroke(line, with: .color(Color.white.opacity(downbeat ? 0.28 : 0.1)), lineWidth: downbeat ? 1.4 : 1)
                }
            }
            var playhead = Path(); playhead.move(to: CGPoint(x: size.width / 2, y: 0)); playhead.addLine(to: CGPoint(x: size.width / 2, y: size.height)); context.stroke(playhead, with: .color(deck.accent), lineWidth: 1.5)
            if let cue = deck.cuePoint, deck.duration > 0 { let x = size.width / 2 + CGFloat((cue - deck.position) / window) * size.width; var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: size.height * 0.7)); context.stroke(line, with: .color(.white), lineWidth: 1) }
        }.background(Color.black.opacity(0.25))
    }

    private func fallbackBeats(bpm: Double, position: Double, window: Double) -> [Double] {
        guard bpm > 0 else { return [] }
        let spacing = 60 / bpm
        let start = Int(floor((position - window / 2) / spacing)) - 1
        let end = Int(ceil((position + window / 2) / spacing)) + 1
        guard end >= start else { return [] }
        return (start...end).map { Double($0) * spacing }
    }
}

private struct DJV2OverviewBand: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let bins = max(1, deck.waveform.count)
                for i in 0..<bins {
                    let b = deck.waveform.isEmpty ? WaveformBin(min: -0.1, max: 0.1, rms: 0.1) : deck.waveform[i]
                    let x = CGFloat(i) / CGFloat(bins) * size.width
                    let h = max(1, CGFloat(max(abs(b.min), abs(b.max))) * size.height)
                    var line = Path(); line.move(to: CGPoint(x: x, y: size.height / 2 - h / 2)); line.addLine(to: CGPoint(x: x, y: size.height / 2 + h / 2)); context.stroke(line, with: .color(deck.accent.opacity(0.6)), lineWidth: max(1, size.width / CGFloat(bins)))
                }
            }.frame(height: 12).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in model.minimapSeek(deck.id, x: value.location.x, width: proxy.size.width) })
        }.frame(height: 12)
    }
}

private struct DJV2ModeRow: View {
    @ObservedObject var model: DJPerformanceModel
    var body: some View {
        HStack(spacing: 3) {
            mode("HOT CUE", .hotCue); mode("LOOP", .loop); mode("FX", .fx); mode("MIX", .mix)
        }.padding(2)
    }
    private func mode(_ title: String, _ value: DJPadMode) -> some View {
        DJV2Button(title: title,
                   second: value == .fx ? (model.activeDeckState.padMode == .beatFX ? "BEAT" : "PAD") : nil,
                   active: model.activeDeckState.padMode == value || (value == .fx && model.activeDeckState.padMode == .beatFX),
                   color: .white) { model.setPadMode(model.activeDeck, mode: value) }
    }
}

private struct DJV2Pads: View {
    @ObservedObject var model: DJPerformanceModel
    var deck: DJDeckState { model.activeDeckState }
    var body: some View {
        GeometryReader { proxy in
            let gap: CGFloat = 3, w = (proxy.size.width - gap * 3) / 4, h = (proxy.size.height - gap) / 2
            ZStack(alignment: .topLeading) {
                ForEach(0..<8, id: \.self) { i in
                    DJV2Pad(deck: deck, index: i, model: model).frame(width: w, height: h).position(x: CGFloat(i % 4) * (w + gap) + w / 2, y: CGFloat(i / 4) * (h + gap) + h / 2)
                }
            }
        }
    }
}

private struct DJV2Pad: View {
    @ObservedObject var deck: DJDeckState
    let index: Int
    let model: DJPerformanceModel
    @State private var held = false
    var body: some View {
        let spec = label
        DJV2Button(title: spec.title, second: spec.second, active: active, color: padColor) {
            if !(deck.padMode == .mix && index == 7) {
                model.setPadAction(deck.id, index: index, pressed: true)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in if deck.padMode == .fx && index < 4 && !held { held = true; model.setPadAction(deck.id, index: index, pressed: true) } }.onEnded { _ in if held { held = false; model.setPadAction(deck.id, index: index, pressed: false) } })
        .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in if deck.padMode == .hotCue && (deck.hotCues[index + 1] != nil || deck.hotLoops[index + 1] != nil) { model.deleteCue(index + 1, deck: deck.id) } })
        .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in if deck.padMode == .mix && index == 7 { model.flatMix() } })
    }
    private var active: Bool { if deck.padMode == .hotCue { return deck.hotCues[index + 1] != nil || deck.hotLoops[index + 1] != nil }; if deck.padMode == .loop { return index == 0 ? deck.loopIn != nil : index == 1 ? deck.loopOut != nil : index == 3 && deck.loopActive }; return deck.padMode == .fx && index < 4 && deck.echoPad != nil }
    private var padColor: Color {
        guard deck.padMode == .hotCue else { return deck.accent }
        switch deck.hotCueColors[index + 1] ?? deck.hotLoops[index + 1]?.color ?? index {
        case 0: return Color(red: 0.95, green: 0.55, blue: 0.20)
        case 1: return Color(red: 0.95, green: 0.35, blue: 0.38)
        case 2: return Color(red: 0.70, green: 0.45, blue: 0.95)
        case 3: return Color(red: 0.30, green: 0.65, blue: 0.95)
        case 4: return Color(red: 0.25, green: 0.78, blue: 0.65)
        case 5: return Color(red: 0.82, green: 0.78, blue: 0.25)
        case 6: return Color(red: 0.95, green: 0.45, blue: 0.75)
        default: return Color(red: 0.55, green: 0.78, blue: 0.95)
        }
    }
    private var label: (title: String, second: String?) {
        switch deck.padMode {
        case .hotCue: return ("\(index + 1)", nil)
        case .loop: return (index == 0 ? "IN" : index == 1 ? "OUT" : index == 2 ? "SET \(model.loopLengthLabel(deck.id))" : index == 3 ? (deck.loopActive ? "EXIT" : "ENTER") : index == 4 ? "½×" : index == 5 ? "2×" : index == 6 ? "◀ \(model.loopLengthLabel(deck.id))" : "\(model.loopLengthLabel(deck.id)) ▶", nil)
        case .fx: return (index < 4 ? ["¼", "½", "1", "2"][index] : index == 4 ? "ECHO OUT" : index == 5 ? "ROLL" : index == 6 ? "REVERB" : "BRAKE", "")
        case .mix: return (index == 0 ? "A TRIM" : index == 1 ? "B TRIM" : index == 2 ? "AUTO GAIN" : index == 3 ? "REC" : index == 4 ? "ISO LOW" : index == 5 ? "ISO MID" : index == 6 ? "ISO HI" : "FLAT", "")
        case .beatFX: return (index == 0 ? "TYPE" : index == 1 ? "◀ BEAT" : index == 2 ? "BEAT ▶" : index == 3 ? "ON" : index == 4 ? "CH A" : index == 5 ? "CH B" : index == 6 ? "MASTER" : "LEVEL", "")
        case .keyShift: return (["♭ −1", "♯ +1", "♭♭ −2", "♯♯ +2", "KEY SYNC", "RESET", "MT", "DONE"][index], "")
        case .grid: return (["◀ GRID", "▶ GRID", "1.1 HERE", "TAP", "BPM ÷2", "BPM ×2", "RESET", "DONE"][index], "")
        case .echo: return ("ECHO", "")
        }
    }
}

private struct DJV2Jog: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    @State private var lastAngle: Double?
    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2), radius = min(proxy.size.width, proxy.size.height) * 0.38
            ZStack { Circle().fill(Color.black.opacity(0.8)).overlay(Circle().stroke(deck.accent, lineWidth: 2)).frame(width: radius * 2, height: radius * 2); Circle().stroke(Color.white.opacity(0.12), lineWidth: 1).frame(width: radius * 1.55, height: radius * 1.55); VStack(spacing: 2) { Text(deck.id.rawValue + (model.deckIsOnAir(deck.id) ? " · ON AIR" : " · CDJ")).font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(model.deckIsOnAir(deck.id) ? .red : deck.accent); Text(format(deck.position)).font(.system(size: 16, weight: .bold, design: .monospaced)); Text("\(deck.tempoPercent >= 0 ? "+" : "")\(String(format: "%.1f", deck.tempoPercent))%").font(.system(size: 9, design: .monospaced)); Text(deck.vinyl ? "VINYL" : "CDJ").font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.ink3) } }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Circle()).gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - center.x, dy = value.location.y - center.y, angle = atan2(dy, dx)
                if let previous = lastAngle {
                    var delta = angle - previous; if delta > .pi { delta -= 2 * .pi }; if delta < -.pi { delta += 2 * .pi }
                    if value.location.distance(to: center) > radius * 0.78 { if deck.isPlaying { model.nudge(deck.id, direction: delta) } else { model.movePaused(deck.id, by: -delta * 40, width: 100) } }
                    else if deck.isPlaying { model.scratch(deck.id, by: -delta * 30, width: 100) } else { model.movePaused(deck.id, by: -delta * 12, width: 100) }
                }
                lastAngle = angle
            }.onEnded { _ in lastAngle = nil; model.endScratch(deck.id); model.snapIfQuantized(deck.id) })
        }
    }
    private func format(_ value: Double) -> String { String(format: "%d:%02d", Int(max(0, value)) / 60, Int(max(0, value)) % 60) }
}

private struct DJV2CueGesture: Gesture {
    let model: DJPerformanceModel
    let deck: DJDeckID
    var body: some Gesture { DragGesture(minimumDistance: 0).onChanged { _ in model.cueDown(deck) }.onEnded { _ in model.cueUp(deck) } }
}

private struct DJV2TempoFader: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    var body: some View { DJV2HorizontalFader(label: "TEMPO", value: (deck.tempoPercent / max(1, deck.tempoRange) + 1) / 2, left: "−", right: "+") { model.setTempoPercent(deck.id, value: ($0 * 2 - 1) * deck.tempoRange) } }
}

private struct DJV2HorizontalFader: View {
    let label: String
    let value: Double
    let left: String
    let right: String
    let onChange: (Double) -> Void
    @State private var start: Double?
    var body: some View {
        GeometryReader { proxy in
            let handleWidth = min(proxy.size.height, proxy.size.width / 4)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15)).frame(height: 4).padding(.horizontal, handleWidth / 2)
                Rectangle().fill(Palette.brass).frame(width: max(0, (proxy.size.width - handleWidth) * value + handleWidth / 2), height: 3)
                DJV2Button(title: label, active: false, color: Palette.brass) { }.frame(width: handleWidth, height: min(proxy.size.height, handleWidth)).offset(x: (proxy.size.width - handleWidth) * value)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { change in let initial = start ?? value; start = initial; let v = initial + Double(change.translation.width / max(1, proxy.size.width - handleWidth)); onChange(DJFaderMapping.snapped(v)) }.onEnded { _ in start = nil })
                HStack { Text(left); Spacer(); Text(right) }.font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Palette.ink3).padding(.horizontal, 3).padding(.top, 2).frame(maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

private struct DJV2VerticalFader: View {
    @ObservedObject var deck: DJDeckState
    let model: DJPerformanceModel
    var body: some View {
        GeometryReader { proxy in
            let handleHeight = min(proxy.size.width, proxy.size.height / 3)
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.15)).frame(width: 4).padding(.vertical, handleHeight / 2)
                Rectangle().fill(deck.accent).frame(width: 3, height: max(0, proxy.size.height * deck.channelLevel))
                DJV2Meter(value: deck.peakMeter, hold: deck.peakHold).frame(width: 5).padding(.leading, 4).frame(maxWidth: .infinity, alignment: .leading)
                DJV2Button(title: deck.id.rawValue, second: "\(Int(deck.channelLevel * 100))", active: false, color: deck.accent) { }.frame(width: min(proxy.size.width, handleHeight), height: handleHeight).offset(y: -(proxy.size.height - handleHeight) * deck.channelLevel)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { change in let value = deck.channelLevel - Double(change.translation.height / max(1, proxy.size.height - handleHeight)); model.setChannelLevel(deck.id, value: value) })
            }
        }
    }
}

private struct DJV2Meter: View {
    let value: Double
    let hold: Double
    var body: some View { GeometryReader { proxy in VStack(spacing: 1) { ForEach((0..<16).reversed(), id: \.self) { i in Rectangle().fill(i < Int(value * 16) ? (i >= 14 ? Color.red : i >= 11 ? Color.yellow : Color.green) : (i == Int(hold * 16) ? Color.white : Color.white.opacity(0.08))) } }.frame(width: proxy.size.width) } }
}

private struct DJV2MasterMeter: View {
    @ObservedObject var model: DJPerformanceModel
    var body: some View { HStack(spacing: 4) { DJV2Meter(value: max(model.deckA.peakMeter, model.deckB.peakMeter), hold: max(model.deckA.peakHold, model.deckB.peakHold)); DJV2Meter(value: max(model.deckA.peakMeter, model.deckB.peakMeter), hold: max(model.deckA.peakHold, model.deckB.peakHold)) }.padding(4).background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8)) }
}

private struct DJV2Knob: View {
    let label: String
    let value: Double
    let valueText: String
    let color: Color
    let onChange: (Double) -> Void
    @State private var start: Double?
    var body: some View { VStack(spacing: 1) { Circle().trim(from: 0.125, to: 0.875).stroke(Color.white.opacity(0.16), lineWidth: 3).overlay(Circle().trim(from: 0.125, to: 0.125 + 0.75 * value).stroke(color, lineWidth: 3)).overlay(Rectangle().fill(Palette.ink).frame(width: 2, height: 12).offset(y: -7).rotationEffect(.degrees(-135 + 270 * value))); Text(label).font(.system(size: 8.5, weight: .bold, design: .monospaced)); Text(valueText).font(.system(size: 8, design: .monospaced)).foregroundStyle(Palette.ink2) }.foregroundStyle(Palette.ink).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.white.opacity(0.13))).gesture(DragGesture(minimumDistance: 0).onChanged { change in let initial = start ?? value; start = initial; onChange(DJKnobMapping.adjusted(initial, delta: Double(-change.translation.height + change.translation.width) / 160)) }.onEnded { _ in start = nil }).simultaneousGesture(TapGesture(count: 2).onEnded { onChange(0.5) }) }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
