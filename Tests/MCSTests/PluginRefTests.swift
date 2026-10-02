import Foundation
@testable import mcs
import Testing

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

    @Test("The marketplace name is known unless the reference names a repo")
    func marketplaceName() {
        #expect(PluginRef("pr-review-toolkit").marketplaceName == Constants.Plugins.officialMarketplace)
        #expect(PluginRef("lint@acme").marketplaceName == "acme")
        #expect(PluginRef("lint@myorg/my-marketplace").marketplaceName == nil)
        #expect(PluginRef("x@anthropics/claude-plugins-official").marketplaceName == Constants.Plugins.officialMarketplace)
    }

    @Test("A repo reference resolves its id through the marketplace list")
    func pluginIDFromRepo() {
        let marketplaces = [PluginMarketplace(name: "hud", repo: "MyOrg/My-Marketplace")]
        #expect(PluginRef("lint@myorg/my-marketplace").pluginID(in: marketplaces) == "lint@hud")
        #expect(PluginRef("lint@other/repo").pluginID(in: marketplaces) == nil)
        #expect(PluginRef("lint@acme").pluginID(in: []) == "lint@acme")
    }

    @Test("An id matches on name and, when known, marketplace")
    func matchesID() {
        #expect(PluginRef("lint@acme").matches(id: "lint@acme"))
        #expect(!PluginRef("lint@acme").matches(id: "lint@other"))
        #expect(PluginRef("lint@org/repo").matches(id: "lint@whatever"))
        #expect(!PluginRef("lint@acme").matches(id: "lint-extra@acme"))
    }
}
