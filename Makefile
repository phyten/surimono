.DEFAULT_GOAL := help

CONFIGURATION ?= Debug
DERIVED_DATA ?= build/DerivedData
VERSION ?= $(shell sed -n 's/^MARKETING_VERSION = //p' Configs/Base.xcconfig)
# The app version must be X.Y.Z, so a prerelease such as 0.2.0-beta.1 keeps its suffix in VERSION (file names) only.
MARKETING_VERSION ?= $(VERSION)
BUILD_NUMBER ?= 1
FILE ?=
BENCH_THRESHOLD ?= 20
SWIFT_TEST_FLAGS ?=
SECONDS ?= 600
SEED ?= 1
FORMAT ?=
START ?= 0
COUNT ?=
REPLAY ?=
SANITIZE ?=
SHORT ?=
FIXED ?=

XCODEBUILD = xcodebuild -quiet -project Surimono.xcodeproj -scheme Surimono -derivedDataPath "$(DERIVED_DATA)" -destination 'platform=macOS'
SWIFT_TEST = swift test --package-path Packages/SurimonoKit
SWIFT_PATHS = Tools/PageAX/Package.swift Tools/PageAX/Sources Tools/PageAX/Tests Tools/Snapshots/Package.swift Tools/Snapshots/Sources Tools/Snapshots/Tests Tools/LaTeXCoverage/Package.swift Tools/LaTeXCoverage/Sources Tools/LaTeXCoverage/Tests App QuickLook AppTests Packages/SurimonoKit/Sources Packages/SurimonoKit/Tests
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Surimono.app
RELEASE_APP = $(DERIVED_DATA)/Build/Products/Release/Surimono.app
# Both app targets make Surimono.app (the menu bar shows PRODUCT_NAME), so the App Store app gets derived data of its own.
APP_STORE_DERIVED_DATA ?= build/DerivedData-AppStore
APP_STORE_APP = $(APP_STORE_DERIVED_DATA)/Build/Products/Release/Surimono.app

.PHONY: help build run test test-kit test-formats test-core rst-compare latex-dump latex-coverage latex-coverage-compare latex-line-dump latex-line-dump-webkit test-rendering test-app bench bench-compare lint format package build-appstore check-appstore clean

help:
	@echo "build      Build the app (Debug by default)"
	@echo "run        Build and launch; optionally FILE=Samples/sample.md"
	@echo "test       Run package and hosted app tests"
	@echo "test-kit   Run SurimonoKit tests (Formats, Core, then Rendering)"
	@echo "test-kit-asan / test-kit-tsan  Run Kit tests with AddressSanitizer / ThreadSanitizer"
	@echo "robustness Feed damaged documents to every reader: SECONDS=600 [FORMAT=latex] [SEED=1] [START=0 COUNT=1] [REPLAY=<file>]"
	@echo "           SHORT=1 leaves out the long hand-written cases, FIXED=1 runs only them and the regressions"
	@echo "robustness-rendering  Typeset unusual pages in the hidden WebView (few, slow)"
	@echo "test-formats Run the SurimonoFormats tests"
	@echo "test-core  Run the SurimonoCore tests"
	@echo "rst-compare Compare the Swift RST reader with rst2html5 on the fixture corpus"
	@echo "latex-coverage  Read real manuscripts and count what the reader flags: DIR=<manuscripts> [OUT=] [BASELINE=<run>] [HTML=1]"
	@echo "latex-coverage-compare  Compare two coverage runs: BEFORE=<run> AFTER=<run>"
	@echo "test-rendering  Run the SurimonoRendering tests, one at a time"
	@echo "test-app   Run hosted app tests"
	@echo "snapshots  Render local snapshots; snapshots-report compares and snapshots-approve accepts reviewed cases"
	@echo "bench      Record rendering benchmarks (SURIMONO_BENCH_RUNS / SURIMONO_BENCH_OUT)"
	@echo "bench-source  Measure source conversion, first/all pages and memory (bench-source-conversion skips WebKit)"
	@echo "bench-latex-class  Measure main-thread LaTeX class detection in Release"
	@echo "bench-prose  Time the writing check on generated Japanese, English and mixed texts (SURIMONO_BENCH_RUNS)"
	@echo "bench-compare  Compare medians: BASE=<json> NEW=<json> [BENCH_THRESHOLD=20]"
	@echo "lint       Check Swift formatting"
	@echo "format     Format Swift sources"
	@echo "package    Build Release, verify signing, and create DMG + ZIP with SHA-256"
	@echo "build-appstore  Build the sandboxed Mac App Store app (target Surimono App Store, Release)"
	@echo "check-appstore  Build it and check that it is sandboxed and carries no Sparkle"
	@echo "clean      Remove build products"

