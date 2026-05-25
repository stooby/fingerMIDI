//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                id: Int32(i), rnboIndex: Int32(i),
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
        }
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
