# Manual end-to-end checklist — 0.14.0

The offline suites cover everything 0.14 ships, but they fake exactly the
things only a person can see: the rendered Touch ID sheets, macOS's
notification permission, the real agent config files, a live MCP client and
the gateway on its real port. This page is the one pass a human makes on a
real Mac with the built app before the release goes out. It takes about ten
minutes of attention, plus the release build.

You need: this checkout at the 0.14.0 tree, Xcode's toolchain (and the signing
identity from [SIGNING.md](../SIGNING.md) if you sign with `make app`),
Claude Code, Touch ID enrolled, and nothing else. Every key in this run is
fake and assembled at runtime — no real credential is typed, pasted, printed
or committed anywhere — and the scratch project is deleted at the end.

The steps depend on each other: the import in step 5 creates the two wrapped
files that step 8 unwraps one of and step 9's uninstall offer unwraps the
other, and the grant from step 6 is one of the things step 7 revokes. Do them
in order. If any step does not show what it says, stop there: this checklist
is the release gate, and a mismatch is a finding, not a speed bump.

The surfaces behind each step are documented in depth in
[agents.md](agents.md) (the MCP server and its tools) and
[release.md](release.md) (the packaging scripts).

## 1. Build, package and install

From the checkout, build the release binary and the bundle:

```sh
swift build -c release
python3 scripts/build-app.py
```

You should see the release build finish, then one line:

```text
built /…/.build/app/Keysrs.app, signed ad hoc (local use only)
```

An ad-hoc bundle runs on the build Mac but cannot read Keychain items an
earlier install created. If this replaces your working install and you want
the existing vault to keep opening, build the locally signed variant instead:
`make app` re-signs the same bundle with the Apple Development identity from
`~/.config/keysreallysafe/signing-identity` (see SIGNING.md; a locally signed
install is still not a notarized release).

Confirm the signing shape before packaging:

```sh
codesign -dv .build/app/Keysrs.app        # Identifier=keysreallysafe
codesign -d -r- .build/app/Keysrs.app     # the same designated requirement as 0.9.2
plutil -lint .build/app/Keysrs.app/Contents/Info.plist
```

Then stage the DMG contents and pack the DMG (the output paths must not
exist yet):

```sh
python3 scripts/prepare-release.py \
  --app .build/app/Keysrs.app \
  --output /tmp/keysrs-014/Keysrs-arm64 \
  --verify-codesign \
  --dmg /tmp/keysrs-014/Keysrs-arm64.dmg
```

The script verifies the bundle byte for byte against the checkout (Web files,
price table, licence texts, Info.plist) and prints, in order:

```text
offline release prepared: /tmp/keysrs-014/Keysrs-arm64
unsigned DMG created: /tmp/keysrs-014/Keysrs-arm64.dmg
cask filled: /…/packaging/homebrew/keysrs.rb version 0.14.0 sha256 <digest>
```

The third line is the new step: the DMG's digest is written into the
Homebrew cask (`packaging/homebrew/keysrs.rb`) together with the version, so
the cask can never point at a checksum nobody computed.

Install it: open `Keysrs-arm64.dmg`, drag Keysrs to the Applications symlink,
then open Keysrs from Applications. If an older Keysrs is installed, quit it
first (Settings → Quit, or ⌘Q while the window is shown) and let Finder
replace `/Applications/Keysrs.app`; your data stays where it was.

What you should see on first open: **nothing**. Keysrs starts headless — no
Dock icon, no window, no menu bar item — while usage tracking and the gateway
carry on. It adds itself as a login item (System Settings > General > Login
Items lists Keysrs among the apps allowed in the background). Open it again
from Applications or Spotlight to show the window: the dashboard loads from
`http://127.0.0.1:12766/`, with a Dock icon while it is up, and closing the
window hides the app without quitting it.

Install the command line: with the window frontmost, open the Keysrs menu
(beside the Apple menu) and choose **Install Command Line Tool…** → Install.
That links `~/.local/bin/keys` into the bundle. Then confirm the version from
a terminal:

