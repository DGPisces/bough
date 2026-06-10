import Foundation

struct RemoteInstallResult: Sendable {
    let ok: Bool
    let message: String
}

private struct RemoteCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var ok: Bool { exitCode == 0 }
}

enum RemoteInstaller {
    private static let remoteHookVersion = "1.0.0"

    static func installAll(host: RemoteHost) async -> RemoteInstallResult {
        guard let source = remoteHookSource() else {
            return RemoteInstallResult(ok: false, message: "Missing remote hook resource")
        }

        let upload = await uploadRemoteHook(source: source, host: host)
        guard upload.ok else {
            return RemoteInstallResult(ok: false, message: "Upload failed: \(upload.stderrSummary)")
        }

        let configure = await configureRemoteHooks(host: host)
        guard configure.ok else {
            return RemoteInstallResult(ok: false, message: "Install failed: \(configure.stderrSummary)")
        }

        let summary = configure.stdoutSummary.isEmpty ? "Claude/Codex/CodeBuddy/Traecli remote hooks installed" : configure.stdoutSummary
        return RemoteInstallResult(ok: true, message: summary)
    }

    static func cleanupRemoteSocket(host: RemoteHost) async {
        let dir = shellSingleQuoted(host.remoteSocketDirectory)
        let socket = shellSingleQuoted(host.remoteSocketPath)
        _ = await runSSH(host: host, command: "mkdir -p \(dir) && chmod 700 \(dir) && rm -f \(socket)", timeout: 8)
    }

    private static func remoteHookSource() -> String? {
        if let url = Bundle.appModule.url(forResource: "bough-remote-hook", withExtension: "py", subdirectory: "Resources"),
           let src = try? String(contentsOf: url) {
            return src
        }
        if let url = Bundle.appModule.url(forResource: "bough-remote-hook", withExtension: "py"),
           let src = try? String(contentsOf: url) {
            return src
        }
        return nil
    }

    private static func uploadRemoteHook(source: String, host: RemoteHost) async -> RemoteCommandResult {
        let encoded = Data(source.utf8).base64EncodedString()
        let py = """
	import base64, os, pathlib

	target = pathlib.Path.home() / ".bough" / "bough-remote-hook.py"
	target.parent.mkdir(parents=True, exist_ok=True)
	os.chmod(target.parent, 0o700)
	tmp = target.with_name(target.name + f".tmp.{os.getpid()}")
	tmp.write_bytes(base64.b64decode('''\(encoded)'''))
	os.chmod(tmp, 0o700)
	os.replace(tmp, target)
	os.chmod(target, 0o700)
	print(target)
	"""
        return await runSSH(host: host, command: "python3 - <<'PY'\n\(py)\nPY", timeout: 25)
    }

    private static func configureRemoteHooks(host: RemoteHost) async -> RemoteCommandResult {
        let py = configureRemoteHooksScript(host: host)
        // Run via the remote user's login shell so ~/.zprofile / ~/.bash_profile etc. are
        // sourced — that's how $CODEX_HOME (and similar) reach a non-interactive ssh session.
        // base64 keeps the script intact regardless of shell quoting.
        let encoded = Data(py.utf8).base64EncodedString()
        let inner = "(printf '%s' '\(encoded)' | base64 -D 2>/dev/null || printf '%s' '\(encoded)' | base64 -d 2>/dev/null) | python3"
        let command = "\"${SHELL:-/bin/bash}\" -lc \"\(inner)\""
        return await runSSH(host: host, command: command, timeout: 30)
    }

