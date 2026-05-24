//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import SwiftUI

struct ContentView: View {
    private let engine = AudioEngine()
    @State private var isPlaying = false

    var body: some View {
        VStack(spacing: 20) {
            Text("PercTranscriber")
                .font(.title2)

            Button {
                if isPlaying {
                    engine.stop()
                } else {
                    engine.start()
                }
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Stop" : "Play",
                      systemImage: isPlaying ? "stop.fill" : "play.fill")
                    .frame(width: 100)
            }
            .buttonStyle(.borderedProminent)
            .tint(isPlaying ? .red : .accentColor)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
