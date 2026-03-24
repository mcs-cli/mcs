import Foundation

/// Terminal output with ANSI color support and structured logging.
struct CLIOutput {
    let colorsEnabled: Bool
    let isInteractiveTerminal: Bool

    init(colorsEnabled: Bool? = nil) {
        if let explicit = colorsEnabled {
            self.colorsEnabled = explicit
        } else {
            self.colorsEnabled = isatty(STDOUT_FILENO) != 0
        }
        isInteractiveTerminal = self.colorsEnabled && isatty(STDIN_FILENO) != 0
    }

    // MARK: - ANSI Codes

    private var red: String {
        colorsEnabled ? "\u{1B}[0;31m" : ""
    }

    private var green: String {
        colorsEnabled ? "\u{1B}[0;32m" : ""
    }

    private var yellow: String {
        colorsEnabled ? "\u{1B}[1;33m" : ""
    }

    private var blue: String {
        colorsEnabled ? "\u{1B}[0;34m" : ""
    }

    private var cyan: String {
        colorsEnabled ? "\u{1B}[0;36m" : ""
    }

    private var bold: String {
        colorsEnabled ? "\u{1B}[1m" : ""
    }

    private var dim: String {
        colorsEnabled ? "\u{1B}[2m" : ""
    }

    private var reset: String {
        colorsEnabled ? "\u{1B}[0m" : ""
    }

    // MARK: - Terminal Helpers

