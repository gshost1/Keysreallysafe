.PHONY: build release app

build:
	swift build
	python3 scripts/sign-local.py .build/debug/keys

release:
	swift build -c release
	python3 scripts/sign-local.py .build/release/keys

# Keysrs.app in .build/app, re-signed with the persistent Apple Development identity.
app:
	swift build -c release
	python3 scripts/build-app.py --replace
	python3 scripts/sign-local.py .build/app/Keysrs.app
