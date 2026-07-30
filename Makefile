.PHONY: bootstrap format format-check lint test coverage check ios-check ios-test acceptance app dist notarize clean

# Where the Xcode build lands. Inside .build so `make clean` and .gitignore
# already cover it.
XCODE_DERIVED := .build/xcode
APP := $(XCODE_DERIVED)/Build/Products/Release/Artscribe.app
DIST := dist
VERSION := $(shell awk -F'"' '/MARKETING_VERSION/ {print $$2; exit}' project.yml)

# Signing. Ad-hoc unless you say otherwise, so a clean checkout builds a
# runnable app with no account, no certificate and no configuration.
#
# With an Apple Developer account, set these in your shell (or CI) and change
# nothing in the repository:
#
#   ARTSCRIBE_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   ARTSCRIBE_TEAM_ID=TEAMID
#   ARTSCRIBE_HARDENED_RUNTIME=YES
#
# `make notarize` then submits the zip and staples the ticket.
ARTSCRIBE_SIGN_IDENTITY ?= -
ARTSCRIBE_TEAM_ID ?=
ARTSCRIBE_HARDENED_RUNTIME ?= NO
export ARTSCRIBE_SIGN_IDENTITY
export ARTSCRIBE_TEAM_ID
export ARTSCRIBE_HARDENED_RUNTIME

bootstrap:
	brew list rubberband >/dev/null 2>&1 || brew install rubberband
	brew list swiftlint  >/dev/null 2>&1 || brew install swiftlint
	brew list xcodegen   >/dev/null 2>&1 || brew install xcodegen
	brew list pre-commit >/dev/null 2>&1 || brew install pre-commit
	pre-commit install

# swift format ships with the Swift 6.3 toolchain.
format:
	swift format --in-place --recursive Package.swift Sources Tests

format-check:
	swift format lint --strict --recursive Package.swift Sources Tests

lint:
	swiftlint lint --quiet --strict

test:
	swift test

coverage:
	swift test --enable-code-coverage

# The single gate. Run before every commit.
check: format-check lint test

# Proof that the audio stack is still portable.
#
# `ArtscribeKit`, `AudioDecode`, `Waveform`, `TimeStretch` and `Playback` build for
# iOS; `ArtscribeUI` and above are AppKit and do not. Nothing in a macOS build
# notices when that stops being true — an `AVAudioSession` call, an AppKit import,
# a HAL property left outside its `#if` — so it is compiled for real against the
# iOS SDK rather than reasoned about.
#
# Deliberately not part of `check`: it needs the iOS SDK and takes about a minute
# against `check`'s three seconds. CI runs it as its own job.
ios-check:
	xcodebuild build -scheme Playback -destination 'generic/platform=iOS' \
	    -derivedDataPath $(XCODE_DERIVED)-ios -quiet

# The portable suites, actually *run* on an iPad simulator rather than merely
# compiled for one. Regenerates the project first because the test bundle is
# declared in project.yml and the .xcodeproj is gitignored.
#
# A named simulator, not `generic/platform=iOS Simulator`: `xcodebuild test`
# refuses a generic destination, and says only "Unable to find a device matching
# the provided destination specifier". Override with `SIM=`.
SIM ?= iPad (A16)
ios-test:
	xcodegen generate
	xcodebuild test -scheme ArtscribePortableTests \
	    -destination 'platform=iOS Simulator,name=$(SIM)' \
	    -derivedDataPath $(XCODE_DERIVED)-iostest \
	    | grep -E "Test run with|Suite .* (passed|failed)|error:|TEST (SUCCEEDED|FAILED)"

# The acceptance harness, with the display held awake.
#
# `caffeinate -dimsu` is not a nicety. `model.playhead` is polled by
# `PlayheadClock`'s `CADisplayLink` on `NSScreen.main`, and when the display
# sleeps that link stops: the value freezes while audio renders normally, and
# every position-based check fails at once — "0 frames", "0 wraps observed over
# 18 s". It looks exactly like a looping bug and is not one. Measured on
# 2026-07-30: 13 failures without it, 0 with, on identical code.
#
#   make acceptance AUDIO=/path/to/track.flac
#   make acceptance AUDIO=... ARGS='--only loop'
#
# It takes the foreground and the keyboard. Checks that need a key window skip
# themselves rather than fail if you use the machine during the run, so the
# summary will say NOT CHECKED — leave it alone for the three minutes.
AUDIO ?=
ARGS ?=
acceptance:
	@test -n "$(AUDIO)" || { echo "usage: make acceptance AUDIO=<file> [ARGS='--only loop']"; exit 2; }
	swift build -c release --product ArtscribeAcceptance
	caffeinate -dimsu .build/release/ArtscribeAcceptance --acceptance "$(AUDIO)" $(ARGS)