build:
	$(XCODEBUILD) -configuration "$(CONFIGURATION)" build

# open -a looks up a relative path as an application name and fails, so pass an absolute path.
run: build
	open -a "$$(realpath "$(APP)")" $(if $(strip $(FILE)),"$(FILE)")

# The package tests and the hosted app tests do not run at the same time. Measured locally, running test-kit beside
# test-app failed 2 of 4 runs (and 2 of 2 with test-kit niced), each time in a different hosted test that depends on
# waits (FileWatcherTests, WebPageKeyTests, PrintThemePaletteTests), against 0 of 6 sequential runs, and it saved only
# about 20% of the time.
test: test-kit test-app test-tools

# The Rendering tests drive WebKit against timeouts. Run alongside the CPU-heavy Core tests on a slow CI runner, they
# timed out, so the targets run one after the other. Run in parallel on a fresh CI runner, several of them still
# timed out together (on 1 of 10 runners in a comparison, against 0 of 10 run serially), so the Rendering tests also
# run one at a time; run in parallel locally, some of them also fail because they share WebKit and static state. Custom
# flags run once as given: SwiftPM joins several --filter options with "or", which would undo the split.
test-kit:
ifeq ($(strip $(SWIFT_TEST_FLAGS)),)
	$(SWIFT_TEST) --filter SurimonoFormatsTests
	$(SWIFT_TEST) --filter SurimonoCoreTests
	$(SWIFT_TEST) --filter SurimonoRenderingTests --no-parallel
else
	$(SWIFT_TEST) $(SWIFT_TEST_FLAGS)
endif

# CI runs Formats and Core on one runner and Rendering on another.
# A reader's wall-clock deadline includes time waiting for a CPU. On the hosted runner,
# run the cases individually so that the rest of the suite cannot starve that reader.
test-formats:
	$(SWIFT_TEST) --filter SurimonoFormatsTests $(if $(GITHUB_ACTIONS),--no-parallel)

test-core:
	$(SWIFT_TEST) --filter SurimonoCoreTests

rst-compare:
	SURIMONO_RST_LIVE=1 SURIMONO_RST_FIXTURES="$(abspath Packages/SurimonoKit/Tests/SurimonoFormatsTests/Fixtures/RST)" $(SWIFT_TEST) --filter 'RSTOracleTests|RSTClipboardTests'

latex-dump:
	@test -n "$(DIR)" || { echo "Usage: make latex-dump DIR=<directory>" >&2; exit 2; }
	SURIMONO_LATEX_DUMP="$(abspath $(DIR))" $(SWIFT_TEST) --filter LaTeXCorpusDumpTests

