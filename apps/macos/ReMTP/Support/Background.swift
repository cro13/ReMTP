import Foundation

/// Runs blocking work (device calls, file system walks) off the main thread.
func offMain<T>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// Non-throwing variant.
func offMain<T>(qos: DispatchQoS.QoSClass = .userInitiated, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: qos).async {
            continuation.resume(returning: work())
        }
    }
}

/// Hops to the main actor preserving order (UniFFI callbacks arrive on arbitrary threads).
func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async {
        MainActor.assumeIsolated { work() }
    }
}

/// Runs `work` on the main thread through the main run loop (common and modal-panel modes). Unlike the main
/// queue (and so the main actor), this is also serviced by nested run loops entered from main-queue code,
/// such as AppKit waiting for `reply(toApplicationShouldTerminate:)` after `terminate` was called from a
/// main-actor task.
func onMainRunLoop(_ work: @escaping () -> Void) {
    let main = CFRunLoopGetMain()
    let modes = [CFRunLoopMode.commonModes.rawValue, RunLoop.Mode.modalPanel.rawValue as CFString] as CFArray
    CFRunLoopPerformBlock(main, modes, work)
    CFRunLoopWakeUp(main)
}