```sh
keys version --json     # {"version":"0.14.0"} — one line, exit 0
```

`keys version` prints the human form, `Keysrs 0.14.0`. If `keys` is not on
your PATH, add `~/.local/bin` to it or call the bundle binary directly at
`/Applications/Keysrs.app/Contents/MacOS/keys`.

## 2. The one launch ask: notification permission

At the first launch of a newly installed version, macOS asks once for
notification permission: a system alert saying Keysrs would like to send you
notifications, with **Don't Allow** and **Allow** buttons. Choose Allow for
this run. The ask happens once per installed version, not per launch — the
app records the version after asking either way, so 0.14.0 never asks again
even after a relaunch, and the next version bump is what triggers the next
fresh ask.

What the permission buys in this run: while a grant ask waits for your Touch
ID in step 6 you may see the fixed notification "Keysrs is waiting for your
approval — An agent's request is waiting for approval." Later the same
permission carries the expiring-credential, paused-key and update-installed
notifications. None of them ever names a key, token or path — the payloads are
fixed templates.

## 3. Register the MCP server: `keys setup mcp`

```sh
keys setup mcp
```

Registration needs no vault key, no running site, no Keychain and no Touch
ID. It writes the `keysrs` server into five clients, one line each:

```text
registered keysrs with Claude Code: /Users/<you>/.claude.json
<the .bak note for that file>
registered keysrs with Codex: /Users/<you>/.codex/config.toml
<the .bak note for that file>
registered keysrs with Cursor: /Users/<you>/.cursor/mcp.json
<the .bak note for that file>
registered keysrs with Droid: /Users/<you>/.factory/mcp.json
<the .bak note for that file>
registered keysrs with Claude Desktop: /Users/<you>/Library/Application Support/Claude/claude_desktop_config.json
<the .bak note for that file>
restart each client to load the server; undo with: keys setup mcp --remove
```

Each registered line is followed by one backup note, and which one you see
depends on the file: a config that already existed (your `~/.claude.json`,
certainly) was backed up before the write and says "your previous file is
kept beside it as a .bak"; a file Keysrs just created says "edits from here
on keep a .bak beside it" — the promise of a backup starts with the second
edit. The writes merge around each file's other entries, keep the file
owner-only, and hold no secret: each entry names the resolved absolute path
of the installed `keys` binary plus the `mcp` argument, nothing else.

The machine-readable form is one sorted-key line:

```sh
keys setup mcp --json
```

```json
{"action":"register","clients":{"claude_code":"/Users/<you>/.claude.json","claude_desktop":"/Users/<you>/Library/Application Support/Claude/claude_desktop_config.json","codex":"/Users/<you>/.codex/config.toml","cursor":"/Users/<you>/.cursor/mcp.json","droid":"/Users/<you>/.factory/mcp.json"},"command":"/Applications/Keysrs.app/Contents/MacOS/keys","server":"keysrs"}
```

The command in that line is the resolved binary (never the
`~/.local/bin/keys` symlink), which is why re-running the step after moving
the app updates the path. It is idempotent; `keys setup mcp --remove` undoes
all five and leaves every other entry alone.

## 4. Connect Claude Code

Claude Code reads the registration from `~/.claude.json` at launch, so start
it fresh (restart a running session). This step needs no `keys setup claude`
call — that command wires an environment-variable gateway grant for
unattended CLI use and is a different surface; the MCP server needs nothing
but the registration you just wrote.

Open a terminal in the scratch project you will create in step 5 (or anywhere
— but step 5's scan defaults to the session's working directory, so the
project folder is the useful place), run `claude`, then:

```text
/mcp
```

You should see the **keysrs** server listed as connected, with its sixteen
tools: `version`, `list_keys`, `gateway_info`, `open_app`, `check_update`,
`request_grant`, `grant_status`, `scan_project`, `check_exposure`,
`import_and_wrap`, `test_keys`, `send_feedback`, `set_analytics_sharing`,
`revoke_all`, `revoke_project`, `activity`.

