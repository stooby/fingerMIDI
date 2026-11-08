//
//  Icons.swift
//  fingerMIDI
//
//  Vector glyphs drawn with Canvas: the grey spectral min/max icons and Greyhole Delay
//  icon, and the colored kick / snare drum markers.
//

import SwiftUI

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

// MARK: - Greyhole Delay glyph (grey)

/// Greyhole Delay: a train of delay-echo "impulse" stems decaying exponentially in height
/// while fading in opacity, left to right. Spacing grows geometrically, so the echoes start
/// bunched together and spread apart.
struct GreyholeDelayIcon: View {
    var color: Color = .gray

    private static let echoCount = 9
    private static let spacingRatio = 1.28          // each gap is this much wider than the last
    private static let minHeightFraction = 0.12     // last echo's height vs. the first
    private static let minOpacity = 0.15            // last echo's opacity

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let n = Self.echoCount
            let inset: CGFloat = 2
            let spanW = w - 2 * inset
            let yBase = h - 1
            let total = pow(Self.spacingRatio, Double(n - 1)) - 1

            for i in 0..<n {
                let t = Double(i) / Double(n - 1)
                let x = inset + spanW * CGFloat((pow(Self.spacingRatio, Double(i)) - 1) / total)
                // Exponential decay: echo i is minHeightFraction^t as tall as echo 0.
                let top = yBase - (h - 2) * CGFloat(pow(Self.minHeightFraction, t))
                let alpha = 1 - (1 - Self.minOpacity) * t

                var stem = Path()
                stem.move(to: CGPoint(x: x, y: yBase))
                stem.addLine(to: CGPoint(x: x, y: top))
                ctx.stroke(stem, with: .color(color.opacity(alpha)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .contentShape(Rectangle())
    }
}
