//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import Combine
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import SwiftMIDIFile

// MARK: - RotarySlider (NSSlider with .circular style)

struct RotarySlider: NSViewRepresentable {
    @Binding var value: Float
    let min: Float
    let max: Float

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSlider {
        let s = NSSlider()
        s.sliderType = .circular
        s.minValue = Double(min)
        s.maxValue = Double(max)
        s.floatValue = value
        s.target = context.coordinator
        s.action = #selector(Coordinator.changed(_:))
        return s
    }

    func updateNSView(_ nsView: NSSlider, context: Context) {
        guard abs(nsView.floatValue - value) > 0.001 else { return }
        nsView.floatValue = value
    }

    class Coordinator: NSObject {
        var parent: RotarySlider
        init(_ parent: RotarySlider) { self.parent = parent }
        @objc func changed(_ sender: NSSlider) { parent.value = sender.floatValue }
    }
}

// MARK: - ParameterStore

@Observable
final class ParameterStore {
    enum ControlType { case toggle, rotary, discrete, numberInput }

    struct Spec {
        let label: String
        let controlType: ControlType
        let order: Int
        var hasRandomize: Bool = false
        // Overrides the RNBO patch's initialValue in the UI for when assign_defaults values
        // are not suitable
        var initialOverride: Float? = nil
    }

    // Whitelist: only these RNBO parameter IDs get UI controls.
    static let specs: [String: Spec] = [
        "Onset/enable":          .init(label: "Onset Enable",      controlType: .toggle,      order:  0, initialOverride: 1),
        "Onset/needs_init":      .init(label: "Onset Needs Init",  controlType: .toggle,      order:  1),
        "EnableTraining":        .init(label: "Enable Training",   controlType: .toggle,      order:  2),

        // Onset detection tuning — number inputs, positioned right of the toggle row.
        "Onset/thresh":          .init(label: "Thresh",            controlType: .numberInput, order:  3, initialOverride:  0.5),
        "Onset/relaxtime":       .init(label: "Relax",             controlType: .numberInput, order:  4, initialOverride:  0.5),
        "Onset/floor":           .init(label: "Floor",             controlType: .numberInput, order:  5, initialOverride:  0.1),
        "Onset/mingap":          .init(label: "Min Gap",           controlType: .numberInput, order:  6, initialOverride: 20.0),
        "Onset/medspan":         .init(label: "Med Span",          controlType: .numberInput, order:  7, initialOverride: 11.0),
        // Onset/odftype: reserved — dropdown (combo box) to be added in a later step.

        "OnsetInput":            .init(label: "Onset Input",       controlType: .rotary,   order:  8),
        "SpecFlatCutoff":        .init(label: "Spec Flat Cutoff",  controlType: .rotary,   order:  9),
        "SpecCentCutoff":        .init(label: "Spec Cent Cutoff",  controlType: .rotary,   order: 10),
        "Input_dB":              .init(label: "Input dB",          controlType: .rotary,   order: 11),
        "InputDelaySend_dB":     .init(label: "Input→Delay dB",   controlType: .rotary,   order: 12),
        "DrumSynthOutput_dB":    .init(label: "Drum Synth Out",    controlType: .rotary,   order: 13),
        "DrumSynthDelaySend_dB": .init(label: "Drum→Delay dB",    controlType: .rotary,   order: 14, initialOverride: -77.0),
        "DelayOutput_dB":        .init(label: "Delay Out",         controlType: .rotary,   order: 15),
        "SynthMode":             .init(label: "Synth Mode",        controlType: .discrete, order: 16),
        "GreyholeDelayFX_Controller/GreyholePreset":
                .init(label: "Greyhole Preset",  controlType: .discrete, order: 17, hasRandomize: true, initialOverride: 1),
    ]

    struct Param: Identifiable {
        let id: Int32        // RNBO parameter index — unique, used as SwiftUI id
        let rnboIndex: Int32
        let rnboId: String
        let min: Float
        let max: Float
        let defaultValue: Float
        let label: String
        let controlType: ControlType
        let sortOrder: Int
        let hasRandomize: Bool
    }

    let engine = AudioEngine()
    private(set) var params: [Param] = []
    var values: [Float] = []

