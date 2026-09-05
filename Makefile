.PHONY: build release test codesign

build:
	swift build
	./scripts/codesign.sh .build/debug/keys

release:
	swift build -c release
	./scripts/codesign.sh .build/release/keys

test:
	swift test

codesign:
	./scripts/codesign.sh
