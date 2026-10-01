import TonearmWatchCore

/// `TonearmWatchProtocol` and `TonearmWatchCore` both declare a `WatchPlaybackTarget`; views that
/// import both use this name for the core (UI-facing) one.
typealias WatchTarget = TonearmWatchCore.WatchPlaybackTarget
