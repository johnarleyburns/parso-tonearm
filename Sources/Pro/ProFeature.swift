import Foundation

/// The paid capability set. M0 retires the sole legacy case
/// (`remoteLibraries`): all remote-library providers are free for everyone
/// (FR-LIB-7, §2.4). Through commit 0.4 nothing is paid, so the set is empty —
/// the honest intermediate state until the DJ capability lands with
/// `EntitlementStore` (Appendix T.3). Swift forbids a raw type on a case-less
/// enum, so there is no `rawValue` here; the next milestone's capability enum
/// restores it and the registry test repoints to it.
public enum ProFeature: CaseIterable, Sendable {}
