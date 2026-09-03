import Foundation
import ParsoAudioPlayback

/// EQ presets are now shared: `parso-audio-engine`'s `EQPreset`
/// (`ParsoAudioPlayback`) — UUID identity, `[Double]` gains, four built-ins
/// (`Flat` / `Concert Hall` / `Spoken` / `78 rpm`) with stable UUIDs
/// (parso-audio-engine/docs/UNIFICATION_PLAN.md §3). Persistence
/// (`EQSettingsPersistence`) stays app-side.
public typealias EQPreset = ParsoAudioPlayback.EQPreset