Claude Code asks before each tool call (its own permission prompt); approve
them for this run. Then ask it, in plain words:

> What Keysrs vault keys do I have?

The agent calls `list_keys` and answers with names, providers and kinds —
never a value. On an empty vault it says so; on your existing vault it lists
your real keys by name, which is the point: the tool reads the local catalog
with the app closed and returns labels only.

## 5. Onboard a test project with fake keys

Build the scratch project. The fake key is assembled at runtime from
fragments, so no line you paste, echo or commit ever looks like a real key:

```sh
mkdir -p ~/keysrs-e2e && cd ~/keysrs-e2e
git init -q
printf 'ANTHROPIC_API_KEY=%s%s%s\n' "sk-ant-FAKE0" "TEST0VALUE0NOT0A0REAL0KEY" "01" > .env
printf 'ANTHROPIC_API_KEY=%s%s%s\n' "sk-ant-FAKE0" "TEST0VALUE0NOT0A0REAL0KEY" "01" > .env.local
touch Dockerfile
git add .env && git commit -q -m "fixture: fake key on purpose"
```

Both files hold the same fake value, so the import below shares one vault key
across both. The deliberate commit is what makes the git-exposure finding in
this step true. The `Dockerfile` is never opened by Keysrs — presence is all
that is read — and it is what makes the agent ask the Docker question later
in this step. Run `claude` in this folder (restart it if it is already
running elsewhere, so the session's working directory is this project), and
give it the phrases below, one at a time.

**Scan.** Tell the agent:

> Scan this project for credential-shaped environment variables with Keysrs.

The agent calls `scan_project` (no file reading of its own). You should see
it report both variables by name with their relative files
(`.env`, `.env.local`), the likely provider (Anthropic), the category
(`provider_key`), a last-4 hint (`EY01` — at most four characters, never the
value), `in_vault` false, the env files read, and the Dockerfile at the root.
If your vault already holds the same fake value from an earlier run, the
answer says `in_vault` true instead.

**Exposure.** Tell the agent:

> Check which of those env files git has ever seen.

The agent calls `check_exposure`. You should see three read-only booleans per
file: `.env` is tracked and in history (you committed it) with the
recommendation "rotate the keys that were in this file", while `.env.local`
is none of the three. Never any file contents or diffs. This needs no app
and no network — it is git's own facts.

**The one Touch ID import.** Tell the agent:

> Import and wrap this project's keys into the vault.

The agent asks for your go-ahead first — its server instructions require
asking before importing — and asks the Docker question, because the scan
reported a Dockerfile at the root: should Docker containers also be able to
reach the gateway through `host.docker.internal`? Answer **Yes** to the
import and **No** to Docker for this run. The agent then calls
`import_and_wrap` with `docker` unset, and the Keysrs app shows **one**
Touch ID sheet:

```text
Keysrs is trying to import and wrap 2 keys for project keysrs-e2e: anthropic.
```

One prompt covers reading the vault for the dedupe, storing the key, turning
the gateway on and issuing the project token — there is no second prompt.
Approve it. Because you answered No to Docker, the sheet does not mention
Docker, the global Docker setting stays off, and the base URLs written below
stay on loopback.

The agent's answer reports per-variable outcomes — both variables `wrapped`
under one key (named `anthropic` on an empty vault; a taken name is
disambiguated and the answer reports whatever it used) — plus the project
label `keysrs-e2e`, the token's 30-day expiry, `docker_access` false, the
base-URL host `127.0.0.1`, and `backup_kept_outside_project` true. No value,
no token, no absolute path crosses the answer.

Check the file yourself:

```sh
cat .env
```

```text
ANTHROPIC_API_KEY=ksfc_…
ANTHROPIC_BASE_URL=http://127.0.0.1:12767/anthropic
```

Each wrapped line now holds the project's client token (a `ksfc_…` value —
treat it as a secret; do not paste it anywhere), and the wrap appended the
base URL the Anthropic SDK reads. Comments, quoting and blank lines keep
their original shape. The original values were backed up outside the
project: `ls` in the project shows no `*.keysrs-backup-*` file — backups
live in Keysrs' own backups folder beside its catalog.

