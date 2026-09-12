// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tonearm (Platterhead DJ) — Copyright (C) 2026 John Arley Burns.
// See ../../LICENSE.

#if canImport(UIKit) && !os(watchOS)
import BackgroundTasks
import Foundation
import TonearmDiscovery

/// Thin `BackgroundTaskScheduling` conformance over the real
/// `BGTaskScheduler` (IMPLEMENT_CLAP_PLAN.md §7). All of the discovery
/// background *policy* lives in the portable `DiscoveryBackgroundController`;
/// this file only translates its abstract calls into `BackgroundTasks`
/// symbols so that logic stays unit-testable without a device.
struct BGTaskSchedulerAdapter: BackgroundTaskScheduling {
    func register(
        identifier: String,
        launchHandler: @escaping @Sendable (any BackgroundTaskInvocation) -> Void
    ) -> Bool {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            launchHandler(BGProcessingTaskInvocation(processing))
        }
    }

    func submit(_ request: BackgroundProcessingRequest) throws {
        let real = BGProcessingTaskRequest(identifier: request.identifier)
        real.requiresExternalPower = request.requiresExternalPower
        real.requiresNetworkConnectivity = request.requiresNetworkConnectivity
        real.earliestBeginDate = request.earliestBeginDate
        try BGTaskScheduler.shared.submit(real)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Wraps a non-`Sendable` `BGProcessingTask`. The task object is only touched
/// from the controller's actor after the launch handler hands it over; the
/// `@unchecked` is sound because we never race two calls on it.
final class BGProcessingTaskInvocation: BackgroundTaskInvocation, @unchecked Sendable {
    private let task: BGProcessingTask
    init(_ task: BGProcessingTask) { self.task = task }

    var identifier: String { task.identifier }

    func setExpirationHandler(_ handler: @escaping @Sendable () -> Void) {
        task.expirationHandler = handler
    }

    func complete(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}
#endif
