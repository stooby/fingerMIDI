//
//  MIDIHelpersTests.swift
//  fingerMIDI-Tests
//
//  Tests for pairMIDIEventsForDisplay: the pure note-on/note-off pairing logic
//  that turns raw RNBO MIDI event dicts into MIDINoteEvent notes for the overlay.
//  No audio engine involved.
//

import XCTest
@testable import fingerMIDI

final class MIDIHelpersTests: XCTestCase {

    // MARK: Helpers

    private func noteOn(_ note: UInt8, velocity: UInt8, at ms: Double) -> [String: Any] {
        ["timestampMs": ms, "bytes": Data([0x90, note, velocity])]
    }

    private func noteOff(_ note: UInt8, at ms: Double) -> [String: Any] {
        ["timestampMs": ms, "bytes": Data([0x80, note, 0])]
    }

    // MARK: Basic pairing

    func testPairsOnsetAndReleaseIntoOneNote() {
        let notes = pairMIDIEventsForDisplay([noteOn(60, velocity: 100, at: 0),
                                    noteOff(60, at: 250)])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].note, 60)
        XCTAssertEqual(notes[0].velocity, 100)
        XCTAssertEqual(notes[0].onsetMs, 0, accuracy: 0.001)
        XCTAssertEqual(notes[0].durationMs, 250, accuracy: 0.001)
    }

    func testEmptyInputProducesNoNotes() {
        XCTAssertTrue(pairMIDIEventsForDisplay([]).isEmpty)
    }

    // MARK: Note-off variants

    func testNoteOnWithZeroVelocityIsTreatedAsNoteOff() {
        // 0x90 with velocity 0 is the running-status idiom for note-off.
        let notes = pairMIDIEventsForDisplay([noteOn(60, velocity: 100, at: 0),
                                    noteOn(60, velocity: 0, at: 100)])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].durationMs, 100, accuracy: 0.001)
    }

    func testUnclosedNoteGetsFallbackDuration() {
        let notes = pairMIDIEventsForDisplay([noteOn(60, velocity: 80, at: 0)])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].durationMs, 50, accuracy: 0.001)   // flush fallback
    }

    func testStrayNoteOffWithNoMatchingOnsetIsIgnored() {
        XCTAssertTrue(pairMIDIEventsForDisplay([noteOff(60, at: 100)]).isEmpty)
    }

    // MARK: Ordering

    func testEventsAreSortedByTimestampBeforePairing() {
        // Deliberately supply the note-off before the note-on in array order.
        let notes = pairMIDIEventsForDisplay([noteOff(60, at: 200),
                                    noteOn(60, velocity: 90, at: 50)])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].onsetMs, 50, accuracy: 0.001)
        XCTAssertEqual(notes[0].durationMs, 150, accuracy: 0.001)
    }

    func testResultIsSortedByOnset() {
        let notes = pairMIDIEventsForDisplay([noteOn(38, velocity: 90, at: 300),
                                    noteOff(38, at: 350),
                                    noteOn(36, velocity: 90, at: 100),
                                    noteOff(36, at: 150)])
        XCTAssertEqual(notes.map(\.onsetMs), [100, 300])
        XCTAssertEqual(notes.map(\.note), [36, 38])
    }

    // MARK: Overlapping pitches

    func testDistinctPitchesArePairedIndependently() throws {
        // Kick (36) and snare (38) overlap in time; each closes to its own pitch.
        let notes = pairMIDIEventsForDisplay([noteOn(36, velocity: 100, at: 0),
                                    noteOn(38, velocity: 80, at: 20),
                                    noteOff(36, at: 200),
                                    noteOff(38, at: 120)])
        XCTAssertEqual(notes.count, 2)
        let kick = try XCTUnwrap(notes.first { $0.note == 36 })
        let snare = try XCTUnwrap(notes.first { $0.note == 38 })
        XCTAssertEqual(kick.durationMs, 200, accuracy: 0.001)
        XCTAssertEqual(snare.durationMs, 100, accuracy: 0.001)
    }

    // MARK: Malformed input

    func testMalformedEventsAreSkipped() {
        let tooShort: [String: Any] = ["timestampMs": 10.0, "bytes": Data([0x90, 60])]
        let missingBytes: [String: Any] = ["timestampMs": 20.0]
        let notes = pairMIDIEventsForDisplay([tooShort,
                                    missingBytes,
                                    noteOn(60, velocity: 70, at: 0),
                                    noteOff(60, at: 90)])
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].durationMs, 90, accuracy: 0.001)
    }

    // MARK: Same-pitch retrigger (split into adjacent notes)

    func testRetriggerSamePitchEndsFirstNoteAtSecondOnset() {
        // RNBO at a low Onset/mingap double-triggers one hit: two overlapping
        // same-pitch notes, each with its own note-off 100 ms after its onset.
        //   on@1000 → off@1100   (note A)
        //   on@1020 → off@1120   (note B)
        // The first note is ended at the second onset (1020) instead of dropped,
        // and the new note opens there. Pairing is FIFO, so off@1100 belongs to the
        // already-ended note A and must be skipped; off@1120 then closes B.
        let notes = pairMIDIEventsForDisplay([noteOn(36, velocity: 127, at: 1000),
                                              noteOn(36, velocity: 125, at: 1020),
                                              noteOff(36, at: 1100),
                                              noteOff(36, at: 1120)])
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.onsetMs), [1000, 1020])
        XCTAssertEqual(notes[0].velocity, 127)
        XCTAssertEqual(notes[1].velocity, 125)
        XCTAssertEqual(notes[0].durationMs, 20, accuracy: 0.001)    // ended at 2nd onset
        // 100, from off@1120 — proves off@1100 was skipped (else this would be 80).
        XCTAssertEqual(notes[1].durationMs, 100, accuracy: 0.001)
    }

    func testTripleRetriggerSplitsIntoThreeAdjacentNotes() {
        // Three stacked onsets; each earlier note ends at the next onset, and the
        // first two note-offs (owed to the two force-ended notes) are skipped so the
        // final off closes the last note.
        let notes = pairMIDIEventsForDisplay([noteOn(36, velocity: 127, at: 1000),
                                              noteOn(36, velocity: 125, at: 1020),
                                              noteOn(36, velocity: 123, at: 1050),
                                              noteOff(36, at: 1100),
                                              noteOff(36, at: 1120),
                                              noteOff(36, at: 1150)])
        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map(\.onsetMs), [1000, 1020, 1050])
        XCTAssertEqual(notes.map(\.durationMs), [20, 30, 100])
    }

    func testRetriggerWithNoTrailingOffFlushesLastNote() {
        // The user's minimal case: two onsets, only one off. That off is owed to
        // the force-ended first note and skipped; the second note never receives an
        // off, so it flushes with the 50 ms fallback.
        let notes = pairMIDIEventsForDisplay([noteOn(60, velocity: 100, at: 1000),
                                              noteOn(60, velocity: 110, at: 1020),
                                              noteOff(60, at: 1100)])
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].onsetMs, 1000, accuracy: 0.001)
        XCTAssertEqual(notes[0].durationMs, 20, accuracy: 0.001)
        XCTAssertEqual(notes[1].onsetMs, 1020, accuracy: 0.001)
        XCTAssertEqual(notes[1].durationMs, 50, accuracy: 0.001)    // flush fallback
    }
}
