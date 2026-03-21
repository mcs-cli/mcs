import Foundation
@testable import mcs
import Testing

struct TemplateEngineTests {
    // MARK: - Basic substitution

    @Test("Single placeholder substitution")
    func singlePlaceholder() {
        let result = TemplateEngine.substitute(
            template: "Hello __NAME__!",
            values: ["NAME": "World"]
        )
        #expect(result == "Hello World!")
    }

    @Test("Multiple placeholders in one template")
    func multiplePlaceholders() {
        let result = TemplateEngine.substitute(
            template: "Project: __PROJECT__, Repo: __REPO_NAME__, Prefix: __BRANCH_PREFIX__",
            values: [
                "PROJECT": "MyApp",
                "REPO_NAME": "my-app",
                "BRANCH_PREFIX": "user",
            ]
        )
        #expect(result == "Project: MyApp, Repo: my-app, Prefix: user")
    }

    // MARK: - EDIT comment stripping

    @Test("Strip <!-- EDIT: ... --> comment lines")
    func stripEditComments() {
        let template = """
        # Title
        <!-- EDIT: Change the title above -->
        Some content
        <!-- EDIT: Update content -->
        Footer
        """
        let result = TemplateEngine.substitute(template: template, values: [:])
        #expect(!result.contains("<!-- EDIT:"))
        #expect(result.contains("# Title"))
        #expect(result.contains("Some content"))
        #expect(result.contains("Footer"))
    }

    @Test("Non-EDIT comments are preserved")
    func preserveNonEditComments() {
        let template = "<!-- This is a normal comment -->\nContent"
        let result = TemplateEngine.substitute(template: template, values: [:])
        #expect(result.contains("<!-- This is a normal comment -->"))
    }

    // MARK: - Unreplaced placeholder detection

    @Test("findUnreplacedPlaceholders detects remaining placeholders")
    func findUnreplaced() {
        let text = "Hello __NAME__, welcome to __PLACE__. Your id is __USER_ID__."
        let unreplaced = TemplateEngine.findUnreplacedPlaceholders(in: text)
        #expect(unreplaced.contains("__NAME__"))
        #expect(unreplaced.contains("__PLACE__"))
        #expect(unreplaced.contains("__USER_ID__"))
        #expect(unreplaced.count == 3)
    }

    @Test("findUnreplacedPlaceholders returns empty for no placeholders")
    func noUnreplaced() {
        let unreplaced = TemplateEngine.findUnreplacedPlaceholders(in: "No placeholders here")
        #expect(unreplaced.isEmpty)
    }

    @Test("findUnreplacedPlaceholders deduplicates")
    func deduplicateUnreplaced() {
        let text = "__FOO__ and __FOO__ again"
        let unreplaced = TemplateEngine.findUnreplacedPlaceholders(in: text)
        #expect(unreplaced.count == 1)
        #expect(unreplaced.first == "__FOO__")
    }

    // MARK: - Edge cases

    @Test("Empty template produces empty result")
    func emptyTemplate() {
        let result = TemplateEngine.substitute(template: "", values: [:])
        #expect(result == "")
    }

    @Test("Placeholder at beginning of line")
    func placeholderAtBeginning() {
        let result = TemplateEngine.substitute(
            template: "__NAME__ is here",
            values: ["NAME": "Alice"]
        )
        #expect(result == "Alice is here")
    }

    @Test("Placeholder at end of line")
    func placeholderAtEnd() {
        let result = TemplateEngine.substitute(
            template: "Name: __NAME__",
            values: ["NAME": "Bob"]
        )
        #expect(result == "Name: Bob")
    }

    @Test("Placeholder with no matching value remains in output")
    func unmatchedPlaceholder() {
        let result = TemplateEngine.substitute(
            template: "Hello __UNKNOWN__",
            values: ["OTHER": "value"]
        )
        #expect(result.contains("__UNKNOWN__"))
    }

    @Test("emitWarnings false suppresses stderr but preserves output")
    func emitWarningsFalse() {
        let result = TemplateEngine.substitute(
            template: "Hello __NAME__, welcome to __PLACE__",
            values: ["NAME": "World"],
            emitWarnings: false
        )
        // Unreplaced placeholder remains in the output
        #expect(result == "Hello World, welcome to __PLACE__")
    }
}
