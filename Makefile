DERIVED_DATA := .build/xcode
BUILD_DIR := $(DERIVED_DATA)/Build/Products
DEBUG_DIR := $(BUILD_DIR)/Debug
RELEASE_DIR := $(BUILD_DIR)/Release
METALLIB := $(DEBUG_DIR)/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib
SPM_METALLIB := .build/debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib

.PHONY: build build-release run clean metallib

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

clean:
	rm -rf $(DERIVED_DATA)
	rm -rf .build
