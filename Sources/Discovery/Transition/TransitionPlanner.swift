import TonearmCore

/// Compatibility exports for callers that historically imported the planner
/// from TonearmDiscovery. The implementation is pure TonearmCore code so the
/// playback target can use the exact same planner without a dependency cycle.
public typealias TransitionPlanningContext = TonearmCore.TransitionPlanningContext
public typealias TransitionPlanner = TonearmCore.TransitionPlanner
