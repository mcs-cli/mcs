@testable import mcs
import Testing

@Test func mcsPackageBuilds() {
    // Verifies the package compiles and the test target can link against mcs
    #expect(Bool(true))
}

@Test("MCSVersion.current is valid semantic version")
func mcsVersionIsValidSemver() {
    let version = MCSVersion.current
    // Strip pre-release suffix (e.g., "2.1.0-alpha" → "2.1.0")
    let base = version.split(separator: "-", maxSplits: 1).first.map(String.init) ?? version
    let parts = base.split(separator: ".")
    #expect(parts.count == 3, "Expected 3 dot-separated components, got \(parts.count)")
    for part in parts {
        #expect(Int(part) != nil, "'\(part)' is not a valid integer component")
    }
}
