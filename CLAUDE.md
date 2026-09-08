# fingerMIDI — SwiftUI App

## Project Overview

`fingerMIDI` is a simple 2-voice ("kick" and "snare") audio-to-MIDI  percussion transcription app for macOS. 

Specialized for finger percussion, it performs onset detection with spectral centroid and flatness analysis to detect high/snare from low/kick timbres, and map them to MIDI notes.

The app allows users to import or record audio, process it with exported Max RNBO patch DSP to transcribe audio to MIDI notes (and do other audio effects processing), and export audio and MIDI files.

The app is built with Swift and SwiftUI, an Objective-C to C++ bridge for the real-time audio engine, and DSP code authored in Max RNBO, FAUST, and exported to C++.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full architectural plan.

## Key Decisions

- **UI:** SwiftUI (macOS first, then iOS)
- **Bridging:** Objective-C++ wrapper (`.mm`)
- **Audio I/O:** AVAudioEngine + AVAudioSourceNode
- **DSP:** RNBO exported C++ (`CoreObject`), stereo `in~` / `out~`
- **Audio file I/O:** AVAudioFile + AVAudioPCMBuffer (host-side PCM array, streamed via `process()` inputBuffers)
- **MIDI export:** swift-midi-file Swift package (orchetect)

