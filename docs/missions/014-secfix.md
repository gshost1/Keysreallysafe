# 0.14 security-review fixes (014-secfix)

Branch `droid/014-secfix`, from `e040501` (the finished 0.14 integration).
Source: the 0.14 `/security-review` (no High; S1–S2 Medium, S3–S7 Low,
I1–I4 informational). One commit per item, I1 and I2 as one pair. Every item
has a regression test. Each test was run against the pre-fix source (by
reverting that commit's `Sources/` changes, or disabling the one line that is
the fix) and failed there, then passed with the fix. Nothing was pushed or
merged.

## Items

| ID | Commit | Regression test(s) | Pre-fix | Status |
|---|---|---|---|---|
| S1 `import_and_wrap` used the app's cwd | `5edd50b` | `ImportAndWrapTests.testNoFolderArgumentSendsTheSessionFolderNotTheAppWorkingDirectory`, `.testRelativeAndSymlinkedFoldersAreSentCanonical`, `.testASessionInTheRootOrHomeFolderIsRefused`, `.testRouteRefusesAMissingOrRelativeFolder`; `ScanProjectToolTests.testASessionInTheRootOrHomeFolderIsRefused` | 5 tests, 31 failures | Fixed |
| S2 relauncher spawned before the quit-time re-check | `f1c60c3` | `AppUpdaterTests.testABusyQuitTimeHoldsTheRestartHelperUntilTheNextQuietWindow`, `.testTheInstallerHandOffSpawnsOnlyWhenTheCallerSays`; `.testBusyDiscoveredDuringTheInstallDefersTheRelaunchWithoutQuitting` extended | failed with the background factory's `defersRelaunch` line disabled | Fixed |
| S3 guided-add name check gaps; `KeyName.validate` echoed input | `f2d3739` | `GuidedAddTests.testMixedCaseUppercaseHexAndCustomPrefixKeysAreRefusedAsAName`, `.testKeyNameValidateNeverEchoesTheInput` | 2 tests, 9 failures | Fixed |
| S4 uninstall aborted on a deleted project folder | `d4d6dd6` | `UninstallOfferTests.testDeletedProjectFolderDoesNotAbortTheUninstall` | threw "that project folder does not exist" | Fixed |
| S5 agent could opt the person into analytics | `9001df0` | `AnalyticsToolsTests.testRouteSetsConsentLogsOneLineAndAnswersBounded`, `.testToolSetsConsentOverTheRig`, `.testLogLineIsOneTimestampedConfirmation` (rewritten) | 7 tests, 13 failures | Fixed |
| S6 `Paths.appSupport` outside the tripwire | `e4d4fda` | `ProductionTripwireTests.testTheApplicationSupportRootRefusesUnderTestIsolation`, `.testSourcesRootNoStateInApplicationSupportDirectly`; `DroidUsageRowTests` and `KeyLifecycleAndDedupTests` moved to a temp `claude-plan.json` | see note 4 | Fixed |
| S7 planted legacy backup trusted; no containment re-check on unwrap | `884ac09` | `UnwrapTests.testAPlantedInProjectBackupLosesToTheAppSupportOne`, `.testALegacyBesideFileBackupStillRestoresButNeverItsBaseURL` (replaces the old legacy test), `.testASymlinkSwappedParentIsRefused` | 3 tests, 8 failures | Fixed |
| I1 poll-secret compare not constant-time | `606b03f` | `GrantPromptHardeningTests.testThePollSecretIsComparedInConstantTime` | 2 failures | Fixed |
| I2 grant prompt label unbounded | `606b03f` | `GrantPromptHardeningTests.testTheGrantPromptLabelIsStrippedAndCapped` | 4 failures | Fixed |
| I3 unwrap prompt promised a revocation that did not happen | `7c5f306` | `UnwrapTests.testTheFilePromptSaysASharedTokenStays` | 2 failures | Fixed |
| I4 feedback prompt not normalized; GitHub URL uncapped | `1ea98c9` | `FeedbackScrubberTests.testAPromptCarryingZeroWidthCharactersIsStillRemoved`, `FeedbackToolsTests.testLongDraftCapsTheGitHubURLToo` | 2 tests, 5 failures | Fixed |

## Full CI list

Run on 2026-10-28/29 at HEAD `1ea98c9` in this worktree, in the order of
`.github/workflows/test.yml`, with CI's environment (`CLAUDE_CONFIG_DIR`,
`GROK_HOME`, `GROK_BOT_HOME` and `KEYS_DROID_HOME` pointing at `Fixtures/`).
Every step exited 0.

| Step | Suite's own summary line |
|---|---|
| `swift test` | `Executed 1089 tests, with 5 tests skipped and 0 failures (0 unexpected) in 193.864 (193.987) seconds` |
| `scripts/tests` `npm ci` | `added 33 packages, and audited 34 packages in 1s` |
| `Relay` `npm ci` | `added 80 packages, and audited 81 packages in 5s` |
| `Relay` `npm test` | `Test Files  1 passed (1)` / `Tests  43 passed (43)` |
| `python3 -m unittest discover -s scripts/tests -p 'test_*.py'` | `Ran 76 tests in 6.375s` / `OK` |
| `python3 -m unittest Analytics/test_collector.py` | `Ran 20 tests in 10.436s` / `OK` |
| `npx --no-install playwright install chromium` | exit 0, no output (already installed) |
| `node scripts/tests/test_keys_dashboard_ui.cjs` | `Keys dashboard UI passed: 146 cases` |
| `node scripts/tests/test_analytics_ui.cjs` | exit 0; the script prints nothing on success |
| `npm run test:e2e` | `Test Files  1 passed (1)` / `Tests  1 passed (1)` |
| `KEYS_BACKEND_CONTRACT_UI=1 swift test --filter BackendContractUITests` | `Executed 1 test, with 0 failures (0 unexpected) in 4.675 (4.677) seconds` |

