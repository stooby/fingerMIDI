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
            icon.frame(width: 18, height: 18)
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

/// SpectralCentroid: a localized gaussian "energy hump" on a full-width baseline —
/// peaked toward the low (left) end for min, the high (right) end for max. Matches the
/// mockup: a single bell whose apex sits in the left / right third, with the baseline
/// running the full width. Drawn inside a vertically-centered landscape band so the
/// bell keeps its proportions regardless of the (portrait) icon slot.
struct SpectralCentroidIcon: View {
    let isMax: Bool
    var color: Color = .gray

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let bandLeft: CGFloat = 1
            let bandW = w - 2 * bandLeft
            let bandH = bandW / 1.55                 // landscape (~mockup aspect)
            let bandTop = (h - bandH) / 2
            let yBase = bandTop + bandH              // baseline / bell feet
            let amp = bandH                          // apex height above baseline

            // Full-width baseline.
            var base = Path()
            base.move(to: CGPoint(x: bandLeft, y: yBase))
            base.addLine(to: CGPoint(x: w - bandLeft, y: yBase))
            ctx.stroke(base, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            // Localized gaussian bell, apex in the left (min) or right (max) third.
            let mu = bandLeft + bandW * (isMax ? 0.76 : 0.24)
            let sigma = bandW * 0.066
            var bell = Path()
            let steps = 64
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)          // 0…1
                let x = mu + (t * 2 - 1) * 3.2 * sigma       // mu-3.2σ … mu+3.2σ
                let u = Double((x - mu) / sigma)
                let y = yBase - amp * CGFloat(exp(-u * u / 2))
                if i == 0 { bell.move(to: CGPoint(x: x, y: y)) }
                else { bell.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(bell, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .contentShape(Rectangle())
        .tooltip("SpecCentCutoff.range")
    }
}

/// SpectralFlatness: a discrete stem/lollipop spectrum. **max** — every frequency bin
/// equal and tall (broadband noise → maximally flat spectrum). **min** — a single tall
/// center peak (with a main-lobe bell + apex dot) among short flanking bins (a pure sine
/// → one dominant bin). Both sit on a full-width baseline; each stem is capped with a
/// filled circle; the min caps are drawn a touch smaller.
struct SpectralFlatnessIcon: View {
    let isMax: Bool
    var color: Color = .gray

    private static let binCount = 9

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            // Vertically-centered landscape band matching the SpectralCentroidIcon's
            // extent, so this icon is the same (short) height as the centroid icon and
            // the number box — not the full row height.
            let bandH = (w - 2) / 1.55
            let bandTop = (h - bandH) / 2
            let yBase = bandTop + bandH               // baseline / short-bin & peak feet
            let yTall = bandTop                        // tall stem / peak apex

            let n = Self.binCount
            let inset = w * 0.06
            let spanW = w - 2 * inset
            let spacing = spanW / CGFloat(n)
            func binX(_ i: Int) -> CGFloat { inset + spacing * (CGFloat(i) + 0.5) }

            let stemWidth: CGFloat = 1.5               // thicker lines / round caps

            // Full-width baseline.
            var base = Path()
            base.move(to: CGPoint(x: 1, y: yBase))
            base.addLine(to: CGPoint(x: w - 1, y: yBase))
            ctx.stroke(base, with: .color(color),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round))

            func lollipop(_ cx: CGFloat, top: CGFloat, r: CGFloat) {
                var stem = Path()
                stem.move(to: CGPoint(x: cx, y: yBase))
                stem.addLine(to: CGPoint(x: cx, y: top))
                ctx.stroke(stem, with: .color(color),
                           style: StrokeStyle(lineWidth: stemWidth, lineCap: .round))
                ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: top - r, width: 2 * r, height: 2 * r)),
                         with: .color(color))
            }

            if isMax {
                // All 9 bins equal and tall.
                let r = spacing * 0.40
                for i in 0..<n { lollipop(binX(i), top: yTall, r: r) }
            } else {
                // One tall center peak (bell main-lobe + thin stem + apex dot) among short bins.
                let c = n / 2
                let xc = binX(c)
                let rMin = spacing * 0.32              // slightly smaller caps

                // Main-lobe bell centered on the peak.
                let sigma = spanW * 0.10
                let amp = yBase - yTall
                var bell = Path()
                let steps = 56
                for i in 0...steps {
                    let t = CGFloat(i) / CGFloat(steps)
                    let bx = xc + (t * 2 - 1) * 3 * sigma
                    let u = Double((bx - xc) / sigma)
                    let by = yBase - amp * CGFloat(exp(-u * u / 2))
                    if i == 0 { bell.move(to: CGPoint(x: bx, y: by)) }
                    else { bell.addLine(to: CGPoint(x: bx, y: by)) }
                }
                ctx.stroke(bell, with: .color(color),
                           style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))

                // Flanking bins sit UNDER the bell: capped so they never rise above the
                // bell path, and near-flush with the baseline outside the bell's span.
                let shortH = bandH * 0.40             // max height for bins under the bell
                let flushH = rMin                     // dot resting on the baseline
                for i in 0..<n where i != c {
                    let bx = binX(i)
                    let u = Double((bx - xc) / sigma)
                    let bellH = amp * CGFloat(exp(-u * u / 2))
                    let binH = bellH > flushH ? min(shortH, bellH) : flushH
                    lollipop(bx, top: yBase - binH, r: rMin)
                }
                // Tall center peak (thin stem up the bell to the apex dot).
                lollipop(xc, top: yTall, r: rMin)
            }
        }
        .contentShape(Rectangle())
        .tooltip("SpecFlatCutoff.range")
    }
}

