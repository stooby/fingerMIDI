//
//  HorizontalSliderView.swift
//  Percussion-to-MIDI
//
//  SpecCentCutoff / SpecFlatCutoff horizontal sliders with a live, fading spectral
//  histogram behind each. Fed by ParameterStore.centroidSamples / .flatnessSamples
//  (populated from the RNBO SpectralCentroid / SpectralFlatness outports via
//  collectAndClearSpectralEvents). See ARCHITECTURE.md → Step 14.5.
//

import SwiftUI

// MARK: - SpectralDisplayConfig

/// Tuning + per-feature styling for the spectral histograms and cutoff sliders.
/// The numeric constants are shared with ParameterStore (which uses N / T / the
/// per-feature axis defaults + expansion offset when recording samples).
enum SpectralDisplayConfig {
    // Rolling-display tuning.
    static let numberSpecDisplayValues = 20                    // N: values at the rank-based opacity ramp
    static let specDisplayFadeout: TimeInterval = 1.2          // T: seconds to fade min-opacity → 0 after aging
    static let specDisplayMaxOpacity: Double = 1.0             // opacity of the most recent value
    static let specDisplayMinOpacity: Double = 0.35            // opacity of the oldest of the N displayed
    static let maxAxisDisplayValuePercentageOffset: Float = 3  // % of full range added as headroom on expand

    // Rank-based ramp step: rank 0 = max, rank N-1 (oldest displayed) = exactly min.
    static var opacityStep: Double {
        let n = numberSpecDisplayValues
        guard n > 1 else { return 0 }
        return (specDisplayMaxOpacity - specDisplayMinOpacity) / Double(n - 1)
    }

    // Shared colors (Kick/Snare match WaveformView's MIDI note-block colors exactly).
    static let cutoffColor = Color(red: 1.0, green: 0.85, blue: 0.20)   // yellow (distinct from Kick orange)
    static let kickColor   = Color(red: 1.0, green: 0.45, blue: 0.1)    // C1 kick
    static let snareColor  = Color(red: 0.2, green: 0.85, blue: 0.9)    // D1 snare
    static let borderColor = Color.gray.opacity(0.5)

    /// Per-feature axis + bar styling.
    struct Feature {
        let defaultAxisMax: Float        // seed / reset value for the display axis max
        let fullRange: Float             // max possible value range (centroid 10000, flatness 1.0)
        let barColor: Color
        let format: (Float) -> String    // number-box + axisMax-label formatting

        /// Headroom added above a value that exceeds the axis when it auto-expands.
        var expansionOffset: Float {
            fullRange * SpectralDisplayConfig.maxAxisDisplayValuePercentageOffset / 100.0
        }
    }

    static let centroid = Feature(
        defaultAxisMax: 8000, fullRange: 10000,
        barColor: Color(red: 0.30, green: 0.85, blue: 0.38),   // bright green
        format: { String(format: "%.0f", $0) }                 // integer (0–8000+)
    )

    static let flatness = Feature(
        defaultAxisMax: 0.55, fullRange: 1.0,
        barColor: Color(red: 0.66, green: 0.28, blue: 0.92),   // purple
        format: { String(format: "%.2f", $0) }                 // 2 decimals (0–1)
    )

    static func feature(_ f: SpectralFeature) -> Feature {
        switch f {
        case .centroid: return centroid
        case .flatness: return flatness
        }
    }
}

// MARK: - HorizontalSliderView (one histogram + cutoff-slider row)

/// A single feature's row: a Canvas drawing the fading histogram bars, the yellow
/// cutoff bar, and the axisMax label, with a Kick/Snare marker overlay that tracks the
/// cutoff. No number box / spectral icons here — SpectralSlidersView places those in
/// aligned outer columns so the grey border wraps only the canvases.
struct HorizontalSliderView: View {
    @Binding var value: Float          // the cutoff value
    let paramMin: Float
    let paramMax: Float
    let resetValue: Float              // double-click reset target
    let axisMax: Float                 // the feature's dynamic display-axis max
    let samples: [SpectralSample]      // newest-first
    let now: TimeInterval              // driven by SpectralSlidersView's TimelineView
    let feature: SpectralDisplayConfig.Feature

