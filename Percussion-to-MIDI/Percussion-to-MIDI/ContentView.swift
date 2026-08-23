//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers
import SwiftMIDIFile

// MARK: - RotarySlider

struct RotarySlider: View {
    @Binding var value: Float
    let min: Float
    let max: Float
    var resetValue: Float? = nil

    // 270° clockwise sweep from ~7:30 (min) to ~4:30 (max).
    // SwiftUI arc angles: 0° = 3 o'clock, positive = clockwise on screen.
    private static let startDeg: Double = 135
    private static let sweepDeg: Double = 270
    // Pixels of vertical drag to traverse the full min→max range.
    private static let sensitivity: CGFloat = 150

    @State private var dragStartValue: Float? = nil

    private var normalized: Double {
        guard max > min else { return 0 }
        let t = Double((value - min) / (max - min))
        return t < 0 ? 0 : t > 1 ? 1 : t
    }

    private func angleDeg(for t: Double) -> Double {
        Self.startDeg + t * Self.sweepDeg
    }

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = Swift.min(size.width, size.height) / 2 - 3
            let arcWidth: CGFloat = 3.5
            let t = normalized

            // Background arc (full 270° sweep)
            var bg = Path()
            bg.addArc(center: center, radius: radius,
                      startAngle: .degrees(Self.startDeg),
                      endAngle: .degrees(Self.startDeg + Self.sweepDeg),
                      clockwise: false)
            ctx.stroke(bg, with: .color(.gray.opacity(0.3)), lineWidth: arcWidth)

            // Value arc (accent color, min to current)
            if t > 0 {
                var fill = Path()
                fill.addArc(center: center, radius: radius,
                            startAngle: .degrees(Self.startDeg),
                            endAngle: .degrees(angleDeg(for: t)),
                            clockwise: false)
                ctx.stroke(fill, with: .color(.accentColor), lineWidth: arcWidth)
            }

            // Tick indicator
            let rad = angleDeg(for: t) * .pi / 180
            let cosA = CGFloat(cos(rad))
            let sinA = CGFloat(sin(rad))
            var tick = Path()
            tick.move(to: CGPoint(x: center.x + cosA * radius * 0.38,
                                  y: center.y + sinA * radius * 0.38))
            tick.addLine(to: CGPoint(x: center.x + cosA * radius * 0.80,
                                     y: center.y + sinA * radius * 0.80))
            ctx.stroke(tick, with: .color(.white.opacity(0.9)), lineWidth: 2)
        }
        .gesture(dragGesture)
        .onTapGesture(count: 2) {
            if let reset = resetValue { value = reset }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { drag in
                if dragStartValue == nil { dragStartValue = value }
                let base = dragStartValue ?? value
                #if os(macOS)
                let fine = NSEvent.modifierFlags.contains(.shift)
                #else
                let fine = false
                #endif
                let s = fine ? Self.sensitivity * 10 : Self.sensitivity
                let delta = Float(-drag.translation.height / s) * (max - min)
                let raw = base + delta
                value = raw < min ? min : raw > max ? max : raw
            }
            .onEnded { _ in dragStartValue = nil }
    }
}

// MARK: - ParameterStore

// MARK: - Spectral histogram model

/// Which spectral feature a captured value / histogram belongs to. Raw values match
/// the ObjC bridge's `SpectralFeature` (returned by `collectAndClearSpectralEvents`).
enum SpectralFeature: Int {
    case centroid = 0   // top row, green
    case flatness = 1   // bottom row, purple
}

/// One measured spectral value in a feature's rolling display buffer (newest-first).
/// `agedOutAt` (seconds, `timeIntervalSinceReferenceDate`) is nil while the sample is
/// within the N-newest rank-based opacity ramp; it is stamped once when the sample
/// first ages out (crosses to rank N), after which its opacity fades to 0 over
/// `SpectralDisplayConfig.specDisplayFadeout` seconds. No arrival timestamp is kept.
struct SpectralSample {
    let value: Float
    var agedOutAt: TimeInterval? = nil
}

@Observable
final class ParameterStore {
    enum ControlType { case toggle, rotary, discrete, numberInput, spectralSlider }

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

