// XiaomiMouseFix.swift
//
// Menu-bar app that makes the side buttons (Back/Forward) work over Bluetooth
// on the Xiaomi Mi Dual Mode Wireless Mouse Silent Edition (VID 0x2717 /
// PID 0x5014) on macOS, including Apple Silicon.
//
// WHY: the mouse ships a broken HID report descriptor that hides the side
// buttons from macOS, even though their bits are present in every input report.
// We read the raw reports, decode the side-button bits, and synthesize
// Back/Forward mouse events. No kext, no DriverKit, no descriptor rewrite.
//
// The app lives in the menu bar: it shows whether the mouse is connected,
// has a Launch-at-Login toggle, and a Quit item.
//
// Run with `--sniff` from a terminal to print raw reports (for other firmware).

import Cocoa
import IOKit
import IOKit.hid
import CoreGraphics
import ServiceManagement

// ----------------------------------------------------------------------------
// Device identity — from Linux hid-xiaomi.c
// ----------------------------------------------------------------------------
let kVendorID  = 0x2717
let kProductID = 0x5014

// ----------------------------------------------------------------------------
// Report layout (confirmed via --sniff over Bluetooth):
// the report buffer includes the report ID at index 0, button bitfield at 1:
//   byte[1]: bit3 (0x08) = Back (btn4), bit4 (0x10) = Forward (btn5)
// ----------------------------------------------------------------------------
let BUTTON_BYTE_INDEX = 1
let BACK_BIT:    UInt8 = 1 << 3   // 0x08
let FORWARD_BIT: UInt8 = 1 << 4   // 0x10

// macOS mouse button numbers that apps treat as Back / Forward
let kBackButtonNumber    = 3
let kForwardButtonNumber = 4

// ----------------------------------------------------------------------------
// Synthesize a mouse button (down + up) at the current cursor location.
// ----------------------------------------------------------------------------
func postMouseButton(_ buttonNumber: Int) {
    let src = CGEventSource(stateID: .hidSystemState)
    let loc = CGEvent(source: nil)?.location ?? .zero
    if let down = CGEvent(mouseEventSource: src, mouseType: .otherMouseDown,
                          mouseCursorPosition: loc, mouseButton: .center) {
        down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        down.post(tap: .cghidEventTap)
    }
    if let up = CGEvent(mouseEventSource: src, mouseType: .otherMouseUp,
                        mouseCursorPosition: loc, mouseButton: .center) {
        up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(buttonNumber))
        up.post(tap: .cghidEventTap)
    }
}

// ----------------------------------------------------------------------------
// HID C callbacks. They can't capture Swift context, so the AppDelegate is
// passed through the `context` pointer.
// ----------------------------------------------------------------------------
let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, reportLength in
    guard let context = context else { return }
    let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    let len = Int(reportLength)
    guard len > BUTTON_BYTE_INDEX else { return }

    let buttons = report[BUTTON_BYTE_INDEX]
    let changed = buttons ^ app.lastButtons
    if (changed & BACK_BIT) != 0,    (buttons & BACK_BIT) != 0    { NSLog("XMF: Back detected -> posting button 3");    postMouseButton(kBackButtonNumber) }
    if (changed & FORWARD_BIT) != 0, (buttons & FORWARD_BIT) != 0 { NSLog("XMF: Forward detected -> posting button 4"); postMouseButton(kForwardButtonNumber) }
    app.lastButtons = buttons
}

let deviceMatchedCallback: IOHIDDeviceCallback = { context, _, _, device in
    guard let context = context else { return }
    let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    IOHIDDeviceRegisterInputReportCallback(device, app.reportBuffer, app.reportLength,
                                           inputReportCallback, context)
    DispatchQueue.main.async { app.deviceCount += 1; app.connected = app.deviceCount > 0 }
}

let deviceRemovedCallback: IOHIDDeviceCallback = { context, _, _, _ in
    guard let context = context else { return }
    let app = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
    DispatchQueue.main.async { app.deviceCount = max(0, app.deviceCount - 1); app.connected = app.deviceCount > 0 }
}

