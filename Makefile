.PHONY: bootstrap format format-check lint test coverage check ios-check ios-test acceptance \
	ipad ipad-build ipad-install ipad-container app dist notarize clean

# Where the Xcode build lands. Inside .build so `make clean` and .gitignore
# already cover it.
XCODE_DERIVED := .build/xcode
# The product name, read from project.yml rather than repeated here — the
# rename to Artscripture found these paths by breaking them.
NAME := $(shell awk -F': ' '/PRODUCT_NAME:/ {print $$2; exit}' project.yml)
APP := $(XCODE_DERIVED)/Build/Products/Release/$(NAME).app
DIST := dist
VERSION := $(shell awk -F'"' '/MARKETING_VERSION/ {print $$2; exit}' project.yml)

# `CFBundleVersion`. App Store Connect keys uploads on it and refuses one it has
# already seen, so it must be unique and increasing — and a number nobody has to
# remember to bump is the only kind that stays that way. The commit count is
# both, and is derivable from any checkout rather than tracked in a file two
# branches would then conflict over.
#
# `project.yml` reads it as `$(ARTSCRIBE_BUILD_NUMBER:default=1)`, so a bare
# `xcodebuild` or a build from Xcode's UI still works; only builds that leave
# this machine need it to be real.
ARTSCRIBE_BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
export ARTSCRIBE_BUILD_NUMBER

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
# **Compiles `ArtscribeUI`, not just `Playback`.**
#
# It used to build the `Playback` scheme alone, on the reasoning that `Playback`
# is the top of the portable stack. That was true of the *audio* stack and false
# of the app: `ArtscribeUI` builds for iOS too, and nothing here ever compiled
# it. So an iOS-only error in the UI passed `make ios-check` and failed in CI
# instead — twice in one afternoon, both times `UIDevice.current` read from a
# nonisolated context, which macOS never sees because it takes the other branch
# of the `#if`.
#
# The iPad scheme is the honest check: it is the thing that ships. It needs the
# generated project, so `xcodegen` runs first — a second or two, against a
# round trip through CI.
ios-check:
	xcodegen generate
	xcodebuild build -scheme ArtscribeiPad -destination 'generic/platform=iOS Simulator' \
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

# Build, install and run on a connected iPad, with the console attached.
#
#   make ipad                       # build, install, launch, stream stdout/stderr
#   make ipad DEV=1                 # …with Playback > Developer > Stretch Engine
#   make ipad-install               # build and install only, no console
#
# The device is found by name so there is nothing to paste. `--console` keeps
# the process attached and streams its output, which is the only channel that
# reaches this terminal: `log stream` has no `--device-name` on this macOS, and
# `devicectl`'s own `--log-output` logs the tool, not the app. So anything you
# want to see from a device run has to be `print`ed or `FileHandle`-written by
# the app itself.
#
# Ctrl-C detaches the console; it does not kill the app.
#
# Requires Developer Mode on the iPad (Settings > Privacy & Security) and a
# signing team configured once in Xcode. `direnv exec` supplies ARTSCRIBE_TEAM_ID
# without it appearing in any command line or log.
IPAD_NAME ?= iPad
DEV ?=
# Both `available` and `connected` count: devicectl reports either depending on
# how recently the tunnel was used, and both can be built to.
#
# Matched by UUID pattern rather than by column: the Name column contains
# spaces ("iPad Pro M4"), so field-splitting picks up a fragment of the name.
IPAD_ID = $(shell xcrun devicectl list devices 2>/dev/null \
	| grep "$(IPAD_NAME)" | grep -E 'available|connected' \
	| grep -oE '[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}' | head -1)
IPAD_APP = .build/xcode-device/Build/Products/Debug-iphoneos/$(NAME).app

ipad-build:
	@test -n "$(IPAD_ID)" || { echo "No device matching '$(IPAD_NAME)' is connected. Plugged in, unlocked, Developer Mode on?"; exit 2; }
	xcodegen generate
	direnv exec . xcodebuild build -scheme ArtscribeiPad \
	    -destination 'platform=iOS,id=$(IPAD_ID)' \
	    -derivedDataPath .build/xcode-device -allowProvisioningUpdates -quiet

