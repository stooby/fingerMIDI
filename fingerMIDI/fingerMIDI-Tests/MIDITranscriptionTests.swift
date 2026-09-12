//
//  MIDITranscriptionTests.swift
//  fingerMIDI-Tests
//
//  End-to-end regression test for the RNBO audio-to-MIDI transcription.
//
//  Drives the same path as the "Export MIDI" button (ContentView.exportMIDIOffline):
//  import audio → stopForOfflineRender → pushAllValuesToEngine → renderOfflineMIDI →
//  collectAndClearMidiEvents → buildMIDIFile → write .mid. The NSSavePanel is the only
//  step omitted; the file is written to a per-run temp directory instead.
//
//  The rendered file is then compared against a checked-in reference transcription
//  (TestFiles/iPhone13_WindowSill.mid) by an independent Standard MIDI File parser
//  implemented below — deliberately not SwiftMIDIFile, so a regression in the writing
//  library cannot cancel itself out in the reading.
//
//  Preconditions / caveats:
//  • Onset tuning parameters are left at ParameterStore's defaults (the values in
//    ParameterStore.specs). The reference fixture was rendered with those defaults;
//    changing a default is expected to fail this test until the fixture is regenerated.
//  • The offline render runs at the engine's hardware sample rate (AudioEngine.setupEngine
//    reads it from the default output device), and the source audio is resampled to it on
//    import. A machine running at a different sample rate than the one that produced the
//    fixture can shift onsets slightly; the engine sample rate is reported on failure.
//

import XCTest
@testable import fingerMIDI

final class MIDITranscriptionTests: XCTestCase {

    // MARK: Tunables

    /// Maximum allowed divergence, in milliseconds, between a Note On in the freshly
    /// rendered MIDI and its counterpart in the reference fixture. The exported timebase
    /// is 480 PPQ @ 120 BPM (~1.042 ms/tick), so tick rounding alone accounts for ~±1 ms.
    private let timeVarianceTolerance: Double = 5.0

    /// Upper bound on the offline render of an ~11 s file. Generous: it only guards
    /// against a hang, it is not a performance assertion.
    private let renderTimeout: TimeInterval = 120.0

    /// Base name of the test file pair: `<name>.wav` (source audio) and `<name>.mid`
    /// (reference transcription), both in `fingerMIDI-Tests/TestFiles/`.
    private let fixtureName = "iPhone13_WindowSill"

    // MARK: Per-test state

    private var store: ParameterStore!
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Constructing the store constructs AudioEngine, which builds the RNBO CoreObject
        // and starts AVAudioEngine — the same thing the app does at launch. No further
        // app/UI bootstrapping is needed: the transcription path never touches the View.
        store = ParameterStore()

        // Per-run scratch directory. FileManager.temporaryDirectory resolves inside the
        // sandbox container of the test host, so it is writable for every developer and
        // on CI without any extra entitlement or repo-local output folder.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fingerMIDI-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Quiesce the audio hardware before dropping the store. -stopForOfflineRender is
        // the only exposed way to stop AVAudioEngine's IO; the "offline" name is incidental
        // here — what matters is that it halts the render callback and latches the flag that
        // keeps the configuration-change handler from restarting the engine, so the test
        // host is left with no live audio graph. Without it the engine keeps running until
        // ARC gets around to -dealloc, which can outlive the test.
        store?.engine.stopForOfflineRender()
        store = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: The regression test