The 5 tests skipped in the plain `swift test` run are opt-in or
environment-gated, as they were before these fixes:

- `BackendContractUITests.testRealDashboardDrivesTheRealKeysAPIs` (it runs in
  the last step)
- three `RelayEndToEndTests` (they need `wrangler dev`)
- `StableSigningTests.testAppleSignedBuildPassesFreshAndUpgradeValidation`

1089 tests ran, against 1070 in the integration report: these fixes added 19
new test methods (the old legacy-backup test was replaced, not added to).

## Decisions made without asking

1. **S1, `/` and home refusal.** A session whose working directory is `/` or
   the home folder is refused for `scan_project`, `check_exposure` and
   `import_and_wrap`, with or without a `folder` argument. A sub-folder of home
   is still allowed as a session folder. The route also refuses a relative
   folder (400), not only a missing one, since a relative path would resolve
   against the app's cwd.
2. **S1, pre-fix evidence.** In the pre-fix run, `scan_project` with session
   `/` walked `/` read-only to depth 3, about 16 s. EnvScan already refuses
   `auth.json` and `credentials*` by name, so no credential file was read. The
   import test moved the process cwd to a temp folder first, so the pre-fix
   import only touched temp files.
3. **S2, busy at quit time.** The background updater keeps polling for the
   next quiet window (the same `waitForQuiet` gate, repeated), then starts the
   helper and quits back to back. It does not give up after `waitLimit`: the
   swap has already happened, and a later daily check could not redo it. While
   it waits, `inFlight` stays true, so the manual Update Now refuses to start a
   second install. If the person quits first, no helper runs; the new bundle
   is already in place, so the next launch is the new version, and the
   set-aside old bundle is removed by the existing launch-time sweep. If the
   spawn fails, the app logs it and keeps running instead of quitting into no
   restart. The real `UpdateInstaller.run()` cannot run offline (download,
   hdiutil, signing), so the behavioral test drives the production factory's
   real installer through its new `handOff`/`relaunch` seam. The
   source-position test for the pre-swap gate stays, because that gate sits in
   the part of `run()` that cannot run offline.
4. **S6, resolver semantics.** `Paths.resolvingAppSupport()` returns the real
   folder in production even when `KEYS_CATALOG` is set. Only an armed (test)
   process with `KEYS_CATALOG` gets that catalog's folder. This keeps a custom
   catalog from moving the uninstall's removal root next to it. `claude-plan.json`
   is optional, and absent under the tripwire (`liveStatus` and Doctor treat
   it as not there). `DoctorInstall.legacyBinary` became optional; nothing read
   it. `Paths.catalogDB` is removed, and the tests that used it as a shape now
   use `Paths.appSupport/catalog.db`. `grokBotHome` and `claudeDesktopHome`
   now derive from one `Paths.userApplicationSupport`, so the structural test
   can require exactly one Foundation lookup. The S6 tests call APIs that did
   not exist before the fix, so they cannot be compiled against pre-fix code.
   The pre-fix evidence is the grep the structural test encodes: 4 direct
   `Paths.appSupport` consumers (Doctor, KeysService, LoginItem, AppRuntime)
   and 3 Foundation lookups.
5. **S5, already-on state.** When sharing is already on, `enabled: true`
   answers `{"enabled": true}` (the true state) instead of a pending answer
   that would be false. A pending "on" writes no log line, because nothing
   changed. Rule 7 of the frozen server instructions is unchanged and still
   true. The README tool paragraph (not the headline) and `docs/agents.md`
   were updated with the tool description and `docs/product-analytics.md`.
6. **S7, base URLs from a legacy backup.** A legacy in-project backup never
   decides a `*_BASE_URL` companion. As the brief says, the current line is
   kept and reported in `companions_left`, not removed by the fallback.
   Pre-0.14 wraps with a custom base URL therefore keep the gateway URL in that
   line after unwrap and are told so. All of the file's legacy backups are
   deleted, but only when every line restored. The containment re-check is
   "the recorded canonical path still realpaths to itself". It runs before the
   read, where it is reported as a per-file message and nothing is written,
   and again right before the swap, where it throws.
7. **S3 thresholds.** A separator-free run of 24+ characters with upper case,
   lower case and at least one digit is refused. So is uppercase hex of 32+.
   The custom prefixes come from `Providers.overlayRecords()`, which the
   service loads from the catalog. The dashboard UI mock that mirrored the old
   echoing message was updated to the new text.
8. **I2.** Unicode format characters (bidi overrides, zero-width) are dropped
   along with control characters. A label over 60 characters is cut to 59 plus
   an ellipsis.
9. **I3.** Only the file form's prompt changed. The project form revokes the
   project's tokens unconditionally at the end of the call, so its wording was
   already accurate.

## Not changed

- The informational O7 (partial-rewrite message), O9 (`rename` vs `openat`
  residual race), F4 (base64 variants) and the Docker-preference note are
  outside this brief's list and were left as they are.
- `docs/missions/014-integration.md`, `Site/` and the README headline are
  untouched.