ipad-install: ipad-build
	xcrun devicectl device install app --device $(IPAD_ID) $(IPAD_APP)

ipad: ipad-install
	xcrun devicectl device process launch --console \
	    $(if $(DEV),--environment-variables '{"ARTSCRIBE_DEV_MENU":"1"}',) \
	    --device $(IPAD_ID) com.artscribe.Artscribe

# Everything the app has written into its container — the `.artscripture` sidecars
# and, most usefully, its UserDefaults. Reading that plist is how the Open Recent
# bookmark bug was diagnosed: the stored keys disagreed with the stored paths by
# exactly the `/private` prefix, which no amount of reading the code would have
# shown.
ipad-container:
	@test -n "$(IPAD_ID)" || { echo "No device matching '$(IPAD_NAME)' is connected."; exit 2; }
	rm -rf .build/ipad-container && mkdir -p .build/ipad-container
	xcrun devicectl device copy from --device $(IPAD_ID) \
	    --domain-type appDataContainer --domain-identifier com.artscribe.Artscribe \
	    --source Library/Preferences --destination .build/ipad-container
	@find .build/ipad-container -type f -print

# The double-clickable app. `project.yml` is the source of truth; the
# .xcodeproj it generates is disposable and gitignored, so it is rebuilt every
# time rather than trusted.
#
# Development still goes through SwiftPM — `swift run -c release ArtscribeApp`
# needs none of this, and `swift test` never touches Xcode. See README ▸
# Running Artscripture.
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
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/$(NAME)-$(VERSION).zip"
	@echo
	@echo "wrote $(DIST)/$(NAME)-$(VERSION).zip"
	@shasum -a 256 "$(DIST)/$(NAME)-$(VERSION).zip"

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
	id=$$(xcrun notarytool submit "$(DIST)/$(NAME)-$(VERSION).zip" \
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
	rm -f "$(DIST)/$(NAME)-$(VERSION).zip"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(DIST)/$(NAME)-$(VERSION).zip"
	@echo
	@# The honest end-to-end check: this is what Gatekeeper will say on the
	@# recipient's Mac, and it is the only one that proves the whole chain.
	spctl --assess --type execute --verbose=4 "$(APP)"
	@shasum -a 256 "$(DIST)/$(NAME)-$(VERSION).zip"

clean:
	rm -rf .build Artscribe.xcodeproj $(DIST) App/Artscribe.icns

# ---------------------------------------------------------------------------
# App Store submission (iPadOS)
# ---------------------------------------------------------------------------
#
# Separate from `dist`/`notarize`, which are the *macOS direct download* path.
# These two are the App Store path and share nothing with it: a different
# certificate (Apple Distribution, not Developer ID), a different destination,
# and no notarisation step — Apple notarises App Store builds itself.
#
# Credentials come from an App Store Connect **Team** API key with the **Admin**
# role, set in your .envrc. See README ▸ The App Store (iPadOS).
#
# App Manager is not enough, and it fails late: `archive` succeeds, then
# `-exportArchive` stops with FORBIDDEN_ERROR — "You haven't been given access
# to cloud-managed distribution certificates". App Manager can upload builds and
# edit metadata; only Account Holder or Admin may mint a *distribution*
# certificate, which is what automatic signing needs.
#
#   ARTSCRIBE_ASC_ISSUER_ID   the UUID at the top of the Integrations page
#   ARTSCRIBE_ASC_KEY_ID      the 10-character key ID
#   ARTSCRIBE_ASC_KEY_PATH    absolute path to AuthKey_<keyid>.p8
#
# An *individual* key cannot do this: Apple excludes them from the provisioning
# endpoints, which is exactly what `-allowProvisioningUpdates` uses to mint the
# distribution certificate and profile. That is why no certificate has to be
# created by hand.
ARCHIVE := $(XCODE_DERIVED)-archive/$(NAME).xcarchive
EXPORT := .build/export

# The three flags every App Store xcodebuild invocation needs. Kept in one
# variable so the two recipes cannot drift, and referenced rather than echoed —
# `make` prints the recipe otherwise, and these identify the account.
ASC_AUTH = -authenticationKeyPath "$(ARTSCRIBE_ASC_KEY_PATH)" \
	   -authenticationKeyID "$(ARTSCRIBE_ASC_KEY_ID)" \
	   -authenticationKeyIssuerID "$(ARTSCRIBE_ASC_ISSUER_ID)"

.PHONY: archive upload asc-check

# Fails early and by name rather than letting xcodebuild report something
# oblique forty seconds in.
asc-check:
	@for v in ARTSCRIBE_ASC_ISSUER_ID ARTSCRIBE_ASC_KEY_ID ARTSCRIBE_ASC_KEY_PATH; do \
	  eval "val=\$$$$v"; \
	  test -n "$$val" || { echo "$$v is not set — see README ▸ Signing"; exit 2; }; \
	done
	@test -f "$(ARTSCRIBE_ASC_KEY_PATH)" || { \
	  echo "no key file at ARTSCRIBE_ASC_KEY_PATH"; exit 2; }

archive: asc-check
	xcodegen generate
	@rm -rf "$(ARCHIVE)"
	@ARTSCRIBE_BUILD_NUMBER=$(ARTSCRIBE_BUILD_NUMBER) xcodebuild archive \
	    -project Artscribe.xcodeproj -scheme ArtscribeiPad \
	    -destination 'generic/platform=iOS' \
	    -archivePath "$(ARCHIVE)" \
	    -allowProvisioningUpdates $(ASC_AUTH) \
	    | grep -E '^(error|warning|\*\*)' || true
	@test -d "$(ARCHIVE)" || { echo "no archive was produced"; exit 1; }
	@echo "archived $(ARCHIVE) (build $(ARTSCRIBE_BUILD_NUMBER))"

# Exports a signed .ipa and uploads it.
#
# `ExportOptions.plist` is *generated* rather than tracked: it has to carry the
# team ID, and the project's rule is that the signing identity never lands in a
# tracked file or a build log. It goes under .build, which is gitignored.
#
# Two keys in it are not obvious and both have bitten people:
#
#   method = app-store-connect   — `app-store` is deprecated as of Xcode 26
#   manageAppVersionAndBuildNumber = false
#       defaults to YES, and Xcode then *rewrites* the build number, silently
#       undoing the `git rev-list --count HEAD` scheme that exists so App Store
#       Connect never sees the same one twice.
upload: archive
	@mkdir -p "$(EXPORT)"
	@printf '%s\n' \
	  '<?xml version="1.0" encoding="UTF-8"?>' \
	  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
	  '<plist version="1.0"><dict>' \
	  '<key>method</key><string>app-store-connect</string>' \
	  '<key>destination</key><string>export</string>' \
	  '<key>teamID</key><string>$(ARTSCRIBE_TEAM_ID)</string>' \
	  '<key>signingStyle</key><string>automatic</string>' \
	  '<key>uploadSymbols</key><true/>' \
	  '<key>manageAppVersionAndBuildNumber</key><false/>' \
	  '</dict></plist>' > "$(EXPORT)/ExportOptions.plist"
	@xcodebuild -exportArchive -archivePath "$(ARCHIVE)" \
	    -exportPath "$(EXPORT)" \
	    -exportOptionsPlist "$(EXPORT)/ExportOptions.plist" \
	    -allowProvisioningUpdates $(ASC_AUTH) \
	    | grep -E '^(error|warning|\*\*)' || true
	@ls "$(EXPORT)"/*.ipa >/dev/null 2>&1 || { echo "no .ipa was exported"; exit 1; }
	@echo "exported $$(ls "$(EXPORT)"/*.ipa)"
	@xcrun altool --upload-app -f "$$(ls "$(EXPORT)"/*.ipa)" -t ios \
	    --apiKey "$(ARTSCRIBE_ASC_KEY_ID)" --apiIssuer "$(ARTSCRIBE_ASC_ISSUER_ID)"
	@echo "uploaded. It appears in App Store Connect ▸ TestFlight after processing."