        // Onset detection tuning — number inputs, in the main toolbar right of the onset toggle buttons.
        "Onset/thresh":          .init(label: "Thresh",            controlType: .numberInput, order:  3, initialOverride:  0.5),
        "Onset/relaxtime":       .init(label: "Relax",             controlType: .numberInput, order:  4, initialOverride:  0.5),
        "Onset/floor":           .init(label: "Floor",             controlType: .numberInput, order:  5, initialOverride:  0.1),
        "Onset/mingap":          .init(label: "Min Gap",           controlType: .numberInput, order:  6, initialOverride: 20.0),
        "Onset/medspan":         .init(label: "Med Span",          controlType: .numberInput, order:  7, initialOverride: 11.0),
        // Onset/odftype: reserved — dropdown (combo box) to be added in a later step.

        "OnsetInput":            .init(label: "Onset Input",       controlType: .rotary,   order:  8),
        // Rendered as horizontal sliders with a spectral histogram (SpectralSlidersView),
        // not rotary knobs — .spectralSlider drops them out of the rotary grid.
        "SpecFlatCutoff":        .init(label: "Spec Flat Cutoff",  controlType: .spectralSlider, order:  9),
        "SpecCentCutoff":        .init(label: "Spec Cent Cutoff",  controlType: .spectralSlider, order: 10),
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

    // MARK: Spectral histogram

    // Rolling display buffers (newest-first FIFOs) of recently-measured spectral values,
    // and their dynamic display-axis maxima (high-water marks). Populated by
    // pollSpectralEvents() during live playback; drive the HorizontalSliderView histograms.
    var centroidSamples: [SpectralSample] = []
    var flatnessSamples: [SpectralSample] = []
    var centroidAxisMax: Float = SpectralDisplayConfig.centroid.defaultAxisMax
    var flatnessAxisMax: Float = SpectralDisplayConfig.flatness.defaultAxisMax

    // Drains spectral outport messages captured during playback and folds them into the
    // display buffers. The PULL counterpart to ContentView.pollRealTimeMidiEvents(); run
    // on the same playback-gated 15 fps timer (new samples only arrive during playback).
    func pollSpectralEvents() {
        let events = engine.collectAndClearSpectralEvents() ?? []
        for dict in events {
            guard
                let f = dict["feature"] as? Int,
                let feature = SpectralFeature(rawValue: f),
                let v = dict["value"] as? Double
            else { continue }
            recordSpectral(feature: feature, value: Float(v))
        }
    }

    // Records one measured value: pushes it newest-first, stamps the sample that just aged
    // out of the rank ramp, expands the display axis if the value exceeds it, and prunes
    // fully-faded samples. Main thread only.
    func recordSpectral(feature: SpectralFeature, value: Float) {
        let now = Date().timeIntervalSinceReferenceDate
        let cfg = SpectralDisplayConfig.feature(feature)
        switch feature {
        case .centroid:
            centroidSamples.insert(SpectralSample(value: value), at: 0)
            Self.stampAndPrune(&centroidSamples, now: now)
            if value > centroidAxisMax { centroidAxisMax = value + cfg.expansionOffset }
        case .flatness:
            flatnessSamples.insert(SpectralSample(value: value), at: 0)
            Self.stampAndPrune(&flatnessSamples, now: now)
            if value > flatnessAxisMax { flatnessAxisMax = value + cfg.expansionOffset }
        }
    }

    // Clears both histograms and resets the display axes to their defaults. Called on new
    // file import (alongside the MIDI overlay reset).
    func clearSpectral() {
        centroidSamples.removeAll()
        flatnessSamples.removeAll()
        centroidAxisMax = SpectralDisplayConfig.centroid.defaultAxisMax
        flatnessAxisMax = SpectralDisplayConfig.flatness.defaultAxisMax
    }