# The double-clickable app. `project.yml` is the source of truth; the
# .xcodeproj it generates is disposable and gitignored, so it is rebuilt every
# time rather than trusted.
#
# Development still goes through SwiftPM — `swift run -c release ArtscribeApp`
# needs none of this, and `swift test` never touches Xcode. See README ▸
# Running Artscribe.
app:
	xcodegen generate
	xcodebuild -project Artscribe.xcodeproj -scheme Artscribe \
		-configuration Release -derivedDataPath $(XCODE_DERIVED) \
		build | grep -E '^(error|warning|\*\*)|embedded' || true
	@test -d "$(APP)" || { echo "no app at $(APP)"; exit 1; }
	@# Ad-hoc, over the whole bundle. Xcode signs the executable; the embedded
	@# dylibs were re-signed by the post-build script after install_name_tool
	@# rewrote them, so this seals the result.
	@# With a real Developer ID the timestamp is required (notarisation rejects
	@# an untrusted-timestamp signature) and the hardened runtime has to be
	@# asked for here too, because this re-sign supersedes Xcode's.
	@if [ "$(ARTSCRIBE_SIGN_IDENTITY)" = "-" ]; then \
		codesign --force --sign - --timestamp=none "$(APP)"; \
	else \
		codesign --force --sign "$(ARTSCRIBE_SIGN_IDENTITY)" --timestamp \
			--options runtime --entitlements App/Artscribe.entitlements "$(APP)"; \
	fi
	codesign --verify --strict --verbose=2 "$(APP)"
	@# Says plainly which kind of signature came out, because "it built" and
	@# "it will open on somebody else's Mac" are different facts.
	@if [ "$(ARTSCRIBE_SIGN_IDENTITY)" = "-" ]; then \
		echo "signed AD-HOC — fine locally, rejected by Gatekeeper on download"; \
	else \
		echo "signed with a real identity — run 'make notarize' next"; \
		codesign -dv --verbose=2 "$(APP)" 2>&1 \
			| awk -F'[=:]' '/^Authority=/ && ++n == 1 { print "  certificate kind:", $$2 }'; \
		codesign -dv --verbose=2 "$(APP)" 2>&1 \
			| grep -q "^Authority=Developer ID Application" \
			|| echo "  NOT a Developer ID — Gatekeeper will reject this on download"; \
	fi
	@echo
	@echo "built $(APP)"
	@echo "open it with:  open '$(APP)'"

# A zip of the signed bundle. `ditto` rather than `zip`: it is the only archiver
# that preserves the code signature and the resource forks intact, and an app
# that arrives with a broken signature is worse than one that arrives unsigned.
dist: app
	rm -rf "$(DIST)"
	mkdir -p "$(DIST)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/Artscribe-$(VERSION).zip"
	@echo
	@echo "wrote $(DIST)/Artscribe-$(VERSION).zip"
	@shasum -a 256 "$(DIST)/Artscribe-$(VERSION).zip"

# Submits the zip to Apple, waits for the verdict, and staples the ticket into
# the bundle so it opens on a Mac that is offline.
#
# Needs credentials, and the least awkward form is a keychain profile made once:
#
#   xcrun notarytool store-credentials artscribe-notary \
#       --apple-id you@example.com --team-id TEAMID \
#       --password <app-specific-password>
#
# App-specific password, not your Apple ID password — appleid.apple.com ▸
# Sign-In and Security ▸ App-Specific Passwords. In CI, use an App Store
# Connect API key instead (see .github/workflows/release.yml).
#
# The bundle is re-zipped afterwards: stapling writes into the .app, so the
# archive made before it does not carry the ticket.
NOTARY_PROFILE ?= artscribe-notary

notarize: dist
	@test "$(ARTSCRIBE_SIGN_IDENTITY)" != "-" || { \
		echo "notarisation needs a Developer ID; set ARTSCRIBE_SIGN_IDENTITY"; exit 1; }
	@# `notarytool submit --wait` exits 0 even when the verdict is Invalid, so
	@# the status has to be read rather than inferred from the exit code. Without
	@# this the recipe walked on to `stapler`, which failed with a "Record not
	@# found" and error 65 — an error about the wrong thing entirely, three steps
	@# after the real one.
	@set -e; \
	id=$$(xcrun notarytool submit "$(DIST)/Artscribe-$(VERSION).zip" \
		--keychain-profile "$(NOTARY_PROFILE)" --wait --output-format json \
		| tee /dev/stderr | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'); \
	status=$$(xcrun notarytool info "$$id" --keychain-profile "$(NOTARY_PROFILE)" \
		--output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'); \
	if [ "$$status" != "Accepted" ]; then \
		echo; echo "notarisation $$status — Apple's reasons:"; \
		xcrun notarytool log "$$id" --keychain-profile "$(NOTARY_PROFILE)"; \
		exit 1; \
	fi
	xcrun stapler staple "$(APP)"
	rm -f "$(DIST)/Artscribe-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/Artscribe-$(VERSION).zip"
	@echo
	@# The honest end-to-end check: this is what Gatekeeper will say on the
	@# recipient's Mac, and it is the only one that proves the whole chain.
	spctl --assess --type execute --verbose=4 "$(APP)"
	@shasum -a 256 "$(DIST)/Artscribe-$(VERSION).zip"

clean:
	rm -rf .build Artscribe.xcodeproj $(DIST) App/Artscribe.icns
