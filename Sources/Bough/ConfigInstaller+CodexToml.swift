import Foundation
import os.log

private let codexTomlLog = Logger(subsystem: "com.dgpisces.bough", category: "CodexToml")

extension ConfigInstaller {

    // MARK: - Codex config.toml

    /// Ensure hooks exists under [features] in $CODEX_HOME/config.toml
    /// (or ~/.codex/config.toml when unset) so Codex can fire hook events.
    ///
    /// Version-guard dispatch:
    /// - Detected version >= 0.130.0  → `migrateCodexHooksKey` (strips `codex_hooks`, writes `hooks`).
    /// - Detected version < 0.130.0   → `preserveCodexHooksKeyAndAddHooks` (leaves `codex_hooks` in
    ///   place, adds `hooks = true/false` alongside so the older CLI keeps the user's intent).
    /// - Detection failure (nil)       → `migrateCodexHooksKey` because current Codex warnings are
    ///   the live failure mode.
    ///
    /// Plan 15-04 addition: `cleanupBoughHooksFromCodexConfigToml` runs FIRST (HOOK-03). On
    /// `.malformedRefused`, the function short-circuits with `false` so the user's malformed file
    /// stays byte-identical — the `[features]` migration is also skipped (D-15).
    @discardableResult
    static func enableCodexHooksConfig(fm: FileManager) -> Bool {
        // HOOK-03: strip Bough-written [hooks.*] / [[hooks]] blocks first (Plan 15-04).
        let cleanupOutcome = cleanupBoughHooksFromCodexConfigToml(fm: fm)
        if case .malformedRefused = cleanupOutcome {
            // D-15: malformed user TOML stays exactly as-is.
            // Skip [features] migration too — the looser codexConfigHasValidTableHeaders gate
            // could pass a file that the stricter cleanup validator rejects, and we must not
            // modify a broken file.
            return false
        }
        let deprecatedKeyWasPresent = codexDeprecatedHooksKeyPresent(fm: fm)
        let detectedVersion: String? = detectCodexVersion()
        let result: Bool
        if let detectedVersion, !versionAtLeast(detectedVersion, codexCLIMinimumHooksVersion) {
            result = preserveCodexHooksKeyAndAddHooks(fm: fm)
        } else {
            result = migrateCodexHooksKey(fm: fm)
        }
        if result,
           deprecatedKeyWasPresent,
           !codexDeprecatedHooksKeyPresent(fm: fm) {
            logCodexAppServerRestartIfNeeded(fm: fm)
        }
        return result
    }

    /// Migrates Codex's deprecated feature flag to the current hooks key while
    /// preserving an explicit user-disabled value.
    @discardableResult
    static func migrateCodexHooksKey(fm: FileManager) -> Bool {
        rewriteCodexHooksFeatureFlag(fm: fm, mode: .removeDeprecatedKey)
    }

    /// Compatibility sibling of `migrateCodexHooksKey` for Codex CLI versions < 0.130.0.
    ///
    /// Differs from `migrateCodexHooksKey` in exactly one way: when a `codex_hooks` line
    /// is encountered inside `[features]`, it is LEFT IN PLACE (the old CLI still reads it
    /// to decide whether to fire events — removing it would cause a silent event drop,
    /// which is the Pitfall-15 scenario this helper exists to prevent).
    /// If `hooks = true/false` is already present, it wins and no second insertion occurs
    /// (idempotent). When `hooks` is absent, `hooks = legacyValue` is inserted at
    /// `featureStart + 1`.
    @discardableResult
    static func preserveCodexHooksKeyAndAddHooks(fm: FileManager) -> Bool {
        rewriteCodexHooksFeatureFlag(fm: fm, mode: .preserveDeprecatedKey)
    }

    private enum CodexHooksFeatureRewriteMode {
        case removeDeprecatedKey
        case preserveDeprecatedKey
    }

    @discardableResult
    private static func rewriteCodexHooksFeatureFlag(
        fm: FileManager,
        mode: CodexHooksFeatureRewriteMode
    ) -> Bool {
        let configPath = codexHome() + "/config.toml"
        var contents = ""
        if fm.fileExists(atPath: configPath) {
            guard let existing = try? String(contentsOfFile: configPath, encoding: .utf8) else {
                return false
            }
            contents = existing
        }

        guard codexConfigHasValidTableHeaders(contents) else { return false }

        var lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let hadTrailingNewline = contents.hasSuffix("\n")
        let featureStart = lines.firstIndex { line in
            isCodexTomlFeaturesHeader(line)
        }

        if let featureStart {
            var featureEnd = codexTomlFeatureEndIndex(from: featureStart, lines: lines)
            var sawHooks = false
            var legacyValue: String?
            var index = featureStart + 1

            while index < featureEnd {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    index += 1
                    continue
                }

                if codexBoolAssignmentValue(trimmed, key: "hooks") != nil {
                    sawHooks = true
                    // Keep the user's existing value exactly — no rewrite needed.
                    index += 1
                    continue
                }

                if let oldValue = codexBoolAssignmentValue(trimmed, key: "codex_hooks") {
                    if legacyValue == nil {
                        legacyValue = oldValue
                    }
                    switch mode {
                    case .removeDeprecatedKey:
                        lines.remove(at: index)
                        featureEnd -= 1
                    case .preserveDeprecatedKey:
                        index += 1
                    }
                    continue
                }

                index += 1
            }

            if !sawHooks {
                lines.insert("hooks = \(legacyValue ?? "true")", at: featureStart + 1)
            }
        } else {
            if !(lines.last ?? "").isEmpty { lines.append("") }
            lines.append("[features]")
            lines.append("hooks = true")
        }

        var result = lines.joined(separator: "\n")
        if hadTrailingNewline, !result.hasSuffix("\n") {
            result.append("\n")
        }
        guard let data = result.data(using: .utf8) else { return false }

