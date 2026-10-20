import Testing
@testable import STPlatform

@Test func subsystemIsStable() { #expect(STLog.subsystem == "com.ducky8x.sTools") }