    static func configureRemoteHooksScript(host: RemoteHost) -> String {
        let hostId = pythonStringLiteral(host.id)
        let hostName = pythonStringLiteral(host.name)
        let version = pythonStringLiteral(remoteHookVersion)
        return """
import json
import pathlib
import shutil
import os
import shlex
import re
import subprocess
import datetime
try:
    import tomllib
except Exception:
    tomllib = None

home = pathlib.Path.home()
hook_path = home / ".bough" / "bough-remote-hook.py"
host_id = \(hostId)
host_name = \(hostName)
socket_path = \(pythonStringLiteral(host.remoteSocketPath))
version = \(version)

def _codex_home():
    raw = (os.environ.get("CODEX_HOME") or "").strip()
    if not raw:
        return home / ".codex"
    expanded = os.path.expanduser(raw)
    return pathlib.Path(expanded)

class ConfigParseError(Exception):
    pass

def strip_json_comments(text):
    result = []
    i = 0
    in_string = False
    escaped = False
    while i < len(text):
        ch = text[i]
        if in_string:
            result.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\\\":
                escaped = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            result.append(ch)
            i += 1
            continue
        if ch == "/" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "/":
                i += 2
                while i < len(text) and text[i] != "\\n":
                    i += 1
                continue
            if nxt == "*":
                i += 2
                while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i = min(i + 2, len(text))
                continue
        result.append(ch)
        i += 1
    return "".join(result)

def ensure_json(path):
    if path.exists():
        try:
            return json.loads(strip_json_comments(path.read_text(encoding="utf-8")))
        except Exception as exc:
            raise ConfigParseError(f"{path} is not valid JSON/JSONC: {exc}") from exc
    return {}

def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\\n")

def write_text_atomic(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(path)

def _skip_json_ws_comments(text, i):
    while i < len(text):
        ch = text[i]
        if ch in " \\t\\r\\n":
            i += 1
            continue
        if ch == "/" and i + 1 < len(text):
            nxt = text[i + 1]
            if nxt == "/":
                i += 2
                while i < len(text) and text[i] != "\\n":
                    i += 1
                continue
            if nxt == "*":
                i += 2
                while i + 1 < len(text) and not (text[i] == "*" and text[i + 1] == "/"):
                    i += 1
                i = min(i + 2, len(text))
                continue
        break
    return i

def _read_json_string_token(text, i):
    if i >= len(text) or text[i] != '"':
        return None
    start = i
    i += 1
    escaped = False
    while i < len(text):
        ch = text[i]
        if escaped:
            escaped = False
        elif ch == "\\\\":
            escaped = True
        elif ch == '"':
            return text[start:i + 1], i + 1
        elif ch in "\\r\\n":
            return None
        i += 1
    return None

def _skip_json_value(text, i):
    i = _skip_json_ws_comments(text, i)
    if i >= len(text):
        return None
    if text[i] == '"':
        read = _read_json_string_token(text, i)
        return read[1] if read else None
    if text[i] in "{[":
        stack = ["}" if text[i] == "{" else "]"]
        i += 1
        while i < len(text) and stack:
            i = _skip_json_ws_comments(text, i)
            if i >= len(text):
                return None
            ch = text[i]
            if ch == '"':
                read = _read_json_string_token(text, i)
                if not read:
                    return None
                i = read[1]
                continue
            if ch in "{[":
                stack.append("}" if ch == "{" else "]")
                i += 1
                continue
            if ch == stack[-1]:
                stack.pop()
                i += 1
                continue
            i += 1
        return i if not stack else None
    while i < len(text) and text[i] not in ",}]":
        i += 1
    return i

def _line_prefix_before(text, index):
    start = text.rfind("\\n", 0, index) + 1
    prefix = text[start:index]
    return prefix if all(ch in " \\t" for ch in prefix) else ""

def _find_top_level_json_key(text, key):
    i = _skip_json_ws_comments(text, 0)
    if i >= len(text) or text[i] != "{":
        return None
    content_start = i + 1
    i += 1
    first_key_indent = None
    entry_count = 0
    while True:
        i = _skip_json_ws_comments(text, i)
        if i >= len(text):
            return None
        if text[i] == "}":
            return {
                "kind": "insert",
                "content_start": content_start,
                "close": i,
                "entry_count": entry_count,
                "indent": first_key_indent or (_line_prefix_before(text, i) + "  "),
                "closing_indent": _line_prefix_before(text, i),
            }
        if text[i] != '"':
            return None
        key_start = i
        read = _read_json_string_token(text, i)
        if not read:
            return None
        token, i = read
        try:
            parsed_key = json.loads(token)
        except Exception:
            return None
        if first_key_indent is None:
            first_key_indent = _line_prefix_before(text, key_start)
        i = _skip_json_ws_comments(text, i)
        if i >= len(text) or text[i] != ":":
            return None
        i += 1
        value_start = _skip_json_ws_comments(text, i)
        value_end = _skip_json_value(text, value_start)
        if value_end is None:
            return None
        entry_count += 1
        if parsed_key == key:
            return {
                "kind": "replace",
                "start": value_start,
                "end": value_end,
                "indent": first_key_indent or "  ",
            }
        i = _skip_json_ws_comments(text, value_end)
        if i < len(text) and text[i] == ",":
            i += 1
            continue
        if i < len(text) and text[i] == "}":
            return {
                "kind": "insert",
                "content_start": content_start,
                "close": i,
                "entry_count": entry_count,
                "indent": first_key_indent or "  ",
                "closing_indent": _line_prefix_before(text, i),
            }
        return None

def _reindent_json_value(raw, key_indent):
    lines = raw.split("\\n")
    if len(lines) <= 1:
        return raw
    return "\\n".join([lines[0]] + [key_indent + line if line else line for line in lines[1:]])

def set_top_level_json_value(text, key, value):
    match = _find_top_level_json_key(text, key)
    if not match:
        return None
    serialized = _reindent_json_value(json.dumps(value, indent=2, sort_keys=True), match["indent"])
    if match["kind"] == "replace":
        return text[:match["start"]] + serialized + text[match["end"]:]
    entry = f'"{key}": {serialized}'
    close = match["close"]
    if match["entry_count"] == 0:
        return text[:match["content_start"]] + f"\\n{match['indent']}{entry}\\n{match['closing_indent']}" + text[close:]
    return text[:close] + f",\\n{match['indent']}{entry}\\n{match['closing_indent']}" + text[close:]

def write_json_hooks(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        original = path.read_text(encoding="utf-8")
        updated = set_top_level_json_value(original, "hooks", data.get("hooks") or {})
        if updated is not None:
            write_text_atomic(path, updated)
            return
    write_json(path, data)

def command_for(source):
    return " ".join([
        f"BOUGH_SOCKET_PATH={shlex.quote(socket_path)}",
        f"BOUGH_REMOTE_HOST_ID={shlex.quote(host_id)}",
        f"BOUGH_REMOTE_HOST_NAME={shlex.quote(host_name)}",
        f"BOUGH_SOURCE={shlex.quote(str(source))}",
        "python3",
        "~/.bough/bough-remote-hook.py",
    ])

_REMOTE_HOOK_COMMAND_RE = re.compile(r"(^|[\\s;&|()])(?:~|/[^\\s;&|()]*)/\\.bough/bough-remote-hook\\.py($|[\\s;&|()]|[?#])")

def is_our_remote_hook_command(command):
    if not isinstance(command, str):
        return False
    normalized = command.replace('"', " ").replace("'", " ")
    return _REMOTE_HOOK_COMMAND_RE.search(normalized) is not None

def remove_our_hooks(hooks):
    for event in list(hooks.keys()):
        entries = hooks.get(event)
        if not isinstance(entries, list):
            continue
        next_entries = []
        for entry in entries:
            if not isinstance(entry, dict):
                next_entries.append(entry)
                continue
            commands = []
            if isinstance(entry.get("hooks"), list):
                commands.extend([h.get("command", "") for h in entry["hooks"] if isinstance(h, dict)])
            if isinstance(entry.get("command"), str):
                commands.append(entry["command"])
            if isinstance(entry.get("bash"), str):
                commands.append(entry["bash"])
            if any(is_our_remote_hook_command(c) for c in commands):
                continue
            next_entries.append(entry)
        if next_entries:
            hooks[event] = next_entries
        else:
            hooks.pop(event, None)

def normalized_hooks(data):
    hooks = data.get("hooks")
    return hooks if isinstance(hooks, dict) else {}

def merge_event_hooks(hooks, event, entries):
    existing = hooks.get(event)
    if isinstance(existing, list):
        hooks[event] = existing + entries
    else:
        hooks[event] = entries

TRAECLI_EVENTS = [
    ("session_start", 5),
    ("session_end", 5),
    ("user_prompt_submit", 5),
    ("pre_tool_use", 5),
    ("post_tool_use", 5),
    ("post_tool_use_failure", 5),
    ("permission_request", 86400),
    ("notification", 86400),
    ("subagent_start", 5),
    ("subagent_stop", 5),
    ("stop", 5),
    ("pre_compact", 5),
    ("post_compact", 5),
]

def _normalize_traecli_hooks_list_indentation(contents):
    # Best-effort repair for invalid YAML produced by mixed indentation under top-level `hooks:`.
    #
    # Only normalize indentation of *hook items* ("- type:" / "- command:")
    # and shift the entire list item block left to match the smallest indent.
    normalized = contents.replace("\\r\\n", "\\n")
    lines = normalized.split("\\n")

    hooks_index = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line != stripped:
            continue
        if stripped.startswith("hooks:"):
            hooks_index = i
            break
    if hooks_index is None:
        return normalized

    def _is_top_level_key(line):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return False
        if line != stripped:
            return False
        return ":" in stripped and not stripped.startswith("hooks:")

    # Find the smallest indent among hook items.
    indents = []
    i = hooks_index + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indents.append(len(line) - len(line.lstrip(" ")))
        i += 1
    if not indents:
        return normalized
    base_indent = min(indents)

    out = list(lines)
    i = hooks_index + 1
    while i < len(out):
        line = out[i]
        stripped = line.strip()
        if not stripped:
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indent = len(line) - len(line.lstrip(" "))
            if indent > base_indent:
                delta = indent - base_indent
                j = i
                while j < len(out):
                    nxt = out[j]
                    nxt_stripped = nxt.strip()
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if j != i:
                        if nxt_indent == indent and nxt_stripped.startswith("- "):
                            break
                        if nxt_indent < indent and nxt_stripped != "":
                            break
                    if nxt.startswith(" " * delta):
                        out[j] = nxt[delta:]
                    j += 1
                i = j
                continue
        i += 1

    return "\\n".join(out)

def _detect_traecli_hook_item_indent(lines, hooks_index):
    def _is_top_level_key(line):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            return False
        if line != stripped:
            return False
        return ":" in stripped and not stripped.startswith("hooks:")

    indents = []
    i = hooks_index + 1
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            i += 1
            continue
        if _is_top_level_key(line):
            break
        if stripped.startswith("- type:") or stripped.startswith("- command:"):
            indents.append(len(line) - len(line.lstrip(" ")))
        i += 1
    return min(indents) if indents else 2

def _render_managed_traecli_hooks(cmd, indent=2):
    # Escape single quotes for YAML single-quoted string
    escaped = cmd.replace("'", "''")
    timeout = max([t for (_, t) in TRAECLI_EVENTS] or [5])
    pad = " " * indent
    pad2 = " " * (indent + 2)
    pad4 = " " * (indent + 4)
    lines = [f"{pad}- type: command"]
    lines.append(f"{pad2}command: '{escaped}'")
    lines.append(f"{pad2}timeout: '{timeout}s'")
    lines.append(f"{pad2}matchers:")
    for (event, _) in TRAECLI_EVENTS:
        lines.append(f"{pad4}- event: {event}")
    return "\\n".join(lines)

def _remove_managed_traecli_hooks(contents):
    normalized = _normalize_traecli_hooks_list_indentation(contents)
    lines = normalized.split("\\n")
    result = []

    # Legacy compatibility: previous versions could leave extra comment lines around our hook.
    # We do NOT key off any marker token. Instead, when removing a hook by command match,
    # we also remove contiguous same-indent comment lines adjacent to that hook.

    def _parse_scalar(raw):
        raw = raw.strip()
        if raw.startswith("'") and raw.endswith("'") and len(raw) >= 2:
            return raw[1:-1].replace("''", "'")
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            inner = raw[1:-1]
            bs = chr(92)
            return inner.replace(bs + bs, bs).replace(bs + '"', '"')
        return raw

    def _normalize_cmd(cmd):
        s = " ".join((cmd or "").strip().split())
        if not s:
            return s
        # Normalize first token: allow quoted executable path.
        if s.startswith('"'):
            end = s.find('"', 1)
            if end != -1:
                first = s[1:end]
                rest = s[end+1:].strip()
                s = first + (" " + rest if rest else "")
        parts = s.split(" ", 1)
        first = parts[0]
        rest = parts[1] if len(parts) > 1 else ""
        if first.startswith("~/"):
            first = str(home) + "/" + first[2:]
        return first + (" " + rest if rest else "")

    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        prefix = "- type: command"
        if stripped.startswith(prefix) and (stripped == prefix or stripped[len(prefix):].startswith((" ", "\t", "#"))):
            indent = len(line) - len(line.lstrip(" "))
            j = i + 1
            cmd_value = None
            while j < len(lines):
                nxt = lines[j]
                nxt_stripped = nxt.strip()
                nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                if nxt_indent == indent and nxt_stripped.startswith("- "):
                    break
                if nxt_indent < indent and nxt_stripped != "":
                    break
                if nxt_stripped.startswith("command:"):
                    cmd_value = _parse_scalar(nxt_stripped.split(":", 1)[1])
                j += 1

            if cmd_value and _normalize_cmd(cmd_value) == _normalize_cmd(command_for("traecli")):
                # Remove adjacent same-indent comment lines already appended.
                while result:
                    prev = result[-1]
                    prev_stripped = prev.strip()
                    prev_indent = len(prev) - len(prev.lstrip(" "))
                    if prev_indent == indent and prev_stripped.startswith("#"):
                        result.pop()
                        continue
                    break

                # Skip forward adjacent same-indent comment lines.
                k = j
                while k < len(lines):
                    nxt = lines[k]
                    nxt_stripped = nxt.strip()
                    nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                    if nxt_indent == indent and nxt_stripped.startswith("#"):
                        k += 1
                        continue
                    break

                i = k
                continue

            result.extend(lines[i:j])
            i = j
            continue

        result.append(line)
        i += 1
    # Trim trailing empty lines (keep one newline at end)
    while len(result) >= 2 and (result[-1] == "") and (result[-2] == ""):
        result.pop()
    return "\\n".join(result)

def _merge_traecli_hooks(contents, cmd):
    if not _traecli_yaml_safe_to_edit(contents):
        return None
    normalized = _normalize_traecli_hooks_list_indentation(contents)
    cleaned = _remove_managed_traecli_hooks(normalized)
    lines = cleaned.split("\\n")
    hooks_index = None
    hooks_scalar = None
    for i, line in enumerate(lines):
        stripped = line.strip()
        if line != stripped:
            continue
        if not stripped.startswith("hooks:"):
            continue
        tail = stripped[len("hooks:"):]
        before_comment = tail.split("#", 1)[0].strip()
        if before_comment in ("", "[]", "{}", "null", "~"):
            hooks_index = i
            hooks_scalar = before_comment
            break
    if hooks_index is not None:
        indent = _detect_traecli_hook_item_indent(lines, hooks_index)
        managed_lines = _render_managed_traecli_hooks(cmd, indent=indent).split("\\n")
        if hooks_scalar and hooks_scalar != "":
            lines[hooks_index] = "hooks:"
        lines[hooks_index+1:hooks_index+1] = managed_lines
    else:
        managed_lines = _render_managed_traecli_hooks(cmd, indent=2).split("\\n")
        while lines and lines[-1] == "":
            lines.pop()
        if lines:
            lines.append("")
        lines.append("hooks:")
        lines.extend(managed_lines)
    merged = "\\n".join(lines)
    if not merged.endswith("\\n"):
        merged += "\\n"
    return merged

def _traecli_yaml_safe_to_edit(contents):
    if not contents.strip():
        return True
    stack = []
    in_single = False
    in_double = False
    in_comment = False
    escaped = False
    for char in contents:
        if in_comment:
            if char == "\\n":
                in_comment = False
            continue
        if in_double:
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_double = False
            elif char == "\\n":
                return False
            continue
        if in_single:
            if char == "'":
                in_single = False
            elif char == "\\n":
                return False
            continue
        if char == '"':
            in_double = True
        elif char == "'":
            in_single = True
        elif char == "#":
            in_comment = True
        elif char in "[{":
            stack.append(char)
        elif char == "]":
            if not stack or stack[-1] != "[":
                return False
            stack.pop()
        elif char == "}":
            if not stack or stack[-1] != "{":
                return False
            stack.pop()
    return not in_single and not in_double and not escaped and not stack

def install_claude():
    claude_root = home / ".claude"
    if not claude_root.exists() and shutil.which("claude") is None:
        return "Claude skipped"

    settings_path = claude_root / "settings.json"
    try:
        data = ensure_json(settings_path)
    except ConfigParseError as exc:
        return f"Claude skipped: {exc}"
    hooks = normalized_hooks(data)
    remove_our_hooks(hooks)

    cmd = command_for("claude")
    without_matcher = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_matcher = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_long_timeout = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    precompact = [
        {"matcher": "auto", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
        {"matcher": "manual", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
    ]
    merge_event_hooks(hooks, "UserPromptSubmit", without_matcher)
    merge_event_hooks(hooks, "PreToolUse", without_matcher)
    merge_event_hooks(hooks, "PostToolUse", with_matcher)
    merge_event_hooks(hooks, "PostToolUseFailure", with_matcher)
    merge_event_hooks(hooks, "PermissionRequest", with_long_timeout)
    merge_event_hooks(hooks, "Notification", with_matcher)
    merge_event_hooks(hooks, "Stop", without_matcher)
    merge_event_hooks(hooks, "SubagentStart", with_matcher)
    merge_event_hooks(hooks, "SubagentStop", with_matcher)
    merge_event_hooks(hooks, "SessionStart", without_matcher)
    merge_event_hooks(hooks, "SessionEnd", without_matcher)
    merge_event_hooks(hooks, "PreCompact", precompact)
    data["hooks"] = hooks
    write_json_hooks(settings_path, data)
    return "Claude ok"

def _toml_bool_assignment_value(stripped, key):
    match = re.match(rf"^{re.escape(key)}\\s*=\\s*(true|false)\\s*(#.*)?$", stripped)
    if match:
        return match.group(1)
    return None

def _toml_without_comment(stripped):
    in_basic_string = False
    in_literal_string = False
    escaped = False
    for idx, char in enumerate(stripped):
        if in_basic_string:
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_basic_string = False
        elif in_literal_string:
            if char == "'":
                in_literal_string = False
        elif char == '"':
            in_basic_string = True
        elif char == "'":
            in_literal_string = True
        elif char == "#":
            return stripped[:idx].strip()
    return stripped.strip()

def _toml_bracket_delta(stripped):
    text = _toml_without_comment(stripped)
    in_basic_string = False
    in_literal_string = False
    escaped = False
    delta = 0
    for char in text:
        if in_basic_string:
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_basic_string = False
        elif in_literal_string:
            if char == "'":
                in_literal_string = False
        elif char == '"':
            in_basic_string = True
        elif char == "'":
            in_literal_string = True
        elif char == "[":
            delta += 1
        elif char == "]":
            delta -= 1
    return delta

def _toml_strip_comments(text):
    result = []
    in_basic_string = False
    in_literal_string = False
    in_multiline_basic_string = False
    in_multiline_literal_string = False
    escaped = False
    idx = 0

    while idx < len(text):
        char = text[idx]
        if in_multiline_basic_string:
            result.append(char)
            if escaped:
                escaped = False
                idx += 1
                continue
            if char == "\\\\":
                escaped = True
                idx += 1
                continue
            if text.startswith('"' * 3, idx):
                result.extend(['"', '"'])
                in_multiline_basic_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_multiline_literal_string:
            result.append(char)
            if text.startswith("'" * 3, idx):
                result.extend(["'", "'"])
                in_multiline_literal_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_basic_string:
            result.append(char)
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_basic_string = False
            idx += 1
            continue
        if in_literal_string:
            result.append(char)
            if char == "'":
                in_literal_string = False
            idx += 1
            continue
        if text.startswith('"' * 3, idx):
            in_multiline_basic_string = True
            result.extend(['"', '"', '"'])
            idx += 3
            continue
        if text.startswith("'" * 3, idx):
            in_multiline_literal_string = True
            result.extend(["'", "'", "'"])
            idx += 3
            continue
        if char == '"':
            in_basic_string = True
            result.append(char)
            idx += 1
            continue
        if char == "'":
            in_literal_string = True
            result.append(char)
            idx += 1
            continue
        if char == "#":
            while idx < len(text) and text[idx] != "\\n":
                idx += 1
            continue
        result.append(char)
        idx += 1

    return "\\n".join(line.rstrip() for line in "".join(result).splitlines()).strip()

def _toml_container_state(text):
    in_basic_string = False
    in_literal_string = False
    in_multiline_basic_string = False
    in_multiline_literal_string = False
    escaped = False
    stack = []
    idx = 0

    while idx < len(text):
        char = text[idx]
        if in_multiline_basic_string:
            if escaped:
                escaped = False
                idx += 1
                continue
            if char == "\\\\":
                escaped = True
                idx += 1
                continue
            if text.startswith('"' * 3, idx):
                in_multiline_basic_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_multiline_literal_string:
            if text.startswith("'" * 3, idx):
                in_multiline_literal_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_basic_string:
            if char == "\\n":
                return False, stack
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_basic_string = False
        elif in_literal_string:
            if char == "'":
                in_literal_string = False
        elif text.startswith('"' * 3, idx):
            in_multiline_basic_string = True
            idx += 3
            continue
        elif text.startswith("'" * 3, idx):
            in_multiline_literal_string = True
            idx += 3
            continue
        elif char == '"':
            in_basic_string = True
        elif char == "'":
            in_literal_string = True
        elif char in ("[", "{"):
            stack.append(char)
        elif char == "]":
            if not stack or stack[-1] != "[":
                return False, stack
            stack.pop()
        elif char == "}":
            if not stack or stack[-1] != "{":
                return False, stack
            stack.pop()
        idx += 1

    if in_basic_string or in_literal_string or in_multiline_basic_string or in_multiline_literal_string or escaped:
        return False, stack
    return True, stack

def _toml_value_is_complete(value):
    valid, stack = _toml_container_state(_toml_strip_comments(value))
    return valid and not stack

def _toml_split_top_level(text, separator):
    parts = []
    current = []
    in_basic_string = False
    in_literal_string = False
    in_multiline_basic_string = False
    in_multiline_literal_string = False
    escaped = False
    stack = []
    idx = 0

    while idx < len(text):
        char = text[idx]
        if in_multiline_basic_string:
            current.append(char)
            if escaped:
                escaped = False
                idx += 1
                continue
            if char == "\\\\":
                escaped = True
                idx += 1
                continue
            if text.startswith('"' * 3, idx):
                current.extend(['"', '"'])
                in_multiline_basic_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_multiline_literal_string:
            current.append(char)
            if text.startswith("'" * 3, idx):
                current.extend(["'", "'"])
                in_multiline_literal_string = False
                idx += 3
                continue
            idx += 1
            continue
        if in_basic_string:
            current.append(char)
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                in_basic_string = False
            idx += 1
            continue
        if in_literal_string:
            current.append(char)
            if char == "'":
                in_literal_string = False
            idx += 1
            continue
        if text.startswith('"' * 3, idx):
            in_multiline_basic_string = True
            current.extend(['"', '"', '"'])
            idx += 3
            continue
        if text.startswith("'" * 3, idx):
            in_multiline_literal_string = True
            current.extend(["'", "'", "'"])
            idx += 3
            continue
        if char == '"':
            in_basic_string = True
            current.append(char)
            idx += 1
            continue
        if char == "'":
            in_literal_string = True
            current.append(char)
            idx += 1
            continue
        if char in ("[", "{"):
            stack.append(char)
            current.append(char)
            idx += 1
            continue
        if char == "]":
            if not stack or stack[-1] != "[":
                return None
            stack.pop()
            current.append(char)
            idx += 1
            continue
        if char == "}":
            if not stack or stack[-1] != "{":
                return None
            stack.pop()
            current.append(char)
            idx += 1
            continue
        if char == separator and not stack:
            parts.append("".join(current).strip())
            current = []
            idx += 1
            continue
        current.append(char)
        idx += 1

    if in_basic_string or in_literal_string or in_multiline_basic_string or in_multiline_literal_string or escaped or stack:
        return None
    parts.append("".join(current).strip())
    return parts

def _toml_int_looks_safe(value):
    decimal = r"[+-]?(?:0|[1-9](?:_?[0-9])*)"
    hexadecimal = r"0x[0-9A-Fa-f](?:_?[0-9A-Fa-f])*"
    octal = r"0o[0-7](?:_?[0-7])*"
    binary = r"0b[01](?:_?[01])*"
    return re.match(rf"^(?:{decimal}|{hexadecimal}|{octal}|{binary})$", value) is not None

def _toml_float_looks_safe(value):
    digits = r"[0-9](?:_?[0-9])*"
    integer_part = r"(?:0|[1-9](?:_?[0-9])*)"
    decimal_float = rf"[+-]?(?:{integer_part}\\.{digits}(?:[eE][+-]?{digits})?|{integer_part}[eE][+-]?{digits})"
    special_float = r"[+-]?(?:inf|nan)"
    return re.match(rf"^(?:{decimal_float}|{special_float})$", value) is not None

def _toml_temporal_looks_safe(value):
    date_pattern = r"[0-9]{4}-[0-9]{2}-[0-9]{2}"
    time_pattern = r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\\.[0-9]+)?"
    offset_pattern = r"(?:Z|[+-][0-9]{2}:[0-9]{2})"
    try:
        if re.match(rf"^{date_pattern}$", value):
            datetime.date.fromisoformat(value)
            return True
        if re.match(rf"^{time_pattern}$", value):
            datetime.time.fromisoformat(value)
            return True
        if re.match(rf"^{date_pattern}[Tt ]{time_pattern}(?:{offset_pattern})?$", value):
            normalized = value.replace("t", "T").replace(" ", "T")
            if normalized.endswith("Z"):
                normalized = normalized[:-1] + "+00:00"
            datetime.datetime.fromisoformat(normalized)
            return True
    except Exception:
        return False
    return False

def _toml_basic_string_looks_safe(value):
    triple = '"' * 3
    if value.startswith(triple):
        if len(value) < 6 or not value.endswith(triple) or not _toml_value_is_complete(value):
            return False
        idx = 3
        end = len(value) - 3
        hex_chars = "0123456789abcdefABCDEF"
        while idx < end:
            if value.startswith(triple, idx):
                return False
            char = value[idx]
            if char == "\\\\":
                continuation_idx = _toml_multiline_basic_line_continuation_end(value, idx + 1, end)
                if continuation_idx is not None:
                    idx = continuation_idx
                    continue
                idx += 1
                if idx >= end:
                    return False
                escaped = value[idx]
                if escaped in ("b", "t", "n", "f", "r", '"', "\\\\"):
                    idx += 1
                    continue
                if escaped == "u":
                    digits = value[idx + 1:idx + 5]
                    if idx + 4 >= end or any(c not in hex_chars for c in digits) or not _toml_unicode_escape_looks_safe(digits):
                        return False
                    idx += 5
                    continue
                if escaped == "U":
                    digits = value[idx + 1:idx + 9]
                    if idx + 8 >= end or any(c not in hex_chars for c in digits) or not _toml_unicode_escape_looks_safe(digits):
                        return False
                    idx += 9
                    continue
                return False
            if ord(char) < 0x20 and char not in ("\\n", "\\t"):
                return False
            idx += 1
        return True
    if len(value) < 2 or not value.startswith('"') or not value.endswith('"') or "\\n" in value:
        return False
    idx = 1
    end = len(value) - 1
    hex_chars = "0123456789abcdefABCDEF"
    while idx < end:
        char = value[idx]
        if char == '"':
            return False
        if char == "\\\\":
            idx += 1
            if idx >= end:
                return False
            escaped = value[idx]
            if escaped in ("b", "t", "n", "f", "r", '"', "\\\\"):
                idx += 1
                continue
            if escaped == "u":
                digits = value[idx + 1:idx + 5]
                if idx + 4 >= end or any(c not in hex_chars for c in digits) or not _toml_unicode_escape_looks_safe(digits):
                    return False
                idx += 5
                continue
            if escaped == "U":
                digits = value[idx + 1:idx + 9]
                if idx + 8 >= end or any(c not in hex_chars for c in digits) or not _toml_unicode_escape_looks_safe(digits):
                    return False
                idx += 9
                continue
            return False
        if ord(char) < 0x20:
            return False
        idx += 1
    return True

def _toml_unicode_escape_looks_safe(digits):
    try:
        codepoint = int(digits, 16)
    except Exception:
        return False
    return codepoint <= 0x10FFFF and not (0xD800 <= codepoint <= 0xDFFF)

def _toml_multiline_basic_line_continuation_end(value, idx, end):
    cursor = idx
    while cursor < end and value[cursor] in (" ", "\\t"):
        cursor += 1
    if cursor >= end:
        return None
    if value[cursor] == "\\r":
        if cursor + 1 >= end or value[cursor + 1] != "\\n":
            return None
        cursor += 2
    elif value[cursor] == "\\n":
        cursor += 1
    else:
        return None
    while cursor < end:
        if value[cursor] in (" ", "\\t", "\\n"):
            cursor += 1
            continue
        if value[cursor] == "\\r":
            if cursor + 1 < end and value[cursor + 1] == "\\n":
                cursor += 2
                continue
            return None
        break
    return cursor

def _toml_literal_string_looks_safe(value):
    triple = "'" * 3
    if value.startswith(triple):
        return len(value) >= 6 and value.endswith(triple) and triple not in value[3:-3] and _toml_value_is_complete(value)
    return len(value) >= 2 and value.startswith("'") and value.endswith("'") and "\\n" not in value and "'" not in value[1:-1]

def _toml_scalar_value_looks_safe(value):
    if value in ("true", "false"):
        return True
    if value.startswith('"'):
        return _toml_basic_string_looks_safe(value) and _toml_value_is_complete(value)
    if value.startswith("'"):
        return _toml_literal_string_looks_safe(value) and _toml_value_is_complete(value)
    if _toml_int_looks_safe(value) or _toml_float_looks_safe(value):
        return True
    if _toml_temporal_looks_safe(value):
        return True
    return False

def _toml_array_looks_safe(value):
    if not value.startswith("[") or not value.endswith("]") or not _toml_value_is_complete(value):
        return False
    body = value[1:-1].strip()
    if not body:
        return True
    parts = _toml_split_top_level(body, ",")
    if parts is None:
        return False
    for idx, part in enumerate(parts):
        if not part:
            if idx == len(parts) - 1:
                continue
            return False
        if not _toml_value_looks_safe(part):
            return False
    return True

def _toml_inline_table_looks_safe(value):
    if not value.startswith("{") or not value.endswith("}") or not _toml_value_is_complete(value):
        return False
    body = value[1:-1].strip()
    if not body:
        return True
    parts = _toml_split_top_level(body, ",")
    if parts is None:
        return False
    seen_keys = {}
    for part in parts:
        key_value = _toml_split_top_level(part, "=")
        if key_value is None or len(key_value) != 2:
            return False
        key, nested_value = key_value
        key_segments = _toml_dotted_key_segments(key.strip())
        if key_segments is None:
            return False
        if not _toml_record_key_path(seen_keys, key_segments):
            return False
        if not _toml_value_looks_safe(nested_value):
            return False
    return True

def _toml_bare_key_char_is_valid(char):
    return char == "_" or char == "-" or ("A" <= char <= "Z") or ("a" <= char <= "z") or ("0" <= char <= "9")

def _toml_parse_key_segment(key, idx):
    if idx >= len(key):
        return None
    if key[idx] == '"':
        idx += 1
        escaped = False
        while idx < len(key):
            char = key[idx]
            if escaped:
                escaped = False
            elif char == "\\\\":
                escaped = True
            elif char == '"':
                return idx + 1
            idx += 1
        return None
    if key[idx] == "'":
        idx += 1
        while idx < len(key):
            if key[idx] == "'":
                return idx + 1
            idx += 1
        return None

    start = idx
    while idx < len(key) and key[idx] != "." and not key[idx].isspace():
        if not _toml_bare_key_char_is_valid(key[idx]):
            return None
        idx += 1
    return idx if idx > start else None

def _toml_dotted_key_segments(key):
    idx = 0
    segments = []

    def skip_whitespace():
        nonlocal idx
        while idx < len(key) and key[idx].isspace():
            idx += 1

    while True:
        skip_whitespace()
        if idx >= len(key):
            return None
        start = idx
        next_idx = _toml_parse_key_segment(key, idx)
        if next_idx is None:
            return None
        raw_segment = key[start:next_idx]
        if raw_segment.startswith('"') and raw_segment.endswith('"'):
            if not _toml_basic_string_looks_safe(raw_segment):
                return None
            segment = raw_segment[1:-1]
        elif raw_segment.startswith("'") and raw_segment.endswith("'"):
            if not _toml_literal_string_looks_safe(raw_segment):
                return None
            segment = raw_segment[1:-1]
        else:
            segment = raw_segment
        segments.append(segment)
        idx = next_idx
        skip_whitespace()
        if idx == len(key):
            return segments
        if key[idx] != ".":
            return None
        idx += 1

def _toml_dotted_key_is_valid(key):
    return _toml_dotted_key_segments(key) is not None

def _toml_record_key_path(root, segments):
    node = root
    for idx, segment in enumerate(segments):
        if "__value__" in node:
            return False
        if idx == len(segments) - 1:
            if segment in node:
                return False
            node[segment] = {"__value__": True}
            return True
        node = node.setdefault(segment, {})
    return False

def _toml_record_global_assignment_path(root, segments, protected_prefix_count=0):
    node = root
    for idx, segment in enumerate(segments):
        if "__value__" in node:
            return False
        if idx == len(segments) - 1:
            if segment in node:
                return False
            node[segment] = {"__value__": True}
            return True
        child = node.setdefault(segment, {})
        if "__value__" in child:
            return False
        if idx >= protected_prefix_count and "__explicit__" not in child:
            child["__implicit__"] = True
        node = child
    return False

def _toml_declare_global_table_path(root, segments):
    node = root
    for idx, segment in enumerate(segments):
        if "__value__" in node:
            return False
        child = node.setdefault(segment, {})
        if "__value__" in child:
            return False
        if idx == len(segments) - 1:
            if "__implicit__" in child or "__explicit__" in child or "__array__" in child:
                return False
            child["__explicit__"] = True
            return True
        node = child
    return False

def _toml_declare_global_array_table_path(root, segments):
    node = root
    for idx, segment in enumerate(segments):
        if "__value__" in node:
            return False
        child = node.setdefault(segment, {})
        if "__value__" in child:
            return False
        if idx == len(segments) - 1:
            if "__array__" in child:
                return True
            if "__implicit__" in child or "__explicit__" in child:
                return False
            if any(not key.startswith("__") for key in child):
                return False
            child["__array__"] = True
            return True
        node = child
    return False

def _is_toml_table_header(stripped):
    header = _toml_without_comment(stripped)
    if header.startswith("[["):
        return header.endswith("]]") and len(header) > 4 and _toml_dotted_key_is_valid(header[2:-2])
    if header.startswith("[") and header.endswith("]") and not header.startswith("[["):
        return _toml_dotted_key_is_valid(header[1:-1])
    return False

def _toml_table_header_segments(stripped):
    header = _toml_without_comment(stripped)
    if header.startswith("[[") and header.endswith("]]"):
        return _toml_dotted_key_segments(header[2:-2])
    if header.startswith("[") and header.endswith("]") and not header.startswith("[["):
        return _toml_dotted_key_segments(header[1:-1])
    return None

def _is_features_header(stripped):
    header = _toml_without_comment(stripped)
    return re.match(r"^\\[\\s*features\\s*\\]$", header) is not None

def _codex_version_from_output(output):
    match = re.search(r"\\b([0-9]+\\.[0-9]+\\.[0-9]+)\\b", output or "")
    if match:
        return match.group(1)
    return None

def _codex_command_v_path():
    for shell in ("/bin/zsh", "/bin/sh"):
        if not pathlib.Path(shell).exists():
            continue
        try:
            result = subprocess.run([shell, "-lc", "command -v codex"], capture_output=True, timeout=5, check=False)
            if result.returncode == 0:
                lines = result.stdout.decode("utf-8", errors="ignore").splitlines()
                path = lines[0].strip() if lines else ""
                if path:
                    return path
        except Exception:
            pass
    return None

def _is_executable_file(path):
    try:
        return path.is_file() and os.access(str(path), os.X_OK)
    except Exception:
        return False

def _resolved_path(path):
    try:
        return pathlib.Path(path).resolve(strict=False)
    except Exception:
        return pathlib.Path(path)

def _is_codex_gui_app_binary(path):
    return str(_resolved_path(path)) == "/Applications/Codex.app/Contents/MacOS/Codex"

def _codex_candidate_paths():
    candidates = []
    override_paths = os.environ.get("BOUGH_CODEX_CANDIDATE_PATHS")
    if override_paths is not None:
        for raw_path in override_paths.split(os.pathsep):
            raw_path = raw_path.strip()
            if raw_path:
                candidates.append(pathlib.Path(os.path.expanduser(raw_path)))
    else:
        shell_path = _codex_command_v_path()
        if shell_path:
            candidates.append(pathlib.Path(shell_path))
        candidates.extend([
            home / ".local" / "bin" / "codex",
            pathlib.Path("/usr/local/bin/codex"),
            pathlib.Path("/opt/homebrew/bin/codex"),
        ])
        nvm_root = home / ".nvm" / "versions" / "node"
        try:
            for child in sorted(nvm_root.iterdir(), key=lambda p: p.name):
                candidates.append(child / "bin" / "codex")
        except Exception:
            pass
        app_resource_path = os.environ.get("BOUGH_CODEX_APP_RESOURCES_PATH") or "/Applications/Codex.app/Contents/Resources/codex"
        candidates.append(pathlib.Path(app_resource_path))

    seen = set()
    result = []
    for candidate in candidates:
        resolved = _resolved_path(candidate)
        key = str(resolved)
        if key in seen:
            continue
        seen.add(key)
        if not _is_codex_gui_app_binary(candidate) and _is_executable_file(resolved):
            result.append(resolved)
    return result

def _detect_codex_version():
    versions = []
    for candidate in _codex_candidate_paths():
        try:
            result = subprocess.run([str(candidate), "--version"], capture_output=True, timeout=5, check=False)
            if result.returncode == 0:
                version = _codex_version_from_output(result.stdout.decode("utf-8", errors="ignore"))
                if version:
                    versions.append(version)
        except Exception:
            pass
    if not versions:
        return None
    for version in versions:
        if _version_at_least(version, "0.130.0"):
            return version
    return versions[0]

def _version_at_least(installed, required):
    def parse_parts(v):
        parts = []
        for p in v.split("."):
            try:
                parts.append(int(p))
            except ValueError:
                parts.append(0)
        return parts
    inst_parts = parse_parts(installed)
    req_parts = parse_parts(required)
    length = max(len(inst_parts), len(req_parts))
    for i in range(length):
        a = inst_parts[i] if i < len(inst_parts) else 0
        b = req_parts[i] if i < len(req_parts) else 0
        if a > b:
            return True
        if a < b:
            return False
    return True

def _toml_value_looks_safe(value):
    value = _toml_strip_comments(value)
    if not value:
        return False
    if value[0] == "[":
        return _toml_array_looks_safe(value) if _toml_value_is_complete(value) else True
    if value[0] == "{":
        return _toml_inline_table_looks_safe(value) if _toml_value_is_complete(value) else True
    return _toml_scalar_value_looks_safe(value)

def _codex_toml_is_safe_to_edit(content):
    if not content.strip():
        return True
    if tomllib is not None:
        try:
            tomllib.loads(content)
            return True
        except Exception:
            return False

    lines = content.splitlines()
    current_table = ""
    current_table_segments = []
    current_table_is_array = False
    seen_tables = set()
    assignment_trees = {"": {}}
    global_assignment_tree = {}
    array_table_count = 0
    index = 0
    while index < len(lines):
        line = lines[index]
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            index += 1
            continue
        header = _toml_without_comment(stripped)
        if header.startswith("["):
            if not _is_toml_table_header(stripped):
                if "," not in header and not header.endswith(","):
                    return False
            elif header.startswith("[["):
                header_segments = _toml_table_header_segments(stripped)
                if header_segments is None:
                    return False
                if not _toml_declare_global_array_table_path(global_assignment_tree, header_segments):
                    return False
                array_table_count += 1
                current_table = f"{header}#{array_table_count}"
                current_table_segments = header_segments
                current_table_is_array = True
                assignment_trees[current_table] = {}
            else:
                header_segments = _toml_table_header_segments(stripped)
                if header_segments is None:
                    return False
                header_key = tuple(header_segments)
                if header_key in seen_tables:
                    return False
                if not _toml_declare_global_table_path(global_assignment_tree, header_segments):
                    return False
                seen_tables.add(header_key)
                current_table = header
                current_table_segments = header_segments
                current_table_is_array = False
                assignment_trees.setdefault(current_table, {})
        elif not _is_toml_table_header(stripped):
            if "=" not in header:
                return False
            key, value = header.split("=", 1)
            key_segments = _toml_dotted_key_segments(key.strip())
            if key_segments is None:
                return False
            if not current_table_is_array:
                global_segments = current_table_segments + key_segments
                if not _toml_record_global_assignment_path(global_assignment_tree, global_segments, len(current_table_segments)):
                    return False
            if not _toml_record_key_path(assignment_trees.setdefault(current_table, {}), key_segments):
                return False
            value_lines = [value]
            while not _toml_value_is_complete("\\n".join(value_lines)):
                index += 1
                if index >= len(lines):
                    return False
                value_lines.append(lines[index])
            full_value = "\\n".join(value_lines)
            if not _toml_value_looks_safe(full_value):
                return False
        index += 1
    return True

def ensure_toml_codex_hooks(path):
    try:
        content = path.read_text() if path.exists() else ""
    except Exception:
        return False
    if not _codex_toml_is_safe_to_edit(content):
        return False
    lines = content.splitlines()
    features_idx = None
    hooks_present = False
    old_value = None
    cleaned = []
    in_features = False
    array_depth = 0

    detected_version = _detect_codex_version()
    # Detection failure strips the deprecated key; only detected old Codex preserves it.
    preserve_legacy = detected_version is not None and not _version_at_least(detected_version, "0.130.0")

    for line in lines:
        stripped = line.strip()
        is_table_header = array_depth == 0 and _is_toml_table_header(stripped)
        if is_table_header:
            in_features = _is_features_header(stripped)

        if in_features:
            if features_idx is None and _is_features_header(stripped):
                features_idx = len(cleaned)
            value = _toml_bool_assignment_value(stripped, "codex_hooks")
            if value is not None:
                if old_value is None:
                    old_value = value
                if preserve_legacy:
                    cleaned.append(line)
                    continue
                continue
            if _toml_bool_assignment_value(stripped, "hooks") is not None:
                hooks_present = True

        cleaned.append(line)
        if not is_table_header:
            array_depth = max(0, array_depth + _toml_bracket_delta(stripped))

    if features_idx is None:
        cleaned = lines[:]
        if lines and lines[-1].strip():
            cleaned.append("")
        cleaned.extend(["[features]", "hooks = true"])
    elif not hooks_present:
        hook_value = old_value or "true"
        cleaned.insert(features_idx + 1, f"hooks = {hook_value}")

    path.parent.mkdir(parents=True, exist_ok=True)
    try:
        write_text_atomic(path, "\\n".join(cleaned).rstrip() + "\\n")
    except Exception:
        return False
    return True

def install_codex():
    codex_root = _codex_home()
    if not codex_root.exists() and shutil.which("codex") is None and not _codex_candidate_paths():
        return "Codex skipped"

    hooks_path = codex_root / "hooks.json"
    try:
        data = ensure_json(hooks_path)
    except ConfigParseError as exc:
        return f"Codex skipped: {exc}"
    if not ensure_toml_codex_hooks(codex_root / "config.toml"):
        return "Codex skipped: config.toml not enabled"
    hooks = normalized_hooks(data)
    remove_our_hooks(hooks)

    cmd = command_for("codex")
    entry = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    long_entry = [{"hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    merge_event_hooks(hooks, "SessionStart", entry)
    merge_event_hooks(hooks, "SessionEnd", entry)
    merge_event_hooks(hooks, "UserPromptSubmit", entry)
    merge_event_hooks(hooks, "PreToolUse", entry)
    merge_event_hooks(hooks, "PostToolUse", entry)
    merge_event_hooks(hooks, "PermissionRequest", long_entry)
    merge_event_hooks(hooks, "Stop", entry)
    data["hooks"] = hooks
    write_json_hooks(hooks_path, data)
    return "Codex ok"

def install_codebuddy():
    codebuddy_root = home / ".codebuddy"
    if not codebuddy_root.exists() and shutil.which("codebuddy") is None:
        return "CodeBuddy skipped"

    settings_path = codebuddy_root / "settings.json"
    try:
        data = ensure_json(settings_path)
    except ConfigParseError as exc:
        return f"CodeBuddy skipped: {exc}"
    hooks = normalized_hooks(data)
    remove_our_hooks(hooks)

    cmd = command_for("codebuddy")
    without_matcher = [{"hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_matcher = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]}]
    with_long_timeout = [{"matcher": "*", "hooks": [{"type": "command", "command": cmd, "timeout": 86400}]}]
    precompact = [
        {"matcher": "auto", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
        {"matcher": "manual", "hooks": [{"type": "command", "command": cmd, "timeout": 60}]},
    ]
    merge_event_hooks(hooks, "UserPromptSubmit", without_matcher)
    merge_event_hooks(hooks, "PreToolUse", without_matcher)
    merge_event_hooks(hooks, "PostToolUse", with_matcher)
    merge_event_hooks(hooks, "PostToolUseFailure", with_matcher)
    merge_event_hooks(hooks, "PermissionRequest", with_long_timeout)
    merge_event_hooks(hooks, "Notification", with_matcher)
    merge_event_hooks(hooks, "Stop", without_matcher)
    merge_event_hooks(hooks, "SubagentStart", with_matcher)
    merge_event_hooks(hooks, "SubagentStop", with_matcher)
    merge_event_hooks(hooks, "SessionStart", without_matcher)
    merge_event_hooks(hooks, "SessionEnd", without_matcher)
    merge_event_hooks(hooks, "PreCompact", precompact)
    data["hooks"] = hooks
    write_json_hooks(settings_path, data)
    return "CodeBuddy ok"

def install_traecli():
    traecli_root = home / ".trae"
    if not traecli_root.exists() and shutil.which("traecli") is None:
        return "Traecli skipped"

    config_path = traecli_root / "traecli.yaml"
    try:
        original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
    except Exception:
        return "Traecli read failed"
    cmd = command_for("traecli")
    merged = _merge_traecli_hooks(original, cmd)
    if merged is None:
        return "Traecli skipped: invalid YAML"
    write_text_atomic(config_path, merged)
    return "Traecli ok"

parts = [install_claude(), install_codex(), install_codebuddy(), install_traecli()]
print(" · ".join(parts))
"""
    }

