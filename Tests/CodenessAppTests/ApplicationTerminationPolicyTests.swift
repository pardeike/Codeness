import AppKit
import Testing
@testable import Codeness

struct ApplicationTerminationPolicyTests {
    @Test
    func autoResumeIsLimitedToSystemLifecycleQuitReasons() {
        #expect(ApplicationTerminationPolicy.isSystemInitiated(reason: OSType(kAEShutDown)))
        #expect(ApplicationTerminationPolicy.isSystemInitiated(reason: OSType(kAERestart)))
        #expect(ApplicationTerminationPolicy.isSystemInitiated(reason: OSType(kAEReallyLogOut)))

        #expect(!ApplicationTerminationPolicy.isSystemInitiated(reason: nil))
        #expect(!ApplicationTerminationPolicy.isSystemInitiated(reason: OSType(kAEQuitAll)))
        #expect(!ApplicationTerminationPolicy.isSystemInitiated(reason: OSType(kAELogOut)))
    }
}
