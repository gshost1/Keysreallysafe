# Licensing transition audit — 2026-09-22

## Decision and scope

The owner requested a non-MIT default for future development. The root LICENSE
now reserves rights in new first-party additions, subject to prior grants,
third-party licenses, and applicable law. It is not a customer EULA and grants
no paid-app use by itself. Before commercial distribution, identify the legal
licensor and supply reviewed customer terms covering use and update rights.

The working-tree baseline was `9a824a6fc752411959e044eb958ffdafefddb9c5`.
This identifies the inspected local commit, not a verified last public release.
All earlier distributed MIT material retains its permissions. Existing public
source is not made exclusive merely by this change. No release tag or Git
history was rewritten. Historical work logs saying MIT was unchanged describe
past work and remain intact; the owner's new instruction supersedes their
old implementation constraints for this transition.

## Evidence inspected

- 204 tracked files; root and plugin license files, README claims, About text,
  npm manifests/lockfile, Package.swift/Package.resolved, release allowlists,
  installer plugin staging, and source import declarations.
- Local reachable history: 37 commits, one author account (`flash2do`), and
  Claude co-author trailers. This is not proof of exclusive copyright ownership
  or a complete audit of assignments, copied code, forks, or remote branches.
- GitHub read-only metadata: `gshost1/Keysreallysafe` is PUBLIC, default branch
  `main`. No visibility change, commit, push, or new release was performed.
- Imported Jev code has documented MIT provenance through
  `gshost1/vercel-compaction` at `a23e181fbd3a0195788bc729d80238d10f5d1b9a`,
  derived from `tamaratran/fast-jev-compaction`. Its entire previous notice is
  preserved in the plugin LICENSE with explicit scope for future additions.
- Swift Argument Parser 1.8.2 checkout matches the pinned revision
  `6a52f3251125d74daf04fcbd5e6f08a75d074382`. Apache 2.0 plus Runtime Library
  Exception copied verbatim; no top-level upstream NOTICE found.
- All 103 npm lockfile dependency entries are development-only: 83 MIT,
  5 Apache-2.0, 12 MPL-2.0, 2 ISC, 1 BSD-3-Clause. None has missing license
  metadata. Metadata is not a file-by-file third-party legal opinion.
  The runtime imports local modules and Node built-ins; node_modules is excluded
  from the packaged app. Dependency licenses were not replaced.
- System frameworks/SQLite, external Node/Python runtimes, model catalog data,
  and optional container images are distinguished in THIRD_PARTY_NOTICES.md.
  Container image contents and provider data redistribution terms remain outside
  this source audit and need review before commercial redistribution.

## Changes

- Proprietary default for new first-party additions, with explicit preservation
  of old MIT grants and third-party rights.
- Root README, plugin README/metadata and app About text no longer advertise
  the entire future product as MIT. npm package marked private to prevent
  accidental registry publication; license points to its scoped LICENSE.
- Prior root MIT text preserved verbatim in licenses/Keysreallysafe-legacy-MIT.txt.
- Third-party notices and exact Swift dependency license added to release
  packaging. Plugin notice is self-contained and travels via existing installer
  and standalone npm package allowlists.
- Existing signed release artifacts, DMGs, deployed apps and public GitHub files
  remain unchanged. Future releases need rebuilding/signing and customer terms.

## Validation

Release tests verify required license files and byte-for-byte preservation in
packaged output, with node_modules and private files still excluded. Exact
legacy texts and dependency metadata preservation are checked against the
baseline. All 8 release-packaging tests and both Swift InstallerPackagingTests
passed. The Swift test run rebuilt the local debug binary only. Exact notice
preservation and unchanged third-party lockfile entries passed automated checks.

## Workflow-trial recording

Tracker status was attempted before edits and failed with the existing error:
Missing or duplicate task trial-01-04 in
/Users/Shost2/Desktop/docs/agent-work-log.jsonl; restore its log before continuing.
No duplicate task was enrolled. This was performed Codex-only as a focused
licensing/packaging update. Usage was not measured. Pre-existing changes to
Web/styles.css, docs/mvp-acceptance.md and
scripts/tests/test_keys_dashboard_ui.cjs were left untouched.
