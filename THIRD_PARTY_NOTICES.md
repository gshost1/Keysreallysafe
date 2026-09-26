# Third-party and prior-license notices

Keysrs is MIT-licensed (`LICENSE`). The components below keep their own
licenses and notices.

## Swift Argument Parser

Version 1.8.2, revision `6a52f3251125d74daf04fcbd5e6f08a75d074382`.
Source: https://github.com/apple/swift-argument-parser

Copyright (c) 2020 Apple Inc. and the Swift project authors.
Licensed under Apache License 2.0 with Swift Runtime Library Exception.
The complete upstream text is in `licenses/swift-argument-parser.txt`.
The resolved checkout has no top-level NOTICE file. The binary links this
library; include its license with releases regardless of exception eligibility.

## Earlier Keysreallysafe material

The previous root MIT notice is preserved in
`licenses/Keysreallysafe-legacy-MIT.txt`. It covers material released before the
2026-09-22 notice; `LICENSE` now covers the whole repository.

## Development and system components

Playwright (Apache-2.0), pinned in `scripts/tests/package.json`, is a
test-only dependency for the dashboard browser suites; its license metadata
remains in `scripts/tests/package-lock.json` and the release packager never
includes it. If dependencies are bundled in a later release, review and
include their actual license texts before distribution.
macOS frameworks and the system SQLite library are linked, not copied into
the release. The app has no Node or Python runtime prerequisite. Model-price/catalog data is not
made exclusively owned by this notice; provider data terms need review if
redistributed commercially.
