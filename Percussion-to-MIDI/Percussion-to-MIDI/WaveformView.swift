//
//  WaveformView.swift
//  Percussion-to-MIDI
//

import SwiftUI

// MARK: - MIDINoteEvent

struct MIDINoteEvent {
    let note: UInt8        // 36 = C1 kick, 38 = D1 snare
    let velocity: UInt8
    let onsetMs: Double
    let durationMs: Double
    var isStale: Bool = false
}

// MARK: - WaveformThumbnail

struct WaveformThumbnail {
    let bins: [(min: Float, max: Float)]

    init?(data: Data) {
        let count = data.count / (2 * MemoryLayout<Float>.size)
        guard count > 0 else { return nil }
        var result = [(min: Float, max: Float)]()
        result.reserveCapacity(count)
        data.withUnsafeBytes { raw in
            let floats = raw.bindMemory(to: Float.self)
            for i in 0..<count {
                result.append((min: floats[i * 2], max: floats[i * 2 + 1]))
            }
        }
        bins = result
    }
}

// MARK: - WaveformView

struct WaveformView: View {
    let thumbnail: WaveformThumbnail?
    let playheadFraction: Double
    let onSeek: ((Double) -> Void)?
    var midiNotes: [MIDINoteEvent] = []
    var totalDurationMs: Double = 0
    // Supplied by the caller from AudioEngine.processingLatencyMs (the single source
    // of truth) — no local fallback, so the overlay shift can never drift from the
    // value the audio engine's settling window uses.
    var midiLatencyCompensationMs: Double

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                // Background
                context.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(.black))

                // Waveform
                if let thumbnail, !thumbnail.bins.isEmpty {
                    let binCount = Double(thumbnail.bins.count)
                    let midY = size.height / 2.0
                    let scale = midY * 0.9
                    var path = Path()
                    for (i, bin) in thumbnail.bins.enumerated() {
                        let x = size.width * Double(i) / (binCount - 1)
                        path.move(to: CGPoint(x: x, y: midY - Double(bin.max) * scale))
                        path.addLine(to: CGPoint(x: x, y: midY - Double(bin.min) * scale))
                    }
                    context.stroke(path,
                                   with: .color(Color(red: 0.2, green: 0.5, blue: 1.0)),
                                   lineWidth: 1)
                }

                // MIDI note overlay — drawn after waveform, before playhead
                if !midiNotes.isEmpty && totalDurationMs > 0 {
                    let stripHeight: CGFloat = 12
                    // D1 (snare, higher pitch) sits above C1 (kick, lower pitch)
                    let yForNote: (UInt8) -> CGFloat = { note in
                        note == 38 ? size.height * 0.68 : size.height * 0.84
                    }
                    for noteEvent in midiNotes {
                        let x = max(0, size.width * ((noteEvent.onsetMs - midiLatencyCompensationMs) / totalDurationMs))
                        let w = max(2, size.width * (noteEvent.durationMs / totalDurationMs))
                        let y = yForNote(noteEvent.note) - stripHeight / 2
                        let rect = CGRect(x: x, y: y, width: w, height: stripHeight)
                        let color: Color = noteEvent.isStale
                            ? Color.gray.opacity(0.35)
                            : (noteEvent.note == 38
                                ? Color(red: 0.2, green: 0.85, blue: 0.9).opacity(0.75)   // D1 snare: cyan
                                : Color(red: 1.0, green: 0.45, blue: 0.1).opacity(0.75))  // C1 kick:  orange
                        context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    }
                }

                // Placeholder text when no file is loaded
                if thumbnail == nil {
                    let resolved = context.resolve(Text(verbatim: "Import an Audio File")
                        .font(.system(size: 14))
                        .foregroundColor(Color(nsColor: .tertiaryLabelColor)))
                    let textSize = resolved.measure(in: size)
                    let origin = CGPoint(
                        x: (size.width  - textSize.width)  / 2,
                        y: (size.height - textSize.height) / 2
                    )
                    context.draw(resolved, at: origin, anchor: .topLeading)
                }

                // Playhead line — only shown once a file is loaded
                if thumbnail != nil {
                    var linePath = Path()
                    let px = size.width * playheadFraction
                    linePath.move(to: CGPoint(x: px, y: 0))
                    linePath.addLine(to: CGPoint(x: px, y: size.height))
                    context.stroke(linePath,
                                   with: .color(Color(red: 1.0, green: 0.85, blue: 0.2)),
                                   lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        onSeek?(fraction)
                    }
            )
        }
    }
}
