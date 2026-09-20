#!/usr/bin/env python3
"""Print project-local Claude Code and Codex commands for the Keys Optimizer MCP server.

Nothing here edits a client configuration, reads a vault key, unlocks the optimizer,
or asks for presence. Commands carry a project UUID and a key *name* only; the
credential stays in Keys. `--check` runs `--help` on the local executables to confirm
the options these commands rely on. `--write-example DIR` writes one JSON file for
`claude --mcp-config` into a directory you choose, never into a client's own folder.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import uuid

REPO_ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER = "PROJECT_UUID"
SERVER_NAME = "keys_optimizer"
EXAMPLE_NAME = "keys-optimizer.mcp.json"
KEY_NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")
# Presence approval happens while the client waits for the server to start.
STARTUP_SECONDS = 120
TOOL_SECONDS = 45


def server_args(options):
    args = ["optimizer", "mcp", "--project", options.project, "--minutes", str(options.minutes)]
    if options.writable:
        args.append("--writable")
    if options.jev_key:
        args += ["--jev-key", options.jev_key]
    return args


def mcp_config(options, keys):
    return {"mcpServers": {SERVER_NAME: {"type": "stdio", "command": keys, "args": server_args(options)}}}


def toml_string(value):
    return json.dumps(value, ensure_ascii=False)


def commands(options, keys, example):
    quoted = shlex.quote
    launcher = REPO_ROOT / "scripts" / "claude-with-jev.py"
    overrides = [
        f"mcp_servers.{SERVER_NAME}.command={toml_string(keys)}",
        f"mcp_servers.{SERVER_NAME}.args=[{', '.join(toml_string(item) for item in server_args(options))}]",
        f"mcp_servers.{SERVER_NAME}.startup_timeout_sec={STARTUP_SECONDS}",
        f"mcp_servers.{SERVER_NAME}.tool_timeout_sec={TOOL_SECONDS}",
    ]
    claude_env = f"MCP_TIMEOUT={STARTUP_SECONDS * 1000}"
    result = {
        "claude_mcp_only": f"cd {quoted(str(options.root))} && {claude_env} claude --mcp-config {quoted(str(example))}",
        "codex_mcp_only": f"codex --cd {quoted(str(options.root))} " + " ".join(f"-c {quoted(item)}" for item in overrides),
        "codex_config_toml_snippet": "\n".join([
            f"[mcp_servers.{SERVER_NAME}]", f"command = {toml_string(keys)}",
            f"args = [{', '.join(toml_string(item) for item in server_args(options))}]",
            f"startup_timeout_sec = {STARTUP_SECONDS}", f"tool_timeout_sec = {TOOL_SECONDS}"]),
    }
    if options.jev_key:
        result["claude_mcp_and_compaction"] = (
            f"cd {quoted(str(options.root))} && {claude_env} python3 {quoted(str(launcher))} {quoted(options.jev_key)}"
            f" --provider {quoted(options.provider)} --keys {quoted(keys)} -- --mcp-config {quoted(str(example))}")
    return result


def help_mentions(program, arguments, needles):
    try:
        done = subprocess.run([program, *arguments, "--help"], capture_output=True, text=True, timeout=20, check=False,
                              stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError, UnicodeError):
        return None
    text = done.stdout + done.stderr
    return {needle: needle in text for needle in needles}


def check(options, keys):
    """Help output and file presence only: no unlock, no grant, no client session."""
    results = []

    def record(name, ok, detail):
        results.append({"check": name, "ok": bool(ok), "detail": detail})

    record("project_uuid", options.project != PLACEHOLDER, "pass the UUID shown in the Optimizer pane" if options.project == PLACEHOLDER else "valid")
    record("project_root", options.root.is_dir(), str(options.root))
    executable = shutil.which(keys)
    record("keys_executable", executable, executable or "not found; pass --keys")
    if executable:
        flags = help_mentions(executable, ["optimizer", "mcp"], ["--project", "--jev-key", "--writable", "--minutes"])
        record("keys_optimizer_mcp_options", flags and all(flags.values()), flags or "help unavailable")
        script = Path(os.path.realpath(executable)).parent.parent / "scripts" / "optimizer-mcp.py"
        repo_script = REPO_ROOT / "scripts" / "optimizer-mcp.py"
        record("mcp_adapter_script", script.is_file() or repo_script.is_file(), str(script if script.is_file() else repo_script))
    record("claude_launcher_plugin", (REPO_ROOT / "Plugins" / "jev-optimizer" / ".claude-plugin" / "plugin.json").is_file(), "Plugins/jev-optimizer")
    for client, needles in (("claude", ["--mcp-config", "--plugin-dir"]), ("codex", ["--config", "--cd"])):
        program = shutil.which(client)
        flags = help_mentions(program, [], needles) if program else None
        record(f"{client}_options", flags and all(flags.values()), flags or f"{client} not found on PATH (optional)")
    return results


def write_example(directory, config):
    directory = directory.expanduser().resolve()
    home = Path.home().resolve()
    for owned in (home / ".claude", home / ".codex"):
        if directory == owned or owned in directory.parents:
            raise ValueError("refusing to write inside a client's own configuration directory")
    if directory == home:
        raise ValueError("choose a project or scratch directory, not the home directory")
    target = directory / EXAMPLE_NAME
    directory.mkdir(parents=True, exist_ok=True)
    # Exclusive create: an existing file is never replaced.
    with open(target, "x", encoding="utf-8") as handle:
        handle.write(json.dumps(config, indent=2) + "\n")
    return target


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=PLACEHOLDER, help="approved project UUID from the Optimizer pane")
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help="project directory the client should run in")
    parser.add_argument("--jev-key", help="stored key NAME for bounded Jev evaluations (not the secret)")
    parser.add_argument("--provider", choices=("vercel-ai-gateway", "typesafe"), default="vercel-ai-gateway",
                        help="compaction transport matching the stored key's provider")
    parser.add_argument("--keys", default="keys", help="Keys executable (default: PATH)")
    parser.add_argument("--minutes", type=int, default=30)
    parser.add_argument("--writable", action="store_true")
    parser.add_argument("--check", action="store_true", help="verify local executables and options via --help only")
    parser.add_argument("--write-example", type=Path, metavar="DIR", help=f"create DIR/{EXAMPLE_NAME}; never overwrites")
    options = parser.parse_args(argv)
    if options.project != PLACEHOLDER:
        try:
            options.project = str(uuid.UUID(options.project))
        except ValueError:
            parser.error("--project must be a UUID")
    if options.jev_key and not KEY_NAME.fullmatch(options.jev_key):
        parser.error("--jev-key must be a stored key name matching [a-z0-9][a-z0-9._-]*")
    if not 1 <= options.minutes <= 120:
        parser.error("--minutes must be 1-120")
    options.root = options.root.expanduser().resolve()

    keys = shutil.which(options.keys) or options.keys
    config = mcp_config(options, keys)
    example = (options.write_example.expanduser().resolve() if options.write_example else options.root / ".keys") / EXAMPLE_NAME
    output = {
        "ready": options.project != PLACEHOLDER,
        "edits_client_configuration": False,
        "contains_credentials": False,
        "claude_mcp_config": config,
        "claude_mcp_config_path": str(example),
        "claude_mcp_config_exists": example.is_file(),
        "commands": commands(options, keys, example),
        "approvals": "Each client start asks for presence in Keys for the MCP session; the compaction launcher asks once more for its grant.",
    }
    if options.write_example:
        try:
            output["example_written"] = str(write_example(options.write_example, config))
            output["claude_mcp_config_exists"] = True
        except FileExistsError:
            print(f"{EXAMPLE_NAME} already exists there; it was left unchanged.", file=sys.stderr)
            return 1
        except (OSError, ValueError) as error:
            print(str(error) if isinstance(error, ValueError) else "could not write the example file", file=sys.stderr)
            return 1
    status = 0
    if options.check:
        output["checks"] = check(options, keys)
        required = [item for item in output["checks"] if not item["check"].startswith(("claude_options", "codex_options"))]
        status = 0 if all(item["ok"] for item in required) else 3
    sys.stdout.write(json.dumps(output, indent=2) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
