DERIVED_DATA := .build/xcode
BUILD_DIR := $(DERIVED_DATA)/Build/Products
DEBUG_DIR := $(BUILD_DIR)/Debug
RELEASE_DIR := $(BUILD_DIR)/Release
METALLIB := $(DEBUG_DIR)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
SPM_METALLIB := .build/debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib

.PHONY: build build-release run clean metallib build-app run-app

build:
	xcodebuild build \
		-scheme livekeet \
		-destination 'platform=OS X' \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA) \
		-skipPackagePluginValidation \
		| tail -1

build-release:
	xcodebuild build \
		-scheme livekeet \
		-destination 'platform=OS X' \
		-configuration Release \
		-derivedDataPath $(DERIVED_DATA) \
		-skipPackagePluginValidation \
		| tail -1

# Symlink the xcodebuild metallib into SPM's .build/debug so `swift run` works
metallib: build
	@mkdir -p $(dir $(SPM_METALLIB))
	@ln -sf $(CURDIR)/$(METALLIB) $(SPM_METALLIB)
	@echo "Metallib linked for swift run"

run: build
	$(DEBUG_DIR)/livekeet $(ARGS)

build-app:
	xcodebuild build \
		-scheme LivekeetApp \
		-destination 'platform=OS X' \
		-configuration Debug \
		-derivedDataPath $(DERIVED_DATA) \
		-skipPackagePluginValidation \
		| tail -1
	@# Wrap the executable into an .app bundle
	@mkdir -p $(DEBUG_DIR)/LivekeetApp.app/Contents/MacOS
	@cp $(DEBUG_DIR)/LivekeetApp $(DEBUG_DIR)/LivekeetApp.app/Contents/MacOS/LivekeetApp
	@/usr/libexec/PlistBuddy -c "Clear dict" $(DEBUG_DIR)/LivekeetApp.app/Contents/Info.plist 2>/dev/null || true
	@/usr/libexec/PlistBuddy \
		-c "Add :CFBundleExecutable string LivekeetApp" \
		-c "Add :CFBundleIdentifier string com.livekeet.app" \
		-c "Add :CFBundleName string Livekeet" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :CFBundleShortVersionString string 0.1.0" \
		-c "Add :CFBundleVersion string 1" \
		-c "Add :LSMinimumSystemVersion string 14.0" \
		-c "Add :NSMicrophoneUsageDescription string 'Livekeet needs microphone access to transcribe audio.'" \
		-c "Add :NSScreenCaptureUsageDescription string 'Livekeet needs screen recording to capture system audio.'" \
		$(DEBUG_DIR)/LivekeetApp.app/Contents/Info.plist
	@# Copy metallib bundle if present
	@if [ -d "$(DEBUG_DIR)/mlx-swift_Cmlx.bundle" ]; then \
		mkdir -p $(DEBUG_DIR)/LivekeetApp.app/Contents/Resources; \
		cp -R $(DEBUG_DIR)/mlx-swift_Cmlx.bundle $(DEBUG_DIR)/LivekeetApp.app/Contents/Resources/; \
	fi
	@# Sign with entitlements
	@codesign --force --sign "Apple Development" --entitlements $(CURDIR)/Sources/LivekeetApp/LivekeetApp.entitlements \
		$(DEBUG_DIR)/LivekeetApp.app
	@echo "Built LivekeetApp.app"

run-app: build-app
	open $(DEBUG_DIR)/LivekeetApp.app

clean:
	rm -rf $(DERIVED_DATA)
	rm -rf .build