    private static let cutoffBarWidth: CGFloat = 3.5
    private static let barWidth: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            // Display axis = the persistent (high-water) axisMax. It does NOT expand to
            // follow the cutoff; instead the cutoff is clamped to axisMax (see the gesture
            // and the number box), so the visible value range never zooms out when the bar
            // is dragged to the right. Scale is hoisted once; every x below is a multiply.
            let displayMax = max(Double(axisMax), 0.0001)
            let scale = Double(width) / displayMax
            let cbw = Self.cutoffBarWidth
            let cutoffX = min(max(CGFloat(Double(value) * scale), cbw / 2), width - cbw / 2)

            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Background
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))

                    // Histogram bars (behind) — full-height, opacity encodes age.
                    for (rank, sample) in samples.enumerated() {
                        let op = opacity(rank: rank, sample: sample)
                        if op <= 0 { continue }
                        let x = CGFloat(Double(sample.value) * scale)
                        let rect = CGRect(x: x - Self.barWidth / 2, y: 0,
                                          width: Self.barWidth, height: size.height)
                        ctx.fill(Path(rect), with: .color(feature.barColor.opacity(op)))
                    }

                    // Yellow cutoff bar (front)
                    let crect = CGRect(x: cutoffX - cbw / 2, y: 0, width: cbw, height: size.height)
                    ctx.fill(Path(crect), with: .color(SpectralDisplayConfig.cutoffColor))

                    // axisMax label (upper-right)
                    let label = ctx.resolve(
                        Text(feature.format(Float(displayMax)))
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.7))
                    )
                    let ls = label.measure(in: size)
                    ctx.draw(label, at: CGPoint(x: size.width - ls.width - 5, y: 3),
                             anchor: .topLeading)
                }

                // Kick / Snare markers flanking the cutoff bar; move with it.
                drumMarkers(cutoffX: cutoffX, height: geo.size.height)
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(positionGesture(width: width))
            .onTapGesture(count: 2) { value = resetValue }
        }
    }

    // Rank-based ramp for the N newest (agedOutAt == nil); time-based fade after.
    private func opacity(rank: Int, sample: SpectralSample) -> Double {
        if let agedOut = sample.agedOutAt {
            let elapsed = now - agedOut
            return max(0, SpectralDisplayConfig.specDisplayMinOpacity
                       * (1 - elapsed / SpectralDisplayConfig.specDisplayFadeout))
        }
        return max(0, SpectralDisplayConfig.specDisplayMaxOpacity
                   - Double(rank) * SpectralDisplayConfig.opacityStep)
    }

    @ViewBuilder
    private func drumMarkers(cutoffX: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            drumMarker(icon: KickDrumIcon(color: SpectralDisplayConfig.kickColor),
                       label: "C1", color: SpectralDisplayConfig.kickColor)
            drumMarker(icon: SnareDrumIcon(color: SpectralDisplayConfig.snareColor),
                       label: "D1", color: SpectralDisplayConfig.snareColor)
        }
        .position(x: cutoffX, y: height / 2)
    }

    private func drumMarker<Icon: View>(icon: Icon, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            icon.frame(width: 15, height: 15)
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundColor(color)
        }
    }

    // Click-to-position (absolute, like the waveform seek): the pointer x maps directly to
    // a value in [0, axisMax]. minimumDistance 0 so a single click sets the cutoff. Clamped
    // to the parameter range and to axisMax so the cutoff can't be pushed past the visible
    // axis. Double-click resets (handled by .onTapGesture(count: 2)).
    private func positionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let frac = max(0, min(1, drag.location.x / width))
                let raw = Float(frac) * axisMax
                let hi = min(paramMax, axisMax)
                value = raw < paramMin ? paramMin : (raw > hi ? hi : raw)
            }
    }
}

// MARK: - Spectral min/max icons (grey vector glyphs)

