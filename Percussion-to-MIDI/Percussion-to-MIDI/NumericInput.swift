//
//  NumericInput.swift
//  Percussion-to-MIDI
//
//  Pure, UI-free numeric helpers. Kept free of SwiftUI/engine dependencies so
//  they can be unit-tested directly (see NumericInputTests).
//

import Foundation

/// Clamp `value` into the closed range [lo, hi].
///
/// Precondition: `lo <= hi`. Returns `lo` for anything below the range,
/// `hi` for anything above it, and the value unchanged when it is inside.
func clampToRange(_ value: Float, min lo: Float, max hi: Float) -> Float {
    value < lo ? lo : (value > hi ? hi : value)
}