    init() {
        let n = Int(engine.numParameters())
        var collected: [Param] = []
        for i in 0..<n {
            guard let dict = engine.parameterInfo(at: Int32(i)) else { continue }
            let rnboId = dict["id"] as? String ?? ""
            guard let spec = Self.specs[rnboId] else { continue }
            let min    = (dict["min"] as? NSNumber)?.floatValue ?? 0
            let max    = (dict["max"] as? NSNumber)?.floatValue ?? 1
            let defVal = (dict["default"] as? NSNumber)?.floatValue ?? 0
            collected.append(Param(
                id: Int32(i), rnboIndex: Int32(i), rnboId: rnboId,
                min: min, max: max, defaultValue: defVal,
                label: spec.label, controlType: spec.controlType, sortOrder: spec.order,
                hasRandomize: spec.hasRandomize
            ))
        }
        params = collected.sorted { $0.sortOrder < $1.sortOrder }
        // Use initialOverride where specified (host defaults that differ from the RNBO
        // patch's assign_defaults), otherwise fall back to the RNBO initial value.
        values = params.map { param in
            Self.specs[param.rnboId]?.initialOverride ?? param.defaultValue
        }
        // RNBO initialises parameters at construction time via ParameterBangEvents.
        // We do NOT call setParameter here — pushAllValuesToEngine() is called by the
        // Swift layer at engine start and before each offline render instead.

        // Listen for parameter writes the RNBO patch makes internally (e.g.
        // SpecFlatCutoff / SpecCentCutoff after EnableTraining runs). The
        // ObjC++ layer filters out self-writes via source-id and only invokes
        // this block for genuine patch-driven changes, on the main thread.
        engine.parameterChangeHandler = { [weak self] index, value in
            guard let self else { return }
            guard let i = self.params.firstIndex(where: { $0.rnboIndex == Int32(index) })
            else { return }
            self.updateValueFromEngine(at: i, value: value)
        }
    }

    func set(value: Float, at i: Int) {
        values[i] = value
        engine.setParameter(index: params[i].rnboIndex, value: value)
    }

    // Mirrors a patch-internal parameter write into the UI state. Does NOT call
    // engine.setParameter — the value is already live in RNBO; pushing it back
    // would just bounce the same event through the source filter again.
    func updateValueFromEngine(at i: Int, value: Float) {
        guard i >= 0, i < values.count else { return }
        values[i] = value
    }

    // Queues the current UI state for all parameters into RNBO's parameter interface.
    // Call after engine.start() and before each offline render so the current UI values
    // survive RNBO's startup ParameterBangEvents (which fire in the first process block
    // and would otherwise re-assert the patch's assign_defaults values).
    func pushAllValuesToEngine() {
        for (i, param) in params.enumerated() {
            engine.setParameter(index: param.rnboIndex, value: values[i])
        }
    }
}

// MARK: - NumberInputCell

