//
//  WaveformView.swift
//  Percussion-to-MIDI
//

import SwiftUI

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
