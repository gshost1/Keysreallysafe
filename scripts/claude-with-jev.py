#!/usr/bin/env python3
"""Launch Claude with Jev and a short-lived, scoped Keys gateway grant.

The provider secret stays in Keys. The grant is passed only in the child
process environment, never in command arguments or a configuration file.
"""

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGIN_DIR = REPO_ROOT / "Plugins" / "jev-optimizer"
EVALUATION_PATH = "/v4/ai/evaluation-model"
PROVIDERS = {
    "vercel-ai-gateway": ("ai-gateway.vercel.sh", EVALUATION_PATH, "/v1"),
    "typesafe": ("api.typesafe.ai", "/v1/systemone", ""),
}
GRANT_ID = re.compile(r"[0-9a-f]{8}")


class LaunchError(Exception):
    """An error with a fixed, credential-free message suitable for display."""


class Interrupted(BaseException):
    def __init__(self, signum):
        self.signum = signum


@contextmanager
def termination_signals():
    # subprocess.run kills and reaps its child when this exception is raised.
    # Restore handlers before attempting the final grant revocation.
    previous = {}

    def interrupt(signum, _frame):
        raise Interrupted(signum)

    try:
        for signum in (signal.SIGTERM, signal.SIGHUP):
            previous[signum] = signal.signal(signum, interrupt)
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def positive_int(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def parse_args(argv):
    # Everything after -- belongs to Claude verbatim, including its own options.
    boundary = argv.index("--") if "--" in argv else len(argv)
    parser = argparse.ArgumentParser(
        description=__doc__,
        usage="%(prog)s KEY [--keys PATH] [--claude PATH] [--minutes N] "
              "[--max-requests N] [-- CLAUDE_ARGS...]",
    )
    parser.add_argument("key", help="Compatible Vercel AI Gateway or TypeSafe vault key name")
    parser.add_argument("--provider", choices=tuple(PROVIDERS), default="vercel-ai-gateway",
                        help="Jev protocol (default: vercel-ai-gateway)")
    parser.add_argument("--keys", help="Keys binary (default: installed bundle, repo debug build, then PATH)")
    parser.add_argument("--claude", default="claude", help="Claude binary (default: PATH)")
    parser.add_argument("--minutes", type=positive_int, default=30)
    parser.add_argument("--max-requests", type=positive_int, default=100)
    args = parser.parse_args(argv[:boundary])
    if len(args.key) > 128 or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*", args.key):
        parser.error("KEY must match [a-z0-9][a-z0-9._-]* and be at most 128 characters")
    if args.minutes > 1440:
        parser.error("--minutes must be between 1 and 1440")
    return args, argv[boundary + 1:]


def resolve_program(value, label):
    program = shutil.which(os.path.expanduser(value))
    if not program:
        raise LaunchError(f"{label} executable was not found. Set its explicit path.")
    return program


def default_keys():
    candidates = [
        REPO_ROOT / "bin" / "keys",
        REPO_ROOT / ".build" / "debug" / "keys",
    ]
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return "keys"


def grant_id(response):
    value = response.get("id") if isinstance(response, dict) else None
    return value if isinstance(value, str) and GRANT_ID.fullmatch(value) else None


def validate_grant(response, args):
    """Fail closed before giving Claude a token or a network destination."""
    identifier = grant_id(response)
    if identifier is None:
        raise LaunchError("Keys returned an invalid grant identifier; Claude was not started.")
    expected_url = f"http://127.0.0.1:12767/{args.key}"
    host, path, prefix = PROVIDERS[args.provider]
    expected = {
        "key": args.key,
        "provider": args.provider,
        "host": host,
        "gateway_url": expected_url,
        "base_url": expected_url + prefix,
        "auth_header": "Authorization",
        "jev_provider": args.provider,
        "exact_paths": True,
        "methods": ["POST"],
        "paths": [path],
        "max_requests": args.max_requests,
        "status": "active",
    }
    if type(response.get("exact_paths")) is not bool or any(response.get(key) != value for key, value in expected.items()):
        raise LaunchError("Keys returned an unexpected grant target or scope; Claude was not started.")
    token = response.get("token")
    if not isinstance(token, str) or not re.fullmatch(
        rf"ksf_{identifier}_[A-Za-z0-9_-]{{43}}", token
    ):
        raise LaunchError("Keys returned an invalid grant token; Claude was not started.")
    return token, expected_url + path


def launch(args, claude_args):
    keys = resolve_program(args.keys or default_keys(), "Keys")
    claude = resolve_program(args.claude, "Claude")
    if not (PLUGIN_DIR / ".claude-plugin" / "plugin.json").is_file():
        raise LaunchError("Bundled Jev plugin was not found next to this launcher.")
    identifier = None
    try:
        print("Approve the Jev context optimization grant in Keysrs.", file=sys.stderr)
        issued = subprocess.run(
            [keys, "grant", args.key, "--task", "Jev context optimization",
             "--methods", "POST", "--paths", PROVIDERS[args.provider][1],
             "--jev-provider", args.provider,
             "--minutes", str(args.minutes), "--max-requests", str(args.max_requests), "--json"],
            capture_output=True, text=True, timeout=180, check=False,
        )
        try:
            response = json.loads(issued.stdout)
        except (ValueError, TypeError):
            raise LaunchError("Could not read the Keys grant response; Claude was not started.") from None
        # Retain only a safely formatted ID for cleanup even if validation fails.
        identifier = grant_id(response)
        if issued.returncode != 0:
            raise LaunchError("Keys could not issue the grant; check the running app and vault key.")
        token, endpoint = validate_grant(response, args)
        child_env = os.environ.copy()
        child_env.update(
            AI_GATEWAY_API_KEY=token,
            AI_GATEWAY_BASE_URL=endpoint,
            CLAUDE_CODE_ENABLE_FUNCTION_HOOKS="1",
            KEYS_JEV_SCOPED_GRANT="1",
            KEYS_JEV_PROVIDER=args.provider,
        )
        # Do not chdir: Claude operates on the project where the user ran us.
        with termination_signals():
            completed = subprocess.run(
                [claude, "--plugin-dir", str(PLUGIN_DIR), *claude_args],
                env=child_env, check=False,
            )
        return completed.returncode if completed.returncode >= 0 else 128 - completed.returncode
    except (OSError, subprocess.SubprocessError, UnicodeError):
        # Exceptions and captured control output may contain credentials.
        raise LaunchError("Could not run Keys or Claude; check the executables and running Keys app.") from None
    finally:
        if identifier is not None:
            try:
                revoked = subprocess.run(
                    [keys, "revoke", identifier],
                    capture_output=True, text=True, timeout=10, check=False,
                )
                if revoked.returncode != 0:
                    print("Could not confirm grant revocation; its expiry and request cap still apply.", file=sys.stderr)
            except (OSError, subprocess.SubprocessError, UnicodeError):
                print("Could not confirm grant revocation; its expiry and request cap still apply.", file=sys.stderr)


def main(argv=None):
    args, claude_args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        return launch(args, claude_args)
    except LaunchError as error:
        print(str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    except Interrupted as error:
        return 128 + error.signum


if __name__ == "__main__":
    sys.exit(main())