// MARK: - Kick / Snare drum glyphs (colored)

/// Bass drum, front view: a large shell ring with two splayed legs/feet and a
/// center beater (ball on a rod) mounted on a trapezoidal pedal footboard.
struct KickDrumIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let s = min(w, h)
            let lw = max(1.0, s * 0.085)
            let cx = w * 0.5

            // Shell (front head) — large ring in the upper portion.
            let ringR = s * 0.36
            let ringCy = h * 0.42
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - ringR, y: ringCy - ringR,
                                              width: 2 * ringR, height: 2 * ringR)),
                       with: .color(color), lineWidth: lw)

            // Two legs splaying from the lower shell to small feet.
            func leg(_ dir: CGFloat) {
                let x0 = cx + dir * ringR * 0.66, y0 = ringCy + ringR * 0.60
                let x1 = cx + dir * ringR * 1.18, y1 = h * 0.92
                var p = Path()
                p.move(to: CGPoint(x: x0, y: y0)); p.addLine(to: CGPoint(x: x1, y: y1))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
                let fr = lw * 0.75
                ctx.fill(Path(ellipseIn: CGRect(x: x1 - fr, y: y1 - fr, width: 2 * fr, height: 2 * fr)),
                         with: .color(color))
            }
            leg(-1); leg(1)

            // Pedal footboard (trapezoid) at the bottom center.
            let pedalTop = h * 0.66, pedalBot = h * 0.92
            var pedal = Path()
            pedal.move(to: CGPoint(x: cx - w * 0.055, y: pedalTop))
            pedal.addLine(to: CGPoint(x: cx + w * 0.055, y: pedalTop))
            pedal.addLine(to: CGPoint(x: cx + w * 0.10, y: pedalBot))
            pedal.addLine(to: CGPoint(x: cx - w * 0.10, y: pedalBot))
            pedal.closeSubpath()
            ctx.fill(pedal, with: .color(color))

            // Beater: rod from the footboard up to a ball near the shell center.
            let ballR = s * 0.09
            let ballCy = ringCy + ringR * 0.12
            var rod = Path()
            rod.move(to: CGPoint(x: cx, y: ballCy)); rod.addLine(to: CGPoint(x: cx, y: pedalTop))
            ctx.stroke(rod, with: .color(color), lineWidth: lw * 0.7)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - ballR, y: ballCy - ballR,
                                            width: 2 * ballR, height: 2 * ballR)),
                     with: .color(color))
        }
    }
}

/// Snare drum, slight 3/4 view: a top rim ellipse, cylindrical shell sides, a
/// curved bottom edge, and evenly-spaced vertical tension lugs across the front.
struct SnareDrumIcon: View {
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lw = max(1.0, min(w, h) * 0.08)
            let cx = w * 0.5
            let rx = w * 0.42
            let ry = h * 0.14
            let topCy = h * 0.28
            let botCy = h * 0.64

            // Top rim.
            ctx.stroke(Path(ellipseIn: CGRect(x: cx - rx, y: topCy - ry, width: 2 * rx, height: 2 * ry)),
                       with: .color(color), lineWidth: lw)

            // Shell sides.
            var sides = Path()
            sides.move(to: CGPoint(x: cx - rx, y: topCy)); sides.addLine(to: CGPoint(x: cx - rx, y: botCy))
            sides.move(to: CGPoint(x: cx + rx, y: topCy)); sides.addLine(to: CGPoint(x: cx + rx, y: botCy))
            ctx.stroke(sides, with: .color(color), lineWidth: lw)

            // Curved bottom edge (front half of the lower ellipse).
            var bot = Path()
            bot.move(to: CGPoint(x: cx - rx, y: botCy))
            bot.addQuadCurve(to: CGPoint(x: cx + rx, y: botCy), control: CGPoint(x: cx, y: botCy + ry * 2))
            ctx.stroke(bot, with: .color(color), lineWidth: lw)

            // Vertical tension lugs with small hardware at their centers.
            let lugTop = topCy + ry * 0.6
            let lugBot = botCy - ry * 0.15
            let lugY = (lugTop + lugBot) / 2
            for f in [-0.66, -0.33, 0.0, 0.33, 0.66] as [CGFloat] {
                let x = cx + rx * f
                var p = Path()
                p.move(to: CGPoint(x: x, y: lugTop)); p.addLine(to: CGPoint(x: x, y: lugBot))
                ctx.stroke(p, with: .color(color), lineWidth: lw * 0.6)
                let lr = lw * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: x - lr, y: lugY - lr, width: 2 * lr, height: 2 * lr)),
                         with: .color(color))
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
                    .tooltip("SpecCentCutoff.range")
                numberBox(index: fi, feature: .flatness, axisMax: store.flatnessAxisMax)
                    .frame(height: Self.rowHeight)
                    .tooltip("SpecFlatCutoff.range")
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
                    .tooltip("SpecCentCutoff.slider")
                Rectangle().fill(SpectralDisplayConfig.borderColor).frame(height: 1)
                slider(index: fi, feature: .flatness,
                       axisMax: store.flatnessAxisMax, samples: store.flatnessSamples, now: now)
                    .frame(height: Self.rowHeight)
                    .tooltip("SpecFlatCutoff.slider")
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