# DIR here is where the manuscripts are (one folder each, or a manifest.json); latex-dump's DIR is its output.
# The manuscripts stay outside the repository. OUT defaults to build/latex-coverage/<time>; BASELINE is an earlier OUT.
LATEX_COVERAGE = swift run -c release --package-path Tools/LaTeXCoverage latex-coverage
latex-coverage:
	@test -n "$(DIR)" || { echo "Usage: make latex-coverage DIR=<manuscripts> [OUT=<run>] [BASELINE=<run>] [MANIFEST=<file>] [HTML=1]" >&2; exit 2; }
	$(LATEX_COVERAGE) run "$(abspath $(DIR))" "$(abspath $(or $(OUT),build/latex-coverage/$(shell date +%Y%m%d-%H%M%S)))" \
		$(if $(MANIFEST),--manifest "$(abspath $(MANIFEST))") $(if $(BASELINE),--baseline "$(abspath $(BASELINE))") $(if $(HTML),--html)

latex-coverage-compare:
	@test -n "$(BEFORE)" -a -n "$(AFTER)" || { echo "Usage: make latex-coverage-compare BEFORE=<run> AFTER=<run>" >&2; exit 2; }
	$(LATEX_COVERAGE) compare "$(abspath $(BEFORE))" "$(abspath $(AFTER))"

# Keep the opt-in measurement harness out of normal rendering and the ordinary test run.
latex-line-dump:
	@test -n "$(DIR)" || { echo "Usage: make latex-line-dump DIR=<directory> CHROMIUM=<headless executable>" >&2; exit 2; }
	@set -e; inputs=$$(mktemp -d); trap 'rm -rf "$$inputs"' EXIT; \
	SURIMONO_LATEX_LINE_INPUTS="$$inputs" $(SWIFT_TEST) --filter LaTeXLatinCorpusInputs; \
	SURIMONO_LATEX_LINE_DUMP="$(abspath $(DIR))" node Benchmarks/dump-latex-lines.mjs "$$inputs"; \
	SURIMONO_LATEX_LINE_DUMP="$(abspath $(DIR))/timing" node Benchmarks/dump-latex-lines.mjs "$$inputs/timing"; \
	SURIMONO_LATEX_TIMING_MEASUREMENTS="$(abspath $(DIR))/timing" $(SWIFT_TEST) --filter LaTeXLatinCorpusInputs/measuredPageCounts

# The native export includes the actual page-reference passes and final document line plan.
# PDF=1 also exports each reading PDF. BOXES=1 adds the measured word boxes for diagnosis.
latex-line-dump-webkit:
	@test -n "$(DIR)" || { echo "Usage: make latex-line-dump-webkit DIR=<directory> [PDF=1] [BOXES=1]" >&2; exit 2; }
	SURIMONO_LATEX_WEBKIT_LINE_DUMP="$(abspath $(DIR))" SURIMONO_LATEX_WEBKIT_PDFS="$(PDF)" \
	SURIMONO_LATEX_WEBKIT_BOXES="$(BOXES)" $(SWIFT_TEST) --filter LaTeXWebKitLineDumpTests --no-parallel

test-rendering:
	$(SWIFT_TEST) --filter SurimonoRenderingTests --no-parallel

# Sanitized builds go to their own scratch paths, so they neither replace nor invalidate the ordinary debug build.
# Each target runs all three test targets even when one fails, and fails at the end if any did. The tests run one
# at a time: run side by side under AddressSanitizer, the Core tests took 224 to 401 seconds and several one-minute
# limits ran out (a test that needs 2.5 seconds alone took 94); one at a time they took 146 seconds.
.PHONY: test-kit-asan test-kit-tsan robustness robustness-rendering
test-kit-asan test-kit-tsan: SANITIZER = $(if $(filter test-kit-asan,$@),address,thread)
test-kit-asan test-kit-tsan:
	@status=0; \
	$(SWIFT_TEST) --sanitize=$(SANITIZER) --scratch-path build/sanitize/$(SANITIZER) --filter SurimonoFormatsTests \
		--no-parallel || status=1; \
	$(SWIFT_TEST) --sanitize=$(SANITIZER) --scratch-path build/sanitize/$(SANITIZER) --filter SurimonoCoreTests \
		--no-parallel || status=1; \
	$(SWIFT_TEST) --sanitize=$(SANITIZER) --scratch-path build/sanitize/$(SANITIZER) --filter SurimonoRenderingTests \
		--no-parallel || status=1; \
	exit $$status

