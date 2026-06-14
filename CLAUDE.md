# PercTranscriber — SwiftUI App

## Project Overview

A macOS audio app built with SwiftUI + RNBO C++ DSP, bridged via Objective-C++. The app allows users to import or record audio, process it through an exported RNBO patch in real time, and export processed audio and MIDI files.

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full architectural plan, including:
- Phase 0–4 roadmap and stack decisions
- Supported user workflows (1a, 1b, 2a, 2b)
- File I/O architecture (audio import/export, MIDI export)
- ObjC++ bridging strategy
- Phase 0 MVP next steps (step-by-step implementation guide)

## Key Decisions

- **UI:** SwiftUI (macOS first, then iOS)
- **Bridging:** Objective-C++ wrapper (`.mm`), one file for Phase 0
- **Audio I/O:** AVAudioEngine + AVAudioSourceNode (no JUCE until Phase 4)
- **DSP:** RNBO exported C++ (`CoreObject`), stereo `in~` / `out~`, no internal `buffer~` in Phase 0
- **Audio file I/O:** AVAudioFile + AVAudioPCMBuffer (host-side PCM array, streamed via `process()` inputBuffers)
- **MIDI export:** swift-midi-file Swift package (orchetect)
- **JUCE:** Deferred until Phase 4 (VST3/AU plugins)