**The analytics question.** The onboarding flow ends with the
share-to-compare question; the agent asks it, and you answer. For this run
answer:

> No — keep analytics local.

The agent calls `set_analytics_sharing` with `enabled` false and relays the
recorded state, `{"enabled":false}`. Nothing was sent anywhere by the call
(it only records your answer; the dashboard's own timer is the only thing
that ever uploads), and no Touch ID was asked. Off is also the default — the
call exists so the agent records your explicit answer rather than guessing.

## 6. Use a grant through the gateway

Still in the `claude` session in the project folder, tell the agent:

> Ask me for a Keysrs grant for the key <name> for this task, 30 minutes.

Use the key name the import answer reported (`anthropic`, unless it was
disambiguated). The agent calls `request_grant` — the host is never an input;
it is the key's own — and immediately reports the ask's answer shape:

```json
{"status":"pending","id":"<8 hex>","secret":"<32 hex>"}
```

The `secret` is the new poll secret: it proves the ask is the agent's. It
reaches no listing, log or notification, and a process holding nothing but
the app's control token can neither poll the ask nor receive the token — the
agent threads the id and the secret itself.

While the ask is live, the Keysrs app shows one Touch ID sheet naming the
key, the key's own host and the project's label — never a path, never a
token:

```text
Keysrs is trying to grant "<the task>" the key anthropic for Anthropic at api.anthropic.com, 30 min, project keysrs-e2e.
```

