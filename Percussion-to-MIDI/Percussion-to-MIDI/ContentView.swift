//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

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
    enum ControlType { case toggle, rotary, discrete }

    struct Spec {
        let label: String
        let controlType: ControlType
        let order: Int
        var hasRandomize: Bool = false
    }

    // Whitelist: only these RNBO parameter IDs get UI controls.
    static let specs: [String: Spec] = [
        "Onset/enable":          .init(label: "Onset Enable",      controlType: .toggle,  order:  0),
        "Onset/needs_init":      .init(label: "Onset Needs Init",  controlType: .toggle,  order:  1),
        "EnableTraining":        .init(label: "Enable Training",   controlType: .toggle,  order:  2),
        "OnsetInput":            .init(label: "Onset Input",       controlType: .rotary,  order:  3),
        "SpecFlatCutoff":        .init(label: "Spec Flat Cutoff",  controlType: .rotary,  order:  4),
        "SpecCentCutoff":        .init(label: "Spec Cent Cutoff",  controlType: .rotary,  order:  5),
        "Input_dB":              .init(label: "Input dB",          controlType: .rotary,  order:  6),
        "InputDelaySend_dB":     .init(label: "Input→Delay dB",   controlType: .rotary,  order:  7),
        "DrumSynthOutput_dB":    .init(label: "Drum Synth Out",    controlType: .rotary,  order:  8),
        "DrumSynthDelaySend_dB": .init(label: "Drum→Delay dB",    controlType: .rotary,  order:  9),
        "DelayOutput_dB":        .init(label: "Delay Out",         controlType: .rotary,  order: 10),
        "SynthMode":             .init(label: "Synth Mode",        controlType: .discrete, order: 11),
        "GreyholeDelayFX_Controller/GreyholePreset":
                                  .init(label: "Greyhole Preset",  controlType: .discrete, order: 12, hasRandomize: true),
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
        values = params.map { $0.defaultValue }
        // RNBO initialises all parameters to their defaults at construction time.
        // We do NOT call setParameter here — only when the user moves a control.
    }

    func set(value: Float, at i: Int) {
        values[i] = value
        engine.setParameter(index: params[i].rnboIndex, value: value)
    }
}

// MARK: - ContentView

struct ContentView: View {
    @State private var store = ParameterStore()
    @State private var isPlaying = false
    @State private var isExporting = false
    @State private var showFilePicker = false
    @State private var loadedFileName: String?

    private var engine: AudioEngine { store.engine }
    private var fileLoaded: Bool { loadedFileName != nil }

    var body: some View {
        VStack(spacing: 0) {
            transportPanel.padding()

            if !store.params.isEmpty {
                Divider()
                parametersPanel
            }
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
        }
    }

    // MARK: Transport

    private var transportPanel: some View {
        VStack(spacing: 12) {
            Text("PercTranscriber").font(.title2)

            if let name = loadedFileName {
                Text(name)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 260)
            }

            Button("Import Audio") { showFilePicker = true }
                .buttonStyle(.bordered)

            HStack(spacing: 16) {
                Button { engine.rewindToStart() } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!fileLoaded)

                Button {
                    if isPlaying { engine.stop() } else { engine.start() }
                    isPlaying.toggle()
                } label: {
                    Label(isPlaying ? "Stop" : "Play",
                          systemImage: isPlaying ? "stop.fill" : "play.fill")
                        .frame(width: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(isPlaying ? .red : .accentColor)
                .disabled(!fileLoaded)
            }

            HStack(spacing: 12) {
                Button("Export Audio") { exportAudioOffline() }
                    .buttonStyle(.bordered)
                Button("Export MIDI") { exportMIDIOffline() }
                    .buttonStyle(.bordered)
            }
            .disabled(!fileLoaded || isExporting)
            .overlay {
                if isExporting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Exporting…").font(.caption)
                    }
                    .padding(6)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
    }

    // MARK: Offline Export

    private func stopEngineIfNeeded() -> Bool {
        guard isPlaying else { return false }
        engine.stop()
        isPlaying = false
        return true
    }

    private func exportAudioOffline() {
        let wasPlaying = stopEngineIfNeeded()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wav")!]
        panel.nameFieldStringValue = "Export.wav"
        panel.title = "Export Processed Audio"
        guard panel.runModal() == .OK, let url = panel.url else {
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
            DispatchQueue.main.async { self.isExporting = false }
        }
    }

    private func exportMIDIOffline() {
        // Onset detection must be active for the offline loop to emit MIDI events.
        // Force-enable it if the user left the toggle off.
        if let i = store.params.firstIndex(where: { $0.rnboId == "Onset/enable" }),
           store.values[i] < 0.5 {
            store.set(value: 1, at: i)
        }

        let wasPlaying = stopEngineIfNeeded()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mid")!]
        panel.nameFieldStringValue = "Export.mid"
        panel.title = "Export MIDI"
        guard panel.runModal() == .OK, let url = panel.url else {
            if wasPlaying { engine.start(); isPlaying = true }
            return
        }

        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async { [engine] in
            engine.renderOfflineMIDI()
            let rawEvents = engine.collectAndClearMidiEvents() ?? []

            do {
                let data = try buildMIDIFile(from: rawEvents)
                try data.write(to: url, options: .atomic)
            } catch {
                NSLog("[ContentView] MIDI export error: %@", error.localizedDescription)
            }
            DispatchQueue.main.async { self.isExporting = false }
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

                // Toggles — row of bordered buttons
                let toggles = indexedParams(ofType: .toggle)
                if !toggles.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(toggles, id: \.0) { i, param in
                            toggleButton(i: i, param: param)
                        }
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
