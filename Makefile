SPM_DEBUG_DIR := .build/debug
SPM_RELEASE_DIR := .build/release

APP_NAME := Livekeet
BUNDLE_ID := com.livekeet.app
VERSION ?= 0.1.0
BUILD_NUMBER ?= 1
SIGNING_IDENTITY ?= Apple Development
RELEASE_SIGNING_IDENTITY ?= Developer ID Application
ENTITLEMENTS := $(CURDIR)/Sources/LivekeetApp/LivekeetApp.entitlements
INFO_PLIST := $(CURDIR)/Sources/LivekeetApp/Info.plist
SPARKLE_FRAMEWORK := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_SIGN_UPDATE := .build/artifacts/sparkle/Sparkle/bin/sign_update
APPCAST_URL_BASE ?= https://github.com/LucaDeLeo/livekeet-mlx/releases/download
MIN_SYSTEM_VERSION ?= 14.0

.PHONY: build build-release run clean build-app run-app build-release-app dmg notarize appcast-entry test

build:
	swift build --product livekeet

build-release:
	swift build -c release --product livekeet

run: build
	$(SPM_DEBUG_DIR)/livekeet $(ARGS)

# --- Debug app bundle ---

build-app:
	swift build --product LivekeetApp
	@$(MAKE) _bundle DIR=$(SPM_DEBUG_DIR) SIGN_ID="$(SIGNING_IDENTITY)"
	@echo "Built $(APP_NAME).app (debug)"

run-app: build-app
	open $(SPM_DEBUG_DIR)/$(APP_NAME).app

# --- Release app bundle ---

build-release-app:
	swift build -c release --product LivekeetApp
	@$(MAKE) _bundle DIR=$(SPM_RELEASE_DIR) SIGN_ID="$(RELEASE_SIGNING_IDENTITY)"
	@echo "Built $(APP_NAME).app (release)"

# --- Shared bundle creation ---

_bundle:
	@rm -rf $(DIR)/$(APP_NAME).app
	@mkdir -p $(DIR)/$(APP_NAME).app/Contents/MacOS
	@cp $(DIR)/LivekeetApp $(DIR)/$(APP_NAME).app/Contents/MacOS/LivekeetApp
	@cp $(INFO_PLIST) $(DIR)/$(APP_NAME).app/Contents/Info.plist
	@/usr/libexec/PlistBuddy \
		-c "Add :CFBundleExecutable string LivekeetApp" \
		-c "Add :CFBundleIdentifier string $(BUNDLE_ID)" \
		-c "Add :CFBundleName string $(APP_NAME)" \
		-c "Add :CFBundlePackageType string APPL" \
		-c "Add :LSMinimumSystemVersion string 14.0" \
		$(DIR)/$(APP_NAME).app/Contents/Info.plist 2>/dev/null || true
	@# Set version fields (already exist in Info.plist)
	@/usr/libexec/PlistBuddy \
		-c "Set :CFBundleShortVersionString $(VERSION)" \
		-c "Set :CFBundleVersion $(BUILD_NUMBER)" \
		$(DIR)/$(APP_NAME).app/Contents/Info.plist
	@# Build and embed MLX metallib bundle
	@bash scripts/build-metallib.sh .build/metallib
	@mkdir -p $(DIR)/$(APP_NAME).app/Contents/Resources
	@cp -R .build/metallib/mlx-swift_Cmlx.bundle $(DIR)/$(APP_NAME).app/Contents/Resources/
	@# Embed Sparkle.framework and add rpath so dyld finds it
	@mkdir -p $(DIR)/$(APP_NAME).app/Contents/Frameworks
	@cp -R $(SPARKLE_FRAMEWORK) $(DIR)/$(APP_NAME).app/Contents/Frameworks/
	@install_name_tool -add_rpath @loader_path/../Frameworks \
		$(DIR)/$(APP_NAME).app/Contents/MacOS/LivekeetApp
	@# Sign with entitlements
	@codesign --force --deep --options runtime --sign "$(SIGN_ID)" \
		--entitlements $(ENTITLEMENTS) \
		$(DIR)/$(APP_NAME).app

# --- DMG creation ---

dmg: build-release-app
	@mkdir -p dist
	@rm -f dist/$(APP_NAME)-$(VERSION).dmg
	@hdiutil create -volname "$(APP_NAME)" \
		-srcfolder $(SPM_RELEASE_DIR)/$(APP_NAME).app \
		-ov -format UDZO \
		dist/$(APP_NAME)-$(VERSION).dmg
	@echo "Created dist/$(APP_NAME)-$(VERSION).dmg"

# --- Notarization ---

notarize:
	@echo "Submitting dist/$(APP_NAME)-$(VERSION).dmg to Apple notary..."
	xcrun notarytool submit dist/$(APP_NAME)-$(VERSION).dmg \
		--keychain-profile "notarytool" \
		--wait
	@echo "Stapling notarization ticket..."
	xcrun stapler staple dist/$(APP_NAME)-$(VERSION).dmg
	@echo "Notarization complete."

test:
	swift test

# --- Appcast entry generation ---
#
# Usage: make appcast-entry VERSION=x.y.z BUILD_NUMBER=NN
#
# Signs dist/$(APP_NAME)-$(VERSION).dmg with Sparkle's sign_update tool (reads the
# ed25519 private key from the macOS keychain; run `generate_keys` once to create it)
# and prints a ready-to-paste <item> block for appcast.xml.
appcast-entry:
	@DMG=dist/$(APP_NAME)-$(VERSION).dmg; \
	if [ ! -f "$$DMG" ]; then \
		echo "ERROR: $$DMG not found. Run 'make dmg VERSION=$(VERSION)' first." >&2; \
		exit 1; \
	fi; \
	if [ ! -x "$(SPARKLE_SIGN_UPDATE)" ]; then \
		echo "ERROR: $(SPARKLE_SIGN_UPDATE) not found. Run 'swift build' first to fetch Sparkle." >&2; \
		exit 1; \
	fi; \
	SIG_OUTPUT=$$("$(SPARKLE_SIGN_UPDATE)" "$$DMG"); \
	LEN=$$(stat -f %z "$$DMG"); \
	PUBDATE=$$(date -u +"%a, %d %b %Y %H:%M:%S +0000"); \
	printf '\n<item>\n' ; \
	printf '  <title>Version %s</title>\n' "$(VERSION)"; \
	printf '  <pubDate>%s</pubDate>\n' "$$PUBDATE"; \
	printf '  <sparkle:version>%s</sparkle:version>\n' "$(BUILD_NUMBER)"; \
	printf '  <sparkle:shortVersionString>%s</sparkle:shortVersionString>\n' "$(VERSION)"; \
	printf '  <sparkle:minimumSystemVersion>%s</sparkle:minimumSystemVersion>\n' "$(MIN_SYSTEM_VERSION)"; \
	printf '  <enclosure\n'; \
	printf '    url="%s/v%s/%s-%s.dmg"\n' "$(APPCAST_URL_BASE)" "$(VERSION)" "$(APP_NAME)" "$(VERSION)"; \
	printf '    type="application/octet-stream"\n'; \
	printf '    %s\n' "$$SIG_OUTPUT"; \
	printf '    length="%s"\n' "$$LEN"; \
	printf '  />\n'; \
	printf '</item>\n\n'

clean:
	rm -rf .build
	rm -rf dist