# Long and local. The readers run in child test processes, so the driver can name the input that ended one.
# SANITIZE=address reads under AddressSanitizer, from the same build as test-kit-asan.
ROBUSTNESS_BUILD = $(if $(strip $(SANITIZE)),--sanitize=$(SANITIZE) --scratch-path build/sanitize/$(SANITIZE))
robustness:
	swift build --package-path Packages/SurimonoKit --build-tests $(ROBUSTNESS_BUILD)
	python3 Benchmarks/robustness.py --seconds "$(SECONDS)" --seed "$(SEED)" --start "$(START)" \
		$(if $(strip $(FORMAT)),--format "$(FORMAT)") $(if $(strip $(COUNT)),--count "$(COUNT)") \
		$(if $(strip $(REPLAY)),--replay "$(REPLAY)") $(if $(strip $(SHORT)),--short) \
		$(if $(strip $(FIXED)),--fixed-only) -- $(SWIFT_TEST) $(ROBUSTNESS_BUILD)

robustness-rendering:
	SURIMONO_ROBUSTNESS_WEB=1 $(SWIFT_TEST) --filter RenderingRobustnessTests --no-parallel

bench:
	SURIMONO_BENCH=1 swift test --package-path Packages/SurimonoKit --disable-sandbox --filter RenderingBenchmarks --no-parallel

# A fresh test process per input keeps earlier WebKit sessions out of the footprint.
.PHONY: bench-source bench-source-conversion
bench-source bench-source-conversion:
	@set -e; for input in 1000 10000 50000 over-highlight; do \
		SURIMONO_BENCH_SOURCE=$$input SURIMONO_BENCH_SOURCE_RENDER=$(if $(filter bench-source,$@),1,0) \
		$(SWIFT_TEST) --disable-sandbox --filter SourceTypesettingBenchmarks --no-parallel; \
	done

.PHONY: bench-latex-class
bench-latex-class:
	SURIMONO_BENCH_LATEX_CLASS=1 $(SWIFT_TEST) --disable-sandbox -c release -debug-info-format none --filter LaTeXClassBenchmarks --no-parallel

.PHONY: bench-large-text
bench-large-text:
	@set -e; for input in text1MB text10MB text50MB csv10k csv100k csv500k; do \
		SURIMONO_BENCH_LARGE_TEXT=$$input $(SWIFT_TEST) --filter LargeTextConversionBenchmarks --no-parallel; \
	done

.PHONY: bench-pages bench-pages-rendering bench-pages-window
bench-pages: bench-pages-rendering bench-pages-window

bench-pages-rendering:
	@set -e; for input in booklet pdf-300 deck images-20; do \
		SURIMONO_BENCH_PAGES=1 SURIMONO_BENCH_PAGE_INPUT=$$input $(SWIFT_TEST) --disable-sandbox --filter PageThumbnailBenchmarks --no-parallel; \
	done

.PHONY: bench-scrubber bench-scrubber-rendering bench-scrubber-window
bench-scrubber: bench-scrubber-rendering bench-scrubber-window

bench-scrubber-rendering:
	@set -e; for input in booklet pdf-300 pdf-2000 deck; do \
		SURIMONO_BENCH_SCRUB=1 SURIMONO_BENCH_PAGES=1 SURIMONO_BENCH_PAGE_INPUT=$$input $(SWIFT_TEST) --disable-sandbox --filter PageThumbnailBenchmarks --no-parallel; \
	done

bench-scrubber-window:
	TEST_RUNNER_SURIMONO_BENCH_SCRUB=1 $(filter-out -quiet,$(XCODEBUILD)) -configuration Debug -only-testing:SurimonoTests/PageScrubberWindowBenchmarks test

