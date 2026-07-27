.PHONY: bootstrap format lint test coverage check clean

bootstrap:
	brew list rubberband >/dev/null 2>&1 || brew install rubberband
	brew list swiftlint  >/dev/null 2>&1 || brew install swiftlint
	brew list xcodegen   >/dev/null 2>&1 || brew install xcodegen

# swift format ships with the Swift 6.3 toolchain.
format:
	swift format --in-place --recursive Sources Tests

format-check:
	swift format lint --strict --recursive Sources Tests

lint:
	swiftlint lint --quiet --strict

test:
	swift test

coverage:
	swift test --enable-code-coverage

# The single gate. Run before every commit.
check: format-check lint test

clean:
	rm -rf .build
