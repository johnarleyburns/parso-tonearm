import XCTest

@testable import TonearmDJ

/// Commit 4.5 — the pure time-pitch / key math (plan §5, spec §31.1–31.3).
///
/// Golden-pinned conversions: rate↔percent, `1200·log2(r)` cents, semitone
/// cents, and the per-deck effective-pitch rule — key lock applies the
/// inverse of the reader's rate-pitch so the key holds under tempo changes,
/// key lock off leaves the vinyl behaviour, and an independent ±N semitone
/// key shift is added on top, rate held. Everything is deterministic and
/// device-free (plan §6 pure-kernel tier).
final class TimePitchTests: XCTestCase {

    // MARK: - Rate / percent (§31.1)

    func testRateFromPercent() {
        XCTAssertEqual(TimePitchMath.rateFromPercent(0), 1.0, accuracy: 1e-12)
        XCTAssertEqual(TimePitchMath.rateFromPercent(1.2), 1.012, accuracy: 1e-9,
                       "+1.2% is a rate of 1.012 (spec §31.1)")
        XCTAssertEqual(TimePitchMath.rateFromPercent(100), 2.0, accuracy: 1e-12)
        XCTAssertEqual(TimePitchMath.rateFromPercent(-8), 0.92, accuracy: 1e-12)
    }

    func testCentsFromRate() {
        XCTAssertEqual(TimePitchMath.centsFromRate(1), 0, accuracy: 1e-9,
                       "unity rate is no pitch shift")
        XCTAssertEqual(TimePitchMath.centsFromRate(2), 1200, accuracy: 1e-6,
                       "an octave is 1200 cents")
        XCTAssertEqual(TimePitchMath.centsFromRate(1.2), 1200 * log2(1.2), accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.centsFromRate(0.5), -1200, accuracy: 1e-6)
        XCTAssertEqual(TimePitchMath.centsFromRate(1.2), 315.641, accuracy: 1e-2,
                       "the documented +1.2% → ~316 cents sanity anchor")
    }

    // MARK: - Key shift (§31.3)

    func testSemitoneCents() {
        XCTAssertEqual(TimePitchMath.semitoneCents(0), 0, accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.semitoneCents(1), 100, accuracy: 1e-9,
                       "one semitone is 100 cents")
        XCTAssertEqual(TimePitchMath.semitoneCents(-2), -200, accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.semitoneCents(12), 1200, accuracy: 1e-9)
    }

    // MARK: - Effective pitch (§31.1–31.3)

    func testPitchCentsKeyLockHoldsPitchUnderTempo() {
        // Key lock on: the unit cancels the reader's rate-pitch so the musical
        // key stays put while the deck plays faster.
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1.2, keyLock: true, keyShiftSemitones: 0),
                       -1200 * log2(1.2), accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1, keyLock: true, keyShiftSemitones: 0),
                       0, accuracy: 1e-9, "key lock at unity rate changes nothing")
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 0.5, keyLock: true, keyShiftSemitones: 0),
                       1200, accuracy: 1e-6, "slowing to half-speed holds the key via +1200¢")
    }

    func testPitchCentsKeyLockOffIsVinyl() {
        // Key lock off: the reader's rate IS the pitch shift (vinyl behaviour);
        // the unit adds nothing.
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1.2, keyLock: false, keyShiftSemitones: 0),
                       0, accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 0.9, keyLock: false, keyShiftSemitones: 0),
                       0, accuracy: 1e-9)
    }

    func testPitchCentsKeyShiftAddsSemitonesRateHeld() {
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1, keyLock: false, keyShiftSemitones: 1),
                       100, accuracy: 1e-9)
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1, keyLock: false, keyShiftSemitones: -1),
                       -100, accuracy: 1e-9)
        // Rate held: a key shift does not drag the tempo compensation along.
        XCTAssertEqual(TimePitchMath.pitchCents(rate: 1.2, keyLock: true, keyShiftSemitones: 1),
                       -1200 * log2(1.2) + 100, accuracy: 1e-9)
    }

    // MARK: - Settings value

    func testSettingsDeriveUnitPitch() {
        let vinyl = TimePitchSettings(rate: 1.2, keyLock: false)
        XCTAssertEqual(vinyl.unitPitchCents, 0, accuracy: 1e-9)

        let locked = TimePitchSettings(rate: 1.2, keyLock: true)
        XCTAssertEqual(locked.unitPitchCents, -1200 * log2(1.2), accuracy: 1e-9)
        XCTAssertEqual(locked.effectiveKeyShiftSemitones, -1200 * log2(1.2) / 100,
                       accuracy: 1e-9, "the UI's Camelot hint reads back semitones (§31.3)")

        let shifted = TimePitchSettings(rate: 1.2, keyLock: true, keyShiftSemitones: 1)
        XCTAssertEqual(shifted.unitPitchCents, -1200 * log2(1.2) + 100, accuracy: 1e-9)
        XCTAssertEqual(shifted.effectiveKeyShiftSemitones,
                       (-1200 * log2(1.2) + 100) / 100, accuracy: 1e-9)
    }

    func testSettingsDefaultIsVinylUnity() {
        let defaults = TimePitchSettings()
        XCTAssertEqual(defaults.rate, 1)
        XCTAssertFalse(defaults.keyLock)
        XCTAssertEqual(defaults.keyShiftSemitones, 0)
        XCTAssertEqual(defaults.unitPitchCents, 0, accuracy: 1e-9)
    }
}