(If you allowed notifications in step 2, the "Keysrs is waiting for your
approval" notification may appear at the same time.) Approve with Touch ID.
The agent polls `grant_status` with the id and the secret, and on exactly
the first approved poll it is handed the connection facts:

```json
{"status":"approved","id":"<8 hex>","token":"ksf_…","base_url":"http://127.0.0.1:12767/anthropic/v1","auth_header":"x-api-key", …}
```

A later poll answers `{"status":"approved","id":"…","delivered":true}` with
no token — the token is handed over exactly once. (Optional negative check:
cancel the sheet once instead of approving; the agent's next poll reports
`{"status":"denied","reason":"cancelled"}`, and asking again works.)

Now spend the grant with one curl through the gateway, using the `token`,
`base_url` and `auth_header` the agent reported — the URL is the loopback
gateway on port 12767, with the key's name in it:

```sh
curl -s "http://127.0.0.1:12767/anthropic/v1/models" -H "x-api-key: <the grant token>"
```

What you should see: the provider's own 401, because the vault key is fake —
and that is the pass. The gateway authorized the grant, swapped the token
for the vault secret and forwarded the call; the provider's answer came back
through it. The gateway's own refusals look different: a request without a
valid token is 401 with `"error":"grant_required"` in the body. Confirm the
call in the gateway's log:

```sh
keys log
```

The last line shows the forwarded call: your key's name, the provider, the
upstream host, status 401, the duration, and the reason `upstream_status` —
the provider answered, the gateway did not fail. The log holds no body and no
token.

## 7. `revoke_all`

Tell the agent:

> Revoke everything now.

The agent calls `revoke_all` — the kill switch needs the app but no Touch ID,
because revocation only removes access. It answers with honest counts of what
was still live and is now dead, for example:

```json
{"revoked_clients":1,"revoked_grants":1}
```

(one grant from step 6, one project client token from step 5 — your counts
depend on what your vault had live). A second call answers zeros: counts are
of things revoked by that call, not totals. Afterwards the grant token is
refused at the gateway with `grant_revoked` and the project token with
`revoked`, and the vault's keys themselves are untouched — this ends
access, it never deletes a key.

Optional confirmation: ask the agent for `gateway_info` — the live grants
list and the active project client tokens it reports are now empty.

## 8. `keys unwrap`

Unwrap one of the two wrapped files, from any directory:

```sh
keys unwrap ~/keysrs-e2e/.env
```

One Touch ID sheet appears:

```text
Keysrs is trying to unwrap .env and revoke its gateway client tokens.
```

Approve it. `keys unwrap` prints what it did — variable names and counts,
never a value:

```text
.env: restored ANTHROPIC_API_KEY from the vault
  ANTHROPIC_BASE_URL removed (the wrap-time backup holds no original for it)
  .env.local still uses this file's gateway token; it was kept
revoked 0 gateway client tokens; the wrapped-files records were cleared
```

The counts are zero for two stacked reasons: the token was **kept** because
`.env.local` still holds it (the report names that file; the token dies when
the last of its files unwraps), and it was already revoked by step 7 anyway —
an already-revoked token is a no-op, not a failure.

What the file looks like after:

```sh
cat .env
```

```text
ANTHROPIC_API_KEY=sk-ant-FAKE0…
```

Back to the original bytes — the real value restored from the vault, the
`ANTHROPIC_BASE_URL` companion the wrap appended removed, everything else as
written. `.env.local` still holds the (dead) token until step 9 unwraps it.

Optional negative check — the one command that never launches the app: quit
Keysrs (Settings → Quit), run `keys unwrap ~/keysrs-e2e/.env` again and
observe:

```text
Keysrs isn't running. Open Keysrs from Applications, then try again.
```

with exit code 6 (`echo $?` prints 6) and nothing changed. Reopen Keysrs
from Applications before continuing.

## 9. Uninstall, with the unwrap offer

`keys autostart --remove` is the uninstall code path, and it offers to unwrap
first: a wrapped file left holding a token that dies with the install is the
silent bricking the offer exists to prevent. Step 8 cleared `.env`'s record;
`.env.local` is still recorded, so the offer appears. Keep Keysrs running for
this step (the offer's unwrap goes through the running app):

```sh
keys autostart --remove
```

You should see the offer — the file list and the question, then your answer:

```text
wrapped env files recorded for this installation:
  /Users/<you>/keysrs-e2e/.env.local
Unwrap these files first? [y/N] y
```

Answer **y**. One more Touch ID sheet appears — the per-project form, one
prompt for every file the project wraps:

```text
Keysrs is trying to unwrap .env.local for project keysrs-e2e and revoke their gateway client tokens.
```

Approve it, and the unwrap report prints, followed by the removal's own
line:

```text
.env.local: restored ANTHROPIC_API_KEY from the vault
  ANTHROPIC_BASE_URL removed (the wrap-time backup holds no original for it)
revoked 0 gateway client tokens; the wrapped-files records were cleared
removed login item com.keysreallysafe.menubar
```

The token count is zero again because step 7 already revoked it — an honest
zero, not a failure. Answering **n** instead prints the plain statement that
the wrapped files were left as they are, holding tokens that no longer work
without Keysrs, and the removal proceeds anyway.

What that removal actually removed: the legacy 0.9.x launchd label and plist
if any, the retired 0.9.x program folders (`bin/`, `Web/`, `Fixtures/`,
`Plugins/`, `scripts/`), `.previous/`, and `menubar.log`. It does not remove
the catalog, the Keychain keys, the backups, or the app bundle. If you are
keeping 0.14.0 installed, you are done — nothing it removed matters to the
running app (it recreates `menubar.log`). To uninstall for real, finish by
dragging Keysrs.app from Applications to the Trash; macOS drops the login
item once the app is gone, and `keys purge` (one Touch ID) removes the
catalog and every Keychain item if you want the data gone too.

## Cleanup

```sh
rm -rf ~/keysrs-e2e
```

The fake key is still in the vault under the name the import used; remove it
with `keys rm <name>` (one Touch ID) if you do not want it, or `keys purge`
if you are removing the app as well. If you do not want the MCP server
registered after the run, `keys setup mcp --remove` undoes the five
registrations from step 3 and leaves every other entry in each file alone.
