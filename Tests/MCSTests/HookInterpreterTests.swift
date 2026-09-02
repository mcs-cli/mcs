import Foundation
@testable import mcs
import Testing

// MARK: - Resolution

@Suite("HookInterpreter resolution")
struct HookInterpreterResolutionTests {
    @Test("Explicit interpreter wins over inference")
    func explicitWins() {
        let resolved = HookInterpreter.resolve(
            explicit: "bun",
            destination: "gate.js",
            source: "hooks/gate.js"
        )
        #expect(resolved == "bun")
    }

    @Test("Explicit interpreter is trimmed")
    func explicitTrimmed() {
        #expect(HookInterpreter.resolve(explicit: "  node  ", destination: "x.sh", source: nil) == "node")
    }

    @Test("Blank explicit interpreter falls through to inference")
    func blankExplicitFallsThrough() {
        #expect(HookInterpreter.resolve(explicit: "   ", destination: "x.py", source: nil) == "python3")
    }

    @Test("Known extensions infer their interpreter")
    func knownExtensions() {
        let cases: [(String, String)] = [
            ("x.sh", "bash"), ("x.bash", "bash"), ("x.zsh", "zsh"),
            ("x.js", "node"), ("x.mjs", "node"), ("x.cjs", "node"),
            ("x.py", "python3"), ("x.rb", "ruby"), ("x.pl", "perl"),
        ]
        for (destination, expected) in cases {
            #expect(
                HookInterpreter.resolve(explicit: nil, destination: destination, source: nil) == expected,
                "\(destination) should infer \(expected)"
            )
        }
    }

    @Test("Extension matching is case-insensitive")
    func caseInsensitive() {
        #expect(HookInterpreter.resolve(explicit: nil, destination: "x.JS", source: nil) == "node")
    }

    @Test("Source extension is the fallback when destination has none")
    func sourceFallback() {
        let resolved = HookInterpreter.resolve(
            explicit: nil,
            destination: "session-start",
            source: "hooks/session_start.py"
        )
        #expect(resolved == "python3")
    }

    @Test("An ambiguous or unknown destination does not fall through to the source")
    func ambiguousDestinationDoesNotFallThrough() {
        // `.ts` infers nothing by policy; falling back to a `.js` source would smuggle node in.
        #expect(
            HookInterpreter.resolve(explicit: nil, destination: "gate.ts", source: "hooks/gate.js")
                == "bash"
        )
        // Same for an extension the table simply does not know.
        #expect(
            HookInterpreter.resolve(explicit: nil, destination: "gate.bin", source: "hooks/gate.py")
                == "bash"
        )
    }

    @Test("Destination extension takes precedence over source")
    func destinationBeatsSource() {
        let resolved = HookInterpreter.resolve(
            explicit: nil,
            destination: "gate.py",
            source: "hooks/gate.js"
        )
        #expect(resolved == "python3")
    }

    @Test("Unknown and absent extensions default to bash")
    func defaultsToBash() {
        #expect(HookInterpreter.resolve(explicit: nil, destination: "hook", source: nil) == "bash")
        #expect(HookInterpreter.resolve(explicit: nil, destination: "hook.bin", source: nil) == "bash")
    }

    @Test("TypeScript infers nothing — no safe default exists")
    func typeScriptIsAmbiguous() {
        for destination in ["gate.ts", "gate.mts", "gate.cts", "gate.tsx"] {
            #expect(HookInterpreter.resolve(explicit: nil, destination: destination, source: nil) == "bash")
            #expect(HookInterpreter.isAmbiguous(path: destination))
        }
    }

    @Test("Binary is the first token")
    func binaryExtraction() {
        #expect(HookInterpreter.binary(of: "node --experimental-strip-types") == "node")
        #expect(HookInterpreter.binary(of: "uv run") == "uv")
        #expect(HookInterpreter.binary(of: "bash") == "bash")
        #expect(HookInterpreter.binary(of: "/opt/homebrew/bin/bun") == "/opt/homebrew/bin/bun")
    }

    @Test("Binary looks through env to the command it dispatches")
    func binaryLooksThroughEnv() {
        // Checking `env` would always pass while the hook dies for want of `node`.
        #expect(HookInterpreter.binary(of: "/usr/bin/env node") == "node")
        #expect(HookInterpreter.binary(of: "env python3") == "python3")
        #expect(HookInterpreter.binary(of: "/usr/bin/env -S node --experimental-strip-types") == "node")
        #expect(HookInterpreter.binary(of: "/usr/bin/env FOO=bar node") == "node")
        #expect(HookInterpreter.binary(of: "/usr/bin/env -u NODE_OPTIONS node") == "node")
        // Nothing to dispatch — report env rather than inventing a binary.
        #expect(HookInterpreter.binary(of: "/usr/bin/env") == "/usr/bin/env")
    }
}

