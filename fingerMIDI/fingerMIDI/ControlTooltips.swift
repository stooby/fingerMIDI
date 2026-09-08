//
//  ControlTooltips.swift
//  fingerMIDI
//
//  Centralized control → tooltip strings. This is the single place to edit tooltips:
//  call sites only attach `.tooltip("id")` (see the View extension below), so changing a
//  tooltip never requires touching ContentView / HorizontalSliderView again.
//
//  ID scheme:
//   - Parameter-backed controls reuse their RNBO `rnboId` (e.g. "Onset/enable", "Input_dB").
//     These need NO entry here unless a custom string is wanted — `text(for:)` falls back to
//     the parameter's capitalized `ParameterStore.specs[id].label`.
//   - Controls with two distinct tooltips, or with no parameter, use explicit IDs
//     (e.g. "SpecCentCutoff.slider", "transport.play").
//
//  Newlines: a `\n` in a Swift string literal is a real newline character, and macOS
//  tooltips honor embedded newlines, so multi-line tooltips render as multiple lines.
//

import SwiftUI

enum ControlTooltips {
    static let all: [String: String] = [
        // Spectral cutoff — "range" (shared by the min/max icons and the number boxes) and
        // "slider" (the histogram sliders' kick/snare behavior).
        "SpecCentCutoff.range":  "Spectral Centroid Cutoff: 0 - 10,000 Hz",
        "SpecFlatCutoff.range":  "Spectral Flatness Cutoff: 0.0 (Sine Tone / Not Flat) - 1.0 (White Noise / Flat)",
        "SpecCentCutoff.slider": "Spectral Centroid Cutoff:\n - values less than cutoff trigger 'kick'\n - values greater than cutoff trigger 'snare'",
        "SpecFlatCutoff.slider": "Spectral Flatness Cutoff:\n - values less than cutoff trigger 'kick'\n - values greater than cutoff trigger 'snare'",

        // Parameter controls with a custom tooltip (override the spec.label fallback).
        "EnableTraining": "Enable training for at least a 5-10 seconds\nduring active playback of your source material,\nand then disable to automatically set the\nSpectral Centroid and Flatness Cutoff values.",

        // Non-parameter action buttons (no rnboId to fall back on).
        "analyze":            "Analyze: Offline onset detection",
        "transport.rewind":   "Rewind to Start",
        "transport.play":     "Play / Stop",
        "transport.record":   "Record",
        "import.audio":       "Import Audio",
        "export.audio":       "Export Audio",
        "export.midi":        "Export MIDI",
        "greyhole.randomize": "Randomize Greyhole Delay Preset",
    ]

    /// Explicit entry if present, else the parameter's capitalized label, else nil.
    static func text(for id: String) -> String? {
        if let t = all[id] { return t }
        return ParameterStore.specs[id]?.label
    }
}

extension View {
    /// Attaches the centralized tooltip for `id`, if one resolves. Passed verbatim so the
    /// string (including any newlines) isn't reinterpreted as a LocalizedStringKey.
    @ViewBuilder
    func tooltip(_ id: String) -> some View {
        if let text = ControlTooltips.text(for: id), !text.isEmpty {
            self.help(Text(verbatim: text))
        } else {
            self
        }
    }
}