    func testOfflineMIDIExportMatchesReferenceTranscription() throws {
        let audioURL = try fixtureURL(ext: "wav")
        let referenceURL = try fixtureURL(ext: "mid")
        let engine = store.engine

        // 1. Import the audio file — the call the file-picker sheet makes (ContentView.loadFile).
        engine.loadAudioFile(from: audioURL)
        XCTAssertGreaterThan(engine.totalFrameCount, 0,
                             "Audio file failed to load: \(audioURL.path)")

        // 2. Mirror exportMIDIOffline()'s pre-render sequence exactly: onset detection must be
        //    on for the offline loop to emit anything, hardware IO is stopped so the offline
        //    loop owns the CoreObject, and only then are the UI parameter values queued (they
        //    are consumed by the offline pre-warm block, after RNBO's startup bang events).
        if let i = store.params.firstIndex(where: { $0.rnboId == "Onset/enable" }),
           store.values[i] < 0.5 {
            store.set(value: 1, at: i)
        }
        engine.stopForOfflineRender()
        store.pushAllValuesToEngine()

        // 3. Render offline on a background queue (renderOfflineMIDI blocks), as the app does.
        let rendered = expectation(description: "offline MIDI render")
        DispatchQueue.global(qos: .userInitiated).async {
            engine.renderOfflineMIDI()
            rendered.fulfill()
        }
        wait(for: [rendered], timeout: renderTimeout)

        // 4. Drain the events and restore the engine, both on the main thread as the app does.
        //    Timestamps arrive file-relative — collectAndClearMidiEvents subtracts the render's
        //    start offset from RNBO's cumulative time counter.
        let rawEvents = engine.collectAndClearMidiEvents() ?? []
        engine.resumeAfterOfflineRender()
        store.pushAllValuesToEngine()
        XCTAssertFalse(rawEvents.isEmpty, "Offline render produced no MIDI events at all")

        // 5. Build and write the .mid — the same bytes the save panel would have written.
        let exportedData = try buildMIDIFile(from: rawEvents)
        let exportURL = tempDir.appendingPathComponent("\(fixtureName)-export.mid")
        try exportedData.write(to: exportURL, options: .atomic)
        attach(exportedData, name: "\(fixtureName)-export.mid")

        // 6. Compare against the reference transcription.
        let exported = try parseNoteOns(midiFileAt: exportURL)
        let reference = try parseNoteOns(midiFileAt: referenceURL)

        XCTAssertFalse(reference.isEmpty, "Reference fixture contains no Note On events")
        XCTAssertEqual(
            exported.count, reference.count,
            """
            Note On count changed: exported \(exported.count), reference \(reference.count). \
            \(contextSuffix)
            \(sideBySide(exported: exported, reference: reference))
            """
        )
        // Without a 1:1 correspondence there is nothing meaningful to measure per note.
        guard exported.count == reference.count else { return }

        var failures: [String] = []
        var worstDelta: Double = 0

        for (i, (actual, expected)) in zip(exported, reference).enumerated() {
            let delta = actual.timeMs - expected.timeMs
            worstDelta = max(worstDelta, abs(delta))
            if actual.note != expected.note {
                failures.append(String(
                    format: "  #%02d @ %8.2f ms — pitch %d, reference expects %d",
                    i, actual.timeMs, Int(actual.note), Int(expected.note)))
            }
            if abs(delta) > timeVarianceTolerance {
                failures.append(String(
                    format: "  #%02d note %d — exported %8.2f ms vs reference %8.2f ms (Δ %+.2f ms)",
                    i, Int(expected.note), actual.timeMs, expected.timeMs, delta))
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            """
            \(failures.count) Note On event(s) diverge from the reference beyond \
            ±\(timeVarianceTolerance) ms:
            \(failures.joined(separator: "\n"))
            \(contextSuffix)
            """
        )

        // Not an assertion — a breadcrumb for tightening/loosening timeVarianceTolerance.
        print(String(format: "[MIDITranscriptionTests] %d Note On events matched; "
                     + "largest deviation %.2f ms (tolerance ±%.1f ms)",
                     exported.count, worstDelta, timeVarianceTolerance))
    }

    /// Guards the test's own SMF parser (and the fixture) independently of the audio path:
    /// if this fails, a failure in the main test says nothing about the DSP.
    func testReferenceFixtureParsesAsAMonotonicNoteOnSequence() throws {
        let reference = try parseNoteOns(midiFileAt: try fixtureURL(ext: "mid"))
        XCTAssertFalse(reference.isEmpty, "Reference fixture contains no Note On events")
        XCTAssertEqual(reference, reference.sorted { $0.timeMs < $1.timeMs },
                       "Parsed reference events are not in ascending time order")
        for event in reference {
            XCTAssertGreaterThan(event.velocity, 0, "Note On with velocity 0 should parse as Note Off")
            XCTAssertGreaterThanOrEqual(event.timeMs, 0)
        }
    }

    // MARK: Diagnostics

    private var contextSuffix: String {
        String(format: "(engine sample rate %.0f Hz; onset params %@)",
               store.engine.sampleRate, onsetParamDescription)
    }

    private var onsetParamDescription: String {
        let ids = ["Onset/thresh", "Onset/relaxtime", "Onset/floor", "Onset/mingap", "Onset/medspan"]
        return ids.compactMap { id -> String? in
            guard let i = store.params.firstIndex(where: { $0.rnboId == id }) else { return nil }
            return "\(id)=\(store.values[i])"
        }.joined(separator: ", ")
    }

    private func sideBySide(exported: [NoteOn], reference: [NoteOn]) -> String {
        (0..<Swift.max(exported.count, reference.count)).map { i -> String in
            func describe(_ events: [NoteOn]) -> String {
                guard i < events.count else { return "—" }
                return String(format: "%8.2f ms note %d", events[i].timeMs, Int(events[i].note))
            }
            let left = describe(exported).padding(toLength: 22, withPad: " ", startingAt: 0)
            return String(format: "  #%02d exported: ", i) + left + "reference: " + describe(reference)
        }.joined(separator: "\n")
    }

    private func attach(_ data: Data, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.midi-audio")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Test file lookup

    /// Locates `<fixtureName>.<ext>`.
    ///
    /// The test files live in `fingerMIDI-Tests/TestFiles/`, which the target's
    /// file-system-synchronized group copies into the test bundle's resources — so they are
    /// read from inside the bundle, where the sandboxed test host can always reach them, and
    /// they never ship inside the app.
    ///
    /// The on-disk fallback covers the case where the resource copy didn't happen (a stale
    /// build, or an Xcode that didn't pick the new files up); it only works if the host can
    /// read outside its sandbox container. When neither is available the test skips with
    /// instructions rather than failing, since nothing about the DSP has been exercised.
    private func fixtureURL(ext: String) throws -> URL {
        let bundle = Bundle(for: Self.self)
        // Synchronized groups flatten resources into the bundle root, but check the
        // subdirectory too in case this one is ever copied as a folder reference.
        if let bundled = bundle.url(forResource: fixtureName, withExtension: ext)
            ?? bundle.url(forResource: fixtureName, withExtension: ext, subdirectory: "TestFiles") {
            return bundled
        }
        // .../fingerMIDI-Tests/MIDITranscriptionTests.swift → .../fingerMIDI-Tests/TestFiles/
        let onDisk = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestFiles/\(fixtureName).\(ext)")
        guard FileManager.default.isReadableFile(atPath: onDisk.path) else {
            throw XCTSkip("""
                Test file \(fixtureName).\(ext) is unavailable: it is not in the test bundle's \
                resources, and \(onDisk.path) is not readable from the sandboxed test host. \
                It should be picked up automatically from fingerMIDI-Tests/TestFiles/ (the target \
                uses a file-system-synchronized group) — check that the file is present there and \
                that it appears in the fingerMIDI-Tests target's Copy Bundle Resources phase.
                """)
        }
        return onDisk
    }

    // MARK: Minimal Standard MIDI File reader
    //
    // Intentionally independent of SwiftMIDIFile: it reads the bytes on disk so that the
    // comparison is against the file a DAW would see, not against the writer's own model.
    // Supports format 0/1 with a musical (PPQ) timebase, running status, meta and SysEx
    // events, and a tempo map assembled from every Set Tempo event in the file.

    struct NoteOn: Equatable {
        let note: UInt8
        let velocity: UInt8
        let timeMs: Double
    }

    private struct MIDIParseError: LocalizedError {
        let message: String
        var errorDescription: String? { "Malformed MIDI file: \(message)" }
    }

    private func parseNoteOns(midiFileAt url: URL) throws -> [NoteOn] {
        try parseNoteOns(midiFile: try Data(contentsOf: url))
    }

    private func parseNoteOns(midiFile data: Data) throws -> [NoteOn] {
        let bytes = [UInt8](data)
        var cursor = 0

        func need(_ count: Int, _ what: String) throws {
            guard cursor + count <= bytes.count else {
                throw MIDIParseError(message: "truncated while reading \(what)")
            }
        }
        func readUInt16() throws -> UInt16 {
            try need(2, "UInt16")
            defer { cursor += 2 }
            return (UInt16(bytes[cursor]) << 8) | UInt16(bytes[cursor + 1])
        }
        func readUInt32() throws -> UInt32 {
            try need(4, "UInt32")
            defer { cursor += 4 }
            return (UInt32(bytes[cursor]) << 24) | (UInt32(bytes[cursor + 1]) << 16)
                 | (UInt32(bytes[cursor + 2]) << 8) | UInt32(bytes[cursor + 3])
        }
        /// MIDI variable-length quantity: 7 bits per byte, high bit = "more to come".
        func readVariableLengthQuantity() throws -> UInt32 {
            var value: UInt32 = 0
            for _ in 0..<4 {
                try need(1, "variable-length quantity")
                let byte = bytes[cursor]; cursor += 1
                value = (value << 7) | UInt32(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw MIDIParseError(message: "variable-length quantity longer than 4 bytes")
        }

        // --- Header ---
        try need(4, "MThd")
        guard bytes[0..<4].elementsEqual("MThd".utf8) else {
            throw MIDIParseError(message: "missing MThd chunk")
        }
        cursor = 4
        let headerLength = Int(try readUInt32())
        try need(headerLength, "header body")
        let headerEnd = cursor + headerLength
        _ = try readUInt16()                       // format — 0 and 1 are read identically here
        _ = try readUInt16()                       // track count — chunks are walked instead
        let division = try readUInt16()
        guard division & 0x8000 == 0, division > 0 else {
            throw MIDIParseError(message: "SMPTE timebase is not supported by this test parser")
        }
        let ticksPerQuarter = Double(division)
        cursor = headerEnd

        // --- Tracks: collect note-ons and tempo changes in ticks ---
        var noteOnsInTicks: [(tick: UInt64, note: UInt8, velocity: UInt8)] = []
        var tempoMap: [(tick: UInt64, microsecondsPerQuarter: Double)] = []

        while cursor + 8 <= bytes.count {
            let isTrack = bytes[cursor..<(cursor + 4)].elementsEqual("MTrk".utf8)
            cursor += 4
            let chunkLength = Int(try readUInt32())
            try need(chunkLength, "chunk body")
            let chunkEnd = cursor + chunkLength
            guard isTrack else { cursor = chunkEnd; continue }   // skip unknown chunk types

            var tick: UInt64 = 0
            var runningStatus: UInt8? = nil

            while cursor < chunkEnd {
                tick += UInt64(try readVariableLengthQuantity())
                try need(1, "event status")
                var status = bytes[cursor]
                if status & 0x80 != 0 {
                    cursor += 1
                    if status < 0xF0 { runningStatus = status }
                } else {
                    guard let running = runningStatus else {
                        throw MIDIParseError(message: "data byte with no running status")
                    }
                    status = running
                }

                switch status {
                case 0xFF:                                    // meta event
                    try need(1, "meta type")
                    let type = bytes[cursor]; cursor += 1
                    let length = Int(try readVariableLengthQuantity())
                    try need(length, "meta payload")
                    if type == 0x51, length == 3 {            // Set Tempo
                        let us = (UInt32(bytes[cursor]) << 16)
                               | (UInt32(bytes[cursor + 1]) << 8)
                               | UInt32(bytes[cursor + 2])
                        tempoMap.append((tick, Double(us)))
                    }
                    cursor += length
                case 0xF0, 0xF7:                              // SysEx — length-prefixed, skipped
                    let length = Int(try readVariableLengthQuantity())
                    try need(length, "SysEx payload")
                    cursor += length
                default:
                    let dataByteCount = (status & 0xF0) == 0xC0 || (status & 0xF0) == 0xD0 ? 1 : 2
                    try need(dataByteCount, "channel message payload")
                    let first = bytes[cursor]
                    let second = dataByteCount == 2 ? bytes[cursor + 1] : 0
                    cursor += dataByteCount
                    // Note On with velocity 0 is a Note Off (MIDI spec) — not collected.
                    if status & 0xF0 == 0x90, second > 0 {
                        noteOnsInTicks.append((tick, first, second))
                    }
                }
            }
            cursor = chunkEnd
        }

        // --- Ticks → milliseconds via the tempo map ---
        let tempos = tempoMap.sorted { $0.tick < $1.tick }
        func milliseconds(at tick: UInt64) -> Double {
            var elapsedMs = 0.0
            var lastTick: UInt64 = 0
            var usPerQuarter = 500_000.0                      // 120 BPM, the SMF default
            for tempo in tempos where tempo.tick < tick {
                elapsedMs += Double(tempo.tick - lastTick) * usPerQuarter / ticksPerQuarter / 1000.0
                lastTick = tempo.tick
                usPerQuarter = tempo.microsecondsPerQuarter
            }
            elapsedMs += Double(tick - lastTick) * usPerQuarter / ticksPerQuarter / 1000.0
            return elapsedMs
        }

        return noteOnsInTicks
            .sorted { $0.tick < $1.tick }
            .map { NoteOn(note: $0.note, velocity: $0.velocity, timeMs: milliseconds(at: $0.tick)) }
    }
}
