//
//  MIDI-Helpers.swift
//  fingerMIDI
//
//  Pure, UI/engine-free MIDI helpers. Kept free of SwiftUI/engine dependencies
//  so they can be unit-tested directly against synthetic events.
//

import Foundation
import SwiftMIDIFile

/// Converts raw RNBO MIDI event dictionaries into a Standard MIDI File (Format 0).
/// This is the exact byte stream written by ContentView's "Export MIDI" — kept here,
/// free of View/engine state, so the offline-render regression test can build the
/// same file the app does (see `MIDITranscriptionTests`).
///
/// Timebase: 480 PPQ at 120 BPM → 1 tick ≈ 1.042 ms.
/// Tick conversion: ticks = round(timestampMs × 480 × 120 / 60_000) = round(ms × 0.96).
///
/// RNBO emits fully-formed Note On (0x9x) and Note Off (0x8x) messages; both are passed
/// through as-is. Zero-velocity Note On (treated as Note Off per MIDI spec) is also handled.
///
/// Unlike `pairMIDIEventsForDisplay`, no pairing happens here — the raw event stream is
/// written faithfully, overlaps included.
func buildMIDIFile(from rawEvents: [[String: Any]]) throws -> Data {
    let bpm: Double = 120.0
    let ppq: UInt16 = 480
    let ticksPerMs = Double(ppq) * bpm / 60_000.0  // 0.96

    // Sort events by timestamp before computing deltas.
    let sorted = rawEvents.sorted {
        let t0 = ($0["timestampMs"] as? Double) ?? 0.0
        let t1 = ($1["timestampMs"] as? Double) ?? 0.0
        return t0 < t1
    }

    var trackEvents: [MusicalMIDI1File.Track.Event] = []

    // Tempo event at the start of the track.
    trackEvents.append(.tempo(delta: .none, bpm: bpm))

    var prevAbsTick: UInt32 = 0

    for dict in sorted {
        guard
            let timestampMs = dict["timestampMs"] as? Double,
            let bytes = dict["bytes"] as? Data,
            bytes.count >= 1
        else { continue }

        let absTick = UInt32(max(0.0, (timestampMs * ticksPerMs).rounded()))
        let deltaTick = absTick >= prevAbsTick ? absTick - prevAbsTick : 0
        prevAbsTick = absTick

        let status = bytes[0]
        let statusNibble = status >> 4
        let channel = status & 0x0F

        guard
            bytes.count >= 3,
            let note = UInt7(exactly: bytes[1]),
            let velocity = UInt7(exactly: bytes[2]),
            let ch = UInt4(exactly: channel)
        else { continue }

        switch statusNibble {
        case 0x9 where velocity > 0:
            trackEvents.append(.noteOn(
                delta: .ticks(deltaTick),
                note: note,
                velocity: .midi1(velocity),
                channel: ch
            ))
        case 0x8, 0x9: // Note Off, or Note On with velocity 0
            trackEvents.append(.noteOff(
                delta: .ticks(deltaTick),
                note: note,
                velocity: .midi1(velocity),
                channel: ch
            ))
        default:
            break
        }
    }

    let track = MusicalMIDI1File.Track(events: trackEvents)
    let midiFile = MusicalMIDI1File(
        format: .singleTrack,
        timebase: .musical(ticksPerQuarterNote: ppq),
        tracks: [track]
    )
    return try midiFile.rawData()
}

/// Pairs raw RNBO MIDI event dicts into `MIDINoteEvent` on/off matches for the
/// on-screen note overlay. Does not affect exported MIDI — the .mid file is
/// built from the raw events (see `buildMIDIFile(from:)` above).
///
/// Each input dict is expected to carry `"timestampMs": Double` and
/// `"bytes": Data` (a 3-byte MIDI status/note/velocity message). Events are
/// sorted by timestamp first. A note-on (status nibble `0x9`, velocity > 0)
/// opens a note; a note-off (status `0x8`, or `0x9` with velocity 0) closes it.
///
/// Same-pitch retrigger: if a note-on arrives for a pitch that is still open
/// (RNBO can emit this at a low `Onset/mingap`, double-triggering one hit), the
/// open note is **ended at the new onset** rather than dropped, and the new
/// note-on opens a fresh note — so overlapping same-pitch notes render as
/// adjacent blocks. Note-on/off pairing is FIFO by time, so the note-off that
/// later closes the force-ended note is redundant; `pendingStaleOffs` tracks how
/// many such offs to skip per pitch before the next genuine off applies.
///
/// Any note left open at the end is flushed with a fallback 50 ms duration.
/// The result is sorted by onset.
func pairMIDIEventsForDisplay(_ rawEvents: [[String: Any]]) -> [MIDINoteEvent] {
    let sorted = rawEvents.sorted {
        (($0["timestampMs"] as? Double) ?? 0) < (($1["timestampMs"] as? Double) ?? 0)
    }
    var open: [UInt8: (onsetMs: Double, velocity: UInt8)] = [:]
    // Per-pitch count of note-offs still owed to notes that were force-ended early
    // by a same-pitch retrigger. These offs are redundant and must be skipped so
    // the next genuine off closes the currently-open note.
    var pendingStaleOffs: [UInt8: Int] = [:]
    var result: [MIDINoteEvent] = []
    for dict in sorted {
        guard
            let ms = dict["timestampMs"] as? Double,
            let bytes = dict["bytes"] as? Data,
            bytes.count >= 3
        else { continue }
        let statusNibble = bytes[0] >> 4
        let note = bytes[1]
        let velocity = bytes[2]
        if statusNibble == 0x9 && velocity > 0 {
            // Note-on. End any still-open note of this pitch at the new onset, then
            // open the new one; the ended note's own note-off arrives later and is
            // owed a skip.
            if let entry = open[note] {
                result.append(MIDINoteEvent(
                    note: note, velocity: entry.velocity,
                    onsetMs: entry.onsetMs, durationMs: ms - entry.onsetMs
                ))
                pendingStaleOffs[note, default: 0] += 1
            }
            open[note] = (onsetMs: ms, velocity: velocity)
        } else if statusNibble == 0x8 || (statusNibble == 0x9 && velocity == 0) {
            // Note-off. Consume any owed stale off first; otherwise close the open note.
            if let skip = pendingStaleOffs[note], skip > 0 {
                pendingStaleOffs[note] = skip - 1
            } else if let entry = open[note] {
                result.append(MIDINoteEvent(
                    note: note, velocity: entry.velocity,
                    onsetMs: entry.onsetMs, durationMs: ms - entry.onsetMs
                ))
                open.removeValue(forKey: note)
            }
        }
    }
    // Flush any note still open at the end with a fallback duration.
    for (note, entry) in open {
        result.append(MIDINoteEvent(
            note: note, velocity: entry.velocity,
            onsetMs: entry.onsetMs, durationMs: 50
        ))
    }
    return result.sorted { $0.onsetMs < $1.onsetMs }
}