    private var terminalColumns: Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
    }

    private func stripANSI(_ string: String) -> String {
        string.replacing(/\u{1B}\[[0-9;?]*[A-Za-z]/, with: "")
    }

    /// Word-wraps text at word boundaries to fit within `columns`,
    /// using `indent` as the prefix for every line (including the first).
    private func wordWrap(_ text: String, indent: String, columns: Int) -> String {
        let maxWidth = columns - indent.count
        guard maxWidth > 10 else {
            return "\(indent)\(text)"
        }

        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var currentLine = ""

        for word in words {
            if currentLine.isEmpty {
                currentLine = String(word)
            } else if currentLine.count + 1 + word.count <= maxWidth {
                currentLine += " \(word)"
            } else {
                lines.append("\(indent)\(currentLine)")
                currentLine = String(word)
            }
        }
        if !currentLine.isEmpty {
            lines.append("\(indent)\(currentLine)")
        }

        return lines.joined(separator: "\n")
    }

    /// Counts visual terminal rows for a rendered output string,
    /// accounting for lines that wrap past `columns`.
    private func visualRowCount(of output: String, columns: Int) -> Int {
        guard columns > 0 else { return output.count(where: { $0 == "\n" }) }

        var lines = output.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }

        var rows = 0
        for line in lines {
            let visible = stripANSI(String(line))
            rows += visible.isEmpty ? 1 : (visible.count - 1) / columns + 1
        }
        return rows
    }

    private func sectionHeaderString(_ title: String) -> String {
        let divider = "──────────────────────────────────────────"
        return "  \(bold)\(title)\(reset)\n  \(dim)\(divider)\(reset)\n"
    }

    // MARK: - Logging

    func info(_ message: String) {
        write("\(blue)[INFO]\(reset) \(message)\n")
    }

    func success(_ message: String) {
        write("\(green)[OK]\(reset) \(message)\n")
    }

    func warn(_ message: String) {
        write("\(yellow)[WARN]\(reset) \(message)\n")
    }

    func error(_ message: String) {
        write("\(red)[ERROR]\(reset) \(message)\n", to: .standardError)
    }

    func header(_ title: String) {
        let bar = "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        write("\n\(bold)\(bar)\(reset)\n")
        write("\(bold)  \(title)\(reset)\n")
        write("\(bold)\(bar)\(reset)\n")
    }

    func step(_ current: Int, of total: Int, _ message: String) {
        let divider = "──────────────────────────────────────────"
        write("\n\(bold)[\(current)/\(total)] \(message)\(reset)\n")
        write("\(dim)\(divider)\(reset)\n")
    }

    func plain(_ message: String) {
        write("\(message)\n")
    }

    func dimmed(_ message: String) {
        write("  \(dim)\(message)\(reset)\n")
    }

    func sectionHeader(_ title: String) {
        write(sectionHeaderString(title))
    }

    /// Colored doctor summary line.
    func doctorSummary(passed: Int, fixed: Int, warnings: Int, issues: Int) {
        var parts: [String] = []
        parts.append("\(blue)\(passed) passed\(reset)")
        if fixed > 0 {
            parts.append("\(green)\(fixed) fixed\(reset)")
        }
        parts.append("\(yellow)\(warnings) warnings\(reset)")
        parts.append("\(red)\(issues) issues\(reset)")
        write(parts.joined(separator: "  ") + "\n")
    }

    // MARK: - Prompts

    /// Ask a yes/no question. Returns true for yes, false for no.
    /// Uses arrow-key navigation on TTY, falls back to text input otherwise.
    func askYesNo(_ prompt: String, default defaultValue: Bool = true) -> Bool {
        if isInteractiveTerminal {
            return interactiveYesNo(prompt, default: defaultValue)
        }
        return fallbackYesNo(prompt, default: defaultValue)
    }

    private func fallbackYesNo(_ prompt: String, default defaultValue: Bool) -> Bool {
        let hint = defaultValue ? "[Y/n]" : "[y/N]"
        while true {
            write("  \(bold)\(prompt)\(reset) \(hint): ")
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces) else {
                return defaultValue
            }
            if answer.isEmpty {
                return defaultValue
            }
            switch answer.lowercased() {
            case "y", "yes":
                return true
            case "n", "no":
                return false
            default:
                write("  Please answer y or n.\n")
            }
        }
    }

    private func interactiveYesNo(_ prompt: String, default defaultValue: Bool) -> Bool {
        withRawTerminal {
            var selected = defaultValue

            renderYesNo(prompt: prompt, selected: selected)

            while true {
                let byte = readByte()

                switch byte {
                case 0x0A, 0x0D, 0x20: // Enter or Space — confirm
                    write("\n")
                    return selected

                case 0x1B: // Escape sequence (arrow keys)
                    if let arrow = readCSIArrowKey() {
                        switch arrow {
                        case 0x43: // Right → move to No
                            if selected {
                                selected = false
                                rerenderYesNo(prompt: prompt, selected: selected)
                            }
                        case 0x44: // Left → move to Yes
                            if !selected {
                                selected = true
                                rerenderYesNo(prompt: prompt, selected: selected)
                            }
                        default:
                            break
                        }
                    }

                case 0x79, 0x59: // 'y' or 'Y'
                    write("\n")
                    return true

                case 0x6E, 0x4E: // 'n' or 'N'
                    write("\n")
                    return false

                case 0x03, 0x04: // Ctrl+C, Ctrl+D
                    write("\n")
                    return defaultValue

                default:
                    break
                }
            }
        }
    }

    private func buildYesNoString(
        prompt: String,
        selected: Bool
    ) -> String {
        var output = ""
        output += "\n"
        output += "  \(bold)\(prompt)\(reset)\n"

        let yesLabel = selected
            ? "\(cyan)\u{203A} \(bold)Yes\(reset)"
            : "  \(bold)Yes\(reset)"
        let noLabel = selected
            ? "  \(bold)No\(reset)"
            : "\(cyan)\u{203A} \(bold)No\(reset)"

        output += "  \(yesLabel)   \(noLabel)\n"
        output += "  \(dim)\u{2190}/\u{2192} Toggle \u{00B7} Enter Confirm\(reset)\n"
        return output
    }

    private func renderYesNo(prompt: String, selected: Bool) {
        write(buildYesNoString(prompt: prompt, selected: selected))
    }

    private func rerenderYesNo(prompt: String, selected: Bool) {
        let output = buildYesNoString(prompt: prompt, selected: selected)
        rerenderInPlace(output, columns: terminalColumns)
    }

    /// Inline text prompt where the user types on the same line as the label.
    func promptInline(_ prompt: String, default defaultValue: String? = nil) -> String {
        let hint = defaultValue.map { " (\($0))" } ?? ""
        write("  \(bold)\(prompt)\(reset)\(hint): ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        if answer.isEmpty, let defaultValue {
            return defaultValue
        }
        return answer
    }

    /// Multi-select checklist with arrow key navigation.
    /// Use arrow keys to move, space to toggle, Enter to confirm.
    /// Falls back to number-based input when not a TTY.
    func multiSelect(groups: inout [SelectableGroup]) -> Set<Int> {
        if isInteractiveTerminal {
            return interactiveMultiSelect(groups: &groups)
        }
        return fallbackMultiSelect(groups: &groups)
    }

    // MARK: - Single Select

    /// Single-select: arrow keys to navigate, Enter to confirm.
    /// Returns the index of the selected item.
    /// Falls back to numbered list with readLine() when not a TTY.
    func singleSelect(title: String, items: [(name: String, description: String)]) -> Int {
        guard !items.isEmpty else { return 0 }

        if isInteractiveTerminal {
            return interactiveSingleSelect(title: title, items: items)
        }
        return fallbackSingleSelect(title: title, items: items)
    }

    private func interactiveSingleSelect(
        title: String,
        items: [(name: String, description: String)]
    ) -> Int {
        withRawTerminal {
            var cursor = 0

            renderSingleSelectList(title: title, items: items, cursor: cursor)

            while true {
                let byte = readByte()

                switch byte {
                case 0x0A, 0x0D, 0x20: // Enter or Space — confirm selection
                    write("\n")
                    return cursor

                case 0x1B: // Escape sequence (arrow keys)
                    if let arrow = readCSIArrowKey() {
                        switch arrow {
                        case 0x41: // Up
                            if cursor > 0 { cursor -= 1 }
                            rerenderSingleSelectList(title: title, items: items, cursor: cursor)
                        case 0x42: // Down
                            if cursor < items.count - 1 { cursor += 1 }
                            rerenderSingleSelectList(title: title, items: items, cursor: cursor)
                        default:
                            break
                        }
                    }

                case 0x03, 0x04: // Ctrl+C, Ctrl+D
                    write("\n")
                    return cursor

                default:
                    break
                }
            }
        }
    }

    private func buildSingleSelectListString(
        title: String,
        items: [(name: String, description: String)],
        cursor: Int,
        columns: Int
    ) -> String {
        var output = ""

        output += "\n"
        output += "  \(bold)\(title)\(reset)\n"
        output += "\n"

        for (index, item) in items.enumerated() {
            if index > 0 { output += "\n" }
            let isCursor = index == cursor
            let pointer = isCursor ? "\(cyan)\u{203A}\(reset)" : " "
            let nameStyle = isCursor
                ? "\(bold)\(cyan)\(item.name)\(reset)"
                : "\(bold)\(item.name)\(reset)"
            output += "  \(pointer) \(nameStyle)\n"
            output += "\(dim)\(wordWrap(item.description, indent: "    ", columns: columns))\(reset)\n"
        }

        output += "\n"
        output += "  \(dim)\u{2191}/\u{2193} Navigate \u{00B7} Space/Enter Select\(reset)\n"
        return output
    }

    private func renderSingleSelectList(
        title: String,
        items: [(name: String, description: String)],
        cursor: Int
    ) {
        let columns = terminalColumns
        write(buildSingleSelectListString(title: title, items: items, cursor: cursor, columns: columns))
    }

    private func rerenderSingleSelectList(
        title: String,
        items: [(name: String, description: String)],
        cursor: Int
    ) {
        let columns = terminalColumns
        let output = buildSingleSelectListString(title: title, items: items, cursor: cursor, columns: columns)
        rerenderInPlace(output, columns: columns)
    }

    private func fallbackSingleSelect(
        title: String,
        items: [(name: String, description: String)]
    ) -> Int {
        write("\n")
        write("  \(bold)\(title)\(reset)\n")
        write("\n")

        for (index, item) in items.enumerated() {
            if index > 0 { write("\n") }
            let num = index + 1
            write("  [\(num)] \(bold)\(item.name)\(reset)\n")
            write("      \(dim)\(item.description)\(reset)\n")
        }

        write("\n")

        while true {
            write("\(bold)> \(reset)")
            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
                return 0
            }
            if let num = Int(input), num >= 1, num <= items.count {
                return num - 1
            }
            write("  Please enter a number between 1 and \(items.count).\n")
        }
    }

    // MARK: - Interactive Multi-Select (raw terminal)

    private func interactiveMultiSelect(groups: inout [SelectableGroup]) -> Set<Int> {
        var flatItems: [(groupIndex: Int, itemIndex: Int)] = []
        for gi in groups.indices {
            for ii in groups[gi].items.indices {
                flatItems.append((gi, ii))
            }
        }

        guard !flatItems.isEmpty else {
            return collectSelected(from: groups)
        }

        return withRawTerminal {
            var cursor = 0

            renderInteractiveList(groups: groups, cursor: cursor)

            while true {
                let byte = readByte()

                switch byte {
                case 0x0A, 0x0D: // Enter
                    write("\n")
                    return collectSelected(from: groups)

                case 0x20: // Space — toggle current item
                    let (gi, ii) = flatItems[cursor]
                    groups[gi].items[ii].isSelected.toggle()
                    rerenderInteractiveList(groups: groups, cursor: cursor)

                case 0x61: // 'a' — select all
                    for gi in groups.indices {
                        for ii in groups[gi].items.indices {
                            groups[gi].items[ii].isSelected = true
                        }
                    }
                    rerenderInteractiveList(groups: groups, cursor: cursor)

                case 0x6E: // 'n' — select none
                    for gi in groups.indices {
                        for ii in groups[gi].items.indices {
                            groups[gi].items[ii].isSelected = false
                        }
                    }
                    rerenderInteractiveList(groups: groups, cursor: cursor)

                case 0x1B: // Escape sequence (arrow keys)
                    if let arrow = readCSIArrowKey() {
                        switch arrow {
                        case 0x41: // Up
                            if cursor > 0 { cursor -= 1 }
                            rerenderInteractiveList(groups: groups, cursor: cursor)
                        case 0x42: // Down
                            if cursor < flatItems.count - 1 { cursor += 1 }
                            rerenderInteractiveList(groups: groups, cursor: cursor)
                        default:
                            break
                        }
                    }

                case 0x03, 0x04: // Ctrl+C, Ctrl+D
                    write("\n")
                    return collectSelected(from: groups)

                default:
                    break
                }
            }
        }
    }

    private func buildInteractiveListString(
        groups: [SelectableGroup],
        cursor: Int,
        columns: Int
    ) -> String {
        var output = ""

        output += "\n"
        output += "  Use \(bold)\u{2191}\u{2193}\(reset) to move, "
        output += "\(bold)space\(reset) to toggle, "
        output += "\(bold)enter\(reset) to confirm\n"

        var flatIndex = 0
        for group in groups where !group.items.isEmpty {
            output += "\n"
            output += sectionHeaderString(group.title)
            for item in group.items {
                let isCursor = flatIndex == cursor
                let marker = item.isSelected
                    ? "\(green)\u{25CF}\(reset)"
                    : "\(dim)\u{25CB}\(reset)"
                let pointer = isCursor ? "\(cyan)\u{276F}\(reset)" : " "
                let nameStyle = isCursor ? "\(bold)\(cyan)\(item.name)\(reset)" : "\(bold)\(item.name)\(reset)"
                output += "  \(pointer) \(marker) \(nameStyle)\n"
                output += "\(dim)\(wordWrap(item.description, indent: "      ", columns: columns))\(reset)\n"
                flatIndex += 1
            }
        }

        let allRequired = groups.flatMap(\.requiredItems)
        if !allRequired.isEmpty {
            output += "\n"
            output += sectionHeaderString("Always included")
            for req in allRequired {
                output += "    \(green)\u{2713}\(reset) \(req.name)\n"
            }
        }

        output += "\n"
        return output
    }

    private func renderInteractiveList(
        groups: [SelectableGroup],
        cursor: Int
    ) {
        let columns = terminalColumns
        write(buildInteractiveListString(groups: groups, cursor: cursor, columns: columns))
    }

    /// Move cursor up to re-render the list in place.
    private func rerenderInteractiveList(
        groups: [SelectableGroup],
        cursor: Int
    ) {
        let columns = terminalColumns
        let output = buildInteractiveListString(groups: groups, cursor: cursor, columns: columns)
        rerenderInPlace(output, columns: columns)
    }

    /// Cursor-up by visual row count, clear, and rewrite.
    private func rerenderInPlace(_ output: String, columns: Int) {
        let rowCount = visualRowCount(of: output, columns: columns)
        write("\u{1B}[\(rowCount)A")
        write("\u{1B}[0J")
        write(output)
    }

    private func readByte() -> UInt8 {
        var byte: UInt8 = 0
        _ = Darwin.read(STDIN_FILENO, &byte, 1)
        return byte
    }

    /// Reads a CSI arrow key escape sequence after the initial 0x1B byte.
    /// Returns the arrow byte (0x41=Up, 0x42=Down, 0x43=Right, 0x44=Left), or nil if not a CSI sequence.
    private func readCSIArrowKey() -> UInt8? {
        guard readByte() == 0x5B else { return nil }
        return readByte()
    }

    /// Enters raw terminal mode (no echo, no canonical processing, hidden cursor),
    /// runs the body closure, then restores the terminal on return.
    private func withRawTerminal<T>(_ body: () -> T) -> T {
        var original = termios()
        tcgetattr(STDIN_FILENO, &original)
        var raw = original
        raw.c_lflag &= ~UInt(ICANON | ECHO)
        raw.c_cc.16 = 1 // VMIN = 1
        raw.c_cc.17 = 0 // VTIME = 0
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        write("\u{1B}[?25l")
        defer {
            write("\u{1B}[?25h")
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
        }
        return body()
    }

    // MARK: - Fallback Multi-Select (non-TTY)

    private func fallbackMultiSelect(groups: inout [SelectableGroup]) -> Set<Int> {
        var isFirstRender = true

        while true {
            if !isFirstRender {
                clearScreen()
            }
            isFirstRender = false

            renderFallbackList(groups: groups)

            write("  \(dim)Toggle: 1 3 5  |  Confirm: Enter\(reset)\n")
            write("\(bold)> \(reset)")

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces) else {
                break
            }

            switch MultiSelectParser.parse(input) {
            case .confirm:
                return collectSelected(from: groups)
            case .selectAll:
                for gi in groups.indices {
                    for ii in groups[gi].items.indices {
                        groups[gi].items[ii].isSelected = true
                    }
                }
            case .selectNone:
                for gi in groups.indices {
                    for ii in groups[gi].items.indices {
                        groups[gi].items[ii].isSelected = false
                    }
                }
            case let .toggle(numbers):
                for num in numbers {
                    for gi in groups.indices {
                        for ii in groups[gi].items.indices
                            where groups[gi].items[ii].number == num {
                            groups[gi].items[ii].isSelected.toggle()
                        }
                    }
                }
            }
        }

        return collectSelected(from: groups)
    }

    private func renderFallbackList(groups: [SelectableGroup]) {
        write("\n")
        write("  All recommended components are pre-selected.\n")
        write("  Type numbers to toggle, \(bold)a\(reset) to select all, ")
        write("\(bold)n\(reset) to select none, \(bold)Enter\(reset) to confirm.\n")

        for group in groups where !group.items.isEmpty {
            write("\n")
            sectionHeader(group.title)
            for item in group.items {
                let marker = item.isSelected
                    ? "\(green)\u{25CF}\(reset)"
                    : "\(dim)\u{25CB}\(reset)"
                let numStr = String(format: "%2d", item.number)
                write("  [\(numStr)]  \(marker) \(bold)\(item.name)\(reset)\n")
                write("         \(dim)\(item.description)\(reset)\n")
            }
        }

        let allRequired = groups.flatMap(\.requiredItems)
        if !allRequired.isEmpty {
            write("\n")
            sectionHeader("Always included")
            for req in allRequired {
                write("       \(green)\u{2713}\(reset) \(req.name)\n")
            }
        }

        write("\n")
    }

    private func collectSelected(from groups: [SelectableGroup]) -> Set<Int> {
        var selected = Set<Int>()
        for group in groups {
            for item in group.items where item.isSelected {
                selected.insert(item.number)
            }
        }
        return selected
    }

    private func clearScreen() {
        guard colorsEnabled else { return }
        write("\u{1B}[2J\u{1B}[H")
    }

    // MARK: - Output

    private enum OutputTarget {
        case standardOutput
        case standardError
    }

    private func write(_ string: String, to target: OutputTarget = .standardOutput) {
        let data = Data(string.utf8)
        switch target {
        case .standardOutput:
            FileHandle.standardOutput.write(data)
        case .standardError:
            FileHandle.standardError.write(data)
        }
    }
}

// MARK: - Multi-Select Types

struct SelectableItem {
    let number: Int
    let name: String
    let description: String
    var isSelected: Bool
}

struct RequiredItem {
    let name: String
}

struct SelectableGroup {
    let title: String
    var items: [SelectableItem]
    let requiredItems: [RequiredItem]
}

// MARK: - Multi-Select Parser

enum MultiSelectAction: Equatable {
    case confirm
    case selectAll
    case selectNone
    case toggle([Int])
}

enum MultiSelectParser {
    static func parse(_ input: String) -> MultiSelectAction {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .confirm }
        if trimmed.lowercased() == "a" { return .selectAll }
        if trimmed.lowercased() == "n" { return .selectNone }
        let numbers = trimmed
            .replacingOccurrences(of: ",", with: " ")
            .split(separator: " ")
            .compactMap { Int($0) }
        guard !numbers.isEmpty else { return .confirm }
        return .toggle(numbers)
    }
}
