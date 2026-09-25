.PHONY: build release

build:
	swift build
	python3 scripts/sign-local.py .build/debug/keys

release:
	swift build -c release
	python3 scripts/sign-local.py .build/release/keys
