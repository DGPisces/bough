import XCTest
@testable import Bough

final class JSONMinimalEditorTests: XCTestCase {

    // MARK: - setTopLevelValue: replace existing key preserves unrelated bytes

    func testReplacePreservesUnrelatedKeysOrderAndSlashesAndComments() throws {
        let original = """
        {
          "env": {
            "ANTHROPIC_API_KEY": "sk-xxx",
            "MAX_MCP_OUTPUT_TOKENS": "200000"
          },
          "hooks": {
            "PreToolUse": []
          },
          "autoMemoryEnabled": false
        }
        """
        let newHooks: [String: Any] = [
            "PreToolUse": [
                ["matcher": "", "hooks": [["type": "command", "command": "~/.bough/bough-hook.sh", "timeout": 5]]]
            ]
        ]
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: original, key: "hooks", value: newHooks))

        // User keys preserved verbatim (API key intact, slashes un-escaped, order unchanged).
        XCTAssertTrue(result.contains("\"ANTHROPIC_API_KEY\": \"sk-xxx\""),
                      "ANTHROPIC_API_KEY must survive untouched")
        XCTAssertTrue(result.contains("\"MAX_MCP_OUTPUT_TOKENS\": \"200000\""))
        XCTAssertTrue(result.contains("\"autoMemoryEnabled\": false"))
        XCTAssertFalse(result.contains("\\/"), "Paths must not be escaped with \\/")

        // "env" stays before "hooks", "hooks" stays before "autoMemoryEnabled".
        let envIdx = try XCTUnwrap(result.range(of: "\"env\""))
        let hooksIdx = try XCTUnwrap(result.range(of: "\"hooks\""))
        let autoIdx = try XCTUnwrap(result.range(of: "\"autoMemoryEnabled\""))
        XCTAssertTrue(envIdx.lowerBound < hooksIdx.lowerBound)
        XCTAssertTrue(hooksIdx.lowerBound < autoIdx.lowerBound)

        // New hooks payload is present.
        XCTAssertTrue(result.contains("~/.bough/bough-hook.sh"))

        // Result is still valid JSON.
        let parsed = try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any]
        XCTAssertNotNil(parsed)
    }

    func testReplacePreservesJSONCCommentsOutsideTargetKey() throws {
        let original = """
        {
          // User-authored settings below
          "model": "sonnet",
          "hooks": {},
          /* auto-generated */
          "autoshare": false
        }
        """
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: original, key: "hooks", value: ["X": "Y"] as [String: Any]))
        XCTAssertTrue(result.contains("// User-authored settings below"))
        XCTAssertTrue(result.contains("/* auto-generated */"))
        XCTAssertTrue(result.contains("\"model\": \"sonnet\""))
    }

    func testReplacePreservesTrailingNewline() throws {
        let originalWithNL = "{\n  \"hooks\": {}\n}\n"
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: originalWithNL, key: "hooks", value: ["A": 1] as [String: Any]))
        XCTAssertTrue(result.hasSuffix("\n"), "Trailing newline must be preserved")

        let originalNoNL = "{\n  \"hooks\": {}\n}"
        let resultNoNL = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: originalNoNL, key: "hooks", value: ["A": 1] as [String: Any]))
        XCTAssertFalse(resultNoNL.hasSuffix("\n"), "No-trailing-newline style must also be preserved")
    }

    // MARK: - setTopLevelValue: insert new key

    func testInsertAppendsNewKeyAtEndWithMatchingIndent() throws {
        let original = """
        {
          "model": "sonnet"
        }
        """
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: original, key: "hooks", value: ["A": 1] as [String: Any]))
        XCTAssertTrue(result.contains("\"model\": \"sonnet\""))
        XCTAssertTrue(result.contains("\"hooks\""))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual((parsed["hooks"] as? [String: Int])?["A"], 1)
        XCTAssertEqual(parsed["model"] as? String, "sonnet")
    }

    func testInsertIntoEmptyObject() throws {
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: "{}", key: "hooks", value: ["A": 1] as [String: Any]))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["hooks"])
    }

    // MARK: - setTopLevelValue: refusal on invalid input

    func testReturnsNilWhenTopLevelIsArray() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(in: "[1, 2, 3]", key: "hooks", value: [:] as [String: Any]))
    }

    func testReturnsNilOnMalformedJSON() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(in: "{ \"hooks\": [", key: "hooks", value: [:] as [String: Any]))
    }

    func testReturnsNilOnTruncatedObject() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(in: "{ \"a\": 1,", key: "hooks", value: [:] as [String: Any]))
    }

    func testReturnsNilOnTrailingGarbageAfterObject() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":"x"} trailing-garbage"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
        XCTAssertNil(JSONMinimalEditor.deleteTopLevelKey(
            in: #"{"model":"x"} trailing-garbage"#,
            key: "model"
        ))
    }

    func testAllowsTrailingJSONCCommentsAfterObject() throws {
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(
            in: "{\n  \"model\": \"x\"\n}\n// comment\n",
            key: "hooks",
            value: ["A": 1] as [String: Any]
        ))
        XCTAssertTrue(result.contains("// comment"))
    }

    func testReturnsNilOnInvalidStringEscape() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":"bad\qescape"}"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
    }

    func testReturnsNilOnMalformedNestedObject() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":{"name" "missing-colon"}}"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
    }

    func testReturnsNilOnInvalidNumbers() {
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":01}"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
        XCTAssertNil(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":1e}"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
    }

    func testAcceptsValidSurrogatePairStringEscape() throws {
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(
            in: #"{"model":"\uD834\uDD1E"}"#,
            key: "hooks",
            value: [:] as [String: Any]
        ))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertNotNil(parsed["hooks"])
    }

    // MARK: - deleteTopLevelKey

    func testDeleteRemovesKeyAndItsTrailingComma() throws {
        let original = """
        {
          "a": 1,
          "hooks": {},
          "b": 2
        }
        """
        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "hooks"))
        XCTAssertFalse(result.contains("hooks"))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["a"] as? Int, 1)
        XCTAssertEqual(parsed["b"] as? Int, 2)
    }

    func testDeleteLastKeyRemovesPrecedingComma() throws {
        let original = """
        {
          "a": 1,
          "hooks": {}
        }
        """
        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "hooks"))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["a"] as? Int, 1)
        XCTAssertNil(parsed["hooks"])
    }

    func testDeleteLastKeyRemovesCommaBeforeLineComment() throws {
        let original = """
        {
          "theme": "dark", // user comment
          "plugin": ["file:///Users/test/.config/opencode/plugins/bough-opencode.js"]
        }
        """

        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "plugin"))
        let stripped = ConfigInstaller.stripJSONComments(result)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any])

        XCTAssertFalse(result.contains("\"plugin\""))
        XCTAssertFalse(stripped.contains(",\n}"))
        XCTAssertEqual(parsed["theme"] as? String, "dark")
    }

    func testDeleteLastKeyRemovesCommaAfterBlockComment() throws {
        let original = """
        {
          "theme": "dark" /* user comment */,
          "plugin": ["file:///Users/test/.config/opencode/plugins/bough-opencode.js"]
        }
        """

        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "plugin"))
        let stripped = ConfigInstaller.stripJSONComments(result)
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any])

        XCTAssertFalse(result.contains("\"plugin\""))
        XCTAssertFalse(stripped.contains(",\n}"))
        XCTAssertEqual(parsed["theme"] as? String, "dark")
    }

    func testDeleteOnlyKeyYieldsEmptyObject() throws {
        let original = "{\n  \"hooks\": {}\n}"
        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "hooks"))
        let parsed = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(parsed.count, 0)
    }

    func testDeleteMissingKeyReturnsSourceUnchanged() throws {
        let original = "{\n  \"a\": 1\n}"
        let result = try XCTUnwrap(JSONMinimalEditor.deleteTopLevelKey(in: original, key: "hooks"))
        XCTAssertEqual(result, original)
    }

    // MARK: - Idempotency

    func testSetSameValueTwiceIsStable() throws {
        let original = """
        {
          "model": "sonnet",
          "hooks": { "A": 1 }
        }
        """
        let first = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: original, key: "hooks", value: ["A": 1] as [String: Any]))
        let second = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: first, key: "hooks", value: ["A": 1] as [String: Any]))
        XCTAssertEqual(first, second, "Writing the same value twice must converge")
    }

    // MARK: - Array values (plugin: [...])

    func testReplaceStringArrayPreservesSurroundingKeys() throws {
        let original = """
        {
          "model": "sonnet",
          "plugin": ["file:///old/bough-opencode.js"],
          "autoshare": false
        }
        """
        let result = try XCTUnwrap(JSONMinimalEditor.setTopLevelValue(in: original, key: "plugin", value: ["file:///new/bough-opencode.js"]))
        XCTAssertTrue(result.contains("\"model\": \"sonnet\""))
        XCTAssertTrue(result.contains("\"autoshare\": false"))
        XCTAssertTrue(result.contains("file:///new/bough-opencode.js"))
        XCTAssertFalse(result.contains("file:///old/bough-opencode.js"))
        XCTAssertFalse(result.contains("\\/"))
    }
}
