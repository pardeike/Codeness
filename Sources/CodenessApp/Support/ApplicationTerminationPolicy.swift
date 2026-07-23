import AppKit

enum ApplicationTerminationPolicy {
    static var isCurrentTerminationSystemInitiated: Bool {
        let reason = NSAppleEventManager.shared().currentAppleEvent?
            .paramDescriptor(forKeyword: AEKeyword(kAEQuitReason))?
            .typeCodeValue
        return isSystemInitiated(reason: reason)
    }

    static func isSystemInitiated(reason: OSType?) -> Bool {
        guard let reason else { return false }
        return reason == OSType(kAEShutDown)
            || reason == OSType(kAERestart)
            || reason == OSType(kAEReallyLogOut)
    }
}