        do {
            try fm.createDirectory(
                atPath: (configPath as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Codex config.toml cleanup (HOOK-03)

    /// Outcome of `cleanupBoughHooksFromCodexConfigToml(fm:)`.
    /// `internal` visibility so test shims in @testable imports can inspect the value.
    enum CodexCleanupOutcome {
        /// The file was modified — Bough-owned blocks were removed.
        case cleaned
        /// No file exists, or no Bough-owned content was found; no write was performed.
        case nothingToDo
        /// The local TOML safety check rejected the file; the file was left byte-identical.
        /// Callers MUST skip all downstream TOML mutations when this outcome is returned (D-15).
        case malformedRefused
    }

    /// Removes Bough-written `[hooks.*]` / `[[hooks]]` blocks from `~/.codex/config.toml` via a
    /// two-pass strategy that preserves every other byte of user-edited TOML content:
    ///
    /// - **Pass 1 (marker-bracketed range, raw text):** Excises any range bounded by
    ///   `# bough-hook-v1-start` / `# bough-hook-v1-end` markers.
    /// - **Pass 2 (section scan + `bough-bridge` substring):** Removes any hooks table or
    ///   array-of-tables entry whose `command` field contains the substring `bough-bridge`.
    ///
    /// Returns `.malformedRefused` (and leaves the file untouched) if the local TOML safety
    /// check rejects the file after Pass 1. Callers must short-circuit all downstream TOML
    /// mutations on this outcome so the user's broken file stays byte-identical (D-15).
    static func cleanupBoughHooksFromCodexConfigToml(fm: FileManager) -> CodexCleanupOutcome {
        let configPath = codexHome() + "/config.toml"

        // No file — trivially clean; no write needed.
        guard fm.fileExists(atPath: configPath) else { return .nothingToDo }

        // Unreadable file — treat as no-op; downstream migration hits same I/O failure.
        guard let originalContents = try? String(contentsOfFile: configPath, encoding: .utf8) else {
            return .nothingToDo
        }

        // ── Pass 1: Marker-bracketed range removal on raw text ────────────────────────────────
        // Operates on raw text before validation so the entire bracketed range (comments,
        // blank lines, values) is removed by a string-range operation that doesn't touch
        // anything outside.
        var lines = originalContents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let hadTrailingNewline = originalContents.hasSuffix("\n")

        var removedByPassOne = false

        markerLoop: while true {
            guard let startIdx = lines.firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "# bough-hook-v1-start"
            }) else { break markerLoop }

            guard let endIdx = lines[(startIdx + 1)...].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "# bough-hook-v1-end"
            }) else {
                // Unbalanced marker — leave file untouched in this pass.
                break markerLoop
            }

            // Remove the start..=end range.
            lines.removeSubrange(startIdx...endIdx)

            // Trim ONE adjacent blank line at the removal site to avoid stacked blanks.
            // After removal, startIdx now points to the line immediately after the removed range.
            if startIdx < lines.count,
               lines[startIdx].trimmingCharacters(in: .whitespaces).isEmpty {
                // Blank line that follows — only remove if it is preceded by a blank line too
                // (or it's the start of the file), to prevent removing a semantically important gap.
                let precedingIsBlankOrBOF = startIdx == 0
                    || lines[startIdx - 1].trimmingCharacters(in: .whitespaces).isEmpty
                if precedingIsBlankOrBOF {
                    lines.remove(at: startIdx)
                }
            }

            removedByPassOne = true
        }

        var passOneOutput = lines.joined(separator: "\n")
        if hadTrailingNewline, !passOneOutput.hasSuffix("\n") {
            passOneOutput.append("\n")
        }

        guard removedByPassOne || passOneOutput.contains("bough-bridge") || codexTomlMayContainHooksTable(passOneOutput) else {
            return .nothingToDo
        }

        guard codexConfigHasValidTableHeaders(passOneOutput) else {
            // Malformed TOML — refuse and leave the file exactly as-is (D-15).
            // NOTE: we do NOT write passOneOutput back even if Pass 1 removed something,
            // because the file is already in a broken state and writing a partial result
            // could make things worse. The caller short-circuits on .malformedRefused.
            return .malformedRefused
        }

        // ── Pass 2: section scan + bough-bridge substring match ─────────────────────────────
        let passTwoOutput = removeBoughOwnedCodexHooksBlocks(from: passOneOutput)

        // If nothing was removed by either pass, no write needed.
        guard removedByPassOne || passTwoOutput.removed else { return .nothingToDo }

        let cleanedText = passTwoOutput.text

