"""Offline guards for the Jev function-hook modules. No client, provider or network call.

A hook module that fails to load is still listed as a loaded plugin in the
client's `system/init` event, and no error reaches the stream, so the session
looks instrumented while no callback is ever registered. That is exactly how a
truncated scratch driver silently produced a headless run with no hook callback
(see `docs/overnight-usage-results.md`). These tests check the two properties
that failure violated: every module named in `hooks.json` exists, and its
delimiters close.
"""

import json
from pathlib import Path
import shutil
import subprocess
import unittest

PLUGIN = Path(__file__).resolve().parents[2] / "Plugins" / "jev-optimizer"
HOOKS = PLUGIN / "hooks" / "hooks.json"
MAX_MODULE_BYTES = 2_000_000


def unbalanced(source):
    """Delimiters that never close, ignoring strings, templates and comments.

    This is a truncation check, not a parser: it answers "did the file end in the
    middle of something", which is the failure that loses a hook registration.
    """
    stack = []
    index = 0
    length = len(source)
    pairs = {")": "(", "]": "[", "}": "{"}
    while index < length:
        char = source[index]
        following = source[index + 1] if index + 1 < length else ""
        if char == "/" and following == "/":
            index = source.find("\n", index)
            if index < 0:
                break
            continue
        if char == "/" and following == "*":
            end = source.find("*/", index + 2)
            index = length if end < 0 else end + 2
            continue
        if char in "'\"`":
            index += 1
            while index < length:
                if source[index] == "\\":
                    index += 2
                    continue
                if source[index] == char:
                    break
                index += 1
            if index >= length:
                return f"unterminated string starting with {char}"
            index += 1
            continue
        if char in "([{":
            stack.append(char)
        elif char in pairs:
            if not stack or stack[-1] != pairs[char]:
                return f"unexpected {char}"
            stack.pop()
        index += 1
    return f"unclosed {''.join(stack)}" if stack else None


def modules():
    config = json.loads(HOOKS.read_text(encoding="utf-8"))
    return [(HOOKS.parent / name).resolve() for name in config["modules"]]


class HookModuleTests(unittest.TestCase):
    def test_hooks_json_lists_modules_that_exist_and_are_bounded(self):
        found = modules()
        self.assertTrue(found, "hooks.json lists no module")
        for path in found:
            self.assertTrue(path.is_file(), f"missing hook module: {path.name}")
            self.assertLess(path.stat().st_size, MAX_MODULE_BYTES, path.name)
            self.assertTrue(path.is_relative_to(PLUGIN), f"hook module escapes the plugin: {path}")

    def test_every_hook_module_closes_its_delimiters_and_registers_events(self):
        for path in modules():
            source = path.read_text(encoding="utf-8")
            self.assertIsNone(unbalanced(source), f"{path.name} is truncated")
            self.assertIn("register", source, f"{path.name} exports no register")
            self.assertRegex(source, r"on\(\s*['\"](session\.compact|turn\.complete)",
                             f"{path.name} registers no known event")

    def test_the_truncation_check_catches_the_shape_that_lost_a_hook_callback(self):
        truncated = ("export const register = (on) => {\n"
                     " on('turn.complete', async ($, event, next) => {\n"
                     "  return next(event);\n"
                     " });\n")
        self.assertEqual(unbalanced(truncated), "unclosed {")
        self.assertIsNone(unbalanced(truncated + "};\n"))

    def test_the_truncation_check_ignores_delimiters_inside_strings_and_comments(self):
        self.assertIsNone(unbalanced("const a = '{(' ; /* } */ // )\nconst b = `${'}'}`;\n"))
        self.assertIsNone(unbalanced("const escaped = '\\'{';\n"))
        self.assertEqual(unbalanced("const broken = 'oops;\n"), "unterminated string starting with '")
        self.assertEqual(unbalanced("}\n"), "unexpected }")

    def test_node_confirms_the_truncation_verdict_when_node_is_available(self):
        """The same two sources, judged by the runtime that actually loads them."""
        node = shutil.which("node")
        if node is None:
            self.skipTest("node is not installed")
        broken = ("export const register = (on) => {\n on('turn.complete', (e, next) => next(e));\n")
        for source, expected_ok in ((broken, False), (broken + "};\n", True)):
            with self.subTest(ok=expected_ok):
                path = Path(__file__).with_name(f"_hook_syntax_probe_{int(expected_ok)}.mjs")
                path.write_text(source, encoding="utf-8")
                try:
                    done = subprocess.run([node, "--check", str(path)], capture_output=True, timeout=30)
                finally:
                    path.unlink(missing_ok=True)
                self.assertEqual(done.returncode == 0, expected_ok)
                self.assertEqual(unbalanced(source) is None, expected_ok)


if __name__ == "__main__":
    unittest.main()