bench-pages-window:
	TEST_RUNNER_SURIMONO_BENCH_PAGES=1 $(filter-out -quiet,$(XCODEBUILD)) -configuration "$(CONFIGURATION)" -only-testing:SurimonoTests/PageDrawerWindowBenchmarks test

# The writing check alone: no WebKit, so it needs neither the sandbox off nor a serial run.
.PHONY: bench-prose
bench-prose:
	SURIMONO_BENCH_PROSE=1 $(SWIFT_TEST) --filter ProseCheckBenchmarks

bench-compare:
	python3 Benchmarks/compare.py "$(BASE)" "$(NEW)" --threshold "$(BENCH_THRESHOLD)"

test-app:
	$(XCODEBUILD) -configuration "$(CONFIGURATION)" test

lint:
	xcrun swift-format lint --strict --recursive --parallel $(SWIFT_PATHS)

format:
	xcrun swift-format format --in-place --recursive --parallel $(SWIFT_PATHS)

package:
	$(XCODEBUILD) -configuration Release MARKETING_VERSION="$(MARKETING_VERSION)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" build
	codesign --verify --deep --strict "$(RELEASE_APP)"
	mkdir -p build/release
	ditto -c -k --keepParent "$(RELEASE_APP)" "build/release/Surimono-$(VERSION).zip"
	cd build/release && shasum -a 256 "Surimono-$(VERSION).zip" > "Surimono-$(VERSION).zip.sha256"
# The disk image holds the app next to a link to /Applications, so installing is one drag. hdiutil on CI runners
# sometimes fails with "Resource busy", so it gets a few tries.
	rm -rf build/dmg
	set -e; trap 'rm -rf build/dmg' EXIT; \
	mkdir -p build/dmg; \
	ditto "$(RELEASE_APP)" build/dmg/Surimono.app; \
	ln -s /Applications build/dmg/Applications; \
	for attempt in 1 2 3; do \
		if hdiutil create -volname Surimono -srcfolder build/dmg -ov -format UDZO "build/release/Surimono-$(VERSION).dmg"; then break; fi; \
		[ $$attempt -lt 3 ] || exit 1; sleep 5; \
	done
	cd build/release && shasum -a 256 "Surimono-$(VERSION).dmg" > "Surimono-$(VERSION).dmg.sha256"

build-appstore:
	xcodebuild -quiet -project Surimono.xcodeproj -scheme "Surimono App Store" -derivedDataPath "$(APP_STORE_DERIVED_DATA)" -destination 'platform=macOS' -configuration Release build

# The App Store build must be sandboxed and must not carry or load Sparkle: the App Store updates the app.
check-appstore: build-appstore
	test -x "$(APP_STORE_APP)/Contents/PlugIns/SurimonoQuickLook.appex/Contents/MacOS/SurimonoQuickLook"
	@set -eu; app="$(APP_STORE_APP)/Contents/Info.plist"; ext="$(APP_STORE_APP)/Contents/PlugIns/SurimonoQuickLook.appex/Contents/Info.plist"; \
	for key in CFBundleShortVersionString CFBundleVersion; do \
		parent="$$(plutil -extract "$$key" raw "$$app")"; child="$$(plutil -extract "$$key" raw "$$ext")"; \
		test -n "$$parent" && test "$$child" = "$$parent" || { echo "Quick Look: $$key mismatch"; exit 1; }; \
	done; \
	parent="$$(plutil -extract CFBundleIdentifier raw "$$app")"; child="$$(plutil -extract CFBundleIdentifier raw "$$ext")"; \
	test "$$child" = "$$parent.QuickLook"
	@set -eu; signed="$$(codesign -d --entitlements - --xml "$(APP_STORE_APP)/Contents/PlugIns/SurimonoQuickLook.appex")"; \
	entitlements="$$(printf '%s' "$$signed" | plutil -convert json -o - -)"; \
	printf '%s' "$$entitlements" | jq -e 'type == "object" and .["com.apple.security.app-sandbox"] == true and .["com.apple.security.files.user-selected.read-only"] == true and (.["com.apple.security.network.client"] != true) and (.["com.apple.security.network.server"] != true) and all(keys[]; startswith("com.apple.security.temporary-exception") | not)' >/dev/null
	codesign -d --entitlements - --xml "$(APP_STORE_APP)" 2>/dev/null | grep -q '<key>com.apple.security.app-sandbox</key><true/>'
	frameworks="$$(find "$(APP_STORE_APP)" -name Sparkle.framework -print)" && test -z "$$frameworks"
	libraries="$$(otool -L "$(APP_STORE_APP)/Contents/MacOS/Surimono")" && ! printf '%s\n' "$$libraries" | grep -q Sparkle
	info="$$(plutil -convert json -o - "$(APP_STORE_APP)/Contents/Info.plist")" && printf '%s\n' "$$info" | jq -e 'type == "object" and all(.. | objects | keys[]; startswith("SU") | not)' >/dev/null
	plutil -lint "$(APP_STORE_APP)/Contents/Resources/PrivacyInfo.xcprivacy"
	private_api="$$(strings "$(APP_STORE_APP)/Contents/MacOS/Surimono")" && ! printf '%s\n' "$$private_api" | grep -q '_setDrawsBackground'
	@echo "AppStore build: sandboxed, no Sparkle, no private background API"