        // Write back atomically (D-15 threat T-15-04-04).
        guard let data = cleanedText.data(using: .utf8) else { return .nothingToDo }
        do {
            try data.write(to: URL(fileURLWithPath: configPath), options: .atomic)
            return .cleaned
        } catch {
            // Write failed — file on disk is unchanged; downstream migration may still proceed.
            return .nothingToDo
        }
    }

    static func isCodexTomlSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return false }
        let header = codexTomlLineWithoutTrailingComment(trimmed)
            .trimmingCharacters(in: .whitespaces)

        if header.hasPrefix("[[") {
            guard header.hasSuffix("]]"), header.count > 4 else { return false }
            let inner = String(header.dropFirst(2).dropLast(2))
            return codexTomlDottedKeyIsValid(inner)
        }

        guard header.hasSuffix("]"), !header.hasPrefix("[[") else { return false }
        let inner = String(header.dropFirst().dropLast())
        return codexTomlDottedKeyIsValid(inner)
    }

    static func isCodexTomlFeaturesHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[") else { return false }
        let header = codexTomlLineWithoutTrailingComment(trimmed)
            .trimmingCharacters(in: .whitespaces)
        guard header.hasPrefix("["),
              header.hasSuffix("]"),
              !header.hasPrefix("[[")
        else { return false }
        let inner = String(header.dropFirst().dropLast())
            .trimmingCharacters(in: .whitespaces)
        return inner == "features"
    }

    private static func codexTomlLineWithoutTrailingComment(_ line: String) -> String {
        var inBasicString = false
        var inLiteralString = false
        var escaped = false
        var index = line.startIndex

        while index < line.endIndex {
            let character = line[index]

            if inBasicString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
            } else if inLiteralString {
                if character == "'" {
                    inLiteralString = false
                }
            } else if character == "\"" {
                inBasicString = true
            } else if character == "'" {
                inLiteralString = true
            } else if character == "#" {
                return String(line[..<index])
            }

            index = line.index(after: index)
        }

        return line
    }

    private static func codexTomlFeatureEndIndex(from featureStart: Int, lines: [String]) -> Int {
        var arrayDepth = 0
        var index = featureStart + 1

        while index < lines.endIndex {
            if arrayDepth == 0, isCodexTomlSectionHeader(lines[index]) {
                return index
            }
            arrayDepth = max(0, arrayDepth + codexTomlBracketDelta(lines[index]))
            index += 1
        }

        return lines.endIndex
    }

    private static func codexTomlBracketDelta(_ line: String) -> Int {
        let text = codexTomlLineWithoutTrailingComment(line)
        var inBasicString = false
        var inLiteralString = false
        var escaped = false
        var delta = 0
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            if inBasicString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
            } else if inLiteralString {
                if character == "'" {
                    inLiteralString = false
                }
            } else if character == "\"" {
                inBasicString = true
            } else if character == "'" {
                inLiteralString = true
            } else if character == "[" {
                delta += 1
            } else if character == "]" {
                delta -= 1
            }

            index = text.index(after: index)
        }

        return delta
    }

    private static func codexTomlDottedKeyIsValid(_ key: String) -> Bool {
        codexTomlDottedKeySegments(key) != nil
    }

    private static func codexTomlDottedKeySegments(_ key: String) -> [String]? {
        var index = key.startIndex
        var segments: [String] = []

        func skipWhitespace() {
            while index < key.endIndex, key[index].isWhitespace {
                index = key.index(after: index)
            }
        }

        while true {
            skipWhitespace()
            guard index < key.endIndex else { return nil }
            let start = index
            guard codexTomlParseKeySegment(key, index: &index) else { return nil }
            let rawSegment = String(key[start..<index])
            if rawSegment.hasPrefix("\""), rawSegment.hasSuffix("\"") {
                guard codexBasicStringValue(rawSegment) != nil else { return nil }
                segments.append(String(rawSegment.dropFirst().dropLast()))
            } else if rawSegment.hasPrefix("'"), rawSegment.hasSuffix("'") {
                segments.append(String(rawSegment.dropFirst().dropLast()))
            } else {
                segments.append(rawSegment)
            }
            skipWhitespace()

            if index == key.endIndex {
                return segments
            }

            guard key[index] == "." else { return nil }
            index = key.index(after: index)
        }
    }

    private static func codexTomlParseKeySegment(_ key: String, index: inout String.Index) -> Bool {
        if key[index] == "\"" {
            index = key.index(after: index)
            var escaped = false

            while index < key.endIndex {
                let character = key[index]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    index = key.index(after: index)
                    return true
                }
                index = key.index(after: index)
            }

            return false
        }

        if key[index] == "'" {
            index = key.index(after: index)

            while index < key.endIndex {
                if key[index] == "'" {
                    index = key.index(after: index)
                    return true
                }
                index = key.index(after: index)
            }

            return false
        }

        let start = index
        while index < key.endIndex {
            let character = key[index]
            if character == "." || character.isWhitespace {
                break
            }
            guard codexTomlBareKeyCharacterIsValid(character) else { return false }
            index = key.index(after: index)
        }

        return index > start
    }

    private static func codexTomlBareKeyCharacterIsValid(_ character: Character) -> Bool {
        if character == "_" || character == "-" {
            return true
        }
        return character.unicodeScalars.allSatisfy { scalar in
            (65...90).contains(scalar.value)
                || (97...122).contains(scalar.value)
                || (48...57).contains(scalar.value)
        }
    }

    static func codexConfigHasValidTableHeaders(_ contents: String) -> Bool {
        codexTomlIsSafeToEdit(contents)
    }

    private static func codexTomlIsSafeToEdit(_ contents: String) -> Bool {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }

        let lines = normalized.components(separatedBy: "\n")
        var currentTableSegments: [String] = []
        var currentTableKey = ""
        var currentTableIsArray = false
        var arrayTableCount = 0
        var seenNormalTables = Set<String>()
        var seenArrayTables = Set<String>()
        var globalAssignedPaths = Set<String>()
        var tableAssignedPaths: [String: Set<String>] = ["": []]

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else {
                index += 1
                continue
            }

            let withoutComment = codexTomlLineWithoutTrailingComment(trimmed)
                .trimmingCharacters(in: .whitespaces)
            if withoutComment.hasPrefix("[") {
                guard isCodexTomlSectionHeader(withoutComment),
                      let headerSegments = codexTomlTableHeaderSegments(withoutComment) else {
                    return false
                }
                let tablePath = codexTomlPathKey(headerSegments)
                let declaredTables = seenNormalTables.union(seenArrayTables)
                guard codexTomlCanDeclareTable(
                    headerSegments,
                    assignedPaths: globalAssignedPaths,
                    declaredTables: declaredTables
                ) else {
                    return false
                }

                if withoutComment.hasPrefix("[[") {
                    guard !seenNormalTables.contains(tablePath) else { return false }
                    seenArrayTables.insert(tablePath)
                    arrayTableCount += 1
                    currentTableKey = "\(tablePath)#\(arrayTableCount)"
                    currentTableIsArray = true
                } else {
                    guard !seenNormalTables.contains(tablePath),
                          !seenArrayTables.contains(tablePath) else {
                        return false
                    }
                    seenNormalTables.insert(tablePath)
                    currentTableKey = tablePath
                    currentTableIsArray = false
                }
                currentTableSegments = headerSegments
                tableAssignedPaths[currentTableKey] = []
                index += 1
                continue
            }

            guard let equals = withoutComment.firstIndex(of: "=") else { return false }
            let keyText = String(withoutComment[..<equals]).trimmingCharacters(in: .whitespaces)
            let valueStart = withoutComment.index(after: equals)
            var valueLines = [String(withoutComment[valueStart...])]
            while !codexTomlValueIsComplete(valueLines.joined(separator: "\n")) {
                index += 1
                guard index < lines.count else { return false }
                valueLines.append(lines[index])
            }

            guard let keySegments = codexTomlDottedKeySegments(keyText) else { return false }
            let localPath = codexTomlPathKey(keySegments)
            var localAssigned = tableAssignedPaths[currentTableKey] ?? []
            guard codexTomlRecordAssignedPath(localPath, in: &localAssigned) else { return false }
            tableAssignedPaths[currentTableKey] = localAssigned

            if !currentTableIsArray {
                let globalPath = codexTomlPathKey(currentTableSegments + keySegments)
                guard codexTomlRecordAssignedPath(globalPath, in: &globalAssignedPaths) else { return false }
            }

            guard codexTomlValueLooksSafe(valueLines.joined(separator: "\n")) else { return false }
            index += 1
        }

        return true
    }

    private static func codexTomlTableHeaderSegments(_ header: String) -> [String]? {
        let stripped = codexTomlLineWithoutTrailingComment(header)
            .trimmingCharacters(in: .whitespaces)
        if stripped.hasPrefix("[[") {
            guard stripped.hasSuffix("]]") else { return nil }
            return codexTomlDottedKeySegments(String(stripped.dropFirst(2).dropLast(2)))
        }
        guard stripped.hasPrefix("["), stripped.hasSuffix("]"), !stripped.hasPrefix("[[") else {
            return nil
        }
        return codexTomlDottedKeySegments(String(stripped.dropFirst().dropLast()))
    }

    private static func codexTomlPathKey(_ segments: [String]) -> String {
        segments.joined(separator: "\u{1F}")
    }

    private static func codexTomlRecordAssignedPath(_ path: String, in assignedPaths: inout Set<String>) -> Bool {
        if assignedPaths.contains(path) { return false }
        let prefix = path + "\u{1F}"
        if assignedPaths.contains(where: { $0.hasPrefix(prefix) }) { return false }

        var cursor = path
        while let separator = cursor.lastIndex(of: "\u{1F}") {
            cursor = String(cursor[..<separator])
            if assignedPaths.contains(cursor) { return false }
        }

        assignedPaths.insert(path)
        return true
    }

    private static func codexTomlCanDeclareTable(
        _ segments: [String],
        assignedPaths: Set<String>,
        declaredTables: Set<String>
    ) -> Bool {
        let tablePath = codexTomlPathKey(segments)
        if assignedPaths.contains(tablePath) { return false }
        let prefix = tablePath + "\u{1F}"
        for assignedPath in assignedPaths where assignedPath.hasPrefix(prefix) {
            let remainder = String(assignedPath.dropFirst(prefix.count))
            let remainderSegments = remainder.components(separatedBy: "\u{1F}")
            var coveredByDeclaredDescendant = false
            if remainderSegments.count > 1 {
                var descendantSegments = segments
                for segment in remainderSegments.dropLast() {
                    descendantSegments.append(segment)
                    if declaredTables.contains(codexTomlPathKey(descendantSegments)) {
                        coveredByDeclaredDescendant = true
                        break
                    }
                }
            }
            if !coveredByDeclaredDescendant {
                return false
            }
        }
        return true
    }

    private static func codexTomlValueLooksSafe(_ value: String) -> Bool {
        let stripped = codexTomlStripComments(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = stripped.first else { return false }
        if first == "[" {
            return codexTomlArrayLooksSafe(stripped)
        }
        if first == "{" {
            return codexTomlInlineTableLooksSafe(stripped)
        }
        return codexTomlScalarValueLooksSafe(stripped)
    }

    private static func codexTomlValueIsComplete(_ value: String) -> Bool {
        let state = codexTomlContainerState(codexTomlStripComments(value))
        return state.valid && state.stack.isEmpty
    }

    private static func codexTomlStripComments(_ text: String) -> String {
        var result = ""
        var inBasicString = false
        var inLiteralString = false
        var inMultilineBasicString = false
        var inMultilineLiteralString = false
        var escaped = false
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inMultilineBasicString {
                if text[index...].hasPrefix(#"""""#), !escaped {
                    result.append(#"""""#)
                    inMultilineBasicString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                }
                index = text.index(after: index)
                continue
            }
            if inMultilineLiteralString {
                if text[index...].hasPrefix("'''") {
                    result.append("'''")
                    inMultilineLiteralString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                result.append(character)
                index = text.index(after: index)
                continue
            }
            if inBasicString {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
                index = text.index(after: index)
                continue
            }
            if inLiteralString {
                result.append(character)
                if character == "'" {
                    inLiteralString = false
                }
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix(#"""""#) {
                result.append(#"""""#)
                inMultilineBasicString = true
                index = text.index(index, offsetBy: 3)
                continue
            }
            if text[index...].hasPrefix("'''") {
                result.append("'''")
                inMultilineLiteralString = true
                index = text.index(index, offsetBy: 3)
                continue
            }
            if character == "\"" {
                inBasicString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "'" {
                inLiteralString = true
                result.append(character)
                index = text.index(after: index)
                continue
            }
            if character == "#" {
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                continue
            }
            result.append(character)
            index = text.index(after: index)
        }

        return result
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func codexTomlContainerState(_ text: String) -> (valid: Bool, stack: [Character]) {
        var inBasicString = false
        var inLiteralString = false
        var inMultilineBasicString = false
        var inMultilineLiteralString = false
        var escaped = false
        var stack: [Character] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inMultilineBasicString {
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }
                if character == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }
                if text[index...].hasPrefix(#"""""#) {
                    inMultilineBasicString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inMultilineLiteralString {
                if text[index...].hasPrefix("'''") {
                    inMultilineLiteralString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inBasicString {
                if character == "\n" { return (false, stack) }
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
            } else if inLiteralString {
                if character == "'" {
                    inLiteralString = false
                }
            } else if text[index...].hasPrefix(#"""""#) {
                inMultilineBasicString = true
                index = text.index(index, offsetBy: 3)
                continue
            } else if text[index...].hasPrefix("'''") {
                inMultilineLiteralString = true
                index = text.index(index, offsetBy: 3)
                continue
            } else if character == "\"" {
                inBasicString = true
            } else if character == "'" {
                inLiteralString = true
            } else if character == "[" || character == "{" {
                stack.append(character)
            } else if character == "]" {
                guard stack.last == "[" else { return (false, stack) }
                stack.removeLast()
            } else if character == "}" {
                guard stack.last == "{" else { return (false, stack) }
                stack.removeLast()
            }
            index = text.index(after: index)
        }

        if inBasicString || inLiteralString || inMultilineBasicString || inMultilineLiteralString || escaped {
            return (false, stack)
        }
        return (true, stack)
    }

    private static func codexTomlSplitTopLevel(_ text: String, separator: Character) -> [String]? {
        var parts: [String] = []
        var current = ""
        var inBasicString = false
        var inLiteralString = false
        var inMultilineBasicString = false
        var inMultilineLiteralString = false
        var escaped = false
        var stack: [Character] = []
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]
            if inMultilineBasicString {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if text[index...].hasPrefix(#"""""#) {
                    current.append("\"")
                    current.append("\"")
                    inMultilineBasicString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inMultilineLiteralString {
                current.append(character)
                if text[index...].hasPrefix("'''") {
                    current.append("'")
                    current.append("'")
                    inMultilineLiteralString = false
                    index = text.index(index, offsetBy: 3)
                    continue
                }
                index = text.index(after: index)
                continue
            }
            if inBasicString {
                current.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inBasicString = false
                }
                index = text.index(after: index)
                continue
            }
            if inLiteralString {
                current.append(character)
                if character == "'" {
                    inLiteralString = false
                }
                index = text.index(after: index)
                continue
            }
            if text[index...].hasPrefix(#"""""#) {
                inMultilineBasicString = true
                current.append(#"""""#)
                index = text.index(index, offsetBy: 3)
                continue
            }
            if text[index...].hasPrefix("'''") {
                inMultilineLiteralString = true
                current.append("'''")
                index = text.index(index, offsetBy: 3)
                continue
            }
            if character == "\"" {
                inBasicString = true
                current.append(character)
            } else if character == "'" {
                inLiteralString = true
                current.append(character)
            } else if character == "[" || character == "{" {
                stack.append(character)
                current.append(character)
            } else if character == "]" {
                guard stack.last == "[" else { return nil }
                stack.removeLast()
                current.append(character)
            } else if character == "}" {
                guard stack.last == "{" else { return nil }
                stack.removeLast()
                current.append(character)
            } else if character == separator, stack.isEmpty {
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }

        if inBasicString || inLiteralString || inMultilineBasicString || inMultilineLiteralString || escaped || !stack.isEmpty {
            return nil
        }
        parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return parts
    }

    private static func codexTomlScalarValueLooksSafe(_ value: String) -> Bool {
        if value == "true" || value == "false" { return true }
        if value.hasPrefix("\"") {
            return codexTomlBasicStringLooksSafe(value) && codexTomlValueIsComplete(value)
        }
        if value.hasPrefix("'") {
            return codexTomlLiteralStringLooksSafe(value) && codexTomlValueIsComplete(value)
        }
        return codexTomlIntLooksSafe(value)
            || codexTomlFloatLooksSafe(value)
            || codexTomlTemporalLooksSafe(value)
    }

    private static func codexTomlArrayLooksSafe(_ value: String) -> Bool {
        guard value.hasPrefix("["), value.hasSuffix("]"), codexTomlValueIsComplete(value) else {
            return false
        }
        let body = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return true }
        guard let parts = codexTomlSplitTopLevel(String(body), separator: ",") else { return false }
        for (index, part) in parts.enumerated() {
            if part.isEmpty {
                if index == parts.count - 1 { continue }
                return false
            }
            guard codexTomlValueLooksSafe(part) else { return false }
        }
        return true
    }

    private static func codexTomlInlineTableLooksSafe(_ value: String) -> Bool {
        guard value.hasPrefix("{"), value.hasSuffix("}"), codexTomlValueIsComplete(value) else {
            return false
        }
        let body = value.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return true }
        guard let parts = codexTomlSplitTopLevel(String(body), separator: ",") else { return false }

        var assigned = Set<String>()
        for part in parts {
            guard let keyValue = codexTomlSplitTopLevel(part, separator: "="),
                  keyValue.count == 2,
                  let keySegments = codexTomlDottedKeySegments(keyValue[0].trimmingCharacters(in: .whitespaces))
            else {
                return false
            }
            var localAssigned = assigned
            guard codexTomlRecordAssignedPath(codexTomlPathKey(keySegments), in: &localAssigned),
                  codexTomlValueLooksSafe(keyValue[1]) else {
                return false
            }
            assigned = localAssigned
        }
        return true
    }

    private static func codexTomlIntLooksSafe(_ value: String) -> Bool {
        let decimal = #"[+-]?(?:0|[1-9](?:_?[0-9])*)"#
        let hexadecimal = #"0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*"#
        let octal = #"0o[0-7](?:_?[0-7])*"#
        let binary = #"0b[01](?:_?[01])*"#
        return codexRegexMatches(value, #"^(?:\#(decimal)|\#(hexadecimal)|\#(octal)|\#(binary))$"#)
    }

    private static func codexTomlFloatLooksSafe(_ value: String) -> Bool {
        let digits = #"[0-9](?:_?[0-9])*"#
        let integerPart = #"(?:0|[1-9](?:_?[0-9])*)"#
        let decimalFloat = #"[+-]?(?:\#(integerPart)\.\#(digits)(?:[eE][+-]?\#(digits))?|\#(integerPart)[eE][+-]?\#(digits))"#
        let specialFloat = #"[+-]?(?:inf|nan)"#
        return codexRegexMatches(value, #"^(?:\#(decimalFloat)|\#(specialFloat))$"#)
    }

    private static func codexTomlTemporalLooksSafe(_ value: String) -> Bool {
        if codexRegexMatches(value, #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#) {
            return codexTomlDateLooksSafe(value)
        }
        if codexTomlTimeLooksSafe(value) {
            return true
        }
        guard let separator = value.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else {
            return false
        }
        let date = String(value[..<separator])
        var timeAndOffset = String(value[value.index(after: separator)...])
        var offset: String?
        if timeAndOffset.hasSuffix("Z") {
            timeAndOffset.removeLast()
            offset = "Z"
        } else if let offsetStart = timeAndOffset.firstIndex(where: { $0 == "+" || $0 == "-" }) {
            offset = String(timeAndOffset[offsetStart...])
            timeAndOffset = String(timeAndOffset[..<offsetStart])
        }

        return codexTomlDateLooksSafe(date)
            && codexTomlTimeLooksSafe(timeAndOffset)
            && codexTomlOffsetLooksSafe(offset)
    }

    private static func codexTomlDateLooksSafe(_ value: String) -> Bool {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == parts[0] && roundTrip.month == parts[1] && roundTrip.day == parts[2]
    }

    private static func codexTomlTimeLooksSafe(_ value: String) -> Bool {
        guard codexRegexMatches(value, #"^[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?$"#) else {
            return false
        }
        let main = value.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)[0]
        let parts = main.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        return (0...23).contains(parts[0])
            && (0...59).contains(parts[1])
            && (0...59).contains(parts[2])
    }

    private static func codexTomlOffsetLooksSafe(_ value: String?) -> Bool {
        guard let value else { return true }
        if value == "Z" { return true }
        guard codexRegexMatches(value, #"^[+-][0-9]{2}:[0-9]{2}$"#) else { return false }
        let parts = value.dropFirst().split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return false }
        return (0...23).contains(parts[0]) && (0...59).contains(parts[1])
    }

    private static func codexTomlBasicStringLooksSafe(_ value: String) -> Bool {
        if value.hasPrefix(#"""""#) {
            guard value.count >= 6, value.hasSuffix(#"""""#) else { return false }
            let body = String(value.dropFirst(3).dropLast(3))
            guard !body.contains(#"""""#) else { return false }
            return codexTomlBasicStringBodyLooksSafe(body, multiline: true)
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\""), !value.contains("\n") else {
            return false
        }
        return codexTomlBasicStringBodyLooksSafe(String(value.dropFirst().dropLast()), multiline: false)
    }

    private static func codexTomlBasicStringBodyLooksSafe(_ body: String, multiline: Bool) -> Bool {
        var index = body.startIndex
        while index < body.endIndex {
            let character = body[index]
            if character == "\\" {
                let escapedIndex = body.index(after: index)
                guard escapedIndex < body.endIndex else { return false }
                let escaped = body[escapedIndex]
                if ["b", "t", "n", "f", "r", "\"", "\\"].contains(escaped) {
                    index = body.index(after: escapedIndex)
                    continue
                }
                if escaped == "u" || escaped == "U" {
                    let count = escaped == "u" ? 4 : 8
                    guard let digits = codexTomlCharacters(body, after: escapedIndex, count: count),
                          digits.allSatisfy(\.isHexDigit),
                          codexTomlUnicodeEscapeLooksSafe(digits) else {
                        return false
                    }
                    index = body.index(escapedIndex, offsetBy: count + 1)
                    continue
                }
                if multiline,
                   let continuationEnd = codexTomlMultilineBasicLineContinuationEnd(body, from: escapedIndex) {
                    index = continuationEnd
                    continue
                }
                return false
            }
            if !multiline, character == "\"" {
                return false
            }
            if codexTomlUnicodeScalarValue(character) < 0x20,
               !(multiline && (character == "\n" || character == "\t")) {
                return false
            }
            index = body.index(after: index)
        }
        return true
    }

    private static func codexTomlMultilineBasicLineContinuationEnd(_ text: String, from index: String.Index) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        if cursor < text.endIndex, text[cursor] == "\r" {
            let next = text.index(after: cursor)
            guard next < text.endIndex, text[next] == "\n" else { return nil }
            cursor = text.index(after: next)
        } else if cursor < text.endIndex, text[cursor] == "\n" {
            cursor = text.index(after: cursor)
        } else {
            return nil
        }
        while cursor < text.endIndex {
            if text[cursor] == " " || text[cursor] == "\t" || text[cursor] == "\n" {
                cursor = text.index(after: cursor)
                continue
            }
            if text[cursor] == "\r" {
                let next = text.index(after: cursor)
                guard next < text.endIndex, text[next] == "\n" else { return nil }
                cursor = text.index(after: next)
                continue
            }
            break
        }
        return cursor
    }

    private static func codexTomlLiteralStringLooksSafe(_ value: String) -> Bool {
        if value.hasPrefix("'''") {
            guard value.count >= 6, value.hasSuffix("'''") else { return false }
            return !String(value.dropFirst(3).dropLast(3)).contains("'''")
        }
        return value.count >= 2
            && value.hasPrefix("'")
            && value.hasSuffix("'")
            && !String(value.dropFirst().dropLast()).contains("'")
            && !value.contains("\n")
    }

    private static func codexTomlUnicodeEscapeLooksSafe(_ digits: String) -> Bool {
        guard let value = UInt32(digits, radix: 16) else { return false }
        return value <= 0x10FFFF && !(0xD800...0xDFFF).contains(value)
    }

    private static func codexTomlCharacters(_ text: String, after index: String.Index, count: Int) -> String? {
        var cursor = text.index(after: index)
        var result = ""
        for _ in 0..<count {
            guard cursor < text.endIndex else { return nil }
            result.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return result
    }

    private static func codexTomlUnicodeScalarValue(_ character: Character) -> UInt32 {
        character.unicodeScalars.first?.value ?? 0
    }

    private static func codexRegexMatches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func codexTomlMayContainHooksTable(_ contents: String) -> Bool {
        return contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .contains { line in
                let header = codexTomlLineWithoutTrailingComment(line.trimmingCharacters(in: .whitespaces))
                    .trimmingCharacters(in: .whitespaces)
                return codexTomlHeaderIsHooks(header)
            }
    }

    private struct CodexTomlHooksRemovalResult {
        let text: String
        let removed: Bool
    }

    private static func removeBoughOwnedCodexHooksBlocks(from contents: String) -> CodexTomlHooksRemovalResult {
        var lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        let hadTrailingNewline = contents.hasSuffix("\n")
        let headers = codexTomlSectionHeaders(in: lines)

        var rangesToRemove: [Range<Int>] = []
        for (position, header) in headers.enumerated() where codexTomlHeaderIsHooks(header.text) {
            let end = position + 1 < headers.count ? headers[position + 1].line : lines.count
            let bodyStart = header.line + 1
            let bodyLines = bodyStart < end ? Array(lines[bodyStart..<end]) : []
            if codexTomlBlockHasBoughBridgeCommand(bodyLines) {
                rangesToRemove.append(header.line..<end)
            }
        }

        guard !rangesToRemove.isEmpty else {
            return CodexTomlHooksRemovalResult(text: contents, removed: false)
        }

        for range in rangesToRemove.reversed() {
            lines.removeSubrange(range)
            let insertionPoint = range.lowerBound
            if insertionPoint < lines.count,
               insertionPoint > 0,
               lines[insertionPoint].trimmingCharacters(in: .whitespaces).isEmpty,
               lines[insertionPoint - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                lines.remove(at: insertionPoint)
            }
        }

        var text = lines.joined(separator: "\n")
        if hadTrailingNewline, !text.hasSuffix("\n") {
            text.append("\n")
        }
        return CodexTomlHooksRemovalResult(text: text, removed: true)
    }

    private struct CodexTomlSectionHeader {
        let line: Int
        let text: String
    }

    private static func codexTomlSectionHeaders(in lines: [String]) -> [CodexTomlSectionHeader] {
        var headers: [CodexTomlSectionHeader] = []
        var inBasicMultilineString = false
        var inLiteralMultilineString = false

        for (index, line) in lines.enumerated() {
            if !inBasicMultilineString, !inLiteralMultilineString {
                let header = codexTomlLineWithoutTrailingComment(line.trimmingCharacters(in: .whitespaces))
                    .trimmingCharacters(in: .whitespaces)
                if isCodexTomlSectionHeader(header) {
                    headers.append(CodexTomlSectionHeader(line: index, text: header))
                }
            }

            let textForDelimiterScan = (inBasicMultilineString || inLiteralMultilineString)
                ? line
                : codexTomlLineWithoutTrailingComment(line)
            if codexTomlDelimiterOccurrenceCount(in: textForDelimiterScan, delimiter: #"""""#).isMultiple(of: 2) == false {
                inBasicMultilineString.toggle()
            }
            if codexTomlDelimiterOccurrenceCount(in: textForDelimiterScan, delimiter: #"'''"#).isMultiple(of: 2) == false {
                inLiteralMultilineString.toggle()
            }
        }

        return headers
    }

    private static func codexTomlHeaderIsHooks(_ header: String) -> Bool {
        let hooksHeader = "[" + "hooks]"
        let hooksPrefix = "[" + "hooks."
        let hooksArrayHeader = "[[" + "hooks]]"
        return header == hooksHeader || header.hasPrefix(hooksPrefix) || header == hooksArrayHeader
    }

    private static func codexTomlBlockHasBoughBridgeCommand(_ lines: [String]) -> Bool {
        lines.contains { line in
            let stripped = codexTomlLineWithoutTrailingComment(line)
                .trimmingCharacters(in: .whitespaces)
            return codexStringAssignmentValue(stripped, key: "command")?.contains("bough-bridge") == true
        }
    }

    private static func codexStringAssignmentValue(_ line: String, key: String) -> String? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let name = line[..<equals].trimmingCharacters(in: .whitespaces)
        guard name == key else { return nil }

        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix(#"""""#) {
            let remainder = value.dropFirst(3)
            guard let end = remainder.range(of: #"""""#)?.lowerBound else { return nil }
            return String(remainder[..<end])
        }
        if value.hasPrefix("\"") {
            return codexBasicStringValue(value)
        }
        if value.hasPrefix("'''") {
            let remainder = value.dropFirst(3)
            guard let end = remainder.range(of: "'''")?.lowerBound else { return nil }
            return String(remainder[..<end])
        }
        if value.hasPrefix("'") {
            let remainder = value.dropFirst()
            guard let end = remainder.firstIndex(of: "'") else { return nil }
            return String(remainder[..<end])
        }
        return nil
    }

    private static func codexBasicStringValue(_ value: String) -> String? {
        var escaped = false
        var index = value.index(after: value.startIndex)
        let start = index
        while index < value.endIndex {
            let character = value[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return String(value[start..<index])
            }
            index = value.index(after: index)
        }
        return nil
    }

    private static func codexTomlDelimiterOccurrenceCount(in contents: String, delimiter: String) -> Int {
        contents.components(separatedBy: delimiter).count - 1
    }

    static func codexBoolAssignmentValue(_ line: String, key: String) -> String? {
        let pattern = #"^\#(key)\s*=\s*(true|false)\s*(#.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange),
              let valueRange = Range(match.range(at: 1), in: line)
        else {
            return nil
        }
        return String(line[valueRange])
    }

    static func codexHooksFeatureDisabled(fm: FileManager) -> Bool {
        let configPath = codexHome() + "/config.toml"
        if let hooksValue = codexBoolFeatureValue(fm: fm, configPath: configPath, key: "hooks") {
            return hooksValue == "false"
        }
        return codexBoolFeatureValue(fm: fm, configPath: configPath, key: "codex_hooks") == "false"
    }

    static func codexAutoReviewEnabled(fm: FileManager) -> Bool {
        let configPath = codexHome() + "/config.toml"
        guard fm.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8)
        else { return false }

        return codexAutoReviewEnabled(in: contents)
    }

    static func codexAutoReviewEnabled(in contents: String) -> Bool {
        guard codexConfigHasValidTableHeaders(contents) else { return false }

        var approvalsReviewer: String?
        var approvalPolicy: String?
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let stripped = codexTomlLineWithoutTrailingComment(trimmed)
                .trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            if isCodexTomlSectionHeader(stripped) {
                break
            }

            if let value = codexStringAssignmentValue(stripped, key: "approvals_reviewer") {
                approvalsReviewer = value
                continue
            }
            if let value = codexStringAssignmentValue(stripped, key: "approval_policy") {
                approvalPolicy = value
                continue
            }
        }

        return approvalsReviewer == "auto_review" && approvalPolicy != "never"
    }

    static func codexDeprecatedHooksKeyPresent(fm: FileManager) -> Bool {
        codexDeprecatedHooksKeyPresent(fm: fm, configPath: codexHome() + "/config.toml")
    }

    static func codexDeprecatedHooksKeyPresent(fm: FileManager, configPath: String) -> Bool {
        codexBoolFeatureValue(fm: fm, configPath: configPath, key: "codex_hooks") != nil
    }

    private static func codexBoolFeatureValue(fm: FileManager, configPath: String, key: String) -> String? {
        guard fm.fileExists(atPath: configPath),
              let contents = try? String(contentsOfFile: configPath, encoding: .utf8)
        else { return nil }

        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let featureStart = lines.firstIndex(where: isCodexTomlFeaturesHeader) else { return nil }

        let featureEnd = codexTomlFeatureEndIndex(from: featureStart, lines: lines)

        for line in lines[(featureStart + 1)..<featureEnd] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#") else { continue }
            if let value = codexBoolAssignmentValue(trimmed, key: key) {
                return value
            }
        }
        return nil
    }

    struct CodexAppServerProcessStart: Equatable {
        let pid: Int32
        let startDate: Date
    }

    struct CodexAppServerRestartStatus: Equatable {
        let configModificationDate: Date?
        let runningPIDs: [Int32]
        let stalePIDs: [Int32]

        var needsRestart: Bool {
            configModificationDate != nil && !stalePIDs.isEmpty
        }
    }

    static func codexAppServerRestartStatus(
        fm: FileManager = .default,
        processStarts: [CodexAppServerProcessStart] = runningCodexAppServerProcessStarts()
    ) -> CodexAppServerRestartStatus {
        codexAppServerRestartStatus(
            configPath: codexHome() + "/config.toml",
            fm: fm,
            processStarts: processStarts
        )
    }

    static func codexAppServerRestartStatus(
        configPath: String,
        fm: FileManager = .default,
        processStarts: [CodexAppServerProcessStart] = runningCodexAppServerProcessStarts()
    ) -> CodexAppServerRestartStatus {
        let configModificationDate = (try? fm.attributesOfItem(atPath: configPath)[.modificationDate]) as? Date
        return codexAppServerRestartStatus(
            configModificationDate: configModificationDate,
            processStarts: processStarts
        )
    }

    static func codexAppServerRestartStatus(
        configModificationDate: Date?,
        processStarts: [CodexAppServerProcessStart]
    ) -> CodexAppServerRestartStatus {
        let runningPIDs = processStarts.map(\.pid)
        guard let configModificationDate else {
            return CodexAppServerRestartStatus(
                configModificationDate: nil,
                runningPIDs: runningPIDs,
                stalePIDs: []
            )
        }
        let stalePIDs = processStarts
            .filter { $0.startDate < configModificationDate }
            .map(\.pid)
        return CodexAppServerRestartStatus(
            configModificationDate: configModificationDate,
            runningPIDs: runningPIDs,
            stalePIDs: stalePIDs
        )
    }

    private static func logCodexAppServerRestartIfNeeded(fm: FileManager) {
        let status = codexAppServerRestartStatus(fm: fm)
        guard status.needsRestart else { return }
        let pids = status.stalePIDs.map(String.init).joined(separator: ",")
        codexTomlLog.warning(
            "Migrated deprecated Codex codex_hooks flag while older codex app-server PID(s) \(pids, privacy: .public) are running; restart Codex Desktop if the deprecated-hooks warning persists."
        )
    }

    private static func runningCodexAppServerProcessStarts() -> [CodexAppServerProcessStart] {
        guard let data = ProcessRunner.run(
            path: "/usr/bin/pgrep",
            args: ["-f", "codex app-server"],
            timeout: 2
        ),
              let output = String(data: data, encoding: .utf8)
        else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .compactMap { pid -> CodexAppServerProcessStart? in
                guard let startDate = codexProcessStartDate(pid: pid) else { return nil }
                return CodexAppServerProcessStart(pid: pid, startDate: startDate)
            }
    }

    private static func codexProcessStartDate(pid: Int32) -> Date? {
        guard let data = ProcessRunner.run(
            path: "/bin/ps",
            args: ["-o", "lstart=", "-p", String(pid)],
            timeout: 2
        ),
              let output = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        let normalized = output
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0.isNewline })
            .joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}
