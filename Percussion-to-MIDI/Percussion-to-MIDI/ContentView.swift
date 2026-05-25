//
//  ContentView.swift
//  Percussion-to-MIDI
//
//  Created by Scott Tooby on 5/22/26.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private let engine = AudioEngine()
    @State private var isPlaying = false
    @State private var showFilePicker = false
    @State private var loadedFileName: String?

    private var fileLoaded: Bool { loadedFileName != nil }

    var body: some View {
        VStack(spacing: 20) {
            Text("PercTranscriber")
                .font(.title2)

            if let name = loadedFileName {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260)
            }

            Button("Import Audio") {
                showFilePicker = true
            }
            .buttonStyle(.bordered)

            HStack(spacing: 16) {
                Button {
                    engine.rewindToStart()
                } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!fileLoaded)

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
                .disabled(!fileLoaded)
            }
        }
        .padding()
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
}

#Preview {
    ContentView()
}
