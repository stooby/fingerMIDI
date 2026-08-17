# Architectural Plan: SwiftUI + RNBO C++ — Full Roadmap Assessment

## Context

The user is building audio apps using RNBO for DSP (exported to C++ or JS) and wants SwiftUI for UI. They need an architecture that:
- Works for a standalone macOS app first
- Ports naturally to iOS
- Accommodates a web app version later (via RNBO's JS export)
- Doesn't foreclose VST3/AU plugin distribution in the future

The assessment also needed to resolve: (1) whether RNBO `buffer~` supports runtime audio data injection from the host; (2) how MIDI file export should work; (3) whether JUCE for the audio engine adds net value given this roadmap.

---

## Key Research Findings

### 1. RNBO `buffer~` + `setExternalData()`: Fully Supported

RNBO's C++ API exposes `setExternalData()` on `CoreObject`. The host decodes an audio file to raw PCM float data and passes ownership to RNBO:

```cpp
// Decode audio file → float* audioData (host allocates)
RNBO::Float32AudioBuffer bufferType(numChannels, sampleRate);
coreObject.setExternalData(
    "myBufferName",                             // must match buffer~ name in patch
    reinterpret_cast<char*>(audioData),
    numSamples * numChannels * sizeof(float),
    bufferType,
    [audioData](RNBO::ExternalDataId, char*) { delete[] audioData; }
);
```

Caveats:
- Call once per load — calling again erases contents
- `CoreObject` is single-threaded; synchronize if calling from a non-audio thread
- Host owns and manages the memory lifetime via the cleanup callback

### 2. RNBO MIDI: Real-time events only

RNBO outputs `MidiEvent` objects via an `EventHandler` subclass after each `process()` call. There is no MIDI file writing in RNBO. The host is fully responsible for:
- **Export**: capturing `MidiEvent` objects and writing them to a `.mid` file
- **Import** (if ever needed): parsing a `.mid` file and feeding events via `coreObject.scheduleEvent(MidiEvent(...))`

### 3. JUCE for web audio vs. RNBO JS export

JUCE does have an Emscripten/WebAssembly target, but it is experimental and limited. **RNBO's native JavaScript export is the correct path for web audio** — it's mature, first-party supported, and purpose-built. No overlap with the Swift stack.

---

## Target Roadmap and Architecture Per Phase

### Phase 0: Standalone macOS App — MVP (Simple Streaming I/O RNBO Patch)
**Current patch design: stereo `in~` / `out~` signal inlets only, no internal `buffer~`.**

**Stack: AVAudioEngine + ObjC++ Bridge + RNBO C++ + SwiftUI**

```
SwiftUI (UI layer)
    ↕  Swift ↔ ObjC++ bridging header
ObjC++ Wrapper (.mm)
    ├── AVAudioEngine + AVAudioSourceNode (real-time I/O)
    ├── RNBO CoreObject (DSP)
    ├── Host-side PCM float array (decoded audio file, owned by ObjC++ wrapper)
    ├── Playhead for streaming PCM through process() inputBuffers
    ├── Lock-free ring buffer (live input monitoring — Workflow 2a / Step 9.5 only)
    └── EventHandler subclass for MIDI event capture
AVFoundation (audio file decode/encode, in ObjC++ or Swift)
swift-midi-core + swift-midi-file packages (MIDI file export)
```

No JUCE. No `buffer~` in the RNBO patch — all audio file data is held and streamed by the host.
The bridge wrapper is one `.mm` file.

**Key simplification vs. Phase 1:** No `setExternalData()` calls. The host decodes an audio file into a PCM float array and streams it block-by-block through RNBO's `in~` inlets as `inputBuffers` — both for real-time playback and offline rendering. From RNBO's perspective, file playback and live input look identical.

### Phase 1: Standalone macOS App (RNBO Patch w/ Internal Audio Input Buffer)
**Future patch design: adds an `audioInput` buffer~ inside the RNBO patch for host-loaded audio.**

**Stack: same as Phase 0, with `setExternalData()` added to the ObjC++ wrapper.**

```
SwiftUI (UI layer)
    ↕  Swift ↔ ObjC++ bridging header
ObjC++ Wrapper (.mm)
    ├── AVAudioEngine + AVAudioSourceNode (real-time I/O)
    ├── RNBO CoreObject (DSP)
    ├── setExternalData() for audio file → audioInput buffer~ injection
    ├── Lock-free ring buffer (live input monitoring — Workflow 2a / Step 9.5 only)
    └── EventHandler subclass for MIDI event capture
AVFoundation (audio file decode/encode, in ObjC++ or Swift)
swift-midi-core + swift-midi-file packages (MIDI file export)
```

No JUCE. The bridge wrapper is still one `.mm` file — the only change from Phase 0 is the addition of `setExternalData()` and the patch gaining an `audioInput` buffer~.

**When to move from Phase 0 → Phase 1:** When the RNBO patch gains use cases that benefit from internal audio memory — e.g. playback rate resampling, pitch shifting with buffer-based algorithms, or other DSP that operates on a stored buffer rather than a live stream.

### Phase 2: iOS App
**Same stack — nearly zero changes required.**

- AVAudioEngine works on iOS (add AVAudioSession configuration)
- RNBO C++ compiles to ARM via Xcode with no changes
- SwiftUI is native iOS
- swift-midi-core / swift-midi-file work on iOS
- Main delta: add `AVAudioSession.sharedInstance().setCategory(.playAndRecord)` and handle interruptions

### Phase 3: Web App
**Entirely separate stack — no code sharing with Swift. React is the chosen UI framework.**

- Export RNBO patch as JavaScript target (RNBO's native JS export — mature, first-party supported; no JUCE Emscripten needed)
- Build the web UI in React; RNBO JS handles all audio DSP in the browser
- **Why React specifically:** the React UI components built here are reused directly in Phase 4 — JUCE 8's `WebBrowserComponent` hosts the React app as the plugin UI, so building in React now avoids writing a separate plugin GUI later

This is a separate project and codebase from the Swift app. The Swift codebase has no bearing on it.

### Phase 4: VST3 / AU Plugins
**Introduce JUCE at this point — replace the AVAudioEngine wrapper layer, and replace SwiftUI with the Phase 3 React UI hosted inside a JUCE 8 WebView.**

The cleanest transition path:
1. Create a `JUCE::AudioProcessor` subclass that wraps `RNBO::CoreObject` (replaces the AVAudioEngine callback)
2. Use Projucer (or JUCE CMake) to target VST3, AU, AUv3
3. The RNBO C++ DSP code is completely unchanged
4. Host the Phase 3 React app inside JUCE 8's `WebBrowserComponent` as the plugin UI — no new plugin GUI needs to be built

**React UI reuse via JUCE 8 WebView:**

JUCE 8's `WebBrowserComponent` embeds a native browser (WebKit on macOS, Edge/Chromium on Windows) directly in the plugin window. The Phase 3 React app becomes the plugin UI layer with minimal changes.

- **Development:** point `WebBrowserComponent` at `localhost:3000` (React dev server); UI changes hot-reload without recompiling C++
- **Release:** bundle the React build output and serve from C++ via `withResourceProvider` (from `BinaryData` or a zip). The official `WebViewPluginDemo` in the JUCE repo demonstrates this exact pattern.

**C++ ↔ React bridge (JUCE 8 APIs):**

| Direction | API |
|---|---|
| React → C++ | `withNativeFunction` (C++) / `Juce.getNativeFunction()` (JS, returns a Promise) |
| C++ → React | `emitEventIfBrowserIsVisible()` (C++) / `window.__JUCE__.backend.addEventListener()` (JS) |
| Parameter binding | `WebSliderParameterAttachment`, `WebToggleButtonParameterAttachment`, `WebComboBoxParameterAttachment` |

Enable bidirectional communication by passing `withNativeIntegrationEnabled` to `WebBrowserComponent` — this injects JUCE's JS shim (`index.js`) into the page, which runs without errors even when the C++ backend is absent, so the React UI can be developed and tested independently in a browser.

**Key caveat — what transfers and what doesn't:**

The Web Audio API / RNBO JS DSP logic from the standalone web app (Phase 3) cannot run inside the JUCE WebView — the WebView is a UI renderer, not a full browser runtime. All audio DSP stays in RNBO C++ / JUCE. Only the React UI components (controls, layout, styling) are shared between Phase 3 and Phase 4; the audio wiring is completely different in each context (RNBO JS in browser vs. RNBO C++ in plugin).

**What changes vs. what doesn't:**

The key architectural insight: **the ObjC++ bridge wrapper is the only audio-layer change.** RNBO DSP code is completely unchanged. SwiftUI is replaced by the Phase 3 React app hosted in `WebBrowserComponent` — the plugin window shows the React UI rather than native SwiftUI controls. The refactor scope at Phase 4 is bounded to one `.mm` file → one JUCE `AudioProcessor` subclass, plus wiring the JUCE ↔ React bridge.

---

## File I/O Architecture

### Supported User Workflows

#### Phase 0 (Streaming I/O patch — no internal buffer~)

All workflows converge after the input stage — audio held as a host-side PCM array — after which export paths are identical regardless of how the audio was sourced.

**Workflow 1a: Import file → real-time processing & playback → offline export**
1. User imports audio file → ObjC++ wrapper decodes via AVAudioFile → host-side PCM float array; playhead reset to 0
2. AVAudioSourceNode streams PCM array through RNBO `process()` as `inputBuffers`, advancing playhead each block; user hears processed output and can adjust parameters in real time
3. Offline export: host resets playhead and resets RNBO DSP state via `prepareToProcess(force=true)` (preserving parameter values); calls `process()` loop feeding same PCM array, captures output → AVAudioFile / swift-midi-file

**Workflow 1b: Import file → real-time processing & playback → real-time export**
1. Same as Workflow 1a step 1
2. Same as Workflow 1a step 2
3. Real-time export: ObjC++ wrapper simultaneously captures `process()` output to AVAudioFile and accumulates MidiEvents from EventHandler during the live session → AVAudioFile / swift-midi-file

**Workflow 2b: Record live input → (no real-time monitoring) → offline or real-time export** *(Step 9)*
1. Live audio input: inputNode tap → **Branch A only**: raw recording to AVAudioFile (unprocessed). No ring buffer and no live input to RNBO — the transport is in its stopped/silent state, so the render block feeds RNBO silence (the always-alive engine keeps `process()` running so any effects tail from prior playback rings out, but its output is not the live input). "No monitoring" is a property of the input source (silence vs. live samples), not a bypass parameter.
2. Recording stops → raw AVAudioFile finalized on disk
3. Decode recorded file → host-side PCM float array → from here identical to Workflow 1a step 3 (offline) or Workflow 1b step 3 (real-time)

**Workflow 2a: Record live input → monitor real-time processing → offline or real-time export** *(Step 9.5)*
1. Live audio input: inputNode tap → Branch A: raw recording to AVAudioFile (unprocessed); **Branch B**: ring buffer → AVAudioSourceNode render block feeds live samples as RNBO `process()` `inputBuffers`; user hears processed output and can adjust parameters in real time
2. Recording stops → raw AVAudioFile finalized on disk
3. Decode recorded file → host-side PCM float array → from here identical to Workflow 1a step 3 (offline) or Workflow 1b step 3 (real-time)

#### Phase 1 (RNBO patch w/ internal `audioInput` buffer~)

All workflows converge after the input stage — audio loaded into RNBO's `audioInput` buffer~ — after which export paths are identical.

**Workflow 1a: Import file → real-time processing & playback → offline export**
1. User imports audio file → decoded → `setExternalData("audioInput")` on CoreObject; patch handles playback from buffer~ internally
2. AVAudioSourceNode drives `process()` with null `inputBuffers`; patch reads from `audioInput` buffer~; user hears processed output and can adjust parameters in real time
3. Offline export: reset RNBO DSP state via `prepareToProcess(force=true)`; call `process()` loop with null `inputBuffers` (patch re-reads from buffer~), capture output → AVAudioFile / swift-midi-file; or direct buffer~ read

**Workflow 1b: Import file → real-time processing & playback → real-time export**
1. Same as Phase 1 Workflow 1a step 1
2. Same as Phase 1 Workflow 1a step 2
3. Real-time export: simultaneously capture `process()` output to AVAudioFile and accumulate MidiEvents from EventHandler during the live session

**Workflow 2b: Record live input → (no real-time monitoring) → offline or real-time export** *(Step 9)*
1. Live audio input: inputNode tap → **Branch A only**: raw recording to AVAudioFile. No ring buffer and no live input to RNBO — the transport is stopped, so the render block feeds RNBO silence (tails ring out; output is not the live input). "No monitoring" is a property of the input source, not a bypass parameter.
2. Recording stops → raw AVAudioFile finalized on disk
3. Decode recorded file → `setExternalData("audioInput")` → from here identical to Phase 1 Workflow 1a step 3 (offline) or Workflow 1b step 3 (real-time)

**Workflow 2a: Record live input → monitor real-time processing → offline or real-time export** *(Step 9.5)*
1. Live audio input: inputNode tap → Branch A: raw recording to AVAudioFile; **Branch B**: ring buffer → AVAudioSourceNode → RNBO `process()` `inputBuffers`; user hears processed output and can adjust parameters in real time
2. Recording stops → raw AVAudioFile finalized on disk
3. Decode recorded file → `setExternalData("audioInput")` → from here identical to Phase 1 Workflow 1a step 3 (offline) or Workflow 1b step 3 (real-time)

**RNBO patch design note (Phase 1):** The patch must handle two input modes — live streaming via `in~` inlets (Workflow 2a monitored recording only) and buffer~-based playback (Workflows 1a/1b, post-recording 2a/2b, and Workflow 2b during recording, when RNBO is fed silence). Design the patch with this dual-source routing in mind.

---

### Audio File Import

**Phase 0 — host-side PCM array (no buffer~ in patch)**
```
User selects file (SwiftUI FileImporter)
    → Swift passes URL to ObjC++ wrapper
    → ObjC++ decodes via AVAudioFile → AVAudioPCMBuffer
    → Extracts float* pointer from floatChannelData
    → Stores PCM array + length + channel count in ObjC++ wrapper (host owns memory)
    → Playhead reset to 0; ready for streaming via process() inputBuffers
```
Also the final step of Phase 0 Workflows 2a and 2b after live recording finishes (same path, source is the just-written recording file).

**Phase 1 — load into RNBO `audioInput` buffer~ via `setExternalData()`**
```
User selects file (SwiftUI FileImporter)
    → Swift passes URL to ObjC++ wrapper
    → ObjC++ decodes via AVAudioFile → AVAudioPCMBuffer
    → Extracts float* pointer from floatChannelData
    → Calls setExternalData("audioInput") on CoreObject
    → RNBO audioInput buffer~ now contains the audio data; patch handles playback internally
```
Also the final step of Phase 1 Workflows 2a and 2b after live recording finishes (same path, source is the just-written recording file).

### Live Audio Input (Workflows 2a/2b — both phases)
```
AVAudioEngine inputNode receives audio from mic / audio interface

    Workflow 2b (no monitoring — Step 9):
    Branch A only — raw recording: inputNode tap → AVAudioFile writer (unprocessed, to disk)
        → RNBO render block is fed SILENCE (transport stopped); process() keeps running so
          effects tails ring out, but RNBO's output is not the live input

    Workflow 2a (monitoring — Step 9.5): Branch A, plus
    Branch B — real-time monitoring: inputNode tap → lock-free ring buffer
        → AVAudioSourceNode render block reads ring buffer → RNBO process() inputBuffers
        → RNBO processes live input → output to AVAudioEngine output

[Recording stops]
    → AVAudioFile finalized on disk
    Phase 0: Decode file → host-side PCM float array → Workflows 2a/2b now identical to Workflows 1a/1b
    Phase 1: Decode file → setExternalData("audioInput") on CoreObject → Workflows 2a/2b now identical to Workflows 1a/1b
```

**Threading note (Workflow 2a monitoring — Step 9.5 only):** The `inputNode` tap and `AVAudioSourceNode` render block run on separate audio threads. Since `CoreObject` is single-threaded, a lock-free ring buffer in the ObjC++ wrapper bridges them for monitored recording — the tap writes input samples; the render block reads and passes them to `process()` as `inputBuffers`. This is a standard real-time audio pattern and requires no new technologies, but is an explicit implementation detail in the ObjC++ wrapper. **Step 9 (Workflow 2b) has no such bridge** — it uses only the Branch A tap → AVAudioFile writer.

**Workflow 2b note (no monitoring — Step 9):** Branch B is absent entirely; only Branch A runs. The render block feeds RNBO silence because the transport is in its stopped state (the always-alive engine keeps `process()` running so effects tails ring out, but its output is not the live input). "No monitoring" is achieved by the input source, **not** by a patch bypass parameter — none is required or used. In Step 9.5, monitoring is toggled by switching the render block's input source between the ring buffer (monitor) and silence (no monitor), again with no bypass parameter.

### Audio File Export

**A. Real-time recording** *(Workflow 1b — real-time export during live session)*
```
ObjC++ wrapper captures process() output into a float buffer (during AVAudioSourceNode callback)
    → Writes to disk via AVAudioFile (WAV/AIFF/CAF)
    → Returns file URL to Swift
    → Swift presents via ShareSheet / SavePanel
```

**B. Offline rendering** *(Workflows 1a, 2a, 2b — offline export)*
```
ObjC++ wrapper calls prepareToProcess(sampleRate, blockSize)
    → Tight C++ loop: call process() with pre-allocated output buffers (no audio device)
    → Accumulate output samples into host-side float array
    → Write completed array to disk via AVAudioFile
    → Return file URL to Swift
```
No AVAudioEngine involved — runs faster than real-time, pure C++ in the ObjC++ wrapper.

- **Phase 0:** host feeds decoded PCM file data as `inputBuffers` each iteration (patch reads from `in~` inlets as usual)
- **Phase 1:** host passes null/empty `inputBuffers`; patch reads from its internal `audioInput` buffer~ and handles all playback logic internally

**C. Direct buffer~ read** *(future — bypasses DSP entirely)*
```
ObjC++ wrapper calls releaseDataBuffer(id) on CoreObject
    → Returns a DataBuffer; call .data() to get float* pointer to raw PCM
    → Write directly to AVAudioFile (no process() loop needed)
    → Return file URL to Swift
```
Shortcut for cases where the RNBO patch has already deposited finished audio into a `buffer~`
and no further DSP is required before export.

### MIDI File Export (only direction needed)

Both approaches use the same `EventHandler` subclass in the ObjC++ wrapper and the same swift-midi-file write step on the Swift side. The only difference is whether `process()` is driven by AVAudioEngine or a manual loop.

**A. Real-time capture** *(Workflow 1b — real-time export during live session)*
```
AVAudioSourceNode drives process() on the audio thread
    → RNBO EventHandler (in ObjC++) receives MidiEvent objects per block
    → ObjC++ wrapper accumulates events with timestamps in a host-side array
    → On export trigger: passes array of (time, bytes) to Swift
    → swift-midi-file (Swift) assembles MidiFile and writes .mid to disk
```

**B. Offline capture** *(Workflows 1a, 2a, 2b — offline export)*
```
ObjC++ wrapper calls prepareToProcess(sampleRate, blockSize)
    → Tight C++ loop: call process(), then drainEvents() after each block
    → RNBO EventHandler accumulates MidiEvent objects with computed timestamps
    → On loop completion: passes array of (time, bytes) to Swift
    → swift-midi-file (Swift) assembles MidiFile and writes .mid to disk
```
Runs faster than real-time. Works identically to offline audio rendering (Export approach B)
and can be combined with it to produce both an audio file and a MIDI file from a single offline pass.

**swift-midi-core + swift-midi-file** (orchetect, MIT licensed, Swift-native, iOS + macOS):
- `swift-midi-core`: core MIDI types; `swift-midi-file`: Standard MIDI File read/write
- Clean Swift API for constructing and writing Standard MIDI Files
- No C++ or ObjC bridge needed for the file writing step
- Note: formerly known as `MIDIKit` / `MIDIKitSMF`; `orchetect/MIDIKit` now redirects to the `orchetect/swift-midi` umbrella repo

---

## On JUCE: When to Add It

| Phase | JUCE needed? | Reason |
|---|---|---|
| macOS standalone (Phase 0 + 1) | No | AVAudioEngine is sufficient |
| iOS app (Phase 2) | No | Same AVAudioEngine stack |
| Web app (Phase 3) | No | RNBO JS export is the path, not JUCE Emscripten; React UI built here is reused in Phase 4 |
| VST3/AU plugins (Phase 4) | Yes | JUCE AudioProcessor handles the full plugin API surface; WebBrowserComponent hosts the Phase 3 React UI |

Adding JUCE to the standalone app now for "future-proofing" buys little — the refactor at plugin time is bounded to replacing one wrapper layer, not a full rewrite. Starting without JUCE keeps the build system simpler (pure Xcode, no Projucer/CMake) for Phases 0–2.

---

## Recommended Stack (Final Summary)

| Layer | Technology | Phase 0 (MVP) | Phase 1+ |
|---|---|---|---|
| UI | SwiftUI | ✓ | ✓ |
| Bridging | ObjC++ (.mm) wrapper | ✓ | ✓ |
| Real-time audio I/O | AVAudioEngine + AVAudioSourceNode | ✓ | ✓ (replaced by JUCE at Phase 4) |
| DSP | RNBO exported C++ (`CoreObject`) | ✓ | ✓ (unchanged across all phases) |
| Host PCM array + playhead | ObjC++ wrapper (streams file data via `inputBuffers`) | ✓ | not needed |
| Audio file load into patch | AVAudioFile + AVAudioPCMBuffer → `setExternalData()` | not needed | ✓ |
| Offline export (audio + MIDI) | `process()` loop in ObjC++ wrapper | ✓ | ✓ |
| Audio file encode (export) | AVAudioFile | ✓ | ✓ |
| MIDI real-time output | CoreMIDI | future (not needed for Phase 0) | future |
| MIDI file export | swift-midi-core + swift-midi-file | ✓ | ✓ |
| Web audio (Phase 3) | RNBO JS export + React UI | separate project | separate project |
| Plugins (Phase 4) | JUCE AudioProcessor + WebBrowserComponent (React UI) + Projucer | replaces AVAudioEngine wrapper only | replaces AVAudioEngine wrapper only |

---

## Verification / Testing Approach

**Phase 0 MVP — streaming I/O patch, no internal buffer~:**

*Setup:*
1. Export current RNBO patch (stereo `in~` / `out~`, MIDI output) to C++ target
2. Build Xcode project: SwiftUI app, ObjC++ wrapper `.mm`, RNBO C++ sources

*Workflow 1a — Import file → real-time processing & playback → offline export:*
3. Decode a WAV file → host PCM array → stream through `process()` inputBuffers via AVAudioSourceNode → confirm processed audio output is audible and parameters adjustable in real time
4. Verify offline audio export: call `prepareToProcess(force=true)`, reset playhead, run `process()` loop feeding same PCM array, write output to AVAudioFile (Audio Export approach B)
5. Verify offline MIDI export: confirm EventHandler accumulates MidiEvents during offline loop → write `.mid` file with swift-midi-file

*Workflow 1b — Import file → real-time processing & playback → real-time export:*
6. During real-time playback (step 3), simultaneously write `process()` output to AVAudioFile and accumulate MidiEvents → confirm both output files produced correctly

*Workflow 2b (Step 9) — Record live input → no monitoring → offline export:*
7. Grant mic permission; press Record → confirm raw input is written to the temp AVAudioFile (Branch A) while RNBO is fed silence (no live-input monitoring) and any prior effects tail rings out; confirm the live red 60 s waveform scrolls and the `MM:SS.MMM` position display counts up in red
8. Press Stop → confirm the recording auto-loads into the host PCM array (playhead reset, thumbnail refreshed) → confirm offline export (step 4) produces consistent output

*Workflow 2a (Step 9.5) — Record live input → monitor real-time processing → offline export:*
9. With monitoring enabled, press Record → confirm simultaneous raw write to AVAudioFile (Branch A) and ring-buffer delivery to RNBO `process()` inputBuffers with audible processed output (Branch B)
10. Toggle monitoring off mid-record → confirm output falls to silence (render block feeds silence) while Branch A recording continues; after stop, confirm offline export matches the Workflow 2b result

**Phase 1 — RNBO patch w/ internal `audioInput` buffer~ (validate when patch gains buffer~):**
11. Verify `setExternalData()` import: decode WAV → `setExternalData("audioInput")` → confirm patch reads and plays from buffer~ with null `inputBuffers`
12. Verify offline render: call `prepareToProcess(force=true)`, run `process()` loop with null `inputBuffers` → confirm patch re-reads from buffer~ → write output to AVAudioFile and swift-midi-file
13. Verify direct buffer~ read export: call `releaseDataBuffer()`, write `DataBuffer::data()` directly to AVAudioFile (Audio Export approach C)
14. Verify Workflows 2a/2b → Phase 1 handoff: after recording stops, decode written file → `setExternalData("audioInput")` → confirm parity with Workflow 1a import path

---

## Next Steps: Phase 0 MVP Implementation

### Step 1 — Prepare the RNBO Patch (IMPLEMENTED)

1. Confirm the patch has stereo `in~` and `out~` signal inlets and at least one MIDI output object.
2. Export the patch to the **C++ target** in RNBO. Note the output folder location — it contains a `rnbo/` subfolder (the RNBO runtime) and a generated patch C++ file.

---

### Step 2 — Create the Xcode Project (IMPLEMENTED)

1. Create a new **macOS App** in Xcode, with SwiftUI as the interface and Swift as the language.
2. In **Build Settings**:
   - Set **C++ Language Dialect** to C++17 or later (RNBO requires C++17 minimum; C++20 or C++23 are fine).
   - **C++ Standard Library** does not need to be set — on macOS, `libc++` is the only available standard library and is used by default. There is no separate setting for it in current Xcode.
3. Create a `BridgingHeader.h` file and add it to the project.
4. Set it as the bridging header in **Build Settings → Swift Compiler - General → Bridging Header**. Enter the path relative to the project root, e.g. `$(PROJECT_NAME)/BridgingHeader.h` (or the literal folder name if your project name contains hyphens, e.g. `Percussion-to-MIDI/BridgingHeader.h`).
   - Note: in current Xcode the setting is labelled "Bridging Header" under "Swift Compiler - General", not "Objective-C Bridging Header".
   - The separately-listed "Generated Header Name" field (pre-populated with `$(PROJECT_NAME)-Swift.h`) is unrelated — it controls an auto-generated Swift→ObjC header. Leave it as-is.

---

### Step 3 — Integrate RNBO C++ Sources (IMPLEMENTED)

1. Add the entire RNBO export folder to the Xcode project (drag in; uncheck "Copy items if needed" to keep it as an external reference, or leave it checked to copy). **When Xcode presents the "Add to targets" sheet during the drag, uncheck the target checkbox** — do not let Xcode auto-add files to Compile Sources or Copy Bundle Resources. You will add the specific files you need manually below.
2. Add two entries to **Header Search Paths** in Build Settings (both non-recursive):
   - `$(SRCROOT)/$(PROJECT_NAME)/RNBO/rnbo`
   - `$(SRCROOT)/$(PROJECT_NAME)/RNBO`
3. In **Build Phases → Compile Sources**, add exactly **two** `.cpp` files:
   - `RNBO.cpp` — the RNBO runtime unity build file, at `RNBO/rnbo/RNBO.cpp`. This file `#include`s all necessary RNBO runtime `.cpp` files internally. Do not add any other individual RNBO runtime `.cpp` files or you will get duplicate symbol errors.
   - Your generated patch `.cpp` file (e.g. `rnbo_your-patch-name.cpp`, at the top level of the RNBO export folder).
   - Do **not** add anything from `rnbo/adapters/` (JUCE, Max, WebAssembly adapters), `rnbo/src/platforms/nostdlib/` (bare-metal platform files), `rnbo/src/*U.cpp` / `rnbo/common/*U.cpp` (JUCE-based unit tests), or `rnbo/test/` (test harness including `main.cpp` — this will conflict with your app entry point).
4. In **Build Phases → Copy Bundle Resources**, remove any RNBO files that Xcode may have auto-added (LICENSE files, `.cmake`, `.json`, `.js`, `.plist.in` files, etc.). Keep only `Assets.xcassets` and any audio sample files your patch uses (e.g. `.wav` files from the `media/` folder).
5. **Xcode 26 / Apple Clang compatibility patch:** The RNBO runtime has a bug in `rnbo/common/RNBO_PatcherStateInterface.h` that newer Apple Clang correctly rejects. At line 34, change the rvalue assignment operator return type from `T&` to `T`:
   ```cpp
   // Before:
   template <typename T> T& operator=(T&& val) {
       _state.add(_key, val);
       return val;
   }
   // After:
   template <typename T> T operator=(T&& val) {
       _state.add(_key, val);
       return std::forward<T>(val);
   }
   ```
   This is a Cycling '74 bug (returning a reference to a temporary) that should be fixed in a future RNBO release.
6. Clean build folder (⇧⌘K) and build (⌘B). Confirm the project compiles cleanly before proceeding.

---

### Step 4 — Add swift-midi packages via Swift Package Manager (IMPLEMENTED)

Note: the MIDIKit package has been rebranded. The old `orchetect/MIDIKit` URL now redirects to the `orchetect/swift-midi` umbrella repo. Add the two individual packages you need directly:

1. In Xcode → File → Add Package Dependencies, add each of the following URLs separately:
   - `https://github.com/orchetect/swift-midi-core` — core MIDI types (formerly `MIDIKit` / `MIDIKitCore`)
   - `https://github.com/orchetect/swift-midi-file` — Standard MIDI File read/write (formerly `MIDIKitSMF`)
2. Add the libraries from each package to the app target when prompted.
3. `MIDIKitIO` (real-time MIDI device I/O) is **not** needed for Phase 0 — MIDI output to hardware devices is deferred to a future phase.

---

### Step 5 — Create the ObjC++ Wrapper Skeleton (IMPLEMENTED)

Create two files: `AudioEngine.h` (pure ObjC interface, imported by the bridging header) and `AudioEngine.mm` (ObjC++ implementation, mixes ObjC and C++ freely).

`AudioEngine.h` — define the public interface Swift will call. Wrap the ObjC parts in `#ifdef __OBJC__` so the header is safely includable from pure C++ translation units (e.g. RNBO internals):
```objc
#ifndef AudioEngine_h
#define AudioEngine_h

#ifdef __OBJC__
#import <Foundation/Foundation.h>

@interface AudioEngine : NSObject
- (void)start;
- (void)stop;
- (void)setParameterWithIndex:(int)index value:(float)value;
@end
#endif

#endif /* AudioEngine_h */
```

`AudioEngine.mm` — add the RNBO include and instantiate `CoreObject` as a private ivar. Replace `rnbo_your-patch-name.cpp` with the actual generated patch filename:
```objc
#import "AudioEngine.h"
#include "rnbo/RNBO.h"
#include "rnbo_your-patch-name.cpp"   // generated RNBO patch file

@implementation AudioEngine {
    RNBO::CoreObject _coreObject;
}
@end
```

**Important:** When Xcode adds the generated `.cpp` patch file to the project, it will also add it to "Compile Sources". Remove it from **Build Phases → Compile Sources** — it must only be pulled in via `#include` from `AudioEngine.mm`, not compiled as a separate translation unit, or you will get duplicate symbol linker errors.

Import `AudioEngine.h` in the bridging header. Confirm the project builds before proceeding.

---

### Step 6 — Set Up AVAudioEngine and AVAudioSourceNode (IMPLEMENTED)

In `AudioEngine.mm`:

1. Add `AVFoundation` import and `AVAudioEngine` / `AVAudioSourceNode` ivars.
2. In `-start`, configure and start the engine with an `AVAudioSourceNode` render block that calls `_coreObject.process()`:

```objc
_sourceNode = [[AVAudioSourceNode alloc] initWithRenderBlock:^OSStatus(
    BOOL *isSilence, const AudioTimeStamp *timestamp,
    AVAudioFrameCount frameCount, AudioBufferList *outputData) {

    // Fill inputBuffers from host PCM array (playhead-based streaming)
    // Call _coreObject.process(inputBuffers, 2, outputBuffers, 2, frameCount)
    // Copy outputBuffers into outputData
    return noErr;
}];
```

3. Call `_coreObject.prepareToProcess(sampleRate, maxFrameCount)` before starting the engine.
4. Connect `_sourceNode` → `engine.mainMixerNode` → `engine.outputNode` and call `[_engine startAndReturnError:]`.
5. Expose `-start` / `-stop` to Swift. In `ContentView.swift`, add a stateful **Play / Stop** toggle button that calls `engine.start()` / `engine.stop()`. Confirm audio output is running (silence at this point is expected).

---

### Step 7 — Implement Audio File Import (IMPLEMENTED)

In `AudioEngine.mm`:

1. After `[_engine startAndReturnError:]`, read the engine's actual negotiated format:
   - Query `engine.outputNode.outputFormatForBus(0)` for the real `sampleRate` and maximum frames per slice.
   - Re-call `_coreObject.prepareToProcess(realSampleRate, realMaxFrames)` with these values so RNBO is configured for what the hardware actually delivers.
2. Add ivars for the host PCM float array, total frame count, channel count, and an atomic playhead position.
3. Add a method `-loadAudioFileFromURL:(NSURL *)url`:
   - Open with `AVAudioFile` and inspect its `fileFormat.sampleRate`.
   - If the file sample rate matches the engine rate, read directly into `AVAudioPCMBuffer`.
   - If they differ, resample via `AVAudioConverter` to produce a buffer at the engine's sample rate before storing.
   - Extract `floatChannelData` pointers, copy into the host-owned float array.
   - Reset playhead to 0.
4. In the `AVAudioSourceNode` render block, advance the playhead and feed the PCM array into `process()` `inputBuffers` each block. Handle end-of-file (stop advancing or loop, depending on desired behaviour).
5. Expose `-loadAudioFileFromURL:` to Swift. Wire up a `SwiftUI FileImporter` in `ContentView.swift` that calls it on file selection and starts playback.
6. Verify: import a WAV file and confirm processed audio is audible through the output.

---

### Step 8 — Implement Parameter Control (IMPLEMENTED)

1. Add `-setParameterWithIndex:(int)index value:(float)value` to the wrapper, calling `_coreObject.setParameterValue(index, value)`.
2. Call `_coreObject.getNumParameters()` and `_coreObject.getParameterInfo(i)` to retrieve parameter names, ranges, and defaults.
3. In SwiftUI, add a control for each of the primary parameters, and confirm parameter changes affect the processed output during playback:
  - `Parameter (control type: value range, default value)`
  - Onset/enable (toggle: 0/1, default: 0)
  - Onset/needs_init (toggle: 0/1, default: 0)
  - OnsetInput (rotary slider: -77 - 0, default: -22)
  - EnableTraining (toggle: 0/1, default: 0)
  - SpecFlatCutoff (horizontal spectral slider w/ live histogram: 0.0 - 1.0, default: 0.1)
  - SpecCentCutoff (horizontal spectral slider w/ live histogram: 0 - 5000, default: 2100)
  - Input_dB (rotary slider: -77 - 18, default: -6)
  - InputDelaySend_dB (rotary slider: -77 - 18, default: -77)
  - DrumSynthOutput_dB (rotary slider: -77 - 18, default: 0)
  - DrumSynthDelaySend_dB (rotary slider: -77 - 18, default: -77)
  - DelayOutput_dB (rotary slider: -77 - 18, default: 0)
  - SynthMode (2-state toggle: 0/1, default: 1)
  - GreyholeDelayFX_Controller/GreyholePreset (horizontal slider w/ discrete positions: 0 - 8, default: 0)
  - GreyholeDelayFX_Controller/GreyholePreset (`dice`-icon push button (fixed output): 9) #randomizes GreyholePreset


---

### Step 9 — Live Audio Input Recording *without* Input Monitoring (Workflow 2b) (IMPLEMENTED)

**Goal:** Record live input to disk with **no** monitoring, then hand off to the file-playback pipeline (Workflow 1a/1b). No ring buffer and no `bypass` parameter — "no monitoring" is the always-alive engine's existing stopped state: the render block keeps calling `core->process()` with silence when `_isPlaying == false` (see *Keep `AVAudioEngine` Alive Across Stop/Play Cycles*).

#### Prerequisites — microphone permission

1. **Usage string:** `INFOPLIST_KEY_NSMicrophoneUsageDescription` build setting (project uses `GENERATE_INFOPLIST_FILE = YES`, so there is no physical `Info.plist`).
2. **Sandbox entitlement:** `com.apple.security.device.audio-input`, via the `ENABLE_RESOURCE_ACCESS_AUDIO_INPUT = YES` build setting (sandbox is build-setting-driven; no `.entitlements` file).
3. **Runtime gate:** `AVCaptureDevice.requestAccess(for: .audio)` before the first record; on denial, show an alert pointing to System Settings.

#### `AudioEngine.mm` / `AudioEngine.h`

1. Recording ivars: `AVAudioFile *_recordFile`, `NSURL *_recordURL`, `std::atomic<bool> _isRecording`, `std::atomic<int64_t> _recordedFrames`, and a `LiveWaveform` accumulator.
2. `-startRecordingToURL:` — query the input node's format, open `_recordFile` at that format, then **stop the engine, install a tap on `inputNode` (bus 0), and restart** (see *I/O reconfiguration*). The tap (**Branch A only**) writes each buffer to `_recordFile`, adds to `_recordedFrames`, and folds its min/max into `_liveWaveform`. Set `_isPlaying = false` so RNBO receives silence; do **not** advance the playhead. On restart failure, remove the tap and restart output-only.
3. `-stopRecording` — **stop, remove the tap, restart output-only**, release `_recordFile` (finalizes the file on disk), and return `_recordURL` (nil on failure). The Swift layer loads it via the shared load path.
   - **Temp file is transient.** After loading it, `finishRecording` deletes the temp file — its samples are in the in-memory PCM array and exports render from there, so recordings don't accumulate in the container `tmp`. A failed record-start also removes its empty file.
   - **No filename shown for takes.** `loadFile(displayName:)` gets `nil` for a recording (the temp file is gone), so the header stays blank; imports still pass the file's name. A separate `audioLoaded` flag keeps the transport enabled either way.
4. **No render-block changes** — the existing `!_isPlaying → silence` branch already feeds RNBO silence. (The ring-buffer input read is Step 9.5.)
5. **Live recording waveform (60 s scrolling):** `LiveWaveform` holds 2048 min/max bins for the current 60 s window; the tap folds each buffer in by frame position and wraps (clears + refills) at each 60 s boundary. Exposed as `isRecording`, `recordingElapsedMs` (drives `MM:SS.MMM`), and `recordingWaveformBins` (min/max `Float32` pairs, same layout as `waveformThumbnailData`). A lightweight mutex guards the bins — tap blocks tolerate it (unlike the real-time render block), so Branch A needs no ring.

> **I/O reconfiguration.** One `AVAudioEngine` drives a single shared HAL unit for input and output, so installing/removing the input tap must happen while the engine is **stopped**. `-startRecordingToURL:` and `-stopRecording` therefore bracket the tap change with `[_engine stop]` … `[_engine startAndReturnError:]` (the same pattern offline render uses); this briefly interrupts any ringing effects tail. A failed start recovers output-only. `-loadAudioFileFromURL:` has a zero-frame guard so an empty file fails cleanly.
>
> **Configuration-change recovery.** `-handleConfigurationChange:` observes `AVAudioEngineConfigurationChangeNotification`; `-reconfigureAfterConfigurationChange` rebuilds source→mixer→output and restarts when a device change stops the engine — skipped while `_offlineRenderActive` or while the engine is still running; an in-progress take is finalized and reported via `recordingInterruptedHandler`.

#### Handoff on stop (Workflow 2b → Workflow 1a/1b)

`-stopRecording` returns the temp URL; the Swift layer loads it via `loadFile(url:)` — the shared helper `.fileImporter` also uses (thumbnail regen; reset of `midiNoteOverlay`, snapshots, coverage, spectral histograms; `loadedFileName`). A recording then behaves exactly like an imported file.

#### SwiftUI — transport UI (matches the mockups)

1. **Playhead Position display (new), `MM:SS.MMM`,** placed to the left of the rewind (`backward.end.fill`) button:
   - Not recording: current playhead time = `playheadFraction × totalDurationMs`.
   - Recording: `engine.recordingElapsedMs`, text tinted **red**.
2. **Record button**, to the right of the Play/Stop button:
   - Idle: default `.bordered` button with a red `circle.fill` icon.
   - Recording (active): `.borderedProminent` with a red tint and a **white** `circle.fill`.
   - Action: request mic access (first time) → `engine.startRecordingToURL:(tempURL)`.
3. **Play → Stop swap while recording:** during recording the Play button shows `stop.fill` and its action **stops recording** (`engine.stopRecording()` → shared `loadFile(url:)`). Pressing either the Stop button or the Record toggle ends the take.
4. **Live red waveform + advancing playhead:** while `engine.isRecording`, `WaveformView` strokes `recordingWaveformBins` in **red** up to the recording playhead and advances the yellow playhead by `(recordingElapsedMs mod 60 000) / 60 000` — which wraps to 0 every 60 s, so the display reads as a blank refill. The existing 30 fps `TimelineView` feeds the live bins + recording fraction instead of the file thumbnail / `playheadFraction`.
5. **No MIDI overlay during recording.** Because RNBO receives silence in Workflow 2b, no onsets are detected while recording — the note overlay stays empty during the take. Onset detection on the recorded audio happens *after* Stop, once the recording is loaded, via the normal **Analyze** / offline path.
6. **Mutual exclusion:** disable **Import / Analyze / Export** while recording, and disable **Record** while playing/exporting/analyzing. Recording, playback, and offline render all contend for the single-threaded `CoreObject`, and offline render additionally stops the engine (which would drop the input tap).

#### Verification

1. Grant mic permission on first Record; the deny path shows an "enable in System Settings" prompt and does not start recording.
2. Press Record → red waveform fills left→right, the yellow playhead advances, the position display counts up in red `MM:SS.MMM`; a delay/reverb tail from prior playback rings out and decays. Confirm you do **not** hear your live input (RNBO is fed silence, not the mic).
3. Let recording pass 60 s → the waveform blanks and refills from the left; the position display keeps climbing past `01:00.000`.
4. Press Stop (or the Record toggle) → the take auto-loads: the static blue thumbnail replaces the red waveform, the playhead resets to 0, and the filename updates.
5. Run **Analyze** / **Export MIDI** on the loaded recording → onsets detect normally, exactly as for an imported file.
6. Confirm Import/Analyze/Export are disabled during recording, and Record is disabled during playback/export.

---

### Step 9.5 — Live Audio Input Recording *with* Input Monitoring (Workflow 2a)

**Goal:** Everything in Step 9, plus **real-time monitoring** — the user hears their live input processed through RNBO while recording. This is where the lock-free ring buffer (Branch B) and the render-block input read are introduced. Builds directly on Step 9; only the additions are listed.

#### `AudioEngine.mm`

1. **Add the lock-free ring buffer (Branch B).** A single-producer / single-consumer float ring (reuse the SPSC pattern already used by `MidiEventCapture` / `MessageEventCapture`), sized for ~100 ms of stereo audio at the engine sample rate. Producer = the input tap; consumer = the `AVAudioSourceNode` render block.
2. **Input-format conversion.** The input node's format (sample rate / channel count) may differ from the engine's stereo render format. Convert each tap buffer to stereo @ `_engineSampleRate` (via `AVAudioConverter`, exactly as `-loadAudioFileFromURL:` already does) **before** writing it into the ring. Branch A still writes the raw, unconverted input to `_recordFile`.
3. **Render-block read (the only render-block change in the whole feature).** When monitoring is active, the render block reads a block of frames from the ring and passes them as RNBO `process()` `inputBuffers` in place of the silence/PCM branch. Ring underrun (empty) → feed silence for that block. This is the one spot that must remain strictly real-time safe (no locks, no allocations) — hence the SPSC ring.
4. **Monitoring toggle = input source, not a `bypass` parameter.** A `std::atomic<bool> _monitoring` selects the render-block input source: `true` → ring buffer (hear processed live input, Workflow 2a); `false` → silence (the Step 9 / Workflow 2b behavior). No RNBO `bypass` parameter is involved. Expose `-setMonitoringEnabled:` and `@property (readonly) BOOL monitoringEnabled;`.

#### Threading note

The `inputNode` tap and the `AVAudioSourceNode` render block run on separate audio threads; `CoreObject` is single-threaded, so the SPSC ring bridges them — the tap writes converted input samples, the render block reads them for `process()`. This is the standard real-time input-monitoring pattern and is introduced only here (Step 9.5), never in Step 9.

#### SwiftUI

1. **Monitoring toggle** in the transport (e.g. a `headphones` / `speaker.wave.2` icon toggle) → `engine.setMonitoringEnabled(...)`. Default **off**, so Record defaults to the Workflow 2b (no-monitor) behavior; toggling on switches the live take to Workflow 2a.
2. **MIDI overlay during monitored recording (optional).** With monitoring on, RNBO processes live input and emits onsets, so the existing real-time overlay path (`beginRealTimeCapture` + `collectAndClearRealTimeMidiEvents`, `pollRealTimeMidiEvents` in `ContentView`) *can* populate the overlay live during a take. Recommended: enable it, reusing the existing real-time poller, so monitored input shows detected notes as they happen. (In Step 9 this path is dormant because the input is silent.)

#### Verification

1. Enable monitoring, press Record → you hear your live input processed through RNBO (delay / reverb / synth per current params); adjusting parameters changes the monitored sound in real time.
2. Toggle monitoring off mid-take → monitored output drops to silence (render block feeds silence) while Branch A recording continues uninterrupted; toggle back on → monitoring resumes.
3. After Stop, the recorded (raw) file loads and offline export matches the Workflow 2b result — export is from the loaded raw file and is independent of what was monitored.
4. Confirm no audio dropouts/glitches at record start (ring priming) or under sustained onsets (ring never audibly overflows/underflows).

---

### Step 10 — Implement the MIDI EventHandler (IMPLEMENTED)

In `AudioEngine.mm`:

1. Create a nested C++ class or standalone subclass of `RNBO::EventHandler` that overrides `handleMidiEvent()` and appends incoming `RNBO::MidiEvent` objects to a host-side `std::vector` with their timestamps.
2. Register the handler with `_coreObject` via `createParameterInterface()`.
3. After each `process()` call (both real-time and offline loop), call `drainEvents()` to flush pending events to the handler's accumulation buffer.
4. Add a method `-collectAndClearMidiEvents` that returns the accumulated events as an `NSArray` of value objects (timestamp + raw bytes) and resets the buffer. Expose to Swift.

---

### Step 11 — Implement Offline Audio and MIDI Export (IMPLEMENTED)

In `AudioEngine.mm`, add two separate methods — `-renderOfflineAudioToURL:(NSURL *)url` and `-renderOfflineMIDIToURL:(NSURL *)url` — each running the same offline processing loop but writing to a different output:

1. Suspend or bypass the live `AVAudioEngine` session if running.
2. Call `_coreObject.prepareToProcess(sampleRate, blockSize, true)` to reset DSP state while preserving parameters.
3. Reset the host PCM playhead to 0.
4. Clear the MIDI EventHandler accumulation buffer.
5. **Audio method**: allocate output float buffers and open an `AVAudioFile` at `url` for writing.
6. Loop over the full PCM array in blocks: call `process()` feeding PCM as `inputBuffers`, write output frames to the `AVAudioFile` (audio method) or skip writing (MIDI method), and call `drainEvents()` each iteration.
7. **Audio method**: close the `AVAudioFile`. **MIDI method**: pass the accumulated events to Swift via `-collectAndClearMidiEvents`, then use swift-midi-file to assemble and write a Standard MIDI File to `url`.
8. In `ContentView.swift`, expose two separate buttons — **Export Audio (Offline)** and **Export MIDI (Offline)** — each presenting its own save panel dialogue and calling the corresponding method. *(Now rendered as SF Symbol icon buttons in the main toolbar.)*
9. Verify using Verification steps 4–5 from the Verification section above.

---

### Step 12 — Implement Real-time Audio and MIDI Export (Workflow 1b)

In `AudioEngine.mm`:

1. Add an `AVAudioFile` writer ivar and an atomic real-time audio-capture flag.
2. Add `-startCapturingAudioToURL:(NSURL *)url` / `-stopCapturingAudio` methods that set the flag and open/close the writer.
3. In the `AVAudioSourceNode` render block, when the audio-capture flag is set, write each output buffer to the writer alongside normal playback.
4. MIDI capture during real-time export is handled automatically by the EventHandler accumulation already implemented in Step 10. Add `-startCapturingMIDI` / `-stopCapturingMIDI` methods that start/stop accumulation; on stop, call `-collectAndClearMidiEvents` and pass the result to swift-midi-file to write the file.
5. In `ContentView.swift`, expose two separate toggle buttons — **Record Audio (Real-time)** and **Record MIDI (Real-time)** — each with its own save panel dialogue and calling its corresponding start/stop methods independently.
6. Verify using Verification step 6 from the Verification section above.

---

### Step 13 - Implement Audio Waveform Display (IMPLEMENTED)

Analogous to JUCE's `AudioThumbnail`, the implementation separates three concerns:

1. **Thumbnail computation** — done once on file load, on a background thread. Downsamples the raw left-channel PCM into N (min, max) float pairs by scanning equal-sized bins.
2. **Waveform rendering** — done at draw time using SwiftUI `Canvas`. Draws one vertical line segment per bin in a single path pass.
3. **Playhead animation** — driven by `TimelineView` polling `engine.playheadFraction` at 30 fps. The engine's `_playhead` is an `std::atomic<int64_t>`, safe for a lock-free read from the main thread.

See **Audio Waveform Display (Step 13)** in the *Architectural Notes* section for the full implementation details and deviations from this plan.

#### Verification

1. Launch app → waveform area shows dark background with "Import an Audio File" placeholder text.
2. Import mono audio file → waveform renders with visible amplitude envelope.
3. Import stereo audio file → waveform renders (left channel).
4. Press Play → yellow playhead traverses waveform at a rate consistent with audio duration.
5. Press Stop → playhead line persists at stopped position.
6. Press Rewind → playhead snaps to left edge.
7. Click on waveform while stopped → playhead jumps to clicked position.
8. Drag across waveform while stopped → playhead scrubs continuously.
9. Click/drag on waveform during playback → playhead seeks; audio continues from new position.
10. Import new file while one is already loaded → waveform updates to new file's shape.
11. Resize window → waveform scales horizontally without distortion.

### Step 14 - MIDI Note Overlay (IMPLEMENTED)

Overlays rectangles representing RNBO onset-detection output on top of the `WaveformView`, allowing users to see how detected MIDI notes align with the audio waveform and adjust Onset parameters accordingly. The RNBO patch outputs exactly two notes — **C1 (note 36, kick)** and **D1 (note 38, snare)** — so no piano-roll y-axis is needed; two fixed horizontal strips with a vertical offset matching their pitch relationship is sufficient.

The overlay is populated from two sources:
- **Offline analysis** — a full offline render pass triggered by "Analyze" or "Export MIDI"
- **Real-time capture** — notes are accumulated into the overlay incrementally as the transport plays through the file

#### Visual design

Two horizontal strips occupy the lower third of the waveform view. Each detected note is drawn as a semi-transparent filled rounded rectangle whose:
- **x-position** scales `(onsetMs - midiLatencyCompensationMs) / totalDurationMs` by view width to a horizontal start coordinate, compensating for the RNBO patch's I/O processing latency so rectangles align visually with their waveform onsets (clamped to 0 so notes near the file start don't render off-screen)
- **width** maps `durationMs / totalDurationMs` to view width (minimum 2 pt so zero-width events are still visible)
- **y-position** is fixed per note number: D1 strip sits above the C1 strip, reflecting their relative pitch
- **color** distinguishes the two drums: C1 (kick) in warm orange, D1 (snare) in cyan
- **opacity / color shift** reflects freshness: **stale** notes (detected with now-changed parameters) are drawn in grey at 0.35 opacity; **fresh** notes use the full orange/cyan colors at 0.75 opacity

The strips are drawn after the waveform lines and before the playhead line so both remain visible.

#### Data model

`MIDINoteEvent` lives in `WaveformView.swift`:

```swift
struct MIDINoteEvent {
    let note: UInt8        // 36 = C1 kick, 38 = D1 snare
    let velocity: UInt8
    let onsetMs: Double
    let durationMs: Double
    var isStale: Bool = false
}
```

`isStale` is `false` for notes freshly produced by either an offline pass or real-time capture. It is set to `true` in bulk when onset tuning parameters change (see staleness marking below).

#### Note-pairing helper

`pairMIDIEvents(_:) -> [MIDINoteEvent]` in `ContentView.swift` converts the raw `[[String: Any]]` from `collectAndClearMidiEvents()` into matched On/Off pairs. Used by the offline paths only (real-time pairing uses `pollRealTimeMidiEvents`, described below):

1. Sort events by `timestampMs`.
2. Maintain a `[UInt8: (onsetMs: Double, velocity: UInt8)]` dictionary of open note-ons keyed by note number.
3. On Note On (`status nibble 0x9`, `velocity > 0`): insert into the open-notes dict.
4. On Note Off (`status nibble 0x8`, or Note On with `velocity == 0`): look up the matching open entry, compute `durationMs = offMs - onMs`, append a `MIDINoteEvent`, remove from dict.
5. After the loop, flush any unclosed note-ons with a 50 ms fallback duration.
6. Return sorted by `onsetMs`.

#### `AudioEngine` additions

**`sampleRate` property** (added in the initial Step 14 implementation) — exposes the hardware sample rate needed to compute `totalDurationMs`:

```objc
@property (readonly) double sampleRate;   // returns _engineSampleRate
```

**Real-time capture API** — two new methods for the real-time overlay path:

```objc
/// Call on the main thread immediately before start() and after setPlayheadPosition()
/// when seeking during active playback. Records the current playhead frame and sets a
/// flag for the render block to capture the matching RNBO engine time on the next
/// process() call.
- (void)beginRealTimeCapture;

/// Returns MIDI events accumulated during real-time playback since the last call, with
/// timestamps converted to file-relative milliseconds. Same dictionary format as
/// collectAndClearMidiEvents(). Safe to call from the main thread.
- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearRealTimeMidiEvents;
```

**Implementation — real-time timestamp anchor:** RNBO's time counter is cumulative and unrelated to the playhead position, so a per-session anchor is required to convert RNBO event timestamps to file-relative milliseconds. Three new ivars (all in the anonymous `@implementation` ivar block):

```objc
std::atomic<bool>     _needsRtAnchor;         // set by beginRealTimeCapture, cleared by render block
std::atomic<int64_t>  _rtAnchorPlayheadFrame; // playhead frame at beginRealTimeCapture time
std::atomic<uint64_t> _rtAnchorRnboTimeBits;  // RNBO engine time captured by render block
                                               // (IEEE 754 double stored as uint64_t for atomic access)
```

`beginRealTimeCapture` (main thread): stores `_playhead` into `_rtAnchorPlayheadFrame`, then sets `_needsRtAnchor = true`.

Render block: on the first block after `_needsRtAnchor` is true and `_isPlaying` is true, captures `core->getCurrentTime()` (before `process()` advances time), stores it as bit-cast `uint64_t`, clears the flag. Uses captured raw pointers (`needsRtAnchorPtr`, `rtAnchorBitsPtr`) to avoid implicitly capturing `self` in the block.

`collectAndClearRealTimeMidiEvents` (main thread): reads both anchor values, computes `fileRelativeMs = anchorFileMs + (rnboEventTime - anchorRnboMs)` where `anchorFileMs = anchorPlayheadFrame / sampleRate * 1000`, then drains and converts all accumulated events.

The shared `_midiCapture` buffer is safe to use for both paths: `_runOfflineLoopWritingTo:` calls `collectAndClear()` at its start to discard any accumulated real-time events, and offline renders only run after `stopForOfflineRender()` halts the audio engine.

#### `WaveformView` update

`midiNotes: [MIDINoteEvent]` and `totalDurationMs: Double` parameters added. Drawing pass between waveform stroke and playhead line.

**Latency compensation** — the RNBO patch's I/O processing introduces a consistent delay between a physical onset and the MIDI note timestamp it emits (empirically ~40 ms). Without compensation the overlay rectangles land visibly to the right of their waveform onsets. Two additions handle this:

- `private let rnboProcessingLatencyMs: Double = 40.0` — file-scope constant (hardcoded fallback). When a future update adds a `processingLatency` outport to the RNBO patch, replace this with the dynamic value passed through `midiLatencyCompensationMs`.
- `var midiLatencyCompensationMs: Double = rnboProcessingLatencyMs` — `WaveformView` property. Defaults to the constant so no call-site changes are required today; callers can pass a dynamic value later without any structural changes.

> **Superseded by Step 14.35:** the latency figure was moved to `AudioEngine` as the single source of truth
> (`kRnboProcessingLatencyMs`, exposed via the `processingLatencyMs` property). `WaveformView` no longer holds
> `rnboProcessingLatencyMs`; `midiLatencyCompensationMs` is now a required input, passed by `ContentView` as
> `engine.processingLatencyMs`. The snippet below reflects the original Step-14 form.

The x-position formula shifts each onset left by the latency amount and clamps to zero:

```swift
// file-scope constant (WaveformView.swift)
private let rnboProcessingLatencyMs: Double = 40.0

// WaveformView property
var midiLatencyCompensationMs: Double = rnboProcessingLatencyMs

// drawing loop
if !midiNotes.isEmpty && totalDurationMs > 0 {
    let stripHeight: CGFloat = 12
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
```

#### `ContentView` changes

**State:**

```swift
@State private var midiNoteOverlay: [MIDINoteEvent] = []
@State private var isMIDIAnalyzing: Bool = false
// nil = no analysis has run yet for the currently loaded file. Drives button enabled state only.
@State private var lastAnalyzedOnsetParams: [String: Float]? = nil
// Snapshot of onset tuning params in effect when midiNoteOverlay was last populated,
// by either offline analysis or real-time capture. Drives stale marking independently
// of lastAnalyzedOnsetParams (see implementation note on staleness marking below).
@State private var lastOverlayOnsetParams: [String: Float]? = nil
// Tracks real-time note-on events awaiting their matching note-off across polling intervals.
@State private var openRealTimeNoteOns: [UInt8: (onsetMs: Double, velocity: UInt8)] = [:]
// Accumulated real-time playback duration (ms) since the last reset event (param change,
// seek without full coverage, or file import). When >= totalDurationMs, the entire file
// has been processed in real-time with the current params, making an offline pass redundant.
@State private var realTimeCoverageMs: Double = 0
```

**Constants:**

```swift
// The five onset tuning parameters that determine overlay staleness.
// Onset/enable and Onset/needs_init are excluded — they don't alter detection sensitivity.
private static let onsetTuningParamIds: Set<String> = [
    "Onset/thresh", "Onset/relaxtime", "Onset/floor", "Onset/mingap", "Onset/medspan"
]

// Half-width of the time window (ms) for matching a fresh real-time note against an
// existing overlay note of the same pitch during loop overlap-replacement.
// Kept tight (5 ms) because RNBO DSP is deterministic — the same onset recurs at
// virtually the same timestamp on every loop.
private static let realtimeNoteReplaceWindowMs: Double = 5.0
```

**Computed properties and helpers:**

`paramsChanged(from:)` — shared comparison logic used by both dirty properties:

```swift
private func paramsChanged(from snapshot: [String: Float]) -> Bool {
    for (i, param) in store.params.enumerated()
        where Self.onsetTuningParamIds.contains(param.rnboId)
    {
        if abs((snapshot[param.rnboId] ?? Float.nan) - store.values[i]) > 0.0001 { return true }
    }
    return false
}
```

`currentOnsetParamSnapshot()` — captures the current onset tuning param values; used by offline analysis, export, and real-time polling:

```swift
private func currentOnsetParamSnapshot() -> [String: Float] {
    var snapshot: [String: Float] = [:]
    for (i, param) in store.params.enumerated()
        where Self.onsetTuningParamIds.contains(param.rnboId)
    {
        snapshot[param.rnboId] = store.values[i]
    }
    return snapshot
}
```

`onsetParamsDirty` — drives the "Analyze" button enabled state only. Returns `true` when no offline analysis has run yet for the current file, or when params have drifted from the last offline snapshot:

```swift
private var onsetParamsDirty: Bool {
    guard let last = lastAnalyzedOnsetParams else { return true }
    return paramsChanged(from: last)
}
```

`overlayParamsDirty` — drives stale marking. Compares against `lastOverlayOnsetParams` (set by both offline and real-time paths) so that real-time-only notes also grey out on param changes:

```swift
private var overlayParamsDirty: Bool {
    guard let last = lastOverlayOnsetParams else { return false }
    return paramsChanged(from: last)
}
```

`fullRealTimeCoverageAchieved` — `true` when the entire file has been processed in real-time with the current onset params, making an explicit offline pass redundant. Resets to `false` on param change, file import, or seek before full coverage:

```swift
private var fullRealTimeCoverageAchieved: Bool {
    totalDurationMs > 0 && realTimeCoverageMs >= totalDurationMs && !midiNoteOverlay.isEmpty
}
```

**Staleness marking** — `.onChange(of: overlayParamsDirty)` modifier on the root `VStack`. When the value transitions to `true`, all overlay notes are re-mapped with `isStale: true` and `realTimeCoverageMs` is reset (param change invalidates any accumulated coverage):

```swift
.onChange(of: overlayParamsDirty) { _, isDirty in
    if isDirty && !midiNoteOverlay.isEmpty {
        midiNoteOverlay = midiNoteOverlay.map {
            MIDINoteEvent(note: $0.note, velocity: $0.velocity,
                          onsetMs: $0.onsetMs, durationMs: $0.durationMs, isStale: true)
        }
    }
    if isDirty { realTimeCoverageMs = 0 }
}
```

**File import** — no auto-analysis. The overlay, both snapshots, and the coverage counter are cleared; `onsetParamsDirty` returns `true` (nil snapshot), enabling "Analyze" immediately:

```swift
midiNoteOverlay = []
lastAnalyzedOnsetParams = nil
lastOverlayOnsetParams = nil
openRealTimeNoteOns.removeAll()
realTimeCoverageMs = 0
```

**Play/stop button** — calls `beginRealTimeCapture()` before `start()` on play; flushes open real-time notes on stop:

```swift
if isPlaying {
    engine.stop()
    flushOpenRealTimeNotes()
} else {
    engine.beginRealTimeCapture()
    engine.start()
    store.pushAllValuesToEngine()
}
```

**Seek callback** — re-anchors timestamps and clears open notes. Coverage is only reset if full coverage has not yet been achieved: seeking after the whole file has already been processed in real-time is purely navigation and should not re-enable "Analyze":

```swift
engine.setPlayheadPosition(Int64(fraction * Double(engine.totalFrameCount)))
engine.beginRealTimeCapture()
openRealTimeNoteOns.removeAll()
if !fullRealTimeCoverageAchieved { realTimeCoverageMs = 0 }
```

**Real-time MIDI polling** — 15 fps timer fires while `isPlaying`. Each tick accumulates `1000/15` ms (~66.7 ms) toward `realTimeCoverageMs`:

```swift
.onReceive(Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()) { _ in
    guard isPlaying else { return }
    realTimeCoverageMs += 1000.0 / 15.0
    pollRealTimeMidiEvents()
}
```

**Real-time helpers:**

`mergeRealTimeNote(_:)` — inserts a fresh note, removing any same-pitch note within `realtimeNoteReplaceWindowMs` first (handles loop-iteration replacement):

```swift
private func mergeRealTimeNote(_ note: MIDINoteEvent) {
    let window = Self.realtimeNoteReplaceWindowMs
    midiNoteOverlay.removeAll { existing in
        existing.note == note.note && abs(existing.onsetMs - note.onsetMs) <= window
    }
    midiNoteOverlay.append(note)
}
```

`pollRealTimeMidiEvents()` — drains newly accumulated real-time events, pairs note-ons and note-offs across polling intervals, and merges completed notes into the overlay. After any note is successfully added, `lastOverlayOnsetParams` is updated so that a subsequent param change will trigger `overlayParamsDirty`'s `false → true` transition:

```swift
private func pollRealTimeMidiEvents() {
    let rawEvents = engine.collectAndClearRealTimeMidiEvents() ?? []
    var addedAnyNote = false
    for dict in rawEvents {
        guard let ms = dict["timestampMs"] as? Double,
              let bytes = dict["bytes"] as? Data, bytes.count >= 3 else { continue }
        let statusNibble = bytes[0] >> 4
        let note = bytes[1]; let velocity = bytes[2]
        if statusNibble == 0x9 && velocity > 0 {
            openRealTimeNoteOns[note] = (onsetMs: ms, velocity: velocity)
        } else if statusNibble == 0x8 || (statusNibble == 0x9 && velocity == 0) {
            if let entry = openRealTimeNoteOns[note] {
                mergeRealTimeNote(MIDINoteEvent(note: note, velocity: entry.velocity,
                    onsetMs: entry.onsetMs, durationMs: ms - entry.onsetMs, isStale: false))
                openRealTimeNoteOns.removeValue(forKey: note)
                addedAnyNote = true
            }
        }
    }
    if addedAnyNote { lastOverlayOnsetParams = currentOnsetParamSnapshot() }
}
```

`flushOpenRealTimeNotes()` — called on transport stop and when `stopTransportIfNeeded()` is used before offline exports. Closes any still-open note-ons with a 50 ms fallback duration and updates `lastOverlayOnsetParams` if any were flushed:

```swift
private func flushOpenRealTimeNotes() {
    var flushedAny = false
    for (note, entry) in openRealTimeNoteOns {
        mergeRealTimeNote(MIDINoteEvent(note: note, velocity: entry.velocity,
            onsetMs: entry.onsetMs, durationMs: 50, isStale: false))
        flushedAny = true
    }
    openRealTimeNoteOns.removeAll()
    if flushedAny { lastOverlayOnsetParams = currentOnsetParamSnapshot() }
}
```

**`analyzeMIDI()` method** — uses `currentOnsetParamSnapshot()` to capture the param snapshot before dispatching. On completion, sets both `lastAnalyzedOnsetParams` and `lastOverlayOnsetParams` to the same snapshot, so both `onsetParamsDirty` and `overlayParamsDirty` return `false` until the user changes a param.

**`exportMIDIOffline()`** — same snapshot behaviour as `analyzeMIDI`: updates `midiNoteOverlay`, `lastAnalyzedOnsetParams`, and `lastOverlayOnsetParams` from the same event batch at no extra cost.

**"Analyze" button** — enabled when `onsetParamsDirty` is true (no offline analysis yet, or params have changed), and additionally disabled when `fullRealTimeCoverageAchieved` is true (full file already processed in real-time with current params):

```swift
Button("Analyze") { analyzeMIDI() }
    .buttonStyle(.bordered)
    .disabled(!fileLoaded || isPlaying || isExporting || isMIDIAnalyzing
              || !onsetParamsDirty || fullRealTimeCoverageAchieved)
```

#### Trigger and staleness summary

| Event | Overlay | `isStale` | `realTimeCoverageMs` | Button state |
|---|---|---|---|---|
| App launch, no file | Empty | — | 0 | Disabled (no file) |
| File imported | Cleared | — | 0 | **Enabled** (no analysis yet) |
| Transport playing | Notes accumulate in real-time | `false` | Accumulating | Unchanged |
| Loop iteration | Same-position notes replaced | `false` | Accumulating | Unchanged |
| Full file played through in real-time | Complete | `false` | ≥ `totalDurationMs` | **Disabled** (full coverage) |
| Seek before full coverage | Unchanged | Unchanged | Reset to 0 | Unchanged |
| Seek after full coverage | Unchanged | Unchanged | Unchanged | Unchanged (still disabled) |
| Transport stopped | Open note-ons flushed | `false` | Unchanged | Unchanged |
| Onset tuning param changed | All notes marked stale | `true` | Reset to 0 | **Enabled** |
| `Onset/enable` / `Onset/needs_init` toggled | Unchanged | Unchanged | Unchanged | Unchanged |
| **Analyze** pressed | Replaced by offline result | `false` | Unchanged | Disabled (up-to-date) |
| **Export MIDI** pressed | Replaced from same event batch | `false` | Unchanged | Disabled (up-to-date) |
| New file imported | Cleared | — | 0 | **Enabled** (no analysis yet) |

#### Implementation note — RNBO timestamp normalisation

**Discovered during implementation.** RNBO's engine time counter is absolute and cumulative: `prepareToProcess(sr, blockSize, reset=true)` resets DSP state but does **not** reset the time counter. Event timestamps from `MidiEvent::getTime()` therefore reflect elapsed wall time since the `CoreObject` was constructed, not the position within the current file.

Without correction, every rectangle mapped to `onsetMs / totalDurationMs > 1.0`, placing all rectangles off-screen to the right. The same bug also caused exported MIDI files to have a large silence before the first note.

**Offline fix:** `_offlineRenderStartMs` is captured via `_coreObject.getCurrentTime()` immediately after the pre-warm block. `collectAndClearMidiEvents` subtracts this offset from every event timestamp.

**Real-time fix:** `_rtAnchorRnboTimeBits` / `_rtAnchorPlayheadFrame` are set per-session (on play start and after each seek). `collectAndClearRealTimeMidiEvents` computes `fileRelativeMs = anchorFileMs + (rnboTime - anchorRnboMs)`.

A secondary issue arises from transport looping: the render block loops the playhead back to frame 0 at end-of-file, but RNBO time keeps advancing monotonically. Without correction, post-wrap events produce `fileRelativeMs > totalDurationMs`, mapping all rectangles off the right edge of the waveform. The fix is a single `fmod(ms, totalMs)` applied to each computed timestamp before it is returned — this maps the value back into `[0, totalMs)` for any number of loop iterations.

#### Implementation note — staleness marking and the `.onChange` transition requirement

**Discovered during testing.** `.onChange(of:)` in SwiftUI only fires when the observed value *transitions* — it is a no-op if the value is already `true` when a param changes.

Before the first offline analysis, `lastAnalyzedOnsetParams` is `nil`, so `onsetParamsDirty` returns `true` unconditionally. After drawing real-time notes and then changing a param, `onsetParamsDirty` was already `true` and stays `true` — no transition occurs and `.onChange(of: onsetParamsDirty)` never fires, leaving the notes colored instead of greyed out.

**Fix:** stale marking is driven by a separate `overlayParamsDirty` computed property backed by `lastOverlayOnsetParams`. This snapshot is set to the current params whenever notes are added to the overlay (by `pollRealTimeMidiEvents`, `flushOpenRealTimeNotes`, `analyzeMIDI`, or `exportMIDIOffline`). Because `lastOverlayOnsetParams` reflects the params actually in effect when the overlay was populated, `overlayParamsDirty` starts `false` after notes are drawn and transitions to `true` only when params subsequently change — giving `.onChange` the transition it needs in all cases.

`onsetParamsDirty` is retained unchanged and continues to drive only the "Analyze" button enabled state via `lastAnalyzedOnsetParams` (offline-analysis-only snapshot).

#### Verification

1. Import audio file → "Analyze" button is immediately enabled; waveform overlay is empty.
2. Press **Analyze** → offline analysis runs; orange (C1 kick) and cyan (D1 snare) rectangles appear at correct positions; button disables.
3. Press **Play** → real-time notes accumulate on the waveform as the transport scrolls; notes appear at the correct file-relative positions.
4. Let transport loop → previously detected real-time notes are replaced in-place on each loop (total count stays stable, not accumulating indefinitely).
5. Change an onset tuning parameter → all overlay rectangles turn grey/translucent immediately; "Analyze" re-enables.
6. Resume playback → fresh real-time detections (at the new parameter values) replace stale grey notes as the playhead passes through them.
7. Press **Analyze** → entire overlay replaced by fresh offline results; all notes return to full color; button disables.
8. Toggle `Onset/enable` or `Onset/needs_init` → overlay and button state unchanged.
9. Press **Export MIDI** → exported file and overlay both reflect the same event set; button disables.
10. Seek by clicking/dragging the waveform → overlay rectangles remain at their file-relative positions; timestamp anchor resets for subsequent real-time capture.
11. Import a second file → overlay clears; "Analyze" immediately enables.

---

### Step 14.25 - Make MIDI Note Overlay RT Safe (IMPLEMENTED)

Hardens the Step-14 MIDI capture against real-time audio-thread violations, and establishes the lock-free
buffering pattern reused by Step 14.5's spectral capture. Verified against the live code (not just this doc);
the four refinements below (API split, ring reset, mode-flip ordering, retained offline mutex) came out of
that review.

#### Motivation — two RT violations in the render block

`MidiEventCapture` (Step 14) buffers outgoing `RNBO::MidiEvent`s in a `std::mutex`-guarded `std::vector`,
pushed from `handleMidiEvent` and swapped out by `collectAndClear()` on the main thread. `handleMidiEvent`
runs on the **real-time audio render thread** — it is invoked from `_midiCapture.drain()`, called right
after `core->process()` inside the `AVAudioSourceNode` render block. Two operations there violate real-time
audio safety:

1. **`std::vector::push_back` can `malloc`.** When the vector outgrows its capacity it reallocates on the
   audio thread — an unbounded, lock-taking operation. Dormant today only because MIDI events are sparse; a
   dense onset burst, or a main-thread stall that lets the vector fill between drains, can trigger it.
2. **`std::mutex` on the audio thread** risks priority inversion: if the main thread is preempted mid-
   `collectAndClear`, the render block blocks on the lock. The critical section is a pointer swap (tiny), so
   the window is small — but it is not lock-free.

Neither is currently audible, but both are latent glitch sources that worsen as event density rises. This
step replaces the *real-time* transport with a **lock-free single-producer/single-consumer (SPSC) ring
buffer** (the JUCE `AbstractFifo` pattern) so the render block never allocates and never locks.
`RNBO::MidiEvent` is default-constructible and trivially copyable (plain value type — `RNBO_MidiEvent.h`),
so a preallocated fixed-size array of slots is valid.

#### The offline-lossless constraint

`MidiEventCapture` feeds two consumers with opposite needs:

| Consumer | Thread | RT-safe required? | Lossless required? |
|---|---|---|---|
| Real-time overlay (`collectAndClearRealTimeMidiEvents`) | render block → main | **yes** | no — best-effort live preview |
| Offline MIDI export (`collectAndClearMidiEvents`) | offline loop (background) | no — no audio device | **yes — every event must survive** |

A fixed ring that drops on overflow is perfect for the preview but wrong for the export. The two paths are
**temporally exclusive** — `analyzeMIDI`/`exportMIDIOffline` call `-stopForOfflineRender` (which stops the
engine, halting the render block) on the main thread, dispatch `renderOfflineMIDI` + `collectAndClearMidiEvents`
to a background queue, then `-resumeAfterOfflineRender` on main. The render block is never running during the
offline loop, so a single mode flag routes `handleMidiEvent` to the correct buffer:

- **Real-time mode (default):** `handleMidiEvent` writes to the **lock-free SPSC ring** (drop-newest when
  full). The render block is allocation- and lock-free. Overflow is acceptable — the real-time overlay is a
  best-effort preview, and the *authoritative* MIDI is produced by the offline export.
- **Offline mode:** `handleMidiEvent` writes to the **existing `std::mutex`-guarded `std::vector`,
  unchanged**, collected once at loop end. `malloc` and the mutex are fine here — the offline loop runs on a
  background thread with no real-time deadline, where the producer (`drain()`) and consumer
  (`collectAndClearMidiEvents`) are the *same* thread, so the mutex is uncontended. **The proven Step-14
  offline collection path is untouched** (refinement D).

`setOfflineMode(bool)` (a `std::atomic<bool>`) is toggled alongside the existing `_paramCapture.setDeliveryEnabled`
brackets: **`true` in `-stopForOfflineRender`, `false` in `-resumeAfterOfflineRender` before `[_engine start]`**
(refinement C) so the resumed render block is already in real-time mode on its first callback — otherwise a
few stray RT events could dribble into the offline vector. On the audio thread the flag is read
`memory_order_relaxed` — one cheap branch per event.

#### Ring buffer design

- Fixed capacity `kEventRingCapacity = 2048`, a **power of two** so index wrap is a bitmask
  (`i & (kEventRingCapacity - 1)`), not a modulo. Backed by a preallocated `RNBO::MidiEvent[kEventRingCapacity]`.
- `std::atomic<size_t> _writeIdx, _readIdx`. Strict SPSC: the **producer** (audio thread) owns `_writeIdx`,
  the **consumer** (main thread) owns `_readIdx` — neither index is written by both threads.
  - **Produce** (`handleMidiEvent`, real-time mode): `next = (_writeIdx + 1) & mask`; if
    `next == _readIdx.load(acquire)` the ring is full → **drop the incoming event** (drop-newest keeps the
    producer from ever touching `_readIdx`, preserving strict SPSC); else store the event at `_writeIdx`,
    then `_writeIdx.store(next, release)`.
  - **Consume** (`drainRealTimeRing()`, main thread): snapshot `w = _writeIdx.load(acquire)`, copy
    `[_readIdx, w)` (with wrap) into the returned `std::vector`, then `_readIdx.store(w, release)`. The
    returned vector's allocation happens on the main thread — never on the producer side.
- **Capacity rationale:** the onset detector's `Min Gap` parameter bounds the onset rate at the source
  (default 20 ms → ≤ 50 onsets/s → ≤ 100 MIDI ev/s; a 5 ms floor → ≤ 200 onsets/s → ≤ 400 ev/s). The
  consumer drains at 15 fps, so normal occupancy is single digits. 2048 slots absorb **~5–20 s of complete
  main-thread unresponsiveness** at those rates before a single event is dropped — well past the point the
  app is effectively hung. Cost: 2048 × sizeof(`RNBO::MidiEvent`) ≈ a few tens of KB. Dropping only ever
  affects the live preview, never the export.
- **Note-pairing under overflow:** a drop can orphan a note-on/note-off pair in the preview, but only during
  extreme overflow (a multi-second stall); the overlay's re-detection/replacement and `flushOpenRealTimeNotes`
  self-heal it on the next loop. Acceptable for a best-effort preview.

#### API split + ring lifecycle (refinements A & B)

Today one C++ `collectAndClear()` serves four call sites. Split it in two:

- **`drainRealTimeRing()`** — drains the ring; called only by `-collectAndClearRealTimeMidiEvents` (the RT
  overlay poll, main thread). The anchor-based timestamp math in that ObjC method is unchanged; only its
  source (ring vs. vector) changes.
- **`collectAndClear()`** (vector, retained as-is) — called by `-collectAndClearMidiEvents` (offline export)
  and the two internal offline discards (pre-`prepareToProcess` cleanup and pre-warm discard). All three are
  offline-mode, so they correctly target the vector.

- **Ring reset in `-beginRealTimeCapture`.** Because RT and offline now use *separate* buffers, the offline
  loop's "discard any real-time-phase events" step no longer clears leftovers sitting in the **ring**.
  `-beginRealTimeCapture` is the fresh-timeline hook — called on play-start **and** on seek, already paired
  with `openRealTimeNoteOns.removeAll()` — so reset the ring there (`_readIdx = _writeIdx.load(acquire)`, a
  consumer-side op, safe). This preserves the old discard intent **and fixes a latent pre-existing issue**:
  today, ≤ one poll-interval of events left over before a stop/seek are returned by the next poll and
  re-timestamped against the *new* anchor, misplacing notes near the seek point. The reset discards them
  cleanly. (Optional, out of scope: a final `drainRealTimeRing()` on stop would also capture the last
  ≤ 66 ms of events, which are currently dropped — the ring makes this a trivial add if wanted later.)

`WaveformView` is unaffected — it renders the SwiftUI `midiNoteOverlay` array and never touches the capture.

#### Reuse the ring *design* in `MessageEventCapture` (Step 14.5) — a separate instance

Step 14.5's spectral capture reuses this **ring design**, but as its **own dedicated ring instance** — not
the MIDI ring. `MidiEventCapture` owns `MidiEvent _ring[kEventRingCapacity]`; `MessageEventCapture` owns a
separate `SpectralMsg _ring[kEventRingCapacity]` holding its own POD slots. They share only the SPSC pattern,
the drop-newest policy, and the `kEventRingCapacity` constant. The spectral capture has **no** lossless
offline consumer — offline delivery is gated off entirely via `_deliveryEnabled` — so it uses only the ring
half: written drop-newest by `handleMessageEvent` (real-time) and drained by `collectAndClearSpectralEvents`
(main thread). No mode flag, no fallback vector, no `-beginRealTimeCapture` reset needed (the store clears its
sample arrays on import instead). `SpectralMsg` is 16 bytes, so its ring is ~32 KB. Step 14.5's "mutex-guarded
`std::vector`" wording is superseded by this ring pattern.

#### Verification

1. Play a dense percussion file → the real-time overlay still populates and loops correctly (no regression
   from Step 14).
2. Reason through / instrument the render block → no `malloc` and no lock on the audio path during playback.
3. Export MIDI on a long, dense file → exported event count matches offline analysis exactly (lossless; the
   ring is not involved in offline mode).
4. Play, stop mid-file, seek elsewhere, resume → no stray/misplaced notes appear near the old stop/seek point
   (ring-reset in `-beginRealTimeCapture`).
5. Induce a main-thread stall during playback (e.g. a long synchronous op) → the overlay drops the newest
   events gracefully; **audio stays clean** (no dropout from the render block).

---

### Step 14.3 - Seek-During-Playback MIDI-block Misplacement Bug Fix (IMPLEMENTED)

Fixes a bug — latent since Step 14 — where seeking the transport mid-playback could draw a MIDI note-block at
the **new** playhead position when it belonged at/just before the **previous** position.

#### Root cause — the anchor was applied at poll time

Step 14 reconstructed real-time timestamps in `-collectAndClearRealTimeMidiEvents` using a single
cross-thread **anchor pair** (`_rtAnchorPlayheadFrame`, `_rtAnchorRnboTimeBits`) applied *at poll time*:
`fileMs = anchorFileMs + (event.getTime() − anchorRnboMs)`. A seek installed a *new* anchor
(`anchorFileMs = P_new`) via `-beginRealTimeCapture`, so any event produced **before** the seek but converted
**after** it was re-timed to `≈ P_new` and drawn at the wrong place. Step 14.25's `resetRealTimeRing()`
shrank the window (from a full ~66 ms poll interval to a single render block) but a narrow race remained: an
in-flight block draining just after the reset, and the render block reading `pos` *before* the anchor check
(so the anchor-capture block could pair a `P_new` file frame with `P_old` audio).

#### Fix — convert timestamps per-block, on the audio thread

Each event is now stamped with its file-relative time **on the audio thread, in the block that produced it**,
from that block's own playhead + RNBO-time base. Events are "born" correctly-timed and are inherently
seek-immune — a `P_old` block's events land at `P_old`, a `P_new` block's at `P_new`, regardless of when a
seek lands relative to the render callback. There is no mutable cross-thread anchor left to corrupt.

Implemented in `AudioEngine.mm` / `.h` (offline path and public API surface unchanged):

- New RT ring element `struct RtMidiEvent { double fileMs; uint8_t bytes[3]; uint8_t len; }`. The real-time
  ring stores already-converted timestamps; the offline vector still holds raw `RNBO::MidiEvent`.
- `MidiEventCapture::setBlockBase(fileMs, rnboMs, totalMs)` — producer-thread-only (no atomics), set by the
  render block once per block before `drain()`.
- `handleMidiEvent` (real-time) computes `fileMs = blockBaseFileMs + (event.getTime() − blockBaseRnboMs)`,
  wraps with `std::fmod(fileMs, blockTotalMs)` for the transport loop, and stores `{fileMs, bytes, len}` in
  the ring. `drainRealTimeRing()` now returns `std::vector<RtMidiEvent>`.
- Render block: normalises `pos` once, then sets the block base from that `pos` and `core->getCurrentTime()`
  (captured *before* `process()`) every block. The old deferred-anchor capture branch is deleted.
- Retired the deferred anchor entirely: removed `_needsRtAnchor` / `_rtAnchorPlayheadFrame` /
  `_rtAnchorRnboTimeBits` (ivars + captured render-block locals), the capture branch, and all anchor math from
  `-collectAndClearRealTimeMidiEvents` (which now reads `fileMs` straight through). `-beginRealTimeCapture` is
  reduced to `resetRealTimeRing()` (kept as a UX choice — surviving events are already correctly timed).
- `fmod` moved to the audio thread (a few scalar ops + one `getCurrentTime()` per block; no alloc, no lock —
  RT-safe); `#include <cmath>` added.

#### Verification
1. Hammer far seeks mid-playback (the original repro) → no block lands at the new playhead that belongs near
   the old one.
2. Loop the transport across the seek point → post-wrap events stay in `[0, totalMs)` (the `fmod` wrap now
   runs on the audio thread).
3. Export MIDI on a long dense file → event count still matches `Analyze` (offline path untouched).

#### Known residual (addressed by Step 14.35)
Under **pathological** rapid seeking, a few spurious / slightly-early blocks can still appear in the **live
overlay**. This is **not** a timestamp race — it is RNBO's ~40 ms onset-detection latency and the input step
discontinuity crossing the seek boundary: an onset from pre-seek audio is emitted a few blocks *after* the
seek and stamped at the new playhead (then drawn ~40 ms early by the overlay's `processingLatencyMs`
left-shift), and abrupt seeks also provoke discontinuity false-triggers. No per-block timestamp math can
resolve it — the event genuinely belongs to pre-seek audio. Offline analysis/export is unaffected.

---

### Step 14.35 - Post-Seek MIDI Settling Window (IMPLEMENTED)

Suppresses the residual live-overlay artifact described at the end of Step 14.3 (RNBO's detection latency and
the seek discontinuity leaking spurious / pre-seek onsets into the block(s) just after a seek).

#### Why Step 14.3 can't fix it
RNBO emits each MIDI event ~40 ms *after* the true audio onset (detection latency; the overlay compensates by
left-shifting blocks by `AudioEngine.processingLatencyMs`). An onset in pre-seek audio is therefore emitted a
few blocks after a seek, and per-block timestamping (correctly) stamps it at the new playhead — there is no
correct post-seek position for an event that belongs to pre-seek audio. Abrupt seeks also create input step
discontinuities the onset detector can register as false onsets.

#### Idea
After each seek, suppress **real-time** MIDI capture for exactly the detection latency, measured in
**RNBO-time** (not wall-clock, so it tracks processed audio and is independent of the 15 fps poll
granularity). That window is precisely long enough to flush the latency pipeline, dropping both the in-flight
pre-seek onsets **and** the discontinuity false-triggers in one stroke.

**Window = latency exactly (optimal).** Suppress while `blockRnbo < seekRnbo + latency`. A pre-seek onset
(true time `< seekRnbo`) is emitted `< seekRnbo + latency` → dropped; a real post-seek onset (true time
`≥ seekRnbo`) is emitted `≥ seekRnbo + latency` → kept. So `window = latency` drops every in-flight pre-seek
onset while keeping every real post-seek one — a larger window would start eating real onsets, a smaller one
would leak pre-seek ones.

#### Single source of truth for the latency
`AudioEngine` owns the figure as file-scope `kRnboProcessingLatencyMs` (hardcoded 40 ms placeholder; a future
update feeds it from the patch's `processingLatency` outport). It is used **directly** by the settling window
on the audio thread **and** exposed to Swift via the `processingLatencyMs` property, which `ContentView`
passes into `WaveformView.midiLatencyCompensationMs` (the overlay's left-shift). `WaveformView` no longer
holds its own latency constant, so the overlay shift and the settle window can never drift. There is **no**
separate `kSeekSettleMs` constant — the settle duration *is* `kRnboProcessingLatencyMs`.

#### Design (RT-safe, seek-only)
- `MidiEventCapture`:
  - `armSeekSettle()` (main thread) → sets `std::atomic<bool> _armSeekSettle`.
  - In `setBlockBase` (audio thread, every block): `if (_armSeekSettle.exchange(false)) _settleUntilRnboMs =
    rnboMs + kRnboProcessingLatencyMs;`.
  - In `handleMidiEvent` (real-time, right after the offline-mode check): `if (_blockBaseRnboMs <
    _settleUntilRnboMs) return;`. `_settleUntilRnboMs` is audio-thread-local.
- `-setPlayheadPosition` calls `_midiCapture.armSeekSettle()` — the **seek-only** hook (called only from the
  waveform seek handler), so play-start is unaffected and never suppresses a genuine first onset.

#### Trade-off
Essentially none: `window = latency` keeps all real post-seek onsets. At most, because the RNBO-time check
uses the block-start time, a real onset landing within ~one render block of the window's edge could be missed
**in the live overlay only**; the offline `Analyze` / `Export MIDI` path is unaffected and still
captures everything. Negligible at a manual seek point.

#### Verification
1. Reproduce the Step 14.3 symptom (time a seek right around an onset) → spurious / slightly-early blocks near
   the new playhead no longer appear.
2. Seek to a quiet region, then let onsets play a beat later → they still appear (no over-suppression).
3. Play without seeking → overlay unchanged (settle only arms on `-setPlayheadPosition`).
4. Export MIDI → event count still matches `Analyze` (offline path untouched).

---

### Step 14.5 - SpecFlatCutoff and SpecCentCutoff HorizontalSliderView Controls (IMPLEMENTED)

Replaces the generic rotary knobs for `SpecCentCutoff` and `SpecFlatCutoff` with two purpose-built
horizontal sliders, each backed by a live, fading **histogram** of the spectral values the RNBO patch
measures per detected onset. The RNBO patch emits per-onset **SpectralCentroid** and **SpectralFlatness**
values through outport message objects; until now the host listened to none of them (no
`handleMessageEvent` existed anywhere in the bridge). Surfacing them on the same axis as the cutoff lets
the user place each cutoff exactly where kick vs. snare values cluster.

New views live in their own `HorizontalSliderView.swift`, inserted into `ContentView` between
`mainToolbar` and `parametersPanel` (the same inclusion pattern as `WaveformView`).

#### Visual design

Two rows inside a single subtle light-grey rounded border, split by a light-grey divider:

- **Top row = SpectralCentroid** — bright-green histogram bars, axis `0 – 8000` (default).
- **Bottom row = SpectralFlatness** — purple histogram bars, axis `0 – 0.55` (default).

Per row, left-to-right: a **bordered number box** (editable cutoff value — centroid integer, flatness
2-decimal), a grey **spectral min icon**, the **canvas** (bars + cutoff bar + drum markers + axis label),
and a grey **spectral max icon**. Number boxes and spectral icons sit *outside* the border, column-aligned.

Inside each canvas:
- Each measured value is a thin (~2 pt) **full-height vertical bar** at its value's x-position, colored by
  feature (green / purple), with opacity encoding recency (see *Opacity / fade model*).
- The **cutoff** is a full-height, slightly thicker, full-opacity **yellow** vertical bar (distinct from
  the Kick orange).
- **Kick** (orange, `C1`) and **Snare** (cyan, `D1`) drum icons + note labels flank the yellow cutoff bar
  — Kick+`C1` just left, Snare+`D1` just right — and **move with the cutoff**, encoding "values below the
  cutoff trigger the Kick, values above trigger the Snare." The drum colors are the exact `WaveformView`
  MIDI note-block colors (Kick orange `(1.0, 0.45, 0.1)`, Snare cyan `(0.2, 0.85, 0.9)`), so the sliders
  and the waveform overlay share one colour language.
- The current **`axisMax`** is drawn as a small label in the canvas's upper-right corner.

Spectral min/max icons are self-contained grey vector `Canvas`/`Path` glyphs, each on a full-width
baseline: centroid = a localized gaussian energy hump peaked toward the low (left, min) / high (right,
max) end; flatness = a discrete lollipop-stem spectrum — a single tall center peak with a main-lobe bell
among short flanking bins (min, a pure tone) versus all bins equal and tall (max, broadband noise).

#### Configuration constants

Grouped in a `SpectralDisplayConfig` struct:

| Constant | Default | Meaning |
|---|---|---|
| `numberSpecDisplayValues` (N) | 20 | count of recent values shown at the rank-based ("full") opacity ramp |
| `specDisplayFadeout` (T) | 1.2 | **seconds** to fade a value from min-opacity → 0 after it ages past N |
| `specDisplayMaxOpacity` | 1.0 | native SwiftUI opacity of the most recent value |
| `specDisplayMinOpacity` | 0.35 | native opacity of the oldest of the N displayed (rank N−1) |
| `maxAxisDisplayValuePercentageOffset` | 3 | % of a feature's *full* range added as headroom when the axis auto-expands |

Per-feature: default axis max (centroid 8000, flatness 0.55), full possible range (centroid 10000,
flatness 1.0), bar color, value format, and its min/max icon views.

#### Dynamic display axis (high-water mark)

`axisMax` starts at the default and is a monotonic high-water mark driven **only by measured spectral
values**: when a value `v > axisMax` is received, it expands to `v + offset`, where
`offset = maxAxisDisplayValuePercentageOffset% × fullRange` (centroid 300, flatness 0.03). It never
shrinks within a session and resets to the default on new-file import (when the histogram clears). The
label in the upper-right corner always shows the current extent.

The axis does **not** expand to follow the cutoff. Instead the cutoff is **clamped to `axisMax`** — in
both the slider gesture (`[paramMin, min(paramMax, axisMax)]`) and the number box (its max is
`min(param.max, axisMax)`). So dragging the yellow bar to the far right pins it at `axisMax` (e.g. 8000
for centroid) without zooming the visible value range out; the axis only ever grows when an actual
spectral value exceeds it, keeping all measured bars and the Snare-side region visible.

Existing bars reposition **for free** when `axisMax` grows: samples store only their raw `value`; the
on-screen x is derived each frame from the *current* `axisMax`, so the next redraw places every bar at its
correct compressed position with no cached state to invalidate. Because `axisMax` and `width` are constant
for all bars in a row within a frame, the draw hoists the reciprocal — `let scale = width / axisMax` once
per row per frame — and every x is then a plain multiply `value * scale`.

#### Opacity / fade model

Samples live in a **FIFO** buffer (newest pushed on, oldest pruned off), in two phases:

**Phase 1 — rank-based ramp (the N newest).** For a sample at recency rank `r` (0 = newest), with
`step = (maxOp − minOp) / (N − 1)`: `opacity = maxOp − r·step`. So r = 0 → `maxOp` (1.0) and r = N−1 (the
oldest of the N displayed) → exactly `minOp` (0.35). The `N − 1` denominator is deliberate: N values
ramping inclusively from max to min have N−1 intervals between them, so the oldest displayed lands exactly
on `minOp` (a plain `/N` would leave it one step high).

**Phase 2 — time-based fade-out (older than the N newest).** The instant a sample's rank first reaches N,
it "ages out" and is stamped once with `agedOutAt = now`. From then on its opacity ignores rank and
depends only on elapsed time: `opacity = minOp · (1 − (now − agedOutAt) / T)`, clamped ≥ 0; when
`now − agedOutAt ≥ T` it is fully faded and pruned. The handoff is continuous — Phase 1 already equals
`minOp` at r = N−1, and Phase 2 starts from `minOp` at elapsed 0 — so bars fade smoothly to invisible
rather than blinking out.

Only `agedOutAt` is stored (nil until a sample ages out); no arrival timestamp is kept. `now` and
`agedOutAt` are **seconds** (`Date().timeIntervalSinceReferenceDate` / the `TimelineView` context date),
the same unit as `T`, so no conversion is needed. Both phases yield native SwiftUI opacity (0–1) directly.

#### AudioEngine additions — outport message listener (pull model)

Mirrors the **MIDI-capture pull model** (`MidiEventCapture` + `collectAndClearRealTimeMidiEvents`) — **not**
the parameter-listener's `dispatch_async` push. This choice is load-bearing for real-time safety: spectral
messages fire **twice per detected onset** (Centroid + Flatness) throughout live playback and cluster at
transients — exactly when the render block is busiest — so the audio thread must never `malloc`, lock on a
non-RT thread, or touch ARC/Objective-C for them. The parameter listener's `dispatch_async(main)` per event
is only safe *there* because watched parameter writes are near-zero-frequency during playback (self-writes
are source-id-filtered and only two params are watched); copying that mechanism to a per-onset stream would
put a heap `Block_copy` (a `malloc`) plus a libdispatch lock on the audio thread at every onset. The pull
model does the audio-thread work with a single buffered push and moves all boxing/allocation to the main
thread. A third `EventHandler` interface is still added (one subclass per event type):

- New file-scope class `MessageEventCapture : RNBO::EventHandler` in `AudioEngine.mm`, overriding
  `handleMessageEvent`. It drops events when `!_deliveryEnabled`, keeps only `Number`-type messages, and
  matches `event.getTag()` against `RNBO::TAG("SpectralCentroid")` / `RNBO::TAG("SpectralFlatness")`. A
  surviving event is reduced **on the audio thread** to a POD `struct SpectralMsg { int feature; double
  value; }` — `feature` a plain `int`/enum discriminator (0 = centroid, 1 = flatness), **never an
  `NSString`** — and written into `MessageEventCapture`'s **own dedicated** lock-free SPSC ring buffer,
  `SpectralMsg _ring[kEventRingCapacity]`. This is a **separate ring instance** from the
  `RtMidiEvent _ring[kEventRingCapacity]` in `MidiEventCapture` (Steps 14.25 / 14.3) — same design,
  drop-newest policy, and `kEventRingCapacity` constant, but a distinct buffer holding `SpectralMsg` slots.
  Drop-newest
  when full; strict single-producer/single-consumer, no `malloc`, no lock. **No `dispatch_async`, no ObjC
  object, no callback block touches the audio thread.** `eventsAvailable()` is a no-op; `drain()` is a thin
  `drainEvents()` wrapper, as with the sibling captures.
- Because the spectral capture has no lossless offline consumer, it needs only the ring half of the Step
  14.25 pattern — **skip `MidiEventCapture`'s MIDI-specific machinery**: no offline-mode fallback vector, no
  `-beginRealTimeCapture` reset, **no per-block timestamp conversion** (`setBlockBase` / the `_blockBase*`
  members / the `fileMs` field), and **no seek settling window** (`armSeekSettle` / `_settleUntilRnboMs`).
  `SpectralMsg` carries only `{feature, value}` — spectral bars are plotted on the *value* axis, not a time
  axis, and the histogram is playhead-position-independent, so neither timestamps nor seek handling apply.
  Two consumer-side (main-thread) methods drain the ring: `drainRing()` copies `[readIdx, writeIdx)` into a
  `std::vector<SpectralMsg>`, and `resetRing()` discards buffered samples by advancing `readIdx` to
  `writeIdx` (safe while the producer runs).
- A third `ParameterEventInterface` (`_messageListenerInterface`, handler `_messageCapture`) is created in
  `-init` and `.reset()` in `-dealloc` before the handler is destroyed. `_messageCapture.drain()` is
  called after every `core->process()` — real-time render block and offline loops — alongside the existing
  `_midiCapture` / `_paramCapture` drains (draining during offline, with delivery disabled, keeps RNBO's
  event queue from backing up).
- **Live-playback only:** `_messageCapture`'s `_deliveryEnabled` is bracketed false/true around offline
  renders (in `-stopForOfflineRender` / `-resumeAfterOfflineRender`), so `Analyze` / `Export MIDI`
  do not populate the histogram. In addition, `_messageCapture.resetRing()` is called in
  `-stopForOfflineRender` (after `[_engine stop]`, so no producer races it) and in
  `-resumeAfterOfflineRender` (before the engine restarts), discarding any real-time-phase samples still
  buffered so none bleed across the render boundary.
- `AudioEngine.h` exposes a **receive-only pull method** `collectAndClearSpectralEvents()` (mirrors
  `collectAndClearRealTimeMidiEvents`), returning the batch accumulated since the last call as
  `NSArray<NSDictionary *>` with keys `"feature"` (`NSNumber` int) and `"value"` (`NSNumber` double). It
  calls `drainRing()` and does the `NSDictionary` boxing on the main thread, not on the audio thread. No
  callback block property is added, and nothing is written back to RNBO.

#### ParameterStore additions

- `struct SpectralSample { let value: Float; var agedOutAt: TimeInterval? = nil }`.
- `centroidSamples` / `flatnessSamples` (FIFO, newest-first) and `centroidAxisMax` / `flatnessAxisMax`
  (seeded to the defaults) on the `@Observable` store.
- `recordSpectral(feature:value:)` (main thread): push the new sample; stamp the sample that just crossed
  to rank N with `agedOutAt = now`; expand `axisMax` if exceeded; prune samples past their fade window.
- `pollSpectralEvents()` (main thread): calls `engine.collectAndClearSpectralEvents()` and loops the batch
  into `recordSpectral(feature:value:)`. This is the **pull** counterpart to `pollRealTimeMidiEvents()` —
  there is no engine callback; samples are drained on `ContentView`'s existing playback-gated timer (see
  *ContentView changes*).
- `clearSpectral()` empties both sample arrays and resets both axis maxes to their defaults; called on new
  file import alongside the MIDI-overlay reset.

#### HorizontalSliderView.swift — new views

New file, auto-included by the Xcode file-system-synchronized root group (no `project.pbxproj` edits):

- `HorizontalSliderView` — one row's `Canvas` (bars, yellow cutoff bar, `axisMax` label) plus a `ZStack`
  overlay for the Kick/Snare drum markers positioned at `cutoffX`. Its gesture is **click-to-position**
  (absolute — `DragGesture(minimumDistance: 0)`, reusing `WaveformView`'s seek-x mapping): the pointer x
  maps directly to `value = fraction · axisMax`, clamped to `[paramMin, min(paramMax, axisMax)]` so the
  cutoff can't be pushed past the visible axis. Double-click resets to the RNBO default. (Precision is via
  the number box; there is no shift-fine mode.)
- `SpectralCentroidIcon` / `SpectralFlatnessIcon` (grey), and `KickDrumIcon` / `SnareDrumIcon` drum-marker
  views (custom `Canvas`/`Path` glyphs).
- `InputValueField` (reused, wrapped in a bordered container) for the number boxes, its max clamped to
  `axisMax` per row.
- `SpectralSlidersView` — the container `ContentView` inserts. Looks up both params by `rnboId` (renders
  nothing if either is missing), assembles the column-aligned two-row layout with the grey border/divider,
  and wraps everything in its **own dedicated** `TimelineView(.periodic, 30 fps)` **solely to drive the fade
  redraw** — so aged-out bars keep fading to invisible even when playback is stopped (the waveform's
  TimelineView is fixed in the waveform slot and can't be reused without restructuring the layout, and the
  playback-gated pull timer wouldn't tick while stopped). The `TimelineView` closure only reads state and
  draws; it performs **no** engine pull — side-effecting drains don't belong in a `ViewBuilder` SwiftUI may
  re-evaluate off-cadence. The spectral-event pull lives in `ContentView`'s playback-gated timer instead
  (see below).

#### ContentView changes

- Insert `SpectralSlidersView(store: store)` between `mainToolbar.padding()` and the
  `parametersPanel` block.
- **Pull spectral events on the existing playback-gated 15 fps timer.** The `.onReceive(Timer.publish…)`
  that already calls `pollRealTimeMidiEvents()` under `guard isPlaying` also calls `store.pollSpectralEvents()`.
  New samples only arrive during playback, so gating the pull to playback is correct; the *fade* of
  already-recorded samples is driven separately by `SpectralSlidersView`'s always-on 30 fps `TimelineView`.
  This keeps the audio→UI handoff a main-thread pull — identical to the real-time MIDI overlay, no callback
  from the audio thread.
- Give the `SpecCentCutoff` / `SpecFlatCutoff` specs a new `ControlType` (`.spectralSlider`) so they drop
  out of the single-row rotary layout — the sliders replace the
  knobs entirely, while the store still tracks their values and engine-feedback exactly as before.

#### Verification

1. Import audio with clear kicks + snares; press **Play**. Two sliders appear between transport and
   parameters (Centroid top, Flatness bottom); yellow cutoff bars; green/purple bars stream in at their
   value positions; newest brightest, older bars fade and vanish smoothly ~1.2 s after aging past 20
   values. Kick/Snare markers flank each cutoff; `axisMax` shows upper-right.
2. Feed a value beyond the default axis → the axis expands with 3% headroom and existing bars/handle
   reposition without clipping.
3. Click/drag a slider (click-to-position) or edit its number box → cutoff updates both ways and clamps
   to `axisMax` (dragging to the far right pins it at `axisMax` without zooming the axis out); double-click
   = reset. `SpecCentCutoff` / `SpecFlatCutoff` no longer appear as rotary knobs.
4. Run **Analyze** / **Export MIDI** → histogram does not populate from the offline pass, and
   trained cutoff values still mirror into the sliders.
5. Import a second file → histogram clears and axis maxes reset to defaults.

---

### Step 15 - Real-time Oscilloscope UI Overlay

A real-time oscilloscope layer drawn on top of the waveform view during playback. Post-RNBO output audio is written into a lock-free ring buffer each render callback; the SwiftUI `Canvas` reads a snapshot at 30 fps and draws it as a smooth curve. Multiple consecutive snapshots are retained and drawn with decreasing opacity to produce the SAMPLR-style "persistence" effect — older frames ghost behind the live trace.

The implementation separates three concerns:

1. **Ring buffer write** (audio thread) — copies post-RNBO L-channel output into a fixed circular buffer on every render callback. Single-producer / single-consumer; no lock required.
2. **Snapshot read** (main thread) — copies the most recent N samples from the ring buffer into an `NSData` blob using `memory_order_acquire`, called at 30 fps by the `TimelineView`.
3. **Curve rendering** (draw time) — downsamples the snapshot to a small set of control points and builds a smooth `Path` via Catmull-Rom spline interpolation, then draws 4 layered traces with decreasing opacity.

#### `AudioEngine.h` / `AudioEngine.mm` — Ring buffer and snapshot API

Add to `AudioEngine.mm` ivars:

```objc
// Oscilloscope ring buffer — written by the render thread, read by the main thread.
// Power-of-2 size enables branch-free index wrapping via bitwise AND.
static const size_t kOscilloscopeBufferSize = 4096;  // ~93 ms at 44.1 kHz

float                _oscilloscopeBuffer[kOscilloscopeBufferSize];  // zero-init by ObjC
std::atomic<size_t>  _oscilloscopeWritePos;                          // zero-init
```

In the render block in `-start`, after the `core->process(...)` call, append the L-channel output to the ring buffer. The write uses `memory_order_relaxed` for the index update since the consumer uses `memory_order_acquire` on the read side, and the buffer array itself does not need atomic access (a single-sample tear at the boundary between two reads is visually imperceptible):

```objc
// Write post-RNBO L output into oscilloscope ring buffer.
size_t wp = oscilloscopeWritePosPtr->load(std::memory_order_relaxed);
const size_t mask = kOscilloscopeBufferSize - 1;
for (AVAudioFrameCount i = 0; i < frameCount; ++i)
    oscilloscopeBufferPtr[(wp + i) & mask] = (float)outL[i];
oscilloscopeWritePosPtr->store((wp + frameCount) & mask, std::memory_order_release);
```

Where `oscilloscopeBufferPtr` and `oscilloscopeWritePosPtr` are raw pointers captured before the block, following the same pattern used for `pcmLPtr`, `headPtr`, etc.

Add to `AudioEngine.h`:

```objc
/// Copies the most recent `frameCount` post-RNBO L-channel output samples from the
/// oscilloscope ring buffer into a flat NSData of Float32 values.
/// Safe to call from the main thread at 30 fps — uses memory_order_acquire on the
/// write-position atomic. Returns nil if frameCount is 0 or exceeds the buffer size.
- (nullable NSData *)oscilloscopeSnapshotWithFrameCount:(NSInteger)frameCount
    NS_SWIFT_NAME(oscilloscopeSnapshot(frameCount:));
```

`AudioEngine.mm` implementation:

```objc
- (NSData *)oscilloscopeSnapshotWithFrameCount:(NSInteger)frameCount {
    if (frameCount <= 0 || (size_t)frameCount > kOscilloscopeBufferSize) return nil;
    size_t wp   = _oscilloscopeWritePos.load(std::memory_order_acquire);
    size_t mask = kOscilloscopeBufferSize - 1;
    // Most-recent frameCount samples end at wp-1; start index wraps via mask.
    size_t start = (wp - (size_t)frameCount) & mask;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)frameCount * sizeof(float)];
    float *out = (float *)data.mutableBytes;
    for (NSInteger i = 0; i < frameCount; ++i)
        out[i] = _oscilloscopeBuffer[(start + (size_t)i) & mask];
    return [data copy];
}
```

**Thread-safety note:** the render thread could overwrite a portion of the buffer while the main thread is reading it. This requires the render thread to write a full 4096 samples (~93 ms) during the ~microsecond read window — a race that is effectively impossible at 30 fps polling. No additional locking is needed for a visual oscilloscope; an extremely rare single-sample glitch in one draw frame is imperceptible.

#### `WaveformView` additions

Add four new parameters:

```swift
let oscilloscopeTick: Date?             // nil when stopped; changes each TimelineView tick
let oscilloscopeProvider: (() -> Data?)? // closure that calls engine.oscilloscopeSnapshot
```

Add internal state and constants:

```swift
@State private var oscilloscopeHistory: [[Float]] = []

private static let kHistoryCount   = 4     // number of layered persistence frames
private static let kControlPoints  = 256   // downsampled points fed to the spline
private static let kSnapshotFrames = 1024  // samples per snapshot (~23 ms at 44.1 kHz)
```

**`onChange(of: oscilloscopeTick)`** — fires each 30 fps tick while playing. Reads a fresh snapshot, parses it to `[Float]`, appends to history, and trims to `kHistoryCount`:

```swift
.onChange(of: oscilloscopeTick) { _, newTick in
    guard newTick != nil,
          let data = oscilloscopeProvider?() else { return }
    let count = data.count / MemoryLayout<Float>.size
    var samples = [Float](repeating: 0, count: count)
    samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    var h = oscilloscopeHistory
    h.append(samples)
    if h.count > Self.kHistoryCount { h.removeFirst() }
    oscilloscopeHistory = h
}
```

When playback stops (`oscilloscopeTick` becomes `nil`), `onChange` fires once with `newTick == nil`, the guard returns early, and the history stays frozen at the last playback state.

**Canvas drawing pass** — insert after the MIDI note overlay and before the playhead line. Only draws when `oscilloscopeHistory` is non-empty (i.e., after the first playback snapshot arrives):

```swift
// Oscilloscope persistence traces — oldest frame first (most transparent)
for (frameIdx, samples) in oscilloscopeHistory.enumerated() {
    let opacity = Double(frameIdx + 1) / Double(Self.kHistoryCount) * 0.85
    let path = oscilloscopePath(from: samples, in: size)
    context.stroke(path,
                   with: .color(.white.opacity(opacity)),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
}
```

Opacity ramp with 4 frames: 0.21 → 0.43 → 0.64 → 0.85. Oldest frame is most ghosted; newest frame is near-opaque white. The white color contrasts with the blue waveform beneath.

#### Catmull-Rom smooth curve

A free function (or private method) `oscilloscopePath(from:in:) -> Path` converts a raw sample array to a smooth `Path`:

1. **Downsample** — reduce the `kSnapshotFrames` (1024) raw samples to `kControlPoints` (256) by taking every `kSnapshotFrames / kControlPoints`-th sample (or a short RMS average per bin for anti-aliased clarity).

2. **Map to view coordinates** — for control point `i`:
   ```swift
   let x = size.width * CGFloat(i) / CGFloat(kControlPoints - 1)
   let y = size.height / 2 - CGFloat(sample) * size.height / 2 * 0.8
   ```

3. **Build Path with Catmull-Rom → cubic Bezier conversion** — for each interior segment between P₁ and P₂ (with neighbors P₀ and P₃), the Bezier control points are:
   ```
   CP1 = P1 + (P2 - P0) / 6   // outgoing tangent at P1
   CP2 = P2 - (P3 - P1) / 6   // incoming tangent at P2
   ```
   For the first and last segments, clamp the missing neighbor to the endpoint itself (P₀ = P₁ and P₃ = P₂ respectively). Iterate all `kControlPoints - 1` segments and emit one `addCurve(to:control1:control2:)` call per segment.

This produces a smooth curve that passes exactly through every downsampled control point with C¹ continuity — identical to JUCE's `Path::cubicTo` oscilloscope rendering approach.

#### `ContentView` changes

Thread the two new parameters into the existing `WaveformView` call inside the `TimelineView`:

```swift
TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
    WaveformView(
        thumbnail: waveformThumbnail,
        playheadFraction: engine.playheadFraction,
        midiNotes: midiNoteOverlay,
        totalDurationMs: totalDurationMs,
        oscilloscopeTick: isPlaying ? timeline.date : nil,
        oscilloscopeProvider: { [engine] in
            engine.oscilloscopeSnapshot(frameCount: WaveformView.kSnapshotFrames)
        },
        onSeek: { fraction in ... }
    )
}
```

No new `@State` in `ContentView` — history is entirely internal to `WaveformView`.

#### Verification

1. Import audio and press Play → oscilloscope traces appear, animating smoothly at 30 fps across the waveform.
2. Loud transients produce tall peaks; quiet sections produce a near-flat line near the vertical centre.
3. Four layered traces are visible with the newest trace brightest and older traces ghosting behind it.
4. Press Stop → traces freeze at their last positions; history does not update further.
5. Press Play again → traces resume animating from the new playback position.
6. With no file loaded, no oscilloscope traces appear.
7. Oscilloscope traces do not shift the waveform thumbnail, MIDI overlay, or playhead line — all layers remain visually composited.




---

### Step 16 — SwiftUI Integration Review

Each UI control has been introduced incrementally alongside the step that implements its backing logic. Use this step as a final review to confirm all controls are present, correctly wired, and coherent as a complete interface:

| Control | Added in | Purpose |
|---|---|---|
| **Play / Stop** icon button (`play.fill` / `stop.fill`) | Step 6 | Start and stop real-time playback |
| **Import** icon button (`square.and.arrow.down`+`waveform`) | Step 7 | Import audio file (Workflows 1a/1b) |
| Parameter controls (knobs / sliders / radio / toggles / number boxes) | Step 8 | One per exposed RNBO parameter |
| **Playhead Position** display (`MM:SS.MMM`) | Step 9 | Playhead time (playback) / elapsed time (recording, shown red) |
| **Record / Stop** toggle | Step 9 | Start and stop live input recording (Workflow 2b) |
| **Monitoring** toggle | Step 9.5 | Toggle real-time input monitoring (Workflow 2a) — switches the render-block input between the live ring buffer and silence |
| **Export Audio (Offline)** icon button (`square.and.arrow.up`+`waveform`) | Step 11 | Offline audio render → save panel |
| **Export MIDI (Offline)** icon button (`square.and.arrow.up`+`music.quarternote.3`) | Step 11 | Offline MIDI render → save panel |
| **Record Audio (Real-time)** toggle | Step 12 | Real-time audio capture → save panel |
| **Record MIDI (Real-time)** toggle | Step 12 | Real-time MIDI capture → save panel |

Address any layout, spacing, or grouping issues, and confirm all controls are accessible and functional before proceeding to Step 14.

---

### Step 17 — Run Full Verification

Work through Verification steps 1–10 (Phase 0 section) in the Verification / Testing Approach section above to confirm all four workflows are functional end-to-end before considering Phase 0 complete.

---

## Future Potential Architectural Improvements

### Pixel-Perfect Waveform Rendering

**Motivation**

Step 13 computes the waveform thumbnail at a fixed 2048 bins, which slightly oversamples at typical window widths (800–1500 px) and would undersample on very wide displays. For exact 1-bin-per-pixel fidelity at any window size, the bin count should match the view's actual pixel width in points.

**Implementation sketch**

1. Expose a `@State var waveformViewWidth: CGFloat = 0` in `ContentView`.
2. Read the waveform panel's rendered width using `.onGeometryChange(for: CGSize.self)` (macOS 14+ / iOS 17+):
   ```swift
   TimelineView(...) { _ in WaveformView(...) }
       .frame(height: 150)
       .onGeometryChange(for: CGSize.self, of: { $0.size }) { newSize in
           if abs(newSize.width - waveformViewWidth) > 1 {
               waveformViewWidth = newSize.width
               recomputeWaveformThumbnail()
           }
       }
   ```
3. `recomputeWaveformThumbnail()` dispatches to a background thread, calls `engine.waveformThumbnailData(binCount: Int(waveformViewWidth))`, and updates `waveformThumbnail` on the main thread — identical to the initial file-load path.
4. The thumbnail is recomputed on first layout and on every window resize that changes the waveform panel width by more than 1 pt. Debouncing (e.g., coalescing rapid resize events with a short `DispatchWorkItem` cancel-and-reschedule) prevents redundant recomputes during a live window drag.

**Tradeoff vs. Step 13 fixed bins**

| | Fixed 2048 bins (Step 13) | Geometry-aware bins |
|---|---|---|
| Implementation complexity | Low | Moderate |
| Pixel fidelity | Near-perfect at ≤ 2048 px | Exact at any width |
| Recompute on resize | Never | On each width change |
| Recompute cost | Once per file load | Once per file load + once per resize event |

For most use cases the 2048-bin approach is indistinguishable, making this a low-priority polish improvement.

---

## Architectural Notes

### Parameter Control and Listener System (Step 8)

#### ObjC++ Bridge Layer (`AudioEngine.h` / `AudioEngine.mm`)

Two methods were added to `AudioEngine` to expose RNBO's parameter API to Swift:

```objc
- (int)numParameters;
- (NSDictionary<NSString *, id> *)parameterInfoAtIndex:(int)index
    NS_SWIFT_NAME(parameterInfo(at:));
```

`parameterInfo(at:)` returns a dictionary with five keys populated from `RNBO::ParameterInfo`:

| Key | Type | Source |
|---|---|---|
| `"id"` | `String` | `_coreObject.getParameterId(index)` — full path, e.g. `"Onset/enable"`, `"GreyholeDelayFX_Controller/GreyholePreset"` |
| `"min"` | `NSNumber (float)` | `info.min` |
| `"max"` | `NSNumber (float)` | `info.max` |
| `"default"` | `NSNumber (float)` | `info.initialValue` |
| `"steps"` | `NSNumber (int)` | `info.steps` — `0` = continuous, `1` = toggle, `≥2` = discrete |

`NS_SWIFT_NAME` is used on both new methods to override the Swift bridged name explicitly, avoiding reliance on the ObjC→Swift importer's heuristics (which would generate `setParameterWithIndex(_:value:)` not `setParameter(withIndex:value:)` for set-prefixed multi-argument methods).

#### Swift Data Model (`ParameterStore`)

`ParameterStore` is an `@Observable` class that lives as `@State` on `ContentView`. It owns the `AudioEngine` instance.

**Static whitelist — `ParameterStore.specs: [String: Spec]`**

A dictionary keyed by the exact RNBO parameter ID string. Only parameters present in this dict receive UI controls. Fields:

- `label: String` — human-readable display name
- `controlType: ControlType` — one of `.toggle`, `.rotary`, `.discrete`, `.numberInput`
- `order: Int` — display sort position, independent of RNBO's internal parameter index order
- `hasRandomize: Bool` — whether a `dice`-icon Randomize button appears beside the control (currently only `GreyholeDelayFX_Controller/GreyholePreset`)
- `initialOverride: Float?` — optional host default that overrides the RNBO patch's `assign_defaults` value in the UI display (and in `pushAllValuesToEngine()` if the user never touches the control). Used when the patch default is unsuitable for the target use case. `nil` means use the RNBO `initialValue` as-is.

**To add a new parameter to the UI**, add a single entry to `specs` with its exact RNBO parameter ID and the appropriate `controlType`. No other code changes are required.

**Runtime snapshot — `ParameterStore.Param`**

Built once at init by combining the whitelist metadata with RNBO-queried values. Immutable after construction. Key fields:

- `rnboIndex: Int32` — the RNBO parameter index, used for all `setParameterValue` calls
- `min`, `max`, `defaultValue: Float` — queried from RNBO at init via `getParameterInfo`
- `controlType`, `label`, `sortOrder`, `hasRandomize` — from the static `Spec`

**Parallel arrays — `params: [Param]` and `values: [Float]`**

`params` and `values` are parallel arrays sorted by `sortOrder`. The integer index `i` into both arrays is stable for the lifetime of the `ParameterStore` instance and is used throughout the UI layer to bind controls to values and to call `store.set(value:at:)`.

#### Control Types and UI Rendering

| `ControlType` | SwiftUI control | Notes |
|---|---|---|
| `.toggle` | `Button` (bordered, tinted when on) | Flips between `0.0` and `1.0`; hand-placed in `mainToolbar` with per-toggle icons — Onset Enable = `power`, Onset Needs Init = `x.circle.fill` — while Enable Training renders as a "Train" text button |
| `.rotary` | `RotarySlider` (pure SwiftUI `View` using `Canvas` + `DragGesture`) | Single horizontal row in `parametersPanel`: Onset Input pinned in a leading column set off by a `Divider()`, the other five distributed with equal `Spacer()`s; label and current value displayed below the knob; arc sweeps 270° from ~7:30 (min) to ~4:30 (max); vertical drag changes value (Shift = 10× finer); double-click resets to `initialOverride ?? defaultValue` |
| `.discrete` | Hand-placed per param | Synth Mode renders as a 2-state icon radio (`waveform.circle.fill` = 1 / `hockey.puck` = 0); Greyhole Preset renders as a `Slider(step: 1)` with a `dice`-icon Randomize button (`Param.hasRandomize`) that sends a fixed trigger value (`9`) directly via `setParameter` without updating `values[]` |
| `.numberInput` | `NumberInputCell` — text field + label | Displayed in `mainToolbar` in the same row as the onset toggle icons and the Analyze button (no divider); commits on Return or focus loss; clamps to `param.min…param.max` |

`RotarySlider` is platform-agnostic (no `NSViewRepresentable`/`UIViewRepresentable`) and works unchanged on macOS and iOS. Drag sensitivity is `150 px / full range`; holding Shift multiplies that by 10×. The `#if os(macOS)` block inside `dragGesture` reads `NSEvent.modifierFlags` for the Shift check; on iOS the fine flag is always `false`.

**`NumberInputCell`** is a standalone `View` struct (before `ContentView` in `ContentView.swift`) with its own `@State` text buffer and `@FocusState`. On commit it parses a `Float` from the text, clamps to `param.min…param.max`, and calls `onCommit(clamped)` → `store.set(value:at:)`. The display reverts to the last valid value on unparseable input. Decimal precision adapts to the parameter's range: `%.0f` for range > 10, `%.2f` for range > 1, `%.3f` for range ≤ 1. While the field is focused, external value changes (e.g. from `pushAllValuesToEngine`) do not overwrite `editText` mid-edit.

#### Swift UI → RNBO Parameter Call Chain

```
User moves control
    → SwiftUI Binding<Float>.set closure
    → store.set(value:at:)          [main thread]
        → values[i] = value         [updates display]
        → engine.setParameter(index:value:)
            → AudioEngine.mm: _paramEventInterface->setParameterValue(index, value)
                → RNBO CoreObject applies value on next process() call
```

Host writes route through `_paramEventInterface` rather than calling `_coreObject.setParameterValue(...)` directly. The interface's pointer is recorded as the event's source, which is what the listener path (below) filters on to distinguish host writes from patch-internal writes and avoid feedback loops.

UI-driven parameter changes are fire-and-forget on this path. The reverse direction — patch-internal writes flowing back into `values[]` — is handled by the listener path described under **RNBO Patch → Swift UI Listener Path** below. The `values` array remains the sole source of truth for UI display; both write directions update it before SwiftUI redraws.

#### Initialization Sequence

```
1. ContentView struct initialised by SwiftUI
       ↓
2. @State var store = ParameterStore()
       ↓
3. ParameterStore.init
   a. AudioEngine() created
      └─ AudioEngine.init creates _paramEventInterface (handler = _midiCapture) and
         _paramListenerInterface (handler = _paramCapture); records
         _paramEventInterface.get() on _paramCapture as the host-write source id;
         resolves SpecFlatCutoff and SpecCentCutoff indices and seeds _paramCapture's
         watched set. Then calls -setupEngine, which creates the permanent AVAudioEngine,
         queries the hardware sample rate, allocates scratch buffers, calls
         prepareToProcess(sr, kMaxFrames) and loadRNBODataRefs, then creates and connects
         AVAudioSourceNode and calls [_engine startAndReturnError:]. The audio render thread
         begins immediately; RNBO processes silence (_isPlaying = false) until Play is pressed.
   b. engine.numParameters() → _coreObject.getNumParameters()
      (safe to call before prepareToProcess; CoreObject is fully constructed)
   c. For each RNBO parameter index 0..<n:
      - engine.parameterInfo(at: i) → getParameterInfo() + getParameterId()
      - ID looked up in specs whitelist; non-matching IDs silently skipped
      - Matching entries appended to `collected` array
   d. collected sorted by sortOrder → params
   e. values[] initialised — entries with `initialOverride` use that value; all others
      use `param.defaultValue` (RNBO's `assign_defaults` initialValue). NO
      setParameterValue calls are made here.
   f. engine.parameterChangeHandler assigned a [weak self] closure that maps an
      incoming (index, value) callback to ParameterStore.updateValueFromEngine(at:value:).
      This is the RNBO → UI listener path; see the dedicated section below.
       ↓
4. SwiftUI renders ContentView body; parameter controls display their initial values
       ↓
5. User presses Play → engine.start(), then store.pushAllValuesToEngine()
   - engine.start() sets _isPlaying = true — PCM data begins feeding RNBO (render thread
     already running since init)
   - pushAllValuesToEngine() queues ALL current values[] into RNBO's parameter interface
   - First process() block drains the queued values
```

The key constraint: `getNumParameters()` and `getParameterInfo()` are called before `prepareToProcess()`. This is safe because `RNBO::CoreObject`'s constructor fully initialises the patcher, including the parameter table, before any audio processing begins.

**`ParameterStore.pushAllValuesToEngine()`** iterates all `params[]` entries and calls `engine.setParameter(index:value:)` for each using `values[i]`. It is the single mechanism for syncing the full UI state to RNBO and is called from three sites in `ContentView`:

| Call site | When | Purpose |
|---|---|---|
| Play button, after `engine.start()` | Every time playback starts | Apply current UI state (including `initialOverride` values) before first real-time block |
| `exportAudioOffline()` / `exportMIDIOffline()`, after `engine.stopForOfflineRender()` | Before offline render dispatch | Queue current UI values while no render blocks are running; must follow `stopForOfflineRender()` |
| `exportAudioOffline()` / `exportMIDIOffline()` cancel and completion paths, after `engine.resumeAfterOfflineRender()` | After offline render or cancellation | Re-push UI values after RNBO was reset by offline `prepareToProcess(reset=true)` |

#### RNBO Patch → Swift UI Listener Path

The RNBO patch writes to certain parameters internally. Currently this applies to `SpecFlatCutoff` and `SpecCentCutoff`, which the patch sets after the **Enable Training** feature finishes processing a window of audio: the patch clusters per-onset spectral centroid and flatness features into kick vs. snare groups and computes the cutoff "border" values between the clusters.

Without a listener, those patch-internal writes are invisible to the UI:
- The rotaries continue to display the pre-training values.
- The next `pushAllValuesToEngine()` call (Play press, or before an offline render) overwrites the patch-computed values with the stale UI state.

The listener path captures these writes at the C++ layer and mirrors them into `ParameterStore.values[]` on the main thread. The rotaries then redraw via `@Observable` and subsequent `pushAllValuesToEngine()` calls preserve the trained values.

##### Two-interface architecture

Two `ParameterEventInterface` instances are registered on the `CoreObject`, each with its own `RNBO::EventHandler` subclass:

| Interface | Handler | Purpose |
|---|---|---|
| `_paramEventInterface` | `_midiCapture` (`MidiEventCapture`) | MIDI event drain (Step 10); also the **host-write interface** used by `setParameterWithIndex:value:` and `setParameterWithId:value:` |
| `_paramListenerInterface` *(new)* | `_paramCapture` (`ParameterEventCapture`) | Receives parameter-change notifications for the watched set |

Both interfaces receive the same outgoing events from the engine. Each handler inherits no-op defaults for event types it does not care about, so `MidiEventCapture` silently ignores `handleParameterEvent` notifications and `ParameterEventCapture` silently ignores `handleMidiEvent` notifications. Separating them this way keeps each class focused on a single event type rather than mixing two unrelated concerns into one handler.

`ParameterEventCapture` is a file-scope class in `AudioEngine.mm`, declared immediately after `MidiEventCapture`. It mirrors the `MidiEventCapture` design: `eventsAvailable` is an intentional no-op, `drain()` is a thin public wrapper around `EventHandler::drainEvents()`, and `drain()` is called explicitly from the audio render block — once for `_midiCapture`, then once for `_paramCapture` — immediately after `core->process()`. The same drain pair runs after each `process()` in the offline loop pre-warm and main blocks.

##### handleParameterEvent filter chain

`handleParameterEvent` runs on the audio thread (same context as `handleMidiEvent`). Three filters are applied in order before any work is dispatched:

1. **Delivery flag** — `std::atomic<bool> _deliveryEnabled`. Toggled false around offline renders (see *Offline-render isolation* below). When false, every event is dropped before the source and watched-index filters even run.
2. **Source filter** — drops events whose `getSource()` equals `_hostInterfaceId`. This is the feedback-loop guard described below.
3. **Watched-indices filter** — drops events whose `getIndex()` is not in `_watchedParamIndices`. Currently the set is `{ SpecFlatCutoff, SpecCentCutoff }`; either is silently skipped at init if the patch does not expose it.

Events that survive all three filters are forwarded to Swift by `dispatch_async`'ing the registered Objective-C block onto the main queue. The block invocation captures `index` and `value` by value, so the audio thread holds no reference across the async boundary.

##### Source-ID identity (feedback-loop avoidance)

RNBO's `ParameterInterfaceId` is just the implementation pointer of the originating interface (`const void *`). Every `ParameterEvent` carries the source via `getSource()`.

For the listener to distinguish host-driven writes (which it must drop) from patch-internal writes (which it must forward), all host writes are now routed through `_paramEventInterface->setParameterValue(...)` rather than `_coreObject.setParameterValue(...)` directly. The interface's pointer is recorded once at init on `_paramCapture` as `_hostInterfaceId`:

```objc
_paramCapture.setHostInterfaceId(
    (RNBO::ParameterInterfaceId)_paramEventInterface.get()
);
```

Every host write then comes back through `handleParameterEvent` with `event.getSource() == _hostInterfaceId` and is dropped at the source filter. Patch-internal writes carry a different source (the patcher's internal origin) and pass through.

Concretely, this means a user-driven turn of the `SpecFlatCutoff` rotary:
1. updates `values[i]` immediately (UI redraws),
2. queues a `setParameterValue` on `_paramEventInterface`,
3. drains as a `ParameterEvent` whose source equals `_hostInterfaceId`,
4. is dropped at the source filter — **no redundant listener-driven update**.

##### Offline-render isolation

`prepareToProcess(reset=true)` inside the offline loop fires `ParameterBangEvents` for the patch's `assign_defaults` values, and the Swift layer's `pushAllValuesToEngine()` call (immediately after `stopForOfflineRender`) fires another round through `_paramEventInterface`. Both run on the offline / audio thread; their resulting `dispatch_async` blocks would otherwise land on the main queue **after** `resumeAfterOfflineRender` returns and overwrite training-computed values that `ParameterStore.values` was already correctly holding.

The fix is bracketing the offline window with the delivery flag:

| Step | Effect on `_paramCapture._deliveryEnabled` |
|---|---|
| `stopForOfflineRender` | set to `false` |
| Offline render runs; `_paramCapture.drain()` still called each block to empty the queue | every event dropped at filter 1 |
| `resumeAfterOfflineRender` | set back to `true` |
| `pushAllValuesToEngine()` runs (host writes through `_paramEventInterface`) | events delivered, but dropped at the source filter (filter 2) |

The drain calls themselves are not skipped — the queue must still be emptied to avoid backlogs — only the dispatch-to-main step is suppressed.

##### Swift side — callback registration

`AudioEngine` exposes:

```objc
@property (nonatomic, copy, nullable) void (^parameterChangeHandler)(int index, float value);
```

The custom setter copies the block and forwards it to `_paramCapture.setParamChangeBlock(...)`, adapting the Swift-facing `(int, float)` signature to the C++ `(RNBO::ParameterIndex, RNBO::ParameterValue)` types `ParameterEventCapture` stores internally.

`ParameterStore.init` registers the handler at the end of construction:

```swift
engine.parameterChangeHandler = { [weak self] index, value in
    guard let self else { return }
    guard let i = self.params.firstIndex(where: { $0.rnboIndex == Int32(index) })
    else { return }
    self.updateValueFromEngine(at: i, value: value)
}
```

`updateValueFromEngine(at:value:)` writes `values[i]` directly. It does **not** call `engine.setParameter` — the value is already live in RNBO, and pushing it back would either no-op (filtered by source) or, if constraint clamping shifted it, send a redundant event:

```swift
func updateValueFromEngine(at i: Int, value: Float) {
    guard i >= 0, i < values.count else { return }
    values[i] = value
}
```

The `[weak self]` capture prevents a retain cycle: `AudioEngine` (owned by `ParameterStore`) would otherwise strongly retain a closure that strongly retains `ParameterStore`.

##### End-to-end flow summary

**User-driven write (e.g. user turns the `SpecFlatCutoff` rotary):**
```
[main]   store.set(value:at:) → values[i] = value (UI redraws)
                              → engine.setParameter(...)
                                  → _paramEventInterface->setParameterValue(...)
                                  → event queued, source = _paramEventInterface.get()
[audio]  core->process() → midiCapture->drain() → paramCapture->drain()
                                  → handleParameterEvent fires
                                  → source == _hostInterfaceId → DROPPED ✓
```

**Patch-internal write (e.g. EnableTraining computes `SpecFlatCutoff`):**
```
[audio]  core->process() runs training; patch writes SpecFlatCutoff
                                  → event queued, source = patcher-internal
         paramCapture->drain() → handleParameterEvent fires
                                  → delivery enabled, source ≠ _hostInterfaceId,
                                    index in watched set
                                  → dispatch_async to main queue
[main]   block invocation
                                  → store.updateValueFromEngine(at: i, value:)
                                  → values[i] = value
                                  → @Observable triggers SwiftUI rotary redraw ✓
```

##### Adding more watched parameters

To watch additional parameters in the future, extend the seed list in `AudioEngine -init`:

```objc
for (NSString *paramId in @[@"SpecFlatCutoff", @"SpecCentCutoff", @"NewParamId"]) {
    ...
}
```

No Swift changes are required as long as the new parameter ID already appears in `ParameterStore.specs` (otherwise the callback's `firstIndex(where:)` lookup will return `nil` and the update will silently no-op). The handler's per-call cost is unaffected by the size of the watched set — `std::set::find` is logarithmic and the dispatch overhead dominates.

---

### MIDI Event Handling System (Step 10)

#### Overview

RNBO emits MIDI output events (e.g. Note On per detected onset) via an `RNBO::EventHandler` subclass registered with `CoreObject` through a `ParameterEventInterface`. The host accumulates these events and exposes them to Swift on demand. There is no CoreMIDI involvement — events are captured as raw bytes with timestamps for downstream use by `swift-midi-file` (Step 11).

#### C++ class: `MidiEventCapture`

Defined at file scope in `AudioEngine.mm`, before `@implementation AudioEngine`. Subclasses `RNBO::EventHandler` and owns the accumulation buffer.

```
MidiEventCapture : public RNBO::EventHandler
    std::mutex              _mutex
    std::vector<MidiEvent>  _events

    eventsAvailable()        — intentional no-op (see drain() design below)
    handleMidiEvent(event)   — appends event to _events under _mutex
    drain()                  — public wrapper for protected drainEvents()
    collectAndClear()        — swaps out _events under _mutex; returns the snapshot
```

`eventsAvailable()` must be overridden (it is pure virtual in `RNBO::EventHandler`) but is left as a no-op because we drain explicitly after each `process()` call rather than scheduling a deferred drain. The RNBO documentation warns against draining inside `eventsAvailable()` to avoid blocking the audio thread; for this app the explicit post-process drain is both simpler and correct.

`drain()` exposes the protected `drainEvents()` method from `EventHandler`. Calling `drainEvents()` tells the `ParameterEventInterface` to dequeue all events from its internal lock-free outgoing queue and call back into `handleMidiEvent()` for each one.

#### Connection to RNBO

In `-[AudioEngine init]`, after probing the hardware sample rate:

```cpp
_paramEventInterface = _coreObject.createParameterInterface(
    RNBO::ParameterEventInterface::SingleProducer,
    &_midiCapture
);
```

`SingleProducer` selects a SPSC (single-producer, single-consumer) lock-free queue. The audio thread is the sole producer of outgoing events (MIDI, parameter feedback). Our `drain()` calls are the sole consumer. The `ParameterEventInterfaceUniquePtr` is stored as an ivar; the interface holds a raw pointer to `_midiCapture`, so the interface must be destroyed first (see Lifecycle below).

#### Event flow

```
AVAudioSourceNode render block (audio thread)
    └─ core->process(inBufs, 2, outBufs, 2, frameCount)
           └─ RNBO patch detects onset → emits MidiEvent
              → pushOutgoingEvent() → _outgoingQueue.enqueue()
              → notifyOutgoingEvents() → eventsAvailable() [no-op]
    └─ midiCapture->drain()
           └─ drainEvents() → _paramEventInterface->drainEvents()
                  └─ _outgoingQueue.dequeue() loop
                         └─ handleMidiEvent(event)
                                └─ _mutex.lock()
                                   _events.push_back(event)
                                   _mutex.unlock()
```

`drain()` is called unconditionally every render block. When there are no pending events, `drainEvents()` dequeues zero items and returns immediately — negligible overhead.

For the offline render loop (Step 11), `drain()` is called in the same way after each `process()` iteration on the offline thread. The mechanism is identical; no special-casing is required.

#### Threading model

| Operation | Thread | Lock held |
|---|---|---|
| `handleMidiEvent()` | Audio render thread | `_mutex` (brief append) |
| `collectAndClear()` | Swift/main thread | `_mutex` (brief swap) |
| `drain()` | Audio render thread (real-time) or offline thread | None |

`std::mutex` is sufficient here. The percussion detector generates one MIDI event per onset (sparse), so `_mutex` is almost never contested. The brief lock in `handleMidiEvent()` does not meaningfully impact the audio thread.

#### Swift-visible API

Declared in `AudioEngine.h`:

```objc
- (NSArray<NSDictionary<NSString *, id> *> *)collectAndClearMidiEvents
    NS_SWIFT_NAME(collectAndClearMidiEvents());
```

Each element of the returned array is an `NSDictionary` with two keys:

| Key | ObjC type | Swift type | Content |
|---|---|---|---|
| `"timestampMs"` | `NSNumber (double)` | `Double` | RNBO engine time in milliseconds at the moment the event was generated. Monotonically increasing; origin is `prepareToProcess()`. |
| `"bytes"` | `NSData` | `Data` | Raw MIDI bytes — 1, 2, or 3 bytes depending on message type. For Note On/Off: `[statusByte, noteNumber, velocity]`. |

`collectAndClearMidiEvents()` atomically swaps out the accumulation buffer and returns a snapshot. Subsequent calls return only events accumulated since the previous call.

#### Validated MIDI output

Confirmed via Xcode debugger breakpoint on `handleMidiEvent` during kick onset detection:

```
_midiData[0] = 0x90   →  Note On, channel 1
_midiData[1] = 0x24   →  note 36 (C1 — GM kick drum)
_midiData[2] = 0x7C   →  velocity 124
_eventTime   = 391.0 ms
_length      = 3
```

Note: LLDB displays printable-range `uint8_t` values as ASCII characters (`0x24` → `'$'`, `0x7C` → `'|'`). Cross-reference any character against an ASCII table to recover the numeric byte value.

#### Object lifetime and teardown

`_midiCapture` and `_paramEventInterface` are both value-type ivars of `AudioEngine`. The interface holds a raw `EventHandler*` pointer to `_midiCapture`. If the interface outlived `_midiCapture`, that pointer would dangle.

`-[AudioEngine dealloc]` resets the interface first:

```objc
- (void)dealloc {
    _paramEventInterface.reset(); // disconnects handler before _midiCapture is destroyed
}
```

After `reset()`, the interface calls `handler->linkToParameterEventInterface(nullptr)` internally, setting the handler's `_peInterface` to `nullptr`. Any subsequent `drain()` call on the already-disconnected handler becomes a safe no-op.

---

### Audio File Dependency Loading

RNBO patches that use `buffer~` objects backed by audio files (e.g. `groove~` for sample playback) do not auto-load those files. The host must populate them explicitly via `CoreObject::setExternalData()`. RNBO exposes the required metadata through the `ExternalDataRef` API:

```
_coreObject.getNumExternalDataRefs()       — count of all DataRefs
_coreObject.getExternalDataId(i)           — memory ID (e.g. "buf1", "buf2")
_coreObject.getExternalDataInfo(i).file    — original filename (e.g. "TR-909_Snare...wav")
                                 .tag     — object type ("buffer~" or "data~")
```

The host loads each file-backed ref in `-loadRNBODataRefs` (called from `-setupEngine` after `prepareToProcess`):

1. Look up the filename in the app bundle (searches `RNBO/media/`, `media/`, then root).
2. Read via `AVAudioFile` — `processingFormat` is always Float32 non-interleaved at the file's native rate.
3. Interleave channels into RNBO's `Float32Buffer` layout: `[ch0f0, ch1f0, ch0f1, ...]`.
4. Call `setExternalData(memId, data, sizeInBytes, dtype, releaseCallback)`.

The `DataType` passed to `setExternalData` must include the channel count and the file's **native sample rate** (not the engine rate). RNBO's `groove~` uses the stored rate to pitch-correct playback relative to the current engine rate.

The release callback (`delete[] (float*)data`) is invoked by RNBO when it no longer needs the buffer — either when new data replaces it or when the `CoreObject` is torn down.

The two file-backed refs in the current patch are both mono at 44100 Hz:

| RNBO ID | File | Frames |
|---|---|---|
| `buf2` | `TR-909_Kick_HighToneMinAttackMidDecay.wav` | 13 728 |
| `buf1` | `TR-909_Snare_AccentHighTuningHighToneMaxSnap.wav` | 17 549 |

These are used by `groove~` in **Synth Mode 1**. Synth Mode 0 uses a separate physical modelling synth and does not require these refs to be loaded.

---

### Offline Audio and MIDI Export (Step 11)

#### Overview

Two offline export paths replay the loaded PCM array through the RNBO DSP faster than real time — one writing a processed WAV file, one accumulating MIDI events for export as a Standard MIDI File. Both share a single private processing loop in `AudioEngine.mm` and are triggered by dedicated buttons in the SwiftUI transport panel.

#### Threading model

The critical constraint is mutual exclusion with the real-time `AVAudioSourceNode` render block: RNBO's `CoreObject` is single-threaded and cannot be called from two threads simultaneously.

**Strategy: halt the AVAudioEngine hardware IO before dispatching the offline render.** Swift calls `engine.stopForOfflineRender()` on the main thread, which calls `[_engine stop]` — halting the render block and guaranteeing exclusive access to `_coreObject` from the background thread. The `AVAudioEngine` instance is not released; `engine.resumeAfterOfflineRender()` restarts hardware IO on the main thread after the render completes.

A critical ordering constraint: `store.pushAllValuesToEngine()` must be called after `stopForOfflineRender()` and before the background dispatch. Calling it while the render block is still running risks render blocks consuming the queued parameter values before the offline pre-warm block can process them.

The blocking ObjC++ call is dispatched to `DispatchQueue.global(qos: .userInitiated)` so the main thread remains free for UI updates. `resumeAfterOfflineRender()`, `pushAllValuesToEngine()`, and `isExporting = false` are all posted back to the main queue on completion.

```
Main thread                                    Background thread (userInitiated)
─────────────────────────────────────────      ────────────────────────────────────────────────
engine.stopTransportIfNeeded()
engine.stopForOfflineRender()  ─renders dead─►
store.pushAllValuesToEngine()
isExporting = true
NSSavePanel (modal)
DispatchQueue.global.async ─────────────────── ► renderOfflineAudio(to:) or renderOfflineMIDI()
                                                  [blocking — may take several seconds]
                                                  DispatchQueue.main.async ────────────────►
                                                                             engine.resumeAfterOfflineRender()
                                                                             store.pushAllValuesToEngine()
                                                                             isExporting = false
```

#### Shared offline loop: `_runOfflineLoopWritingTo:pcmBuf:error:`

Both export methods delegate to this private ObjC++ method:

1. **Reset DSP state** — `_coreObject.prepareToProcess(_engineSampleRate, kOfflineBlockSize, true)`. The `force=true` argument reinitialises all internal RNBO state (filter history, delay lines, onset detector accumulators) while preserving user-set parameter values.
2. **Discard real-time MIDI events** — `_midiCapture.collectAndClear()` flushes any events accumulated during real-time playback so they do not contaminate the offline MIDI pass.
3. **Block loop** — iterates `pos = 0 … totalFrames` in `kOfflineBlockSize = 64` frame steps:
   - Copies PCM input (`_pcmL`/`_pcmR`) into local `std::vector` scratch buffers; zero-pads the final partial block.
   - Calls `_coreObject.process(inBufs, 2, outBufs, 2, kOfflineBlockSize)` — always a full 64-frame call for consistent RNBO behaviour.
   - Calls `_midiCapture.drain()` — flushes RNBO's internal lock-free outgoing queue into `_midiCapture._events` after every block.
   - **Audio path only**: copies output samples into a pre-allocated `AVAudioPCMBuffer` (reused across all blocks; `frameLength` adjusted for the final block) and writes to `AVAudioFile`.

The scratch buffers (`std::vector<RNBO::SampleValue>`) are stack-local to the method. There is no sharing with the real-time `_inL`/`_inR`/`_outL`/`_outR` ivars (which are managed by `-start`/`-stop`).

#### Block size choice

```
kOfflineBlockSize = 64 frames
  → ≈1.45 ms/block at 44.1 kHz
  → ≈1.33 ms/block at 48 kHz
```

64 frames is chosen for onset-detection timing resolution. RNBO timestamps each MIDI event to the start of the block in which it was generated, so a smaller block reduces the quantisation error on each detected onset. This is a deliberate trade-off: offline throughput is not a bottleneck on macOS desktop, so we favour accuracy over speed.

#### MIDI event flow (offline path)

```
_runOfflineLoopWritingTo: (background thread)
    └─ process() → MidiEvent pushed to RNBO's outgoing lock-free queue
    └─ _midiCapture.drain() → drainEvents() → handleMidiEvent()
           └─ _mutex.lock()
              _events.push_back(event)
              _mutex.unlock()

[loop completes]

renderOfflineMIDI returns → Swift calls collectAndClearMidiEvents()
    └─ _mutex.lock()
       swap _events → return snapshot
       _mutex.unlock()
    └─ Swift receives [[String: Any]] — timestampMs + raw MIDI bytes
```

`collectAndClearMidiEvents()` is called on the same background thread immediately after `renderOfflineMIDI` returns. Because the engine is stopped (no concurrent render block), `_midiCapture` has a single writer/reader at this point and the `std::mutex` is uncontested.

#### MIDI file construction (Swift layer)

MIDI file assembly is handled entirely in Swift using `swift-midi-file` (`MusicalMIDI1File`), keeping C++ dependencies out of the file-format layer.

**Timebase:** 480 PPQ, 120 BPM.  
**Tick conversion:** `ticks = round(timestampMs × 480 × 120 / 60 000) = round(ms × 0.96)`  
**Delta time:** events are sorted by absolute tick; each event's delta is `absTick − prevAbsTick`.

RNBO emits fully-formed Note On (`0x9x`) and Note Off (`0x8x`) messages — the patch is configured to output 100 ms note durations with explicit Note Offs. The Swift layer passes all bytes through without synthesis:

| Status nibble | Handling |
|---|---|
| `0x9` + velocity > 0 | `Track.Event.noteOn(delta:note:velocity:channel:)` |
| `0x8` or `0x9` + velocity == 0 | `Track.Event.noteOff(delta:note:velocity:channel:)` |
| Other | Skipped |

A `Track.Event.tempo(delta: .none, bpm: 120)` event is prepended at tick 0.

#### `Onset/enable` auto-enable on MIDI export

The `Onset/enable` RNBO parameter gates all onset detection. If it is off during the offline loop, no MIDI events are generated and the export produces an empty file.

`exportMIDIOffline()` checks and force-enables this parameter before running the offline loop:

```swift
if let i = store.params.firstIndex(where: { $0.rnboId == "Onset/enable" }),
   store.values[i] < 0.5 {
    store.set(value: 1, at: i)  // updates UI toggle + calls setParameterValue on CoreObject
}
```

`store.set(value:at:)` updates both `store.values[i]` (UI binding) and calls `engine.setParameter(index:value:)` (live RNBO parameter). The toggle button reflects the change immediately. The parameter is left enabled after export.

To support this lookup, `Param` stores `rnboId: String` (the full RNBO parameter path, e.g. `"Onset/enable"`) populated at `ParameterStore` init time alongside the other parameter metadata.

#### Required entitlement

`NSSavePanel` requires the **User Selected File Read/Write** entitlement (`com.apple.security.files.user-selected.read-write`) in the App Sandbox. Set via Xcode → target → Signing & Capabilities → App Sandbox → File Access → User Selected File → **Read/Write**.

---

### Host-Default Parameters and RNBO Initialization

#### Overview

Some RNBO parameters have `assign_defaults` values unsuitable for the target use case. The host provides better initial values via two cooperating mechanisms:

- **`initialOverride`** in `ParameterStore.specs` — sets the initial display value in the UI
- **`pushAllValuesToEngine()`** — pushes current `values[]` (including `initialOverride` values) into RNBO at the right moment

Currently the five Onset detection-tuning parameters use this pattern:

| RNBO ID | `initialOverride` | RNBO `assign_defaults` |
|---|---|---|
| `Onset/thresh` | 0.5 | (patch default) |
| `Onset/relaxtime` | 0.5 | 1.0 |
| `Onset/floor` | 0.1 | (patch default) |
| `Onset/mingap` | 20.0 | 10.0 |
| `Onset/medspan` | 11.0 | (patch default) |

`Onset/odftype` (int — selects the onset detection function) has no UI control yet and no `initialOverride`; it therefore uses the RNBO `assign_defaults` value. If that default proves incorrect, add it to `specs` with `initialOverride: 1.0` (or the appropriate value) and `.numberInput` control type.

#### ParameterBangEvent ordering problem

RNBO's `startup()` → `processParamInitEvents()` schedules a `ParameterBangEvent` at t=0 for every parameter during `CoreObject` construction. In the very first `process()` call, `drainParameterQueues()` adds our `pushAllValuesToEngine()` events — also at t=0 — but *after* the bang events in `_scheduledEvents` insertion order. Equal-time events are processed FIFO:

```
First process() call (t = 0), without the pre-warm fix:
  1. ParameterBangEvents fire → re-assert assign_defaults values
  2. Metro fires at t=0 (scheduled by startup clock events) → reads wrong values
  3. pushAllValuesToEngine() events fire → correct values, but too late for metro tick 1
```

This only manifests in the **offline render when no real-time blocks have run first** — real-time blocks naturally consume the `ParameterBangEvent`s, so subsequent offline renders see no competing events.

#### Fix: silent pre-warm block in `_runOfflineLoopWritingTo`

Before the main render loop, `_runOfflineLoopWritingTo` processes one silent 64-frame block. The values queued by `pushAllValuesToEngine()` (called from Swift before `renderOfflineMIDI()` / `renderOfflineAudio()`) are in the parameter interface at this point and are drained alongside the `ParameterBangEvent`s. Because our events are inserted after the bang events, they fire last at t=0, winning the ordering race:

```
Swift (main thread, before render dispatch):
    store.pushAllValuesToEngine()       — queues current values[] into RNBO interface

AudioEngine.mm (background thread):
    prepareToProcess(kOfflineBlockSize, force=true)
    _midiCapture.collectAndClear()      — discard real-time events

    process(silence, 64 frames)         — drainParameterQueues(): bang events first,
                                          then our events; both at t=0 but FIFO order:
                                          assign_defaults → our values → metro reads ours ✓
    _midiCapture.drain()
    _midiCapture.collectAndClear()      — discard pre-warm MIDI events

    // main render loop (pos = 0 … totalFrames)
    // RNBO patcher now holds the correct UI values
```

The pre-warm is harmless when real-time blocks have already run: the bang events are already consumed, and the extra block just processes silence with the correct parameter state intact.

#### Adding parameters with host defaults but no UI control yet

Add an entry to `specs` as `.numberInput` with `initialOverride` set to the desired host default. It will appear in the number-input row alongside the existing Onset tuning parameters, giving the user visibility and control over the value. The `initialOverride` ensures `pushAllValuesToEngine()` applies the correct host default if the user never changes it.

#### Adding UI controls for parameters currently without them

1. Add the parameter to `specs` with the appropriate `controlType` and an `initialOverride` if the RNBO `assign_defaults` value is unsuitable.
2. The existing `store.set(value:at:)` → `engine.setParameter(index:value:)` call chain handles all user-driven changes.
3. `pushAllValuesToEngine()` is already called at all relevant sites — no additional wiring needed.

---

### Audio Waveform Display (Step 13)

**Files modified/created:** `AudioEngine.h`, `AudioEngine.mm`, `WaveformView.swift` (new), `ContentView.swift`

The implementation separates three concerns: thumbnail computation (once on file load, background thread), waveform rendering (at draw time via SwiftUI `Canvas`), and playhead animation (30 fps `TimelineView` polling an atomic property).

#### `AudioEngine.h` / `AudioEngine.mm` — Three new APIs

```objc
- (nullable NSData *)waveformThumbnailDataWithBinCount:(NSInteger)binCount
    NS_SWIFT_NAME(waveformThumbnailData(binCount:));

@property (readonly) double playheadFraction;
@property (readonly) int64_t totalFrameCount;
```

`waveformThumbnailData(binCount:)` does a single O(N) linear pass over `_pcmL`. For each bin `i`, it computes `start = i * total / binCount` and `end = (i+1) * total / binCount`, then scans `[start, end)` for min and max, writing the pair at `out[i*2]` / `out[i*2+1]` into a pre-allocated `NSMutableData` of `binCount * 2 * sizeof(float)` bytes.

`playheadFraction` performs `(double)_playhead.load(relaxed) / (double)_pcmFrameCount.load(relaxed)` with a zero guard on `total`. `totalFrameCount` is a direct relaxed atomic load. Both are safe for lock-free reads from the main thread at 30 fps.

#### `WaveformView.swift` — new file

**`WaveformThumbnail`** value type unpacks the flat `NSData` blob into `[(min: Float, max: Float)]` using `withUnsafeBytes` / `bindMemory(to: Float.self)` for a zero-copy decode.

**`WaveformView`** uses `GeometryReader` wrapping a `Canvas`. The `Canvas` closure draws in three layers:

1. **Background** — solid black fill.
2. **Waveform** — when `thumbnail != nil`: one vertical line segment per bin in a single `Path` pass, stroked in `Color(red: 0.2, green: 0.5, blue: 1.0)` at 1 pt.
3. **Placeholder / playhead** — mutually exclusive on `thumbnail`:
   - When `thumbnail == nil`: "Import an Audio File" centred in the canvas, rendered via `context.resolve(Text(...))` + `context.draw(_:at:anchor:)` using `NSColor.tertiaryLabelColor`.
   - When `thumbnail != nil`: yellow playhead line (`Color(red: 1.0, green: 0.85, blue: 0.2)`, 1.5 pt) at `size.width * playheadFraction`.

A `DragGesture(minimumDistance: 0)` on the canvas converts `value.location.x / geo.size.width` to a seek fraction and calls `onSeek?`.

#### `ContentView.swift` changes

New state: `@State private var waveformThumbnail: WaveformThumbnail? = nil`

Thumbnail computation dispatched to a background thread in the `fileImporter` callback, after `engine.loadAudioFile(from: url)`:

```swift
let eng = engine
DispatchQueue.global(qos: .userInitiated).async {
    guard let data = eng.waveformThumbnailData(binCount: 2048) else { return }
    let thumb = WaveformThumbnail(data: data)
    DispatchQueue.main.async { waveformThumbnail = thumb }
}
```

Fixed bin count of **2048** — always ≥ typical macOS window widths, giving at least one bin per display pixel.

`body` restructured into three layers: title (`Text`) with `.padding([.top, .leading, .trailing]).padding(.bottom, 10)`, then edge-to-edge waveform wrapped in `TimelineView(.periodic(from: .now, by: 1.0/30.0))` at `.frame(height: 150)`, then `mainToolbar.padding()`.

`transportPanel` renamed to `transportControls` with `Text("PercTranscriber")` removed from it (title now lives above the waveform in `body`). *(Later renamed `mainToolbar` and expanded to also hold the onset toggles, onset number boxes, and the Analyze button — see the Control Types table and the redesign notes.)*

`TimelineView` runs always — not gated on `isPlaying`. Since `engine.playheadFraction` is a lock-free atomic read and `Canvas` is GPU-accelerated, cost at 30 fps is negligible (< 0.1% CPU). Running always avoids SwiftUI view-identity flicker on play/stop transitions.

#### Deviations from the original plan

| Plan | Actual |
|---|---|
| Playhead always visible, sitting at x=0 before file load | Playhead hidden when `thumbnail == nil` |
| No content shown before file load | "Import an Audio File" grey placeholder text centred in canvas |
| Title padding `[.top, .leading, .trailing]` only | Title padding `[.top, .leading, .trailing]` + `.padding(.bottom, 10)` |

#### Visual spec (as implemented)

| Element | Value |
|---|---|
| Background | `Color.black` |
| Waveform color | `Color(red: 0.2, green: 0.5, blue: 1.0)` |
| Waveform line width | 1 pt |
| Playhead color | `Color(red: 1.0, green: 0.85, blue: 0.2)` |
| Playhead line width | 1.5 pt |
| View height | 150 pt |
| Source channel | Left channel (mono or stereo-L) |
| Playhead visible | Only when audio file is loaded (`thumbnail != nil`) |
| Waveform visible | After first file load (`thumbnail != nil`) |
| Placeholder text | "Import an Audio File" in `NSColor.tertiaryLabelColor` when `thumbnail == nil` |
| Seek | Click or drag on waveform at any time (playing or stopped) |

---

### Keep `AVAudioEngine` Alive Across Stop/Play Cycles

**Files modified:** `AudioEngine.h`, `AudioEngine.mm`, `ContentView.swift`

#### Motivation

The original design tore down `AVAudioEngine` on every `stop()` call and rebuilt it on every `start()` call. Beyond the HAL re-init latency and console noise this caused, it meant RNBO DSP — including all effects processing (delay tails, reverb, etc.) — was abruptly cut whenever the user pressed Stop. This is inconsistent with how DAWs and audio apps typically behave: channel-strip plugin processing runs continuously regardless of transport state, letting delay and reverb tails decay naturally when the transport stops.

#### Architecture: always-alive engine with transport gate

`AVAudioEngine` and `RNBO::CoreObject` are initialized once in the private `-setupEngine` method (called from `-init`) and live for the entire `AudioEngine` object lifetime. Transport state is controlled by a single `std::atomic<bool> _isPlaying` ivar, initialized to `false`:

```
Engine lifecycle:  [-init / -setupEngine] ──────running─────────────── [-dealloc]
Transport state:   false ··· true ··· false ··· true ··· false ···
RNBO process():    called every render block regardless of transport state
RNBO input:        PCM data when _isPlaying=true && file loaded; silence otherwise
```

#### `-setupEngine` (called once from `-init`)

Sets up the entire real-time audio stack in one call:

1. Creates the permanent `AVAudioEngine` instance; queries hardware sample rate
2. Allocates scratch buffers `_inL`, `_inR`, `_outL`, `_outR` (lifetime: until `-dealloc`)
3. Calls `_coreObject.prepareToProcess(sr, kMaxFrames)` then `-loadRNBODataRefs`
4. Creates `AVAudioSourceNode` with the modified render block (see below)
5. Connects source → mainMixerNode → outputNode; calls `[_engine startAndReturnError:]`

RNBO begins processing silence immediately (`_isPlaying = false`, no file loaded). No perceptible CPU impact on macOS desktop.

#### Render block behavior

The original `if (pcmL == nullptr || total == 0)` early-exit (which skipped RNBO entirely) has been replaced with a conditional PCM fill. RNBO always runs:

```objc
bool playing = isPlayingPtr->load(std::memory_order_relaxed);

if (playing && pcmL != nullptr && total > 0) {
    // ... fill inL/inR from PCM array, advance playhead (unchanged) ...
} else {
    // Stopped or no file loaded — feed silence so effects tails ring out naturally.
    memset(inL, 0, frameCount * sizeof(RNBO::SampleValue));
    memset(inR, 0, frameCount * sizeof(RNBO::SampleValue));
}

// RNBO always processes regardless of transport state.
core->process(inBufs, 2, outBufs, 2, frameCount);
midiCapture->drain();
// ... copy outBufs to outputData (unchanged) ...
```

When stopped, RNBO receives silence and its output (delay, reverb decay) continues to play through the hardware until it naturally fades to zero. The playhead is not advanced, preserving file position across stop/start cycles.

#### Transport methods

```objc
- (void)start { _isPlaying.store(true,  std::memory_order_relaxed); }
- (void)stop  { _isPlaying.store(false, std::memory_order_relaxed); }
```

No engine allocation, deallocation, or `prepareToProcess` occurs on transport transitions.

#### Offline render engine management

Both the render block and the offline loop call `_coreObject.process()`. Since `CoreObject` is single-threaded they cannot run concurrently. Two new public methods gate hardware IO for offline rendering:

```objc
- (void)stopForOfflineRender {
    [_engine stop];   // halts render block; _engine instance is NOT released
}

- (void)resumeAfterOfflineRender {
    // Restore real-time block size without resetting DSP state.
    _coreObject.prepareToProcess(_engineSampleRate, kMaxFrames);
    [_engine prepare];
    NSError *e = nil;
    if (![_engine startAndReturnError:&e])
        NSLog(@"[AudioEngine] failed to restart after offline render: %@", e);
}
```

After `resumeAfterOfflineRender`, `_isPlaying` is still `false`, so the render block feeds silence to RNBO. The Swift layer calls `store.pushAllValuesToEngine()` immediately after to restore UI parameter state (the offline `prepareToProcess(reset=true)` will have reset RNBO parameters to `assign_defaults`).

Note: `resumeAfterOfflineRender` calls `[_engine startAndReturnError:]`, which re-initializes the CoreAudio HAL proxy IO context and produces the `HALC_ProxyIOContext::IOWorkLoop: context N received an out of order message` console warning. This is now limited to offline render resume events rather than every Play press.

#### Parameter push ordering for offline render

`pushAllValuesToEngine()` must be called **after** `stopForOfflineRender()` — not before. While the render block is running (even feeding silence), it calls `_coreObject.process()` each block, which may consume parameter values queued via `setParameterValue`. Calling after `[_engine stop]` guarantees no render blocks are in flight, so the queued values survive intact for the offline pre-warm block to consume.

ContentView sequence for both export methods:

```
[main thread]
stopTransportIfNeeded()            ← _isPlaying = false
engine.stopForOfflineRender()      ← [_engine stop], render block dead
store.pushAllValuesToEngine()      ← safe: no render blocks running

[background thread — offline render]
prepareToProcess(kOfflineBlockSize, reset=true)
pre-warm block → ParameterBangEvents then UI values (FIFO, UI values win)
main render loop

[main thread — on completion or cancellation]
engine.resumeAfterOfflineRender()  ← prepareToProcess(kMaxFrames) + engine restart
store.pushAllValuesToEngine()      ← restore UI values after RNBO reset
```

#### Object lifetime and teardown

`-dealloc` stops the engine before releasing RNBO resources:

```objc
- (void)dealloc {
    [_engine stop];               // render block dead before _coreObject is destroyed
    _paramEventInterface.reset(); // disconnects handler before _midiCapture is destroyed
    delete[] _inL; delete[] _inR; delete[] _outL; delete[] _outR;
}
```

#### Tradeoffs

| | Old (stop/start engine on transport) | New (always-alive) |
|---|---|---|
| CPU while stopped | Zero — HAL IO thread not running | Small continuous — render block fires at hardware buffer rate (~microseconds/block) |
| Startup latency on Play | HAL re-init (~few ms) | None |
| HAL console warning | Every Play press | Only on offline render resume |
| Effects on Stop | Abrupt cutoff | Natural decay (delay/reverb tails ring out) |

For iOS targets: stop the engine on app backgrounding regardless, since the continuous render-block overhead is non-trivial on battery-constrained devices.