// ----------------------------------------------------------------------------
// App
// ----------------------------------------------------------------------------
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let hideIconDefaultsKey = "HideMenuBarIcon"
    var statusLine: NSMenuItem!
    var inputMonItem: NSMenuItem!
    var accessItem: NSMenuItem!
    var loginToggle: NSMenuItem!
    var hideIconItem: NSMenuItem!
    var manager: IOHIDManager!
    var settingsWindow: NSWindow?
    var mouseStatusLabel: NSTextField?
    var inputStatusLabel: NSTextField?
    var accessibilityStatusLabel: NSTextField?
    var loginCheckbox: NSButton?
    var menuIconCheckbox: NSButton?

    let reportLength = 32
    lazy var reportBuffer: UnsafeMutablePointer<UInt8> = {
        let b = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        b.initialize(repeating: 0, count: reportLength)
        return b
    }()
    var lastButtons: UInt8 = 0
    var deviceCount = 0
    var connected = false { didSet { updateUI() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        ensureInputMonitoringPermission()
        ensureAccessibilityPermission()
        setupHID()
        applyMenuBarIconVisibility()
        updateUI()
        updatePermissionItems()
        updateLoginState()
        showSettingsWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettingsWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateSettingsWindowState()
    }

    func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        statusLine = NSMenuItem(title: "Mouse: …", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        inputMonItem = NSMenuItem(title: "Input Monitoring: …",
                                  action: #selector(openInputMonitoringSettings), keyEquivalent: "")
        inputMonItem.target = self
        menu.addItem(inputMonItem)

        accessItem = NSMenuItem(title: "Accessibility: …",
                                action: #selector(openAccessibilitySettings), keyEquivalent: "")
        accessItem.target = self
        menu.addItem(accessItem)
        menu.addItem(.separator())

        loginToggle = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        loginToggle.target = self
        menu.addItem(loginToggle)

        hideIconItem = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(toggleMenuBarIcon), keyEquivalent: "")
        hideIconItem.target = self
        menu.addItem(hideIconItem)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let quit = NSMenuItem(title: "Quit XiaomiMouseFix", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func updateUI() {
        if let button = statusItem.button {
            let symbol = connected ? "computermouse.fill" : "computermouse"
            let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "XiaomiMouseFix")
            img?.isTemplate = true
            button.image = img
            button.toolTip = connected ? "Mi Silent Mouse: connected" : "Mi Silent Mouse: not connected"
        }
        statusLine?.title = connected ? "Mouse: Connected ✓" : "Mouse: Not connected"
        mouseStatusLabel?.stringValue = connected ? "Connected" : "Not connected"
    }

    // ---- Launch at login (modern ServiceManagement API, macOS 13+) ----
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("XiaomiMouseFix: login toggle failed: \(error)")
        }
        updateLoginState()
    }

    func updateLoginState() {
        loginToggle?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        loginCheckbox?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionItems()
        updateLoginState()
        updateMenuBarIconState()
    }

    // ---- Menu bar icon visibility ----
    func applyMenuBarIconVisibility() {
        statusItem.isVisible = !UserDefaults.standard.bool(forKey: hideIconDefaultsKey)
        updateMenuBarIconState()
    }

    func updateMenuBarIconState() {
        let hidden = UserDefaults.standard.bool(forKey: hideIconDefaultsKey)
        hideIconItem?.state = hidden ? .on : .off
        menuIconCheckbox?.state = hidden ? .off : .on
    }

    @objc func toggleMenuBarIcon() {
        let hidden = UserDefaults.standard.bool(forKey: hideIconDefaultsKey)
        UserDefaults.standard.set(!hidden, forKey: hideIconDefaultsKey)
        applyMenuBarIconVisibility()
    }

    @objc func toggleMenuBarIconFromWindow(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state != .on, forKey: hideIconDefaultsKey)
        applyMenuBarIconVisibility()
    }

    // ---- Permission status rows ----
    func inputMonitoringGranted() -> Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }
    func accessibilityGranted() -> Bool {
        AXIsProcessTrusted()
    }

    func updatePermissionItems() {
        let im = inputMonitoringGranted()
        inputMonItem.title = im ? "Input Monitoring: Granted" : "Input Monitoring: Not granted — open Settings"
        inputMonItem.state = im ? .on : .off

        let ax = accessibilityGranted()
        accessItem.title = ax ? "Accessibility: Granted" : "Accessibility: Not granted — open Settings"
        accessItem.state = ax ? .on : .off

        inputStatusLabel?.stringValue = im ? "Granted" : "Not granted"
        accessibilityStatusLabel?.stringValue = ax ? "Granted" : "Not granted"
    }

    @objc func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // ---- Settings window ----
    @objc func showSettingsWindow() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            updateSettingsWindowState()
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "XiaomiMouseFix"
        window.center()
        window.isReleasedWhenClosed = false

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "XiaomiMouseFix")
        title.font = .systemFont(ofSize: 22, weight: .semibold)

        let creator = NSTextField(labelWithString: "Creator: KirillEraser")
        creator.textColor = .secondaryLabelColor

        let description = NSTextField(wrappingLabelWithString: "Fixes Back and Forward side buttons for the Xiaomi Mi Dual Mode Wireless Mouse by reading raw HID reports and posting standard mouse button events.")
        description.textColor = .secondaryLabelColor

        let statusBox = NSStackView()
        statusBox.orientation = .vertical
        statusBox.alignment = .leading
        statusBox.spacing = 8

        mouseStatusLabel = NSTextField(labelWithString: "")
        inputStatusLabel = NSTextField(labelWithString: "")
        accessibilityStatusLabel = NSTextField(labelWithString: "")

        statusBox.addArrangedSubview(row(label: "Mouse", value: mouseStatusLabel!))
        statusBox.addArrangedSubview(row(label: "Input Monitoring", value: inputStatusLabel!))
        statusBox.addArrangedSubview(row(label: "Accessibility", value: accessibilityStatusLabel!))

        loginCheckbox = NSButton(checkboxWithTitle: "Launch at Login", target: self, action: #selector(toggleLogin))
        menuIconCheckbox = NSButton(checkboxWithTitle: "Show Menu Bar Icon", target: self, action: #selector(toggleMenuBarIconFromWindow(_:)))

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let inputButton = NSButton(title: "Input Monitoring", target: self, action: #selector(openInputMonitoringSettings))
        let accessibilityButton = NSButton(title: "Accessibility", target: self, action: #selector(openAccessibilitySettings))
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        buttons.addArrangedSubview(inputButton)
        buttons.addArrangedSubview(accessibilityButton)
        buttons.addArrangedSubview(quitButton)

        root.addArrangedSubview(title)
        root.addArrangedSubview(creator)
        root.addArrangedSubview(description)
        root.addArrangedSubview(statusBox)
        root.addArrangedSubview(loginCheckbox!)
        root.addArrangedSubview(menuIconCheckbox!)
        root.addArrangedSubview(buttons)

        window.contentView = NSView()
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            root.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            description.widthAnchor.constraint(equalToConstant: 360),
        ])

        settingsWindow = window
        updateSettingsWindowState()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func row(label: String, value: NSTextField) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8

        let labelField = NSTextField(labelWithString: "\(label):")
        labelField.font = .systemFont(ofSize: 13, weight: .medium)
        labelField.widthAnchor.constraint(equalToConstant: 130).isActive = true

        value.textColor = .secondaryLabelColor

        row.addArrangedSubview(labelField)
        row.addArrangedSubview(value)
        return row
    }

    func updateSettingsWindowState() {
        updateUI()
        updatePermissionItems()
        updateLoginState()
        updateMenuBarIconState()
    }

    // ---- Permissions ----
    func ensureInputMonitoringPermission() {
        // Reading HID input reports requires Input Monitoring. IOHIDManagerOpen
        // alone doesn't reliably trigger the prompt, so request it explicitly.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    func ensureAccessibilityPermission() {
        // Posting synthetic mouse events requires Accessibility trust.
        // Literal key avoids SDK differences around kAXTrustedCheckOptionPrompt.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // ---- HID ----
    func setupHID() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: [String: Any] = [
            kIOHIDVendorIDKey  as String: kVendorID,
            kIOHIDProductIDKey as String: kProductID,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, deviceMatchedCallback, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, deviceRemovedCallback, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let r = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        if r != kIOReturnSuccess {
            NSLog("XiaomiMouseFix: IOHIDManagerOpen failed (0x%08X) — grant Input Monitoring.", r)
        }
    }
}

// ----------------------------------------------------------------------------
// --sniff mode (CLI): print raw reports so you can verify byte/bit layout.
// ----------------------------------------------------------------------------
let sniffBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 64)

let sniffReportCB: IOHIDReportCallback = { _, _, _, _, reportID, report, len in
    var line = String(format: "reportID=%u len=%d : ", reportID, Int(len))
    for i in 0..<Int(len) { line += String(format: "%02X ", report[i]) }
    print(line)
}

let sniffMatchCB: IOHIDDeviceCallback = { _, _, _, device in
    IOHIDDeviceRegisterInputReportCallback(device, sniffBuffer, 64, sniffReportCB, nil)
}

func runSniff() {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, [
        kIOHIDVendorIDKey  as String: kVendorID,
        kIOHIDProductIDKey as String: kProductID,
    ] as CFDictionary)
    IOHIDManagerRegisterDeviceMatchingCallback(mgr, sniffMatchCB, nil)
    IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
    print("SNIFF MODE: press each side button; note which byte/bit toggles. Ctrl-C to quit.")
    CFRunLoopRun()
}

// ----------------------------------------------------------------------------
// Entry point
// ----------------------------------------------------------------------------
if CommandLine.arguments.contains("--sniff") {
    runSniff()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
    app.run()
}