/// A compact text field + label for numeric RNBO parameter entry.
/// Commits the value on Return or focus loss; reverts to the last valid value
/// on invalid input; clamps to param.min…param.max.
struct NumberInputCell: View {
    let param: ParameterStore.Param
    let value: Float
    let onCommit: (Float) -> Void

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 3) {
            TextField("", text: $editText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 62)
                .multilineTextAlignment(.center)
                .focused($isFocused)
                .onAppear { editText = formatted(value) }
                .onChange(of: value) { _, new in
                    if !isFocused { editText = formatted(new) }
                }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
                .onSubmit { commit() }
            Text(param.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 62)
                .multilineTextAlignment(.center)
        }
    }

    private func formatted(_ v: Float) -> String {
        let range = param.max - param.min
        if range > 10 { return String(format: "%.0f", v) }
        if range > 1  { return String(format: "%.2f", v) }
        return String(format: "%.3f", v)
    }

    private func commit() {
        guard let parsed = Float(editText) else {
            editText = formatted(value)
            return
        }
        let clamped = max(param.min, min(param.max, parsed))
        editText = formatted(clamped)
        onCommit(clamped)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var store = ParameterStore()
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var isMIDIAnalyzing = false
    @State private var showFilePicker = false
    @State private var loadedFileName: String?
    @State private var waveformThumbnail: WaveformThumbnail? = nil
    @State private var midiNoteOverlay: [MIDINoteEvent] = []
    // nil = no analysis run yet for the currently loaded file.
    @State private var lastAnalyzedOnsetParams: [String: Float]? = nil
    // Snapshot of onset tuning params in effect when midiNoteOverlay was last populated,
    // whether by offline analysis or real-time capture. Drives stale marking independently
    // of lastAnalyzedOnsetParams so that real-time notes also grey out on param changes.
    @State private var lastOverlayOnsetParams: [String: Float]? = nil
    // Tracks note-on events from real-time playback that are awaiting their matching note-off.
    @State private var openRealTimeNoteOns: [UInt8: (onsetMs: Double, velocity: UInt8)] = [:]
    // Accumulated real-time playback duration (ms) since the last reset event (param change,
    // seek, or file import). When this reaches totalDurationMs, the full file has been
    // processed in real-time with the current params and "Analyze Onsets" can be disabled.
    @State private var realTimeCoverageMs: Double = 0

    private var engine: AudioEngine { store.engine }
    private var fileLoaded: Bool { loadedFileName != nil }

    // The five onset tuning parameters whose changes make the overlay stale.
    // Onset/enable and Onset/needs_init are excluded: toggling them doesn't alter
    // detection sensitivity or timing.
    private static let onsetTuningParamIds: Set<String> = [
        "Onset/thresh", "Onset/relaxtime", "Onset/floor", "Onset/mingap", "Onset/medspan"
    ]

    // Half-width of the time window (in ms) used to match a fresh real-time note
    // against an existing overlay note of the same pitch during loop overlap-replacement.
    // Kept tight because RNBO DSP is deterministic — the same onset recurs at nearly
    // the same timestamp on every loop; the window only needs to absorb float rounding.
    private static let realtimeNoteReplaceWindowMs: Double = 5.0

    private var totalDurationMs: Double {
        guard engine.sampleRate > 0 else { return 0 }
        return Double(engine.totalFrameCount) / engine.sampleRate * 1000.0
    }

    // True when onset tuning parameters differ from the last analysis snapshot, or no analysis
    // has been run yet for the current file. Drives the "Analyze Onsets" button enabled state.
    private var onsetParamsDirty: Bool {
        guard let last = lastAnalyzedOnsetParams else { return true }
        return paramsChanged(from: last)
    }

    // True when onset tuning parameters differ from the params in effect when the overlay
    // was last populated (by either offline analysis or real-time capture). Drives stale
    // marking. Separate from onsetParamsDirty so that real-time-only overlay notes also
    // trigger the false→true transition that .onChange(of:) requires.
    private var overlayParamsDirty: Bool {
        guard let last = lastOverlayOnsetParams else { return false }
        return paramsChanged(from: last)
    }

    // True when the full file has been processed in real-time with the current onset params,
    // making an explicit "Analyze Onsets" pass redundant. Resets on param change, seek, or import.
    private var fullRealTimeCoverageAchieved: Bool {
        totalDurationMs > 0 && realTimeCoverageMs >= totalDurationMs && !midiNoteOverlay.isEmpty
    }

    private func paramsChanged(from snapshot: [String: Float]) -> Bool {
        for (i, param) in store.params.enumerated()
            where Self.onsetTuningParamIds.contains(param.rnboId)
        {
            if abs((snapshot[param.rnboId] ?? Float.nan) - store.values[i]) > 0.0001 { return true }
        }
        return false
    }

    private func currentOnsetParamSnapshot() -> [String: Float] {
        var snapshot: [String: Float] = [:]
        for (i, param) in store.params.enumerated()
            where Self.onsetTuningParamIds.contains(param.rnboId)
        {
            snapshot[param.rnboId] = store.values[i]
        }
        return snapshot
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .center) {
                Text("PercTranscriber")
                    .font(.title2)
                if let name = loadedFileName {
                    HStack {
                        Text(name)
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .leading)
                        Spacer()
                    }
                }
            }
            .padding([.top, .leading, .trailing])
            .padding(.bottom, 5)

            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                WaveformView(
                    thumbnail: waveformThumbnail,
                    playheadFraction: engine.playheadFraction,
                    onSeek: { fraction in
                        engine.setPlayheadPosition(
                            Int64(fraction * Double(engine.totalFrameCount))
                        )
                        // Re-anchor the real-time timestamp offset to the new position and
                        // discard open note-ons. Only reset coverage if the full file hasn't
                        // already been covered — seeking after full coverage is just navigation.
                        engine.beginRealTimeCapture()
                        openRealTimeNoteOns.removeAll()
                        if !fullRealTimeCoverageAchieved { realTimeCoverageMs = 0 }
                    },
                    midiNotes: midiNoteOverlay,
                    totalDurationMs: totalDurationMs
                )
            }
            .frame(height: 150)

            transportControls.padding()

            if !store.params.isEmpty {
                Divider()
                parametersPanel
            }
        }
        .onReceive(Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()) { _ in
            guard isPlaying else { return }
            realTimeCoverageMs += 1000.0 / 15.0
            pollRealTimeMidiEvents()
        }
        .onChange(of: overlayParamsDirty) { _, isDirty in
            if isDirty && !midiNoteOverlay.isEmpty {
                midiNoteOverlay = midiNoteOverlay.map {
                    MIDINoteEvent(note: $0.note, velocity: $0.velocity,
                                  onsetMs: $0.onsetMs, durationMs: $0.durationMs, isStale: true)
                }
            }
            if isDirty { realTimeCoverageMs = 0 }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            engine.loadAudioFile(from: url)
            if accessed { url.stopAccessingSecurityScopedResource() }
            loadedFileName = url.lastPathComponent
            let eng = engine
            DispatchQueue.global(qos: .userInitiated).async {
                guard let data = eng.waveformThumbnailData(binCount: 2048) else { return }
                let thumb = WaveformThumbnail(data: data)
                DispatchQueue.main.async { waveformThumbnail = thumb }
            }
            // Reset overlay, all snapshots, and coverage so the button enables and stale notes don't linger.
            midiNoteOverlay = []
            lastAnalyzedOnsetParams = nil
            lastOverlayOnsetParams = nil
            openRealTimeNoteOns.removeAll()
            realTimeCoverageMs = 0
        }
    }

    // MARK: Transport

    private var transportControls: some View {
        ZStack {
            HStack {
                Button("Import Audio") { showFilePicker = true }
                    .buttonStyle(.bordered)
                Spacer()
                HStack(spacing: 8) {
                    Button("Export Audio") { exportAudioOffline() }
                        .buttonStyle(.bordered)
                    Button("Export MIDI") { exportMIDIOffline() }
                        .buttonStyle(.bordered)
                    Button("Analyze Onsets") { analyzeMIDI() }
                        .buttonStyle(.bordered)
                        .disabled(!fileLoaded || isPlaying || isExporting || isMIDIAnalyzing || !onsetParamsDirty || fullRealTimeCoverageAchieved)
                }
                .disabled(!fileLoaded || isExporting || isMIDIAnalyzing)
                .overlay {
                    if isExporting || isMIDIAnalyzing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(isExporting ? "Exporting…" : "Analyzing…").font(.caption)
                        }
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            HStack(spacing: 8) {
                Button { engine.rewindToStart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!fileLoaded)

                Button {
                    if isPlaying {
                        engine.stop()
                        flushOpenRealTimeNotes()
                    } else {
                        engine.beginRealTimeCapture()
                        engine.start()
                        store.pushAllValuesToEngine()
                    }
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(isPlaying ? .red : .accentColor)
                .disabled(!fileLoaded)
            }
        }
    }

    // MARK: Real-Time MIDI Overlay

    // Inserts a fresh real-time note into midiNoteOverlay, removing any existing note of
    // the same pitch within the replacement window (handles re-detection on loop iterations).
    private func mergeRealTimeNote(_ note: MIDINoteEvent) {
        let window = Self.realtimeNoteReplaceWindowMs
        midiNoteOverlay.removeAll { existing in
            existing.note == note.note && abs(existing.onsetMs - note.onsetMs) <= window
        }
        midiNoteOverlay.append(note)
    }

    // Drains newly accumulated real-time MIDI events and merges completed notes into the overlay.
    private func pollRealTimeMidiEvents() {
        let rawEvents = engine.collectAndClearRealTimeMidiEvents() ?? []
        var addedAnyNote = false
        for dict in rawEvents {
            guard
                let ms     = dict["timestampMs"] as? Double,
                let bytes  = dict["bytes"] as? Data,
                bytes.count >= 3
            else { continue }
            let statusNibble = bytes[0] >> 4
            let note     = bytes[1]
            let velocity = bytes[2]
            if statusNibble == 0x9 && velocity > 0 {
                openRealTimeNoteOns[note] = (onsetMs: ms, velocity: velocity)
            } else if statusNibble == 0x8 || (statusNibble == 0x9 && velocity == 0) {
                if let entry = openRealTimeNoteOns[note] {
                    mergeRealTimeNote(MIDINoteEvent(
                        note: note, velocity: entry.velocity,
                        onsetMs: entry.onsetMs, durationMs: ms - entry.onsetMs,
                        isStale: false
                    ))
                    openRealTimeNoteOns.removeValue(forKey: note)
                    addedAnyNote = true
                }
            }
        }
        // Update the overlay snapshot so overlayParamsDirty can transition false→true
        // if the user later changes onset params — enabling stale marking for real-time notes.
        if addedAnyNote {
            lastOverlayOnsetParams = currentOnsetParamSnapshot()
        }
    }

    // Closes all pending real-time note-ons with a fallback duration and merges them
    // into the overlay. Called when the transport stops to avoid losing the last note(s).
    private func flushOpenRealTimeNotes() {
        var flushedAny = false
        for (note, entry) in openRealTimeNoteOns {
            mergeRealTimeNote(MIDINoteEvent(
                note: note, velocity: entry.velocity,
                onsetMs: entry.onsetMs, durationMs: 50,
                isStale: false
            ))
            flushedAny = true
        }
        openRealTimeNoteOns.removeAll()
        if flushedAny {
            lastOverlayOnsetParams = currentOnsetParamSnapshot()
        }
    }

    // MARK: Offline Export

    // Pairs raw RNBO MIDI event dicts into MIDINoteEvent on/off matches.
    private func pairMIDIEvents(_ rawEvents: [[String: Any]]) -> [MIDINoteEvent] {
        let sorted = rawEvents.sorted {
            (($0["timestampMs"] as? Double) ?? 0) < (($1["timestampMs"] as? Double) ?? 0)
        }
        var open: [UInt8: (onsetMs: Double, velocity: UInt8)] = [:]
        var result: [MIDINoteEvent] = []
        for dict in sorted {
            guard
                let ms = dict["timestampMs"] as? Double,
                let bytes = dict["bytes"] as? Data,
                bytes.count >= 3
            else { continue }
            let statusNibble = bytes[0] >> 4
            let note = bytes[1]
            let velocity = bytes[2]
            if statusNibble == 0x9 && velocity > 0 {
                open[note] = (onsetMs: ms, velocity: velocity)
            } else if statusNibble == 0x8 || (statusNibble == 0x9 && velocity == 0) {
                if let entry = open[note] {
                    result.append(MIDINoteEvent(
                        note: note, velocity: entry.velocity,
                        onsetMs: entry.onsetMs, durationMs: ms - entry.onsetMs
                    ))
                    open.removeValue(forKey: note)
                }
            }
        }
        // Flush any unclosed note-ons with a fallback duration.
        for (note, entry) in open {
            result.append(MIDINoteEvent(
                note: note, velocity: entry.velocity,
                onsetMs: entry.onsetMs, durationMs: 50
            ))
        }
        return result.sorted { $0.onsetMs < $1.onsetMs }
    }

    private func analyzeMIDI() {
        guard !isPlaying, engine.totalFrameCount > 0, !isMIDIAnalyzing else { return }
        if let i = store.params.firstIndex(where: { $0.rnboId == "Onset/enable" }),
           store.values[i] < 0.5 {
            store.set(value: 1, at: i)
        }
        let snapshot = currentOnsetParamSnapshot()
        isMIDIAnalyzing = true
        // Render block calls _coreObject.process() continuously even when transport is
        // stopped (feeding silence). stopForOfflineRender halts it so the offline loop
        // has exclusive CoreObject access, and so queued parameter values survive intact
        // for the offline pre-warm block (pushAllValuesToEngine must follow, not precede).
        engine.stopForOfflineRender()
        store.pushAllValuesToEngine()
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            engine.renderOfflineMIDI()
            let rawEvents = engine.collectAndClearMidiEvents() ?? []
            let notes = self.pairMIDIEvents(rawEvents)
            DispatchQueue.main.async {
                // resumeAfterOfflineRender calls prepareToProcess(reset=true), resetting
                // RNBO parameters; re-push UI values immediately to restore DSP state.
                engine.resumeAfterOfflineRender()
                self.store.pushAllValuesToEngine()
                self.midiNoteOverlay = notes
                self.lastAnalyzedOnsetParams = snapshot
                self.lastOverlayOnsetParams = snapshot
                self.isMIDIAnalyzing = false
            }
        }
    }

    private func stopTransportIfNeeded() -> Bool {
        guard isPlaying else { return false }
        engine.stop()
        flushOpenRealTimeNotes()
        isPlaying = false
        return true
    }

    private func exportAudioOffline() {
        let wasPlaying = stopTransportIfNeeded()
        // Stop hardware IO before pushing parameters — ensures no render blocks
        // consume the queued values before the offline pre-warm block processes them.
        engine.stopForOfflineRender()
        store.pushAllValuesToEngine()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wav")!]
        panel.nameFieldStringValue = "Export.wav"
        panel.title = "Export Processed Audio"
        guard panel.runModal() == .OK, let url = panel.url else {
            engine.resumeAfterOfflineRender()
            store.pushAllValuesToEngine()
            if wasPlaying { engine.start(); isPlaying = true }
            return
        }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            do {
                try engine.renderOfflineAudio(to: url)
            } catch {
                NSLog("[ContentView] audio export error: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                engine.resumeAfterOfflineRender()
                self.store.pushAllValuesToEngine()
                self.isExporting = false
            }
        }
    }

    private func exportMIDIOffline() {
        // Onset detection must be active for the offline loop to emit MIDI events.
        // Force-enable it if the user left the toggle off.
        if let i = store.params.firstIndex(where: { $0.rnboId == "Onset/enable" }),
           store.values[i] < 0.5 {
            store.set(value: 1, at: i)
        }

        let wasPlaying = stopTransportIfNeeded()
        // Stop hardware IO before pushing parameters — ensures no render blocks
        // consume the queued values before the offline pre-warm block processes them.
        engine.stopForOfflineRender()
        store.pushAllValuesToEngine()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid")!]
        panel.nameFieldStringValue = "Export.mid"
        panel.title = "Export MIDI"
        guard panel.runModal() == .OK, let url = panel.url else {
            engine.resumeAfterOfflineRender()
            store.pushAllValuesToEngine()
            if wasPlaying { engine.start(); isPlaying = true }
            return
        }

        // Snapshot onset tuning params used for this render so the overlay
        // and staleness check reflect exactly what was rendered.
        let snapshot = currentOnsetParamSnapshot()

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            engine.renderOfflineMIDI()
            let rawEvents = engine.collectAndClearMidiEvents() ?? []
            let notes = self.pairMIDIEvents(rawEvents)

            do {
                let data = try buildMIDIFile(from: rawEvents)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[ContentView] MIDI export error: %@", error.localizedDescription)
            }
            DispatchQueue.main.async {
                engine.resumeAfterOfflineRender()
                self.store.pushAllValuesToEngine()
                self.midiNoteOverlay = notes
                self.lastAnalyzedOnsetParams = snapshot
                self.lastOverlayOnsetParams = snapshot
                self.isExporting = false
            }
        }
    }

    // Converts the raw RNBO MIDI event dictionaries into a Standard MIDI File (Format 0).
    //
    // Timebase: 480 PPQ at 120 BPM → 1 tick ≈ 1.042 ms.
    // Tick conversion: ticks = round(timestampMs × 480 × 120 / 60_000) = round(ms × 0.96).
    //
    // RNBO emits fully-formed Note On (0x9x) and Note Off (0x8x) messages; both are passed
    // through as-is. Zero-velocity Note On (treated as Note Off per MIDI spec) is also handled.
    private func buildMIDIFile(from rawEvents: [[String: Any]]) throws -> Data {
        let bpm: Double = 120.0
        let ppq: UInt16 = 480
        let ticksPerMs = Double(ppq) * bpm / 60_000.0  // 0.96

        // Sort events by timestamp before computing deltas.
        let sorted = rawEvents.sorted {
            let t0 = ($0["timestampMs"] as? Double) ?? 0.0
            let t1 = ($1["timestampMs"] as? Double) ?? 0.0
            return t0 < t1
        }

        var trackEvents: [MusicalMIDI1File.Track.Event] = []

        // Tempo event at the start of the track.
        trackEvents.append(.tempo(delta: .none, bpm: bpm))

        var prevAbsTick: UInt32 = 0

        for dict in sorted {
            guard
                let timestampMs = dict["timestampMs"] as? Double,
                let bytes = dict["bytes"] as? Data,
                bytes.count >= 1
            else { continue }

            let absTick = UInt32(max(0.0, (timestampMs * ticksPerMs).rounded()))
            let deltaTick = absTick >= prevAbsTick ? absTick - prevAbsTick : 0
            prevAbsTick = absTick

            let status = bytes[0]
            let statusNibble = status >> 4
            let channel = status & 0x0F

            guard
                bytes.count >= 3,
                let note = UInt7(exactly: bytes[1]),
                let velocity = UInt7(exactly: bytes[2]),
                let ch = UInt4(exactly: channel)
            else { continue }

            switch statusNibble {
            case 0x9 where velocity > 0:
                trackEvents.append(.noteOn(
                    delta: .ticks(deltaTick),
                    note: note,
                    velocity: .midi1(velocity),
                    channel: ch
                ))
            case 0x8, 0x9: // Note Off, or Note On with velocity 0
                trackEvents.append(.noteOff(
                    delta: .ticks(deltaTick),
                    note: note,
                    velocity: .midi1(velocity),
                    channel: ch
                ))
            default:
                break
            }
        }

        let track = MusicalMIDI1File.Track(events: trackEvents)
        let midiFile = MusicalMIDI1File(
            format: .singleTrack,
            timebase: .musical(ticksPerQuarterNote: ppq),
            tracks: [track]
        )
        return try midiFile.rawData()
    }

    // MARK: Parameters

    // Returns (storeArrayIndex, Param) pairs filtered to a given control type.
    private func indexedParams(ofType type: ParameterStore.ControlType) -> [(Int, ParameterStore.Param)] {
        store.params.enumerated().compactMap { offset, param in
            param.controlType == type ? (offset, param) : nil
        }
    }

    private var parametersPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Parameters").font(.headline)

                // Toggles + Onset number inputs — single row.
                // Number inputs sit immediately right of the toggle buttons, separated
                // by a divider. Space at the trailing edge is reserved for the future
                // Onset/odftype combo box (to be added in a later step).
                let toggles = indexedParams(ofType: .toggle)
                let numberInputs = indexedParams(ofType: .numberInput)
                if !toggles.isEmpty || !numberInputs.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(toggles, id: \.0) { i, param in
                            toggleButton(i: i, param: param)
                        }
                        if !numberInputs.isEmpty {
                            Divider().frame(height: 40)
                            ForEach(numberInputs, id: \.0) { i, param in
                                NumberInputCell(
                                    param: param,
                                    value: store.values[i]
                                ) { newVal in
                                    store.set(value: newVal, at: i)
                                }
                            }
                        }
                        Spacer()
                    }
                }

                // Rotary sliders — 4-column grid
                let rotaries = indexedParams(ofType: .rotary)
                if !rotaries.isEmpty {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4),
                        spacing: 16
                    ) {
                        ForEach(rotaries, id: \.0) { i, param in
                            rotaryCell(i: i, param: param)
                        }
                    }
                }

                // Discrete slider (GreyholePreset)
                ForEach(indexedParams(ofType: .discrete), id: \.0) { i, param in
                    discreteRow(i: i, param: param)
                }
            }
            .padding()
        }
    }

    // MARK: Control views

    @ViewBuilder
    private func toggleButton(i: Int, param: ParameterStore.Param) -> some View {
        let isOn = store.values[i] >= 0.5
        Button {
            store.set(value: isOn ? 0 : 1, at: i)
        } label: {
            Label(param.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : nil)
    }

    @ViewBuilder
    private func rotaryCell(i: Int, param: ParameterStore.Param) -> some View {
        let binding = Binding<Float>(
            get: { store.values[i] },
            set: { store.set(value: $0, at: i) }
        )
        VStack(spacing: 4) {
            RotarySlider(value: binding, min: param.min, max: param.max)
                .frame(width: 52, height: 52)
            Text(param.label)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(formattedValue(store.values[i], param: param))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func discreteRow(i: Int, param: ParameterStore.Param) -> some View {
        let binding = Binding<Float>(
            get: { store.values[i] },
            set: { store.set(value: $0, at: i) }
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.label)
                Spacer()
                Text(formattedValue(store.values[i], param: param))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
            Slider(value: binding, in: param.min...param.max, step: 1)
            if param.hasRandomize {
                Button("Randomize") {
                    engine.setParameter(index: param.rnboIndex, value: 9)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func formattedValue(_ v: Float, param: ParameterStore.Param) -> String {
        if param.controlType == .discrete { return String(format: "%.0f", v) }
        let range = param.max - param.min
        if range > 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

#Preview {
    ContentView()
}