    private static func runSSH(host: RemoteHost, command: String, timeout: TimeInterval) async -> RemoteCommandResult {
        guard host.validatedSSHTarget != nil else {
            return RemoteCommandResult(stdout: "", stderr: "invalid host", exitCode: -1)
        }
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = sshArguments(host: host) + [command]
            process.environment = sshEnvironment(host: host)

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                continuation.resume(returning: RemoteCommandResult(stdout: "", stderr: error.localizedDescription, exitCode: -1))
                return
            }

            let stdoutHandle = stdout.fileHandleForReading
            let stderrHandle = stderr.fileHandleForReading
            let stdoutTask = Task.detached {
                stdoutHandle.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderrHandle.readDataToEndOfFile()
            }

            Task.detached {
                let exitedBeforeTimeout = ProcessRunner.waitUntilExitOrTerminate(process, timeout: timeout)
                let outData = await stdoutTask.value
                let errData = await stderrTask.value
                let out = String(data: outData, encoding: .utf8) ?? ""
                var err = String(data: errData, encoding: .utf8) ?? ""
                if !exitedBeforeTimeout {
                    let timeoutMessage = "ssh timed out after \(Int(timeout))s"
                    err = err.isEmpty ? timeoutMessage : "\(err)\n\(timeoutMessage)"
                }
                continuation.resume(returning: RemoteCommandResult(
                    stdout: out,
                    stderr: err,
                    exitCode: exitedBeforeTimeout ? process.terminationStatus : -9
                ))
            }
        }
    }

    private static func sshArguments(host: RemoteHost) -> [String] {
        var args: [String] = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
        ]
        if let port = host.port {
            args += ["-p", String(port)]
        }
        let trimmedIdentity = host.identityFile.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedIdentity.isEmpty {
            args += ["-i", trimmedIdentity]
        }
        guard let target = host.validatedSSHTarget else { return [] }
        args += ["--", target]
        return args
    }

    private static func sshEnvironment(host: RemoteHost) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let trimmed = host.authSocket.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            env["SSH_AUTH_SOCK"] = (trimmed as NSString).expandingTildeInPath
        }
        return env
    }

    private static func pythonStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension RemoteCommandResult {
    var stderrSummary: String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown error" : trimmed
    }

    var stdoutSummary: String {
        stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
