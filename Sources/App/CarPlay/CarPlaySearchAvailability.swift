#if !targetEnvironment(macCatalyst)
import CarPlay

/// The single gate for `CPSearchTemplate`.
///
/// Apple's CarPlay Developer Guide (June 2026, "Templates" table) lists the
/// Search template for the Audio/video app category as supported only on
/// **iOS 27 or later**: "Each CarPlay app category supports specific
/// templates and this is governed by the app entitlement. Attempting to use
/// an unsupported template triggers an exception at runtime." On iOS 18 that
/// exception is `CPAssertAllowedClasses` inside `pushTemplate` — the
/// TestFlight crash behind `feda4bf`/`e3ae1a5`, and an Objective-C exception
/// Swift cannot catch. Every search entry point must pass through here;
/// `scripts/check-ci-guards.sh` ("CarPlay Search template gate") pins that.
enum CarPlaySearchAvailability {
    static var templateSupported: Bool {
        if #available(iOS 27.0, *) { return true }
        return false
    }
}
#endif