    // A newly-inserted sample bumps every existing sample's rank by one; the sample now at
    // index N (newest-first) just crossed out of the rank ramp, so stamp its aged-out time
    // once. Then drop any sample whose fade has fully elapsed.
    private static func stampAndPrune(_ samples: inout [SpectralSample], now: TimeInterval) {
        let n = SpectralDisplayConfig.numberSpecDisplayValues
        if samples.count > n, samples[n].agedOutAt == nil {
            samples[n].agedOutAt = now
        }
        let fade = SpectralDisplayConfig.specDisplayFadeout
        samples.removeAll { sample in
            guard let t = sample.agedOutAt else { return false }
            return now - t >= fade
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
                .onSubmit { isFocused = false }
            Text(param.label)
                .font(.parameterLabel)
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

// MARK: - InputValueField

struct InputValueField: View {
    let value: Float
    let min: Float
    let max: Float
    let format: (Float) -> String
    let onCommit: (Float) -> Void

    @State private var editText = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $editText)
            .textFieldStyle(.plain)
            .font(.parameterValueLabel)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(width: 52)
            .focused($isFocused)
            .onAppear { editText = format(value) }
            .onChange(of: value) { _, new in
                if !isFocused { editText = format(new) }
            }
            .onChange(of: isFocused) { _, focused in
                if !focused { commit() }
            }
            .onSubmit { isFocused = false }
    }

    private func commit() {
        guard let parsed = Float(editText) else {
            editText = format(value)
            return
        }
        let clamped = parsed < min ? min : parsed > max ? max : parsed
        editText = format(clamped)
        onCommit(clamped)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var store = ParameterStore()
    @State private var isPlaying = false
    @State private var isRecording = false
    @State private var showMicDeniedAlert = false
    @State private var isExporting = false
    @State private var isMIDIAnalyzing = false
    @State private var showFilePicker = false
    @State private var loadedFileName: String?   // header display only; nil for recordings
    @State private var audioLoaded = false       // whether PCM is loaded (drives transport enablement)
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
    // processed in real-time with the current params and "Analyze" can be disabled.
    @State private var realTimeCoverageMs: Double = 0

    private var engine: AudioEngine { store.engine }
    private var fileLoaded: Bool { audioLoaded }

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
    // has been run yet for the current file. Drives the "Analyze" button enabled state.
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
    // making an explicit "Analyze" pass redundant. Resets on param change, seek, or import.
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
                Text("Percussion-to-MIDI")
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
                let recElapsed = isRecording ? engine.recordingElapsedMs : 0
                let recThumb: WaveformThumbnail? = isRecording
                    ? engine.recordingWaveformBins.flatMap { WaveformThumbnail(data: $0) }
                    : nil
                WaveformView(
                    thumbnail: waveformThumbnail,
                    playheadFraction: engine.playheadFraction,
                    onSeek: { fraction in
                        // No seeking while recording — the playhead tracks elapsed time.
                        guard !isRecording else { return }
                        engine.setPlayheadPosition(
                            Int64(fraction * Double(engine.totalFrameCount))
                        )
                        // Start a fresh real-time capture timeline at the new position:
                        // beginRealTimeCapture() clears the ring; setPlayheadPosition() (above)
                        // also arms the post-seek MIDI settling window. Discard open note-ons;
                        // reset coverage only if the full file hasn't already been covered
                        // (seeking after full coverage is just navigation).
                        engine.beginRealTimeCapture()
                        openRealTimeNoteOns.removeAll()
                        if !fullRealTimeCoverageAchieved { realTimeCoverageMs = 0 }
                    },
                    midiNotes: midiNoteOverlay,
                    totalDurationMs: totalDurationMs,
                    midiLatencyCompensationMs: engine.processingLatencyMs,
                    isRecording: isRecording,
                    recordingThumbnail: recThumb,
                    recordingPlayheadFraction: recElapsed.truncatingRemainder(dividingBy: 60_000) / 60_000
                )
            }
            .frame(height: 150)

            mainToolbar.padding()

            // SpecCentCutoff / SpecFlatCutoff horizontal sliders with live spectral
            // histograms. Renders only when both cutoff params exist in the patch.
            SpectralSlidersView(store: store)

            if !store.params.isEmpty {
                Divider()
                parametersPanel
            }
        }
        // Window sizing (points, not pixels — a 2× Retina display renders these at 2252×982):
        // fixed 490 height (min == max), and a 1126 floor on width that can grow but not shrink.
        // Paired with .windowResizability(.contentSize) on the WindowGroup in Percussion_to_MIDIApp.
        .frame(minWidth: 1126, idealWidth: 1126, maxWidth: 2252,
               minHeight: 490, maxHeight: 490)
        .onReceive(Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()) { _ in
            guard isPlaying else { return }
            realTimeCoverageMs += 1000.0 / 15.0
            pollRealTimeMidiEvents()
            // Drain spectral outport messages into the histogram buffers. Pull (not push)
            // and playback-gated, next to the MIDI pull. The spectral fade redraw runs
            // separately on SpectralSlidersView's always-on TimelineView.
            store.pollSpectralEvents()
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
            loadFile(url: url, securityScoped: true, displayName: url.lastPathComponent)
        }
        .alert("Microphone Access Needed", isPresented: $showMicDeniedAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Enable microphone access for PercTranscriber in System Settings → "
                 + "Privacy & Security → Microphone to record live input.")
        }
        .onAppear {
            // If an audio-device change forces the engine to finalize a recording
            // mid-take, leave recording mode and load whatever was captured.
            engine.recordingInterruptedHandler = { url in finishRecording(url) }
        }
        #if os(macOS)
        // Clear the window's first responder so no text field is auto-focused on launch.
        .background(InitialFocusClearer())
        #endif
    }

    // MARK: Transport

    private var mainToolbar: some View {
        HStack(spacing: 12) {
            // Onset section: label + toggles + Analyze + tuning number boxes.
            // (Grouped in a nested HStack to stay within ViewBuilder's subview limit;
            // spacing matches the outer stack so the layout reads as one flat row.)
            HStack(spacing: 12) {
                Text("ONSET\nDETECTOR")
                    .font(.system(size: 13, weight: .bold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize()

                if let (i, _) = indexed("Onset/enable") {
                    iconToggle(i: i, systemImage: "power")
                }
                if let (i, _) = indexed("Onset/needs_init") {
                    iconToggle(i: i, systemImage: "x.circle.fill")
                }
                if let (i, _) = indexed("EnableTraining") {
                    textToggle(i: i, title: "Train")
                }
                Button("Analyze") { analyzeMIDI() }
                    .buttonStyle(.bordered)
                    .disabled(!fileLoaded || isPlaying || isRecording || isExporting || isMIDIAnalyzing || !onsetParamsDirty || fullRealTimeCoverageAchieved)
                    .tooltip("analyze")

                // Onset tuning number boxes (Thresh / Relax / Floor / Min Gap / Med Span)
                ForEach(indexedParams(ofType: .numberInput), id: \.0) { i, param in
                    NumberInputCell(param: param, value: store.values[i]) { newVal in
                        store.set(value: newVal, at: i)
                    }
                    .tooltip(param.rnboId)
                }
            }

            Spacer()

            // Transport: playhead position, rewind, play/stop, record.
            HStack(spacing: 8) {
                // Playhead position (playback) / elapsed time (recording, in red).
                TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { _ in
                    let ms = isRecording ? engine.recordingElapsedMs
                                         : engine.playheadFraction * totalDurationMs
                    Text(formatTime(ms))
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isRecording ? Color.red : Color.primary)
                        .frame(minWidth: 86, alignment: .trailing)
                }

                Button { engine.rewindToStart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!fileLoaded || isRecording)
                .tooltip("transport.rewind")

                // Play / Stop. While recording, this is a Stop that ends the take.
                Button {
                    if isRecording {
                        stopRecordingAction()
                    } else if isPlaying {
                        engine.stop()
                        flushOpenRealTimeNotes()
                        isPlaying = false
                    } else {
                        engine.beginRealTimeCapture()
                        engine.start()
                        store.pushAllValuesToEngine()
                        isPlaying = true
                    }
                } label: {
                    Image(systemName: (isPlaying || isRecording) ? "stop.fill" : "play.fill")
                        .whiteButtonIcon()
                }
                .buttonStyle(.borderedProminent)
                .tint((isPlaying || isRecording) ? Color.crayonTurquoise.opacity(0.5) : .accentColor)
                .disabled(!fileLoaded && !isRecording)
                .tooltip("transport.play")

                recordButton
                    .tooltip("transport.record")
            }

            Spacer()

            // Import / Export — Import stays always-enabled; Export group keeps the
            // shared disable + the Exporting…/Analyzing… overlay spinner.
            HStack(spacing: 8) {
                Button { showFilePicker = true } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "square.and.arrow.down")
                        Image(systemName: "waveform")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.crayonMagenta.opacity(0.25))
                .disabled(isRecording)
                .tooltip("import.audio")

                HStack(spacing: 8) {
                    Button { exportAudioOffline() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                            Image(systemName: "waveform")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.crayonTangerine.opacity(0.25))
                    .tooltip("export.audio")

                    Button { exportMIDIOffline() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "square.and.arrow.up")
                            Image(systemName: "music.quarternote.3")
                        }
                        .whiteButtonIcon()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.crayonSpring.opacity(0.25))
                    .tooltip("export.midi")
                }
                .disabled(!fileLoaded || isRecording || isExporting || isMIDIAnalyzing)
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
        }
    }

    // MARK: Recording (Step 9)

    @ViewBuilder
    private var recordButton: some View {
        if isRecording {
            // Active: red background, white filled circle.
            Button { toggleRecording() } label: {
                Image(systemName: "circle.fill").whiteButtonIcon()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        } else {
            // Idle: bordered button with a red filled circle.
            Button { toggleRecording() } label: {
                Image(systemName: "circle.fill").foregroundStyle(.red)
            }
            .buttonStyle(.bordered)
            .disabled(isPlaying || isExporting || isMIDIAnalyzing)
        }
    }

    private func toggleRecording() {
        if isRecording { stopRecordingAction() } else { startRecordingAction() }
    }

    private func startRecordingAction() {
        requestMicAccess { granted in
            guard granted else { showMicDeniedAlert = true; return }
            // Stop file playback so RNBO is fed silence during the take (no monitoring).
            if isPlaying {
                engine.stop()
                flushOpenRealTimeNotes()
                isPlaying = false
            }
            engine.startRecording(to: tempRecordingURL())
            isRecording = true
        }
    }

    private func stopRecordingAction() {
        finishRecording(engine.stopRecording())
    }

    // Leaves recording mode and hands the take off to the file-playback pipeline
    // (Workflow 2b → 1a/1b), then deletes the temp file: its samples now live in the
    // in-memory PCM array and exports render from there, so the on-disk file is
    // disposable and must not accumulate in the container's tmp.
    private func finishRecording(_ url: URL?) {
        isRecording = false
        guard let url else { return }
        loadFile(url: url, displayName: nil)
        try? FileManager.default.removeItem(at: url)
    }

    // Requests microphone permission, invoking `completion` on the main thread.
    private func requestMicAccess(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    private func tempRecordingURL() -> URL {
        let name = "PercTranscriber-Recording-\(Int(Date().timeIntervalSince1970)).caf"
        return FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    // MM:SS.MMM for the playhead-position display.
    private func formatTime(_ ms: Double) -> String {
        let total = Int(max(0, ms).rounded())
        return String(format: "%02d:%02d.%03d", total / 60_000, (total / 1_000) % 60, total % 1_000)
    }

    // Shared post-load routine for both file import and record-stop: loads `url` into
    // the host PCM array, regenerates the waveform thumbnail on a background thread, and
    // resets all per-file overlay / analysis / spectral state.
    private func loadFile(url: URL, securityScoped: Bool = false, displayName: String?) {
        let accessed = securityScoped && url.startAccessingSecurityScopedResource()
        engine.loadAudioFile(from: url)
        if accessed { url.stopAccessingSecurityScopedResource() }
        loadedFileName = displayName   // nil for recordings — the temp file is gone, show no name
        audioLoaded = true
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
        // Clear the spectral histograms and reset their display axes for the new file.
        store.clearSpectral()
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

    // Returns the (storeArrayIndex, Param) for one specific RNBO parameter id — for
    // hand-placed controls that need a particular param (distinct icon, custom order)
    // rather than a whole control-type group. nil if the id isn't present in the patch.
    private func indexed(_ rnboId: String) -> (Int, ParameterStore.Param)? {
        guard let i = store.params.firstIndex(where: { $0.rnboId == rnboId }) else { return nil }
        return (i, store.params[i])
    }

    // Onset Input sits in a fixed leading column whose width places the trailing divider at
    // the left edge of the histogram sliders: 64pt number box + 8pt gap + 24pt icon + 8pt gap
    // = 104pt. Both panels share the same leading inset, so the divider lines up with the
    // black slider edge, and the knob still sits roughly under the number-box + icon region.
    private static let onsetInputColumnWidth: CGFloat = 104

    // Input/Output parameters (all rotaries except Onset Input), evenly distributed after the divider.
    private static let IOrotaryOrder = [
        "Input_dB", "DrumSynthOutput_dB",
        "InputDelaySend_dB", "DrumSynthDelaySend_dB", "DelayOutput_dB"
    ]

    private var parametersPanel: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                // Onset Input — an onset-detector parameter, set apart from the IO
                // params by a divider and pinned under the spectral left columns.
                if let (i, param) = indexed("OnsetInput") {
                    rotaryCell(i: i, param: param)
                        .frame(width: Self.onsetInputColumnWidth)
                }
                Divider()

                // IO parameters + Greyhole + Synth Mode, evenly distributed with
                // equal spacers so they spread across the full remaining width.
                ForEach(Self.IOrotaryOrder, id: \.self) { rnboId in
                    Spacer()
                    if let (i, param) = indexed(rnboId) {
                        rotaryCell(i: i, param: param)
                    }
                }
                Spacer()
                if let (i, param) = indexed("GreyholeDelayFX_Controller/GreyholePreset") {
                    greyholeControl(i: i, param: param)
                }
                Spacer()
                if let (i, _) = indexed("SynthMode") {
                    synthModeControl(i: i)
                }
            }
            .padding()
        }
    }

    // MARK: Control views

    // Icon-only onset toggle (e.g. Onset Enable = power, Onset Needs Init = x.circle.fill).
    // Same toggle semantics as before: value >= 0.5 is "on", tinted when on.
    @ViewBuilder
    private func iconToggle(i: Int, systemImage: String) -> some View {
        let isOn = store.values[i] >= 0.5
        Button {
            store.set(value: isOn ? 0 : 1, at: i)
        } label: {
            Image(systemName: systemImage)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : nil)
        .tooltip(store.params[i].rnboId)
    }

    // Text onset toggle (e.g. Enable Training = "Train"). Same toggle semantics.
    @ViewBuilder
    private func textToggle(i: Int, title: String) -> some View {
        let isOn = store.values[i] >= 0.5
        Button {
            store.set(value: isOn ? 0 : 1, at: i)
        } label: {
            Text(title)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? .accentColor : nil)
        .tooltip(store.params[i].rnboId)
    }

    @ViewBuilder
    private func rotaryCell(i: Int, param: ParameterStore.Param) -> some View {
        let binding = Binding<Float>(
            get: { store.values[i] },
            set: { store.set(value: $0, at: i) }
        )
        let resetValue = ParameterStore.specs[param.rnboId]?.initialOverride ?? param.defaultValue
        VStack(spacing: 4) {
            RotarySlider(value: binding, min: param.min, max: param.max, resetValue: resetValue)
                .frame(width: 52, height: 52)
            Text(param.label)
                .font(.parameterLabel)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            InputValueField(
                value: store.values[i],
                min: param.min,
                max: param.max,
                format: { formattedValue($0, param: param) },
                onCommit: { store.set(value: $0, at: i) }
            )
        }
        .tooltip(param.rnboId)
    }

    // Greyhole preset: native discrete slider + randomize dice button
    // The randomize action writes parameter value 9 to RNBO engine to trigger a complete randomization of all underlying "Greyhole Delay" parameters
    @ViewBuilder
    private func greyholeControl(i: Int, param: ParameterStore.Param) -> some View {
        let binding = Binding<Float>(
            get: { store.values[i] },
            set: { store.set(value: $0, at: i) }
        )
        VStack(spacing: 4) {
            Slider(value: binding, in: param.min...(param.max-1), step: 1)
                .frame(width: 240)
                // Scoped to the slider, not the whole VStack: a container-wide tooltip
                // spans all 240pt and swallows the dice button's own tooltip rect.
                .tooltip(param.rnboId)
            // Label centered under the slider; dice pinned leading, value pinned trailing.
            ZStack {
                Text("Greyhole Delay Presets")
                    .font(.parameterLabel)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button {
                        engine.setParameter(index: param.rnboIndex, value: 9)
                    } label: {
                        Image(systemName: "dice")
                    }
                    .buttonStyle(.bordered)
                    .tooltip("greyhole.randomize")
                    Spacer()
                    Text(formattedValue(store.values[i], param: param))
                        .font(.parameterValueLabel).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 240)
        }
    }

    // Synth Mode: 2-state radio (waveform.circle.fill = 1, hockey.puck = 0). Writes the
    // same 0/1 endpoints the old discrete slider did, so this is a lossless restyle.
    @ViewBuilder
    private func synthModeControl(i: Int) -> some View {
        let isOne = store.values[i] >= 0.5
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Button { store.set(value: 1, at: i) } label: {
                    Image(systemName: "waveform.circle.fill")
                        .font(.system(size: 22))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(isOne ? .accentColor : nil)

                Button { store.set(value: 0, at: i) } label: {
                    Image(systemName: "hockey.puck")
                        .font(.system(size: 22))
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.bordered)
                .tint(isOne ? nil : .accentColor)
            }
            Text("Synth Mode")
                .font(.parameterLabel)
                .foregroundStyle(.secondary)
        }
        .tooltip(store.params[i].rnboId)
    }

    private func formattedValue(_ v: Float, param: ParameterStore.Param) -> String {
        if param.controlType == .discrete { return String(format: "%.0f", v) }
        let range = param.max - param.min
        if range > 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

#if os(macOS)
// Clears the window's first responder the moment it attaches, so macOS doesn't
// auto-focus the first text field on launch.
private struct InitialFocusClearer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClearingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ClearingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.initialFirstResponder = nil
            window?.makeFirstResponder(nil)
        }
    }
}
#endif