clean:
	rm -rf build "$(DERIVED_DATA)" "$(APP_STORE_DERIVED_DATA)" Packages/SurimonoKit/.build

.PHONY: snapshots snapshots-selfcheck snapshots-report snapshots-approve snapshots-reference snapshots-baseline test-tools
SNAPSHOTS = swift run -c release --package-path Tools/Snapshots surimono-snapshots
export ONLY REF FORCE_SCALE
SNAPSHOT_RUN ?= $(shell date -u +%Y%m%d-%H%M%S)-$(shell uuidgen | cut -c1-8 | tr A-Z a-z)

test-tools:
	swift test --package-path Tools/PageAX
	swift test --package-path Tools/Snapshots
	swift test --package-path Tools/LaTeXCoverage

snapshots:
	$(MAKE) build CONFIGURATION=Debug
	$(SNAPSHOTS) render "$(abspath $(DERIVED_DATA))/Build/Products/Debug/Surimono.app" "$(SNAPSHOT_RUN)"

snapshots-selfcheck:
ifneq ($(strip $(FIRST)$(SECOND)),)
	$(SNAPSHOTS) selfcheck-files "$(FIRST)" "$(SECOND)"
else
	$(MAKE) build CONFIGURATION=Debug
	$(SNAPSHOTS) selfcheck "$(abspath $(DERIVED_DATA))/Build/Products/Debug/Surimono.app" "$(SNAPSHOT_RUN)"
endif

snapshots-report:
	$(SNAPSHOTS) report

snapshots-approve:
	$(SNAPSHOTS) approve

snapshots-reference:
	$(SNAPSHOTS) reference

snapshots-baseline:
	@Tools/Snapshots/baseline.sh "$(abspath $(DERIVED_DATA))"

.PHONY: math-corpus
math-corpus:
	@set -eu; files=$$(mktemp); trap 'rm -f "$$files"' EXIT; \
	git ls-files Samples AppTests Packages/SurimonoKit/Tests Snapshots/corpus Snapshots/fixtures Snapshots/specimen.md | \
		LC_ALL=C grep -Ei '\.(tex|latex|ltx|md|markdown|mdown|mkdn|mkd|qmd|rmd|rmarkdown|rst|rest|org|ipynb|asciidoc|adoc|dj|djot|textile|wiki|mediawiki|wikitext|docx)$$' | \
		grep -vE '/README\.md$$' | LC_ALL=C sort > "$$files"; \
	SURIMONO_MATH_CORPUS="$$files" $(SWIFT_TEST) --filter AppMathCorpusTests
