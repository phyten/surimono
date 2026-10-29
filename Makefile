.DEFAULT_GOAL := help

CONFIGURATION ?= Debug
DERIVED_DATA ?= build/DerivedData
VERSION ?= $(shell sed -n 's/^MARKETING_VERSION = //p' Configs/Base.xcconfig)
BUILD_NUMBER ?= 1
FILE ?=
SWIFT_TEST_FLAGS ?=

XCODEBUILD = xcodebuild -quiet -project Surimono.xcodeproj -scheme Surimono -derivedDataPath "$(DERIVED_DATA)" -destination 'platform=macOS'
SWIFT_PATHS = App AppTests Packages/SurimonoKit/Sources Packages/SurimonoKit/Tests
APP = $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/Surimono.app
RELEASE_APP = $(DERIVED_DATA)/Build/Products/Release/Surimono.app

.PHONY: help build run test test-kit test-app lint format package clean

help:
	@echo "build      Build the app (Debug by default)"
	@echo "run        Build and launch; optionally FILE=Samples/sample.md"
	@echo "test       Run package and hosted app tests"
	@echo "test-kit   Run SurimonoKit tests"
	@echo "test-app   Run hosted app tests"
	@echo "lint       Check Swift formatting"
	@echo "format     Format Swift sources"
	@echo "package    Build Release, verify signing, and create ZIP + SHA-256"
	@echo "clean      Remove build products"

build:
	$(XCODEBUILD) -configuration "$(CONFIGURATION)" build

run: build
	open -a "$(APP)" $(if $(strip $(FILE)),"$(FILE)")

test: test-kit test-app

# The Rendering tests drive WebKit against timeouts. Run alongside the CPU-heavy Core tests on a slow CI runner, they
# starved until every page load timed out, so the two targets run one after the other. Custom flags run once as given:
# SwiftPM joins several --filter options with "or", which would undo the split.
test-kit:
ifeq ($(strip $(SWIFT_TEST_FLAGS)),)
	swift test --package-path Packages/SurimonoKit --filter SurimonoCoreTests
	swift test --package-path Packages/SurimonoKit --filter SurimonoRenderingTests
else
	swift test --package-path Packages/SurimonoKit $(SWIFT_TEST_FLAGS)
endif

test-app:
	$(XCODEBUILD) -configuration "$(CONFIGURATION)" test

lint:
	xcrun swift-format lint --strict --recursive --parallel $(SWIFT_PATHS)

format:
	xcrun swift-format format --in-place --recursive --parallel $(SWIFT_PATHS)

package:
	$(XCODEBUILD) -configuration Release MARKETING_VERSION="$(VERSION)" CURRENT_PROJECT_VERSION="$(BUILD_NUMBER)" build
	codesign --verify --deep --strict "$(RELEASE_APP)"
	mkdir -p build/release
	ditto -c -k --keepParent "$(RELEASE_APP)" "build/release/Surimono-$(VERSION).zip"
	cd build/release && shasum -a 256 "Surimono-$(VERSION).zip" > "Surimono-$(VERSION).zip.sha256"

clean:
	rm -rf build "$(DERIVED_DATA)" Packages/SurimonoKit/.build