// MARK: - Validation

@Suite("HookInterpreter validation")
struct HookInterpreterValidationTests {
    @Test("Accepts the real-world TypeScript invocation")
    func acceptsTypeScriptInvocation() {
        let interpreter = "node --experimental-strip-types --disable-warning=ExperimentalWarning"
        #expect(HookInterpreter.rejectionReason(for: interpreter) == nil)
    }

    @Test("Accepts bare binaries, subcommands, flags and absolute paths")
    func acceptsValidShapes() {
        let valid = [
            "node", "python3", "ruby", "bun",
            "uv run",
            "python3 -u",
            "node --experimental-strip-types",
            "/opt/homebrew/bin/bun",
            "/usr/bin/env node",
            "deno run --allow-read",
        ]
        for interpreter in valid {
            #expect(HookInterpreter.rejectionReason(for: interpreter) == nil, "should accept '\(interpreter)'")
        }
    }

    @Test("Rejects shell metacharacters")
    func rejectsMetacharacters() {
        let invalid = [
            "node; rm -rf ~",
            "node && curl evil.sh",
            "node | tee /tmp/x",
            "node $(whoami)",
            "node `whoami`",
            "node > /tmp/out",
            "node 'a b'",
            "node \"a b\"",
            "node&",
            "node*",
        ]
        for interpreter in invalid {
            #expect(HookInterpreter.rejectionReason(for: interpreter) != nil, "should reject '\(interpreter)'")
        }
    }

    @Test("Rejects embedded newlines and control characters")
    func rejectsControlCharacters() {
        // A newline is split away as token whitespace, so per-token charset checks never see it —
        // but it survives into the composed command as a shell command separator.
        for interpreter in ["node\nrm -rf", "node\trm", "node\rm", "node\u{0B}rm", "node\u{00A0}rm"] {
            #expect(HookInterpreter.rejectionReason(for: interpreter) != nil, "should reject '\(interpreter)'")
        }
        // A plain single space between tokens remains legal.
        #expect(HookInterpreter.rejectionReason(for: "uv run") == nil)
    }

    @Test("Normalizing on resolve keeps irregular whitespace out of the composed command")
    func resolveNormalizesWhitespace() {
        let resolved = HookInterpreter.resolve(
            explicit: "node\nrm -rf",
            destination: "x.sh",
            source: nil
        )
        // Structural backstop for the validation above: no newline can reach the command string.
        #expect(!resolved.contains("\n"))
        #expect(resolved == "node rm -rf")
    }

    @Test("Rejects empty and whitespace-only values")
    func rejectsEmpty() {
        #expect(HookInterpreter.rejectionReason(for: "") != nil)
        #expect(HookInterpreter.rejectionReason(for: "   ") != nil)
    }

    @Test("Rejects relative interpreter paths")
    func rejectsRelativePaths() {
        // The hook runs with a working directory mcs does not control.
        #expect(HookInterpreter.rejectionReason(for: "./bin/node") != nil)
        #expect(HookInterpreter.rejectionReason(for: "../node") != nil)
    }

    @Test("Rejects values over the length limit")
    func rejectsOversized() {
        #expect(HookInterpreter.rejectionReason(for: String(repeating: "a", count: 201)) != nil)
        #expect(HookInterpreter.rejectionReason(for: String(repeating: "a", count: 200)) == nil)
    }

    @Test("Accepts a long-but-legitimate argument list, rejects only on total length")
    func acceptsManyArguments() {
        // Six --allow-* flags is a real deno invocation; a token-count cap would reject it.
        let deno = "deno run --allow-read --allow-write --allow-net --allow-env --allow-run --no-check"
        #expect(HookInterpreter.rejectionReason(for: deno) == nil)
        #expect(HookInterpreter.rejectionReason(for: String(repeating: "a", count: 201)) != nil)
    }
}

// MARK: - Command parsing

