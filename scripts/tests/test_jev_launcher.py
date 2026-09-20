"""Offline launcher tests: no grant, Claude session, or network access is created."""

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "jev_launcher", Path(__file__).resolve().parents[1] / "claude-with-jev.py"
)
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)

GRANT_ID = "abcdef12"
TOKEN = "ksf_" + GRANT_ID + "_" + "a" * 43


def grant(**updates):
    response = {
        "id": GRANT_ID,
        "key": "vercel-team",
        "provider": "vercel-ai-gateway",
        "host": "ai-gateway.vercel.sh",
        "gateway_url": "http://127.0.0.1:12767/vercel-team",
        "base_url": "http://127.0.0.1:12767/vercel-team/v1",
        "auth_header": "Authorization",
        "jev_provider": "vercel-ai-gateway",
        "exact_paths": True,
        "methods": ["POST"],
        "paths": ["/v4/ai/evaluation-model"],
        "max_requests": 100,
        "status": "active",
        "token": TOKEN,
    }
    response.update(updates)
    return response


def result(code=0, stdout="", stderr=""):
    return subprocess.CompletedProcess([], code, stdout, stderr)


class LauncherTests(unittest.TestCase):
    def invoke(self, results, extra=None, response=None):
        out, err = io.StringIO(), io.StringIO()
        if response is None:
            response = grant()
        sequence = [result(stdout=json.dumps(response), stderr=TOKEN), *results]
        with patch.object(launcher.shutil, "which", side_effect=lambda value: value), \
             patch.object(launcher.subprocess, "run", side_effect=sequence) as run, \
             redirect_stdout(out), redirect_stderr(err):
            code = launcher.main([
                "vercel-team", "--keys", "/safe/keys", "--claude", "/safe/claude", *(extra or [])
            ])
        self.assertNotIn(TOKEN, out.getvalue() + err.getvalue())
        for call in run.call_args_list:
            self.assertNotIn(TOKEN, " ".join(call.args[0]))
            self.assertNotIn("cwd", call.kwargs)
        return code, run, out.getvalue(), err.getvalue()

    def test_scoped_grant_child_environment_and_original_arguments(self):
        cwd = os.getcwd()
        original_env = dict(os.environ)
        code, run, _, _ = self.invoke(
            [result(), result()],
            ["--", "--resume", "session with spaces", "--", "literal $() `text`"],
        )
        self.assertEqual(code, 0)
        issue, child, revoke = run.call_args_list
        self.assertEqual(issue.args[0], [
            "/safe/keys", "grant", "vercel-team", "--task", "Jev context optimization",
            "--methods", "POST", "--paths", "/v4/ai/evaluation-model",
            "--jev-provider", "vercel-ai-gateway",
            "--minutes", "30", "--max-requests", "100", "--json",
        ])
        self.assertTrue(issue.kwargs["capture_output"])
        self.assertEqual(child.args[0], [
            "/safe/claude", "--plugin-dir", str(launcher.PLUGIN_DIR),
            "--resume", "session with spaces", "--", "literal $() `text`",
        ])
        env = child.kwargs["env"]
        self.assertEqual(env["AI_GATEWAY_API_KEY"], TOKEN)
        self.assertEqual(env["AI_GATEWAY_BASE_URL"],
                         "http://127.0.0.1:12767/vercel-team/v4/ai/evaluation-model")
        self.assertEqual(env["CLAUDE_CODE_ENABLE_FUNCTION_HOOKS"], "1")
        self.assertEqual(env["KEYS_JEV_SCOPED_GRANT"], "1")
        self.assertNotIn("capture_output", child.kwargs)
        self.assertNotIn("env", issue.kwargs)
        self.assertNotIn("env", revoke.kwargs)
        self.assertEqual(revoke.args[0], ["/safe/keys", "revoke", GRANT_ID])
        self.assertTrue(revoke.kwargs["capture_output"])
        self.assertEqual(os.getcwd(), cwd)
        self.assertEqual(dict(os.environ), original_env)

    def test_overrides_existing_gateway_environment_only_for_child(self):
        with patch.dict(os.environ, {"AI_GATEWAY_API_KEY": "old", "AI_GATEWAY_BASE_URL": "https://wrong.invalid",
                                      "KEYS_JEV_SCOPED_GRANT": "0"}):
            code, run, _, _ = self.invoke([result(), result()])
            self.assertEqual(code, 0)
            self.assertEqual(run.call_args_list[1].kwargs["env"]["AI_GATEWAY_API_KEY"], TOKEN)
            self.assertEqual(run.call_args_list[1].kwargs["env"]["KEYS_JEV_SCOPED_GRANT"], "1")
            self.assertEqual(os.environ["AI_GATEWAY_API_KEY"], "old")
            self.assertEqual(os.environ["KEYS_JEV_SCOPED_GRANT"], "0")

    def test_bounds_passed_to_keys(self):
        code, run, _, _ = self.invoke([result(), result()],
                                     ["--minutes", "10", "--max-requests", "5"],
                                     grant(max_requests=5))
        self.assertEqual(code, 0)
        args = run.call_args_list[0].args[0]
        self.assertEqual(args[args.index("--minutes") + 1], "10")
        self.assertEqual(args[args.index("--max-requests") + 1], "5")

    def test_direct_typesafe_uses_explicit_protocol_and_scoped_path(self):
        response = grant(provider="typesafe", host="api.typesafe.ai", paths=["/v1/systemone"],
                         jev_provider="typesafe", base_url="http://127.0.0.1:12767/vercel-team")
        code, run, _, _ = self.invoke([result(), result()], ["--provider", "typesafe"], response)
        self.assertEqual(code, 0)
        issue, child, revoke = run.call_args_list
        self.assertEqual(issue.args[0][issue.args[0].index("--paths") + 1], "/v1/systemone")
        self.assertEqual(child.kwargs["env"]["KEYS_JEV_PROVIDER"], "typesafe")
        self.assertEqual(child.kwargs["env"]["AI_GATEWAY_BASE_URL"], "http://127.0.0.1:12767/vercel-team/v1/systemone")
        self.assertEqual(revoke.args[0], ["/safe/keys", "revoke", GRANT_ID])

    def test_direct_typesafe_rejects_wrong_provider_host_or_route(self):
        for update in [{"provider": "vercel-ai-gateway"}, {"host": "api.typesafe.ai.evil.invalid"},
                       {"host": "ai-gateway.vercel.sh"}, {"paths": ["/v4/ai/evaluation-model"]}]:
            response = grant(provider="typesafe", host="api.typesafe.ai", paths=["/v1/systemone"],
                             jev_provider="typesafe", base_url="http://127.0.0.1:12767/vercel-team")
            response.update(update)
            code, run, _, _ = self.invoke([result()], ["--provider", "typesafe"], response)
            self.assertEqual(code, 1)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(run.call_args_list[-1].args[0], ["/safe/keys", "revoke", GRANT_ID])

    def test_child_failure_still_revokes_and_propagates_exit(self):
        code, run, _, _ = self.invoke([result(23), result()])
        self.assertEqual(code, 23)
        self.assertEqual(run.call_args_list[-1].args[0][1:], ["revoke", GRANT_ID])

    def test_exec_failure_still_revokes_without_printing_exception(self):
        code, run, _, _ = self.invoke([OSError(TOKEN), result()])
        self.assertEqual(code, 1)
        self.assertEqual(run.call_args_list[-1].args[0][1:], ["revoke", GRANT_ID])

    def test_interrupt_still_revokes(self):
        for exception, expected in [(KeyboardInterrupt(), 130),
                                    (launcher.Interrupted(signal.SIGTERM), 143)]:
            with self.subTest(exception=type(exception).__name__):
                code, run, _, _ = self.invoke([exception, result()])
                self.assertEqual(code, expected)
                self.assertEqual(run.call_args_list[-1].args[0][1:], ["revoke", GRANT_ID])

    def test_child_signal_exit_is_shell_compatible(self):
        code, _, _, _ = self.invoke([result(-signal.SIGTERM), result()])
        self.assertEqual(code, 143)

    def test_invalid_targets_and_scope_are_rejected_and_revoked(self):
        invalid = [
            {"provider": "openai"}, {"host": "evil.invalid"},
            {"host": "ai-gateway.vercel.sh.evil.invalid"},
            {"gateway_url": "https://127.0.0.1:12767/vercel-team"},
            {"gateway_url": "http://localhost:12767/vercel-team"},
            {"gateway_url": "http://127.0.0.1:12767/vercel-team?redirect=evil"},
            {"gateway_url": "http://127.0.0.1:12767/vercel-team/"},
            {"key": "other"}, {"methods": ["POST", "GET"]},
            {"auth_header": "x-api-key"}, {"base_url": "http://127.0.0.1:12767/vercel-team/custom"},
            {"jev_provider": None}, {"jev_provider": "typesafe"}, {"exact_paths": False}, {"exact_paths": 1},
            {"paths": []}, {"max_requests": None}, {"max_requests": 101},
            {"status": "expired"}, {"token": "provider-secret"},
            {"token": "ksf_deadbeef_" + "a" * 43},
        ]
        for update in invalid:
            with self.subTest(fields=list(update)):
                code, run, _, _ = self.invoke([result()], response=grant(**update))
                self.assertEqual(code, 1)
                self.assertEqual(run.call_count, 2)
                self.assertEqual(run.call_args_list[-1].args[0][1:], ["revoke", GRANT_ID])

    def test_invalid_identifier_cannot_be_used_as_a_revoke_argument(self):
        for identifier in [None, "--all", "../../bad", TOKEN]:
            with self.subTest(identifier_type=type(identifier).__name__):
                code, run, _, _ = self.invoke([], response=grant(id=identifier))
                self.assertEqual(code, 1)
                self.assertEqual(run.call_count, 1)

    def test_invalid_json_is_not_printed_or_launched(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(launcher.shutil, "which", return_value="/safe/tool"), \
             patch.object(launcher.subprocess, "run", return_value=result(stdout=TOKEN, stderr=TOKEN)) as run, \
             redirect_stdout(out), redirect_stderr(err):
            self.assertEqual(launcher.main(["vercel-team"]), 1)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn(TOKEN, out.getvalue() + err.getvalue())

    def test_json_nonobject_is_rejected(self):
        code, run, _, _ = self.invoke([], response=[TOKEN])
        self.assertEqual(code, 1)
        self.assertEqual(run.call_count, 1)

    def test_failed_grant_with_valid_id_is_revoked(self):
        with patch.object(launcher.shutil, "which", return_value="/safe/tool"), \
             patch.object(launcher.subprocess, "run", side_effect=[
                 result(1, json.dumps(grant()), TOKEN), result(),
             ]) as run, redirect_stderr(io.StringIO()) as err:
            self.assertEqual(launcher.main(["vercel-team"]), 1)
        self.assertNotIn(TOKEN, err.getvalue())
        self.assertEqual(run.call_args_list[-1].args[0][1:], ["revoke", GRANT_ID])

    def test_revoke_errors_do_not_leak_and_do_not_mask_child_exit(self):
        for cleanup in [result(1, TOKEN, TOKEN), OSError(TOKEN),
                        subprocess.TimeoutExpired([TOKEN], 10, output=TOKEN),
                        UnicodeDecodeError("utf-8", b"secret\xff", 6, 7, "invalid")]:
            with self.subTest(kind=type(cleanup).__name__):
                code, _, _, err = self.invoke([result(23), cleanup])
                self.assertEqual(code, 23)
                self.assertIn("Could not confirm grant revocation", err)

    def test_grant_decode_failure_never_prints_raw_output(self):
        error = UnicodeDecodeError("utf-8", TOKEN.encode() + b"\xff", 0, 1, TOKEN)
        with patch.object(launcher.shutil, "which", return_value="/safe/tool"), \
             patch.object(launcher.subprocess, "run", side_effect=error) as run, \
             redirect_stderr(io.StringIO()) as err:
            self.assertEqual(launcher.main(["vercel-team"]), 1)
        self.assertEqual(run.call_count, 1)
        self.assertNotIn(TOKEN, err.getvalue())

    def test_missing_executable_does_not_issue_grant(self):
        with patch.object(launcher.shutil, "which", return_value=None), \
             patch.object(launcher.subprocess, "run") as run, redirect_stderr(io.StringIO()):
            self.assertEqual(launcher.main(["vercel-team"]), 1)
        run.assert_not_called()

    def test_invalid_arguments_do_not_issue_grant(self):
        for args in [["../bad"], ["vercel-team", "--minutes", "0"],
                     ["vercel-team", "--minutes", "1441"],
                     ["vercel-team", "--max-requests", "0"],
                     ["vercel-team", "--max-requests", "-1"]]:
            with self.subTest(args=args), patch.object(launcher.subprocess, "run") as run, \
                 redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as caught:
                launcher.main(args)
            self.assertEqual(caught.exception.code, 2)
            run.assert_not_called()

    def test_staged_layout_prefers_installed_binary_then_debug_then_path(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            installed = root / "bin" / "keys"
            debug = root / ".build" / "debug" / "keys"
            installed.parent.mkdir(parents=True)
            debug.parent.mkdir(parents=True)
            installed.write_text("installed")
            debug.write_text("debug")
            installed.chmod(0o755)
            debug.chmod(0o755)
            with patch.object(launcher, "REPO_ROOT", root):
                self.assertEqual(launcher.default_keys(), str(installed))
                installed.unlink()
                self.assertEqual(launcher.default_keys(), str(debug))
                debug.unlink()
                self.assertEqual(launcher.default_keys(), "keys")


if __name__ == "__main__":
    unittest.main()