/// SpectralCentroid: a spectral energy bump, skewed low (min) or high (max).
struct SpectralCentroidIcon: View {
    let isMax: Bool
    var color: Color = .gray

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            var base = Path()
            base.move(to: CGPoint(x: 1, y: h * 0.82))
            base.addLine(to: CGPoint(x: w - 1, y: h * 0.82))
            ctx.stroke(base, with: .color(color.opacity(0.45)), lineWidth: 0.8)

            let peakX = isMax ? w * 0.68 : w * 0.32
            var bump = Path()
            bump.move(to: CGPoint(x: 1, y: h * 0.82))
            bump.addCurve(to: CGPoint(x: peakX, y: h * 0.2),
                          control1: CGPoint(x: peakX * 0.5, y: h * 0.82),
                          control2: CGPoint(x: peakX * 0.78, y: h * 0.2))
            bump.addCurve(to: CGPoint(x: w - 1, y: h * 0.82),
                          control1: CGPoint(x: peakX + (w - peakX) * 0.22, y: h * 0.2),
                          control2: CGPoint(x: peakX + (w - peakX) * 0.5, y: h * 0.82))
            ctx.stroke(bump, with: .color(color), lineWidth: 1.3)
        }
    }
}

/// SpectralFlatness: a tonal peak with a dotted noise floor (min), or a comb of equal
/// partials under a bracket (max, flat/noisy spectrum).
struct SpectralFlatnessIcon: View {
    let isMax: Bool
    var color: Color = .gray

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            if isMax {
                let n = 6
                for i in 0..<n {
                    let x = w * (CGFloat(i) + 0.5) / CGFloat(n)
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: h * 0.26))
                    p.addLine(to: CGPoint(x: x, y: h * 0.82))
                    ctx.stroke(p, with: .color(color), lineWidth: 1.1)
                }
                var top = Path()
                top.move(to: CGPoint(x: w * 0.06, y: h * 0.22))
                top.addLine(to: CGPoint(x: w * 0.94, y: h * 0.22))
                ctx.stroke(top, with: .color(color.opacity(0.55)), lineWidth: 0.9)
            } else {
                var peak = Path()
                peak.move(to: CGPoint(x: w * 0.5, y: h * 0.16))
                peak.addLine(to: CGPoint(x: w * 0.5, y: h * 0.8))
                ctx.stroke(peak, with: .color(color), lineWidth: 1.4)

                var skirt = Path()
                skirt.move(to: CGPoint(x: w * 0.30, y: h * 0.8))
                skirt.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.2),
                                   control: CGPoint(x: w * 0.44, y: h * 0.74))
                skirt.move(to: CGPoint(x: w * 0.70, y: h * 0.8))
                skirt.addQuadCurve(to: CGPoint(x: w * 0.5, y: h * 0.2),
                                   control: CGPoint(x: w * 0.56, y: h * 0.74))
                ctx.stroke(skirt, with: .color(color.opacity(0.55)), lineWidth: 0.8)

                let dots = 7
                for i in 0..<dots {
                    let x = w * (CGFloat(i) + 0.5) / CGFloat(dots)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 0.6, y: h * 0.85, width: 1.2, height: 1.2)),
                             with: .color(color.opacity(0.6)))
                }
            }
        }
    }
}

// MARK: - Kick / Snare drum glyphs (colored)

struct KickDrumIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let d = min(size.width, size.height)
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = d / 2 - 1
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(color), lineWidth: 1.4)
            let r2 = r * 0.42
            ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r2, y: c.y - r2, width: 2 * r2, height: 2 * r2)),
                       with: .color(color), lineWidth: 1.0)
        }
    }
}

struct SnareDrumIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let rect = CGRect(x: 1.5, y: h * 0.3, width: w - 3, height: h * 0.4)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 2), with: .color(color), lineWidth: 1.3)
            for f in [0.42, 0.5, 0.58] as [CGFloat] {
                var p = Path()
                p.move(to: CGPoint(x: rect.minX, y: h * f))
                p.addLine(to: CGPoint(x: rect.maxX, y: h * f))
                ctx.stroke(p, with: .color(color.opacity(0.75)), lineWidth: 0.7)
            }
        }
    }
}

