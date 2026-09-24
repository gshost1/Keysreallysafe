# Third-party and prior-license notices

Keysrs is MIT-licensed (`LICENSE`). The components below keep their own
licenses and notices.

## Jev optimizer / fast-jev-compaction

`Plugins/jev-optimizer` includes MIT-licensed code derived from
[tamaratran/fast-jev-compaction](https://github.com/tamaratran/fast-jev-compaction)
via [gshost1/vercel-compaction](https://github.com/gshost1/vercel-compaction/tree/a23e181fbd3a0195788bc729d80238d10f5d1b9a).
Its original notice, including `Copyright (c) 2025` and
`Copyright (c) 2026 gshost1`, is preserved verbatim in
`Plugins/jev-optimizer/LICENSE`. That file must accompany standalone plugin
packages and installed copies.

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

The optimizer's npm dependencies are development-only in its manifest; their
individual license metadata remains in `package-lock.json`. The release
packager excludes `node_modules`. If dependencies are bundled in a later
release, review and include their actual license texts before distribution.
macOS frameworks and the system SQLite library are linked, not copied into
the release. Node and Python are external runtime prerequisites. Container
images used for the optional collector retain their own licenses and need a
separate image audit when pinned/deployed. Model-price/catalog data is not
made exclusively owned by this notice; provider data terms need review if
redistributed commercially.
