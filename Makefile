# Convenience commands for Wordy development. Xcode remains the build system.

PROJECT := Wordy.xcodeproj
SCHEME := Wordy
BUILD_ROOT ?= build
DERIVED_DATA ?= $(BUILD_ROOT)/DerivedData
CORE_SCRATCH ?= $(BUILD_ROOT)/SwiftPM
ARM64_DERIVED_DATA ?= $(BUILD_ROOT)/arm64
X86_64_DERIVED_DATA ?= $(BUILD_ROOT)/x86_64
XCODE_FLAGS ?= -quiet

XCODEBUILD := xcodebuild
XCODE_COMMON = -project $(PROJECT) -scheme $(SCHEME) $(XCODE_FLAGS)
NATIVE_DESTINATION := platform=macOS
GENERIC_DESTINATION := generic/platform=macOS

DEBUG_APP := $(DERIVED_DATA)/Build/Products/Debug/Wordy.app
RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Wordy.app
RELEASE_EXECUTABLE := $(RELEASE_APP)/Contents/MacOS/Wordy
RELEASE_WORKER := $(RELEASE_APP)/Contents/XPCServices/WordyTranscriptionService.xpc/Contents/MacOS/WordyTranscriptionService

.DEFAULT_GOAL := help

BENCH := $(DERIVED_DATA)/Build/Products/Release/wordy-bench
BENCH_OUTPUT ?= $(BUILD_ROOT)/benchmarks

.PHONY: help doctor list xcode build run test test-core test-arm64 test-x86_64 \
	release build-universal build-arm64 build-x86_64 verify-universal analyze check clean \
	engine engine-clean bench

help: ## Show the available development commands.
	@awk 'BEGIN { FS = ":.*## "; printf "Wordy development commands:\n\n" } /^[a-zA-Z0-9_-]+:.*## / { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

doctor: ## Print the active Xcode and Swift toolchain versions.
	@command -v $(XCODEBUILD) >/dev/null
	@command -v swift >/dev/null
	xcode-select -p
	$(XCODEBUILD) -version
	swift --version

list: ## List Xcode targets, schemes, configurations, and destinations.
	$(XCODEBUILD) -project $(PROJECT) -list
	$(XCODEBUILD) $(XCODE_COMMON) -showdestinations

xcode: ## Open the project in Xcode.
	open $(PROJECT)

build: ## Build a Debug app for the current Mac architecture.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Debug \
		-destination '$(NATIVE_DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

run: build ## Build and launch the Debug app.
	open $(DEBUG_APP)

test: ## Build the app and run the Xcode test scheme on the current Mac.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Debug \
		-destination '$(NATIVE_DESTINATION)' -derivedDataPath $(DERIVED_DATA) test

test-core: ## Run the fast, platform-independent WordyCore tests with SwiftPM.
	swift test --scratch-path $(CORE_SCRATCH)

test-arm64: ## Run Xcode tests as arm64; requires an Apple Silicon Mac.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Debug \
		-destination 'platform=macOS,arch=arm64' -derivedDataPath $(BUILD_ROOT)/tests-arm64 test

test-x86_64: ## Run Xcode tests as x86_64; requires an Intel Mac or an available Rosetta destination.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Debug \
		-destination 'platform=macOS,arch=x86_64' -derivedDataPath $(BUILD_ROOT)/tests-x86_64 test

release: build-universal ## Alias for the Universal Release build.

build-universal: ## Build one Release app containing arm64 and x86_64 slices.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Release \
		-destination '$(GENERIC_DESTINATION)' -derivedDataPath $(DERIVED_DATA) build

build-arm64: ## Cross-compile a Release app containing only arm64 code.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Release \
		-destination '$(GENERIC_DESTINATION)' -derivedDataPath $(ARM64_DERIVED_DATA) \
		ARCHS=arm64 ONLY_ACTIVE_ARCH=NO build

build-x86_64: ## Cross-compile a Release app containing only Intel x86_64 code.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Release \
		-destination '$(GENERIC_DESTINATION)' -derivedDataPath $(X86_64_DERIVED_DATA) \
		ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

verify-universal: build-universal ## Verify both architectures and the ad-hoc signature in the Release app.
	lipo $(RELEASE_EXECUTABLE) -verify_arch arm64 x86_64
	lipo $(RELEASE_WORKER) -verify_arch arm64 x86_64
	codesign --verify --deep --strict --verbose=2 $(RELEASE_APP)
	@nm $(RELEASE_WORKER) | grep -q ' T _whisper_full$$' || (echo 'worker does not contain the whisper engine' && exit 1)
	@printf 'Verified Universal app and XPC worker (with whisper.cpp): arm64 + x86_64\n'

engine: ## Fetch the pinned whisper.cpp release and build the universal static engine library.
	WORDY_BUILD_ROOT=$(abspath $(BUILD_ROOT)) scripts/build-whisper.sh arm64 x86_64

engine-clean: ## Remove the vendored whisper.cpp checkout and its build products.
	rm -rf Vendor/whisper.cpp $(BUILD_ROOT)/whisper

bench: ## Build wordy-bench (Release). Run it with: make bench AUDIO=... MODEL=... MODEL_ID=... [CHUNK=60 OVERLAP=3]
	$(XCODEBUILD) -project $(PROJECT) -scheme wordy-bench $(XCODE_FLAGS) -configuration Release \
		-destination '$(NATIVE_DESTINATION)' -derivedDataPath $(DERIVED_DATA) build
	@if [ -n "$(AUDIO)" ]; then \
		$(BENCH) --audio "$(AUDIO)" --model "$(MODEL)" --model-id "$(MODEL_ID)" \
			--chunk $(or $(CHUNK),60) --overlap $(or $(OVERLAP),3) --output $(BENCH_OUTPUT) $(BENCH_FLAGS); \
	else printf 'Built %s\n' $(BENCH); fi

analyze: ## Run Xcode's static analyzer on the Debug configuration.
	$(XCODEBUILD) $(XCODE_COMMON) -configuration Debug \
		-destination '$(NATIVE_DESTINATION)' -derivedDataPath $(DERIVED_DATA) analyze

check: test verify-universal ## Run native tests and verify a Universal Release build.

clean: ## Ask Xcode and SwiftPM to clean generated build products.
	$(XCODEBUILD) $(XCODE_COMMON) -derivedDataPath $(DERIVED_DATA) clean
	$(XCODEBUILD) $(XCODE_COMMON) -derivedDataPath $(ARM64_DERIVED_DATA) clean
	$(XCODEBUILD) $(XCODE_COMMON) -derivedDataPath $(X86_64_DERIVED_DATA) clean
	swift package --scratch-path $(CORE_SCRATCH) clean
