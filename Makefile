# ---- Config ----------------------------------------------------------------
APP_NAME   := XiaomiMouseFix
BUNDLE_ID  := space.roverprinter.xiaomimousefix
BIN_NAME   := XiaomiMouseFix
SWIFT_SRC  := Sources/XiaomiMouseFix.swift

BUILD_DIR  := build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
APP_MACOS  := $(APP_BUNDLE)/Contents/MacOS

INSTALL_DIR := /Applications/$(APP_NAME).app

FRAMEWORKS := -framework Cocoa -framework IOKit -framework ServiceManagement

# ---- Targets ----------------------------------------------------------------
.PHONY: all build app install uninstall relaunch run sniff clean

all: app

## Compile the binary
build:
	@mkdir -p $(BUILD_DIR)
	swiftc -O $(SWIFT_SRC) $(FRAMEWORKS) -o $(BUILD_DIR)/$(BIN_NAME)

## Assemble the .app bundle and ad-hoc sign it (stable TCC identity)
app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_MACOS)
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(BIN_NAME) $(APP_MACOS)/$(BIN_NAME)
	@chmod +x $(APP_MACOS)/$(BIN_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@cp Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	@codesign -s - -f --deep $(APP_BUNDLE)
	@echo "Built $(APP_BUNDLE)"

## Install to /Applications and launch
install: app
	-@killall $(BIN_NAME) 2>/dev/null || true
	@while pgrep -x $(BIN_NAME) >/dev/null; do sleep 0.1; done
	@rm -rf $(INSTALL_DIR)
	@cp -R $(APP_BUNDLE) /Applications/
	@open $(INSTALL_DIR)
	@echo ""
	@echo "Launched. Grant BOTH permissions in System Settings > Privacy & Security:"
	@echo "  - Input Monitoring -> enable $(APP_NAME)"
	@echo "  - Accessibility    -> enable $(APP_NAME)"
	@echo "Then use 'make relaunch' (or just quit/reopen from the menu bar icon)."

## Rebuild, reinstall, relaunch (use after code changes)
relaunch: install

## Remove the app (turn off Launch at Login from the menu first)
uninstall:
	-@killall $(BIN_NAME) 2>/dev/null || true
	@rm -rf $(INSTALL_DIR)
	@echo "Removed $(INSTALL_DIR). If you enabled Launch at Login, it self-clears once the app is gone."

## Run the bundle in the foreground (for quick testing)
run: app
	$(APP_MACOS)/$(BIN_NAME)

## Print raw HID reports to discover your byte/bit layout
sniff: build
	$(BUILD_DIR)/$(BIN_NAME) --sniff

clean:
	@rm -rf $(BUILD_DIR)
