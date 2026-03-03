import Foundation
@testable import mcs
import Testing

@Suite("PluginRef")
struct PluginRefTests {
    @Test("bare name defaults to official marketplace repo")
    func bareNameDefault() {
        let ref = PluginRef("pr-review-toolkit")
        #expect(ref.bareName == "pr-review-toolkit")
        #expect(ref.marketplaceRepo == "anthropics/claude-plugins-official")
        #expect(ref.fullName == "pr-review-toolkit")
    }

    @Test("short identifier maps to official repo")
    func shortIdentifier() {
        let ref = PluginRef("pr-review-toolkit@claude-plugins-official")
        #expect(ref.bareName == "pr-review-toolkit")
        #expect(ref.marketplaceRepo == "anthropics/claude-plugins-official")
        #expect(ref.fullName == "pr-review-toolkit@claude-plugins-official")
    }

    @Test("full repo path is preserved")
    func fullRepoPath() {
        let ref = PluginRef("my-plugin@myorg/my-marketplace")
        #expect(ref.bareName == "my-plugin")
        #expect(ref.marketplaceRepo == "myorg/my-marketplace")
    }

    @Test("unknown short identifier passes through")
    func unknownShort() {
        let ref = PluginRef("my-plugin@custom-marketplace")
        #expect(ref.bareName == "my-plugin")
        #expect(ref.marketplaceRepo == "custom-marketplace")
    }

    @Test("equatable conformance")
    func equatable() {
        let a = PluginRef("foo@bar")
        let b = PluginRef("foo@bar")
        #expect(a == b)
    }
}