// MARK: - SpectralSlidersView (container inserted into ContentView)

/// Assembles the two cutoff rows (Centroid on top, Flatness on bottom) as aligned
/// columns: number boxes, left (min) icons, the grey-bordered two-canvas stack, and
/// right (max) icons. Owns the dedicated 30 fps TimelineView that drives the fade
/// redraw (event pulling happens on ContentView's playback-gated timer, not here).
struct SpectralSlidersView: View {
    let store: ParameterStore

    private static let rowHeight: CGFloat = 40
    private static let iconWidth: CGFloat = 24

    var body: some View {
        if let ci = store.params.firstIndex(where: { $0.rnboId == "SpecCentCutoff" }),
           let fi = store.params.firstIndex(where: { $0.rnboId == "SpecFlatCutoff" }) {
            TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { ctx in
                content(centroidIndex: ci, flatnessIndex: fi,
                        now: ctx.date.timeIntervalSinceReferenceDate)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func content(centroidIndex ci: Int, flatnessIndex fi: Int, now: TimeInterval) -> some View {
        HStack(spacing: 8) {
            // Number boxes (bordered) — cutoff value entry.
            VStack(spacing: 1) {
                numberBox(index: ci, feature: .centroid, axisMax: store.centroidAxisMax)
                    .frame(height: Self.rowHeight)
                numberBox(index: fi, feature: .flatness, axisMax: store.flatnessAxisMax)
                    .frame(height: Self.rowHeight)
            }

            // Left = "min" spectral icons.
            VStack(spacing: 1) {
                SpectralCentroidIcon(isMax: false).frame(width: Self.iconWidth, height: Self.rowHeight)
                SpectralFlatnessIcon(isMax: false).frame(width: Self.iconWidth, height: Self.rowHeight)
            }

            // The two histogram canvases, wrapped in a single grey border with a divider.
            VStack(spacing: 0) {
                slider(index: ci, feature: .centroid,
                       axisMax: store.centroidAxisMax, samples: store.centroidSamples, now: now)
                    .frame(height: Self.rowHeight)
                Rectangle().fill(SpectralDisplayConfig.borderColor).frame(height: 1)
                slider(index: fi, feature: .flatness,
                       axisMax: store.flatnessAxisMax, samples: store.flatnessSamples, now: now)
                    .frame(height: Self.rowHeight)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(SpectralDisplayConfig.borderColor, lineWidth: 1)
            )

            // Right = "max" spectral icons.
            VStack(spacing: 1) {
                SpectralCentroidIcon(isMax: true).frame(width: Self.iconWidth, height: Self.rowHeight)
                SpectralFlatnessIcon(isMax: true).frame(width: Self.iconWidth, height: Self.rowHeight)
            }
        }
    }

    private func slider(index i: Int, feature: SpectralFeature, axisMax: Float,
                        samples: [SpectralSample], now: TimeInterval) -> some View {
        let param = store.params[i]
        let reset = ParameterStore.specs[param.rnboId]?.initialOverride ?? param.defaultValue
        return HorizontalSliderView(
            value: Binding(get: { store.values[i] }, set: { store.set(value: $0, at: i) }),
            paramMin: param.min, paramMax: param.max, resetValue: reset,
            axisMax: axisMax, samples: samples, now: now,
            feature: SpectralDisplayConfig.feature(feature)
        )
    }

    private func numberBox(index i: Int, feature: SpectralFeature, axisMax: Float) -> some View {
        let param = store.params[i]
        let cfg = SpectralDisplayConfig.feature(feature)
        // Clamp entry to the visible axis (axisMax), not the full RNBO range, so a typed
        // cutoff can't exceed the display axis either.
        return InputValueField(
            value: store.values[i], min: param.min, max: min(param.max, axisMax),
            format: cfg.format, onCommit: { store.set(value: $0, at: i) }
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(SpectralDisplayConfig.borderColor, lineWidth: 1)
        )
    }
}