// Apple "Crayons" palette colors (approximate hex) used at 50% opacity for the
// Import / Export / Stop button tints, matching the Freeform mockup selections.
private extension Color {
    static let crayonMagenta   = Color(red: 1.0, green: 0.251, blue: 1.0)  // #FF40FF "Magenta"
    static let crayonTangerine = Color(red: 1.0, green: 0.576, blue: 0.0)  // #FF9300 "Tangerine"
    static let crayonSpring    = Color(red: 0.0, green: 0.976, blue: 0.0)  // #00F900 "Spring"
    static let crayonTurquoise = Color(red: 0.0, green: 0.992, blue: 1.0)  // #00FDFF "Turquoise"
}

// Shared font for all parameter captions (knob labels, number-box labels, Greyhole, Synth
// Mode) so they stay identical in size. macOS caption2 ≈ 10pt; this is that +3.
private extension Font {
    static let parameterLabel = Font.system(size: 13)
    // Numeric value readouts (knob values, spectral cutoff number boxes, Greyhole value).
    // macOS caption2 ≈ 10pt; this is that +2.
    static let parameterValueLabel = Font.system(size: 12)
}

// Forces a button label's SF Symbols white — needed when a bright .borderedProminent tint
// (Spring / Turquoise) would otherwise auto-pick a black label — while still dimming with
// the button's disabled state. A plain .foregroundStyle(.white) would override the disabled
// greying and stay full-opacity; reading \.isEnabled restores that dimming.
private struct WhiteButtonIcon: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View {
        content.foregroundStyle(.white.opacity(isEnabled ? 1.0 : 0.3))
    }
}

private extension View {
    func whiteButtonIcon() -> some View { modifier(WhiteButtonIcon()) }
}

#Preview {
    ContentView()
}
