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
// Some apps (Finder, Safari) ignore mouse buttons 3/4 but understand
// ⌘[ / ⌘] as Back/Forward. For those, send the shortcut instead (issue #1).
// Not global: in editors (VS Code, Xcode…) ⌘[ means "outdent".
// ----------------------------------------------------------------------------
let kShortcutApps: Set<String> = ["com.apple.finder", "com.apple.Safari"]

// ANSI virtual key codes (physical key positions, US layout)
let kKeyLeftBracket:  CGKeyCode = 33   // '['
let kKeyRightBracket: CGKeyCode = 30   // ']'

func postCommandShortcut(_ keyCode: CGKeyCode) {
    let src = CGEventSource(stateID: .hidSystemState)
    for isDown in [true, false] {
        if let ev = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: isDown) {
            ev.flags = .maskCommand
            ev.post(tap: .cghidEventTap)
        }
    }
}

func postBackForward(_ buttonNumber: Int) {
    let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    if kShortcutApps.contains(frontApp) {
        postCommandShortcut(buttonNumber == kBackButtonNumber ? kKeyLeftBracket : kKeyRightBracket)
    } else {
        postMouseButton(buttonNumber)
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
    if (changed & BACK_BIT) != 0,    (buttons & BACK_BIT) != 0    { postBackForward(kBackButtonNumber) }
    if (changed & FORWARD_BIT) != 0, (buttons & FORWARD_BIT) != 0 { postBackForward(kForwardButtonNumber) }
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
    var statusLine: NSMenuItem!
    var inputMonItem: NSMenuItem!
    var accessItem: NSMenuItem!
    var loginToggle: NSMenuItem!
    var manager: IOHIDManager!

    let reportLength = 32
    lazy var reportBuffer: UnsafeMutablePointer<UInt8> = {
        let b = UnsafeMutablePointer<UInt8>.allocate(capacity: reportLength)
        b.initialize(repeating: 0, count: reportLength)
        return b
    }()
    var lastButtons: UInt8 = 0
    var deviceCount = 0
    var connected = false { didSet { updateUI() } }

    var permissionTimer: Timer?
    var askedInputMonitoring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        updateUI()
        updateLoginState()

        // Ask for Accessibility first: it takes effect without a relaunch.
        // Input Monitoring is requested only after that (macOS may ask to
        // quit & reopen for it), see checkPermissions().
        if !accessibilityGranted() { ensureAccessibilityPermission() }
        checkPermissions()
        if !(accessibilityGranted() && inputMonitoringGranted()) {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.checkPermissions()
            }
        }
    }

    // Runs once at launch, then every second until both permissions are granted.
    func checkPermissions() {
        updatePermissionItems()
        if accessibilityGranted() && !inputMonitoringGranted() && !askedInputMonitoring {
            askedInputMonitoring = true
            ensureInputMonitoringPermission()
        }
        // Open the HID manager only once allowed, so it can't trigger the
        // Input Monitoring prompt before the Accessibility one.
        if inputMonitoringGranted() && manager == nil { setupHID() }
        if accessibilityGranted() && inputMonitoringGranted() {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
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
        menu.addItem(.separator())

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
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePermissionItems()
        updateLoginState()
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