@Suite("HookInterpreter managed-path parsing")
struct HookInterpreterPathTests {
    @Test("Recognises a managed hook regardless of interpreter or arguments")
    func recognisesManagedHooks() {
        let directory = "~/.claude/hooks/"
        let commands = [
            "bash ~/.claude/hooks/p/x.sh",
            "node ~/.claude/hooks/p/x.js",
            "node --experimental-strip-types --disable-warning=ExperimentalWarning ~/.claude/hooks/p/x.ts",
            "uv run ~/.claude/hooks/p/x.py",
            // Trailing arguments: the path is not the last token, and must still be reclaimed
            // on unconfigure or the settings entry orphans.
            "bash ~/.claude/hooks/p/x.sh --verbose",
        ]
        for command in commands {
            #expect(
                HookInterpreter.managedHookPath(in: command, directory: directory) != nil,
                "should recognise '\(command)'"
            )
        }
    }

    @Test("Interpreter recovery requires the path to be the trailing token")
    func interpreterRecoveryIsStrict() {
        let directory = ".claude/hooks/"
        #expect(
            HookInterpreter.interpreter(
                ofRegisteredCommand: "node --experimental-strip-types .claude/hooks/p/gate.ts",
                directory: directory
            ) == "node --experimental-strip-types"
        )
        // Not a managed hook invocation — must not yield a bogus interpreter.
        #expect(HookInterpreter.interpreter(ofRegisteredCommand: "mcs check-updates --hook", directory: directory) == nil)
        #expect(HookInterpreter.interpreter(ofRegisteredCommand: "python3 -m pkg.hook", directory: directory) == nil)
        // Path present but not trailing: recognised as managed, but the interpreter is unclear.
        #expect(HookInterpreter.interpreter(ofRegisteredCommand: "bash .claude/hooks/p/x.sh -v", directory: directory) == nil)
        // Bare path with no interpreter token.
        #expect(HookInterpreter.interpreter(ofRegisteredCommand: ".claude/hooks/p/x.sh", directory: directory) == nil)
    }

    @Test("isDefault compares the whole interpreter, not a prefix")
    func isDefaultIsExact() {
        #expect(HookInterpreter.isDefault("bash"))
        // An explicit bash with flags is a deliberate choice, not the default.
        #expect(!HookInterpreter.isDefault("bash -e"))
        // And a different binary that merely starts with the same letters is not the default.
        #expect(!HookInterpreter.isDefault("bashly"))
    }

    @Test("Ignores commands pointing elsewhere")
    func ignoresForeignCommands() {
        let directory = "~/.claude/hooks/"
        #expect(HookInterpreter.managedHookPath(in: "mcs check-updates --hook", directory: directory) == nil)
        #expect(HookInterpreter.managedHookPath(in: "bash ~/scripts/mine.sh", directory: directory) == nil)
        #expect(HookInterpreter.managedHookPath(in: "", directory: directory) == nil)
    }

    @Test("Project and global directories do not cross-match")
    func scopesDoNotCrossMatch() {
        let command = "bash ~/.claude/hooks/p/x.sh"
        #expect(HookInterpreter.managedHookPath(in: command, directory: ".claude/hooks/") == nil)
        #expect(HookInterpreter.managedHookPath(in: command, directory: "~/.claude/hooks/") != nil)
    }
}

// MARK: - Checkable binaries

@Suite("HookInterpreter checkable binaries")
struct HookInterpreterCheckableBinaryTests {
    private let directory = ".claude/hooks/"

    private func binaries(_ commands: [String]) -> [String] {
        HookInterpreter.distinctCheckableBinaries(inRegisteredCommands: commands, directory: directory)
    }

    @Test("Deduplicates one binary across many hooks")
    func deduplicates() {
        #expect(binaries([
            "node .claude/hooks/p/a.js",
            "node .claude/hooks/p/b.js",
            "node .claude/hooks/p/c.mjs",
        ]) == ["node"])
    }

    @Test("Skips shells that are always present")
    func skipsShells() {
        #expect(binaries([
            "bash .claude/hooks/p/a.sh",
            "zsh .claude/hooks/p/b.zsh",
        ]).isEmpty)
    }

    @Test("Reports the binary only, not its arguments")
    func reportsBinaryOnly() {
        #expect(binaries([
            "node --experimental-strip-types --disable-warning=ExperimentalWarning .claude/hooks/p/a.ts",
        ]) == ["node"])
    }

    @Test("Keeps distinct binaries in command order")
    func keepsDistinctInOrder() {
        #expect(binaries([
            "python3 .claude/hooks/p/a.py",
            "node .claude/hooks/p/b.js",
            "python3 .claude/hooks/p/c.py",
            "ruby .claude/hooks/p/d.rb",
        ]) == ["python3", "node", "ruby"])
    }

    @Test("A command with no interpreter token contributes nothing")
    func ignoresBarePaths() {
        #expect(binaries([".claude/hooks/p/x.sh"]).isEmpty)
    }
}
