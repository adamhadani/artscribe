.PHONY: bootstrap format format-check lint test coverage check app dist clean

# Where the Xcode build lands. Inside .build so `make clean` and .gitignore
# already cover it.
XCODE_DERIVED := .build/xcode
APP := $(XCODE_DERIVED)/Build/Products/Release/Artscribe.app
DIST := dist
VERSION := $(shell awk -F'"' '/MARKETING_VERSION/ {print $$2; exit}' project.yml)

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
	codesign --force --sign - --timestamp=none "$(APP)"
	codesign --verify --strict --verbose=2 "$(APP)"
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

clean:
	rm -rf .build Artscribe.xcodeproj $(DIST) App/Artscribe.icns
