# XiaomiMouseFix

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-000000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M4%20Pro%20tested-success)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

A tiny **menu-bar app** that makes the **side buttons (Back/Forward) work over
Bluetooth** on the **Xiaomi Mi Dual Mode Wireless Mouse — Silent Edition**
(VID `0x2717`, PID `0x5014`) on macOS, including Apple Silicon.

It lives in the menu bar and shows whether the mouse is connected, the live
state of the two permissions it needs, a **Launch at Login** toggle, and **Quit**.

## Tested on

- **MacBook Pro (M4 Pro)** — confirmed working.
- **[Mi Dual Mode Wireless Mouse — Silent Edition](https://www.mi.com/global/product/mi-dual-mode-wireless-mouse/)**
  (this exact mouse).

No guarantees on other Macs or other mice. Different mice — or even a different
firmware revision of this one — may report a different HID layout; in that case
run `make sniff` and adjust the three byte/bit constants (see below).

## The problem

This mouse ships a broken HID report descriptor. Over Bluetooth it tells macOS
it only has 3 buttons, so the side buttons do nothing. Over the USB dongle the
buttons fire but get mapped to garbage (middle-click / wheel-tilt). Linux fixes
this in the kernel by rewriting the descriptor
([`hid-xiaomi.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-xiaomi.c),
by Ilya Skriblovsky), but macOS has no equivalent fixup hook for a
Bluetooth-transport HID device — the system Bluetooth HID driver claims the
device before anything else can touch its descriptor.

## How it works

The side-button bits **are** present in every input report on the wire — the
broken descriptor just tells macOS to ignore them. So this app skips the
descriptor problem entirely:

1. Opens the mouse via `IOHIDManager` (no seize — macOS keeps handling
   movement and normal clicks).
2. Registers a **raw input-report callback** and reads the button byte directly.
3. On a side-button press, synthesizes a `otherMouseButton` 3/4 event, which
   apps interpret as Back/Forward.

No kext, no DriverKit, no SIP changes, no descriptor surgery.

## Requirements

- macOS 13+ (uses the modern `SMAppService` login-item API)
- Xcode Command Line Tools (`xcode-select --install`) for `swiftc`

## Install

```sh
make install
```

This builds a signed `XiaomiMouseFix.app`, copies it to `/Applications`, and
launches it. A mouse icon appears in the menu bar.

Then grant **both** permissions in **System Settings → Privacy & Security**:

- **Input Monitoring** → enable `XiaomiMouseFix` (read the mouse's reports)
- **Accessibility** → enable `XiaomiMouseFix` (post the synthetic clicks)

The app asks for Accessibility first, then for Input Monitoring once
Accessibility is granted. If the buttons don't work right after granting both,
quit and reopen it from the menu bar icon. Test Back/Forward in a browser or
Finder.

To start it automatically at login, click the menu bar icon and enable
**Launch at Login**.

## Menu

- **Mouse: Connected ✓ / Not connected** — live status (the icon also fills in
  when connected).
- **Input Monitoring: Granted / Not granted** — click to open the Settings pane.
- **Accessibility: Granted / Not granted** — click to open the Settings pane.
- **Launch at Login** — toggles a login item via `SMAppService`.
- **Quit** — exits the app.

## Uninstall

Turn off **Launch at Login** from the menu, then:

```sh
make uninstall
```

## Other commands

| Command         | What it does                                           |
| --------------- | ------------------------------------------------------ |
| `make run`      | Run the bundle in the foreground (testing)             |
| `make sniff`    | Print raw HID reports to discover your byte/bit layout |
| `make relaunch` | Rebuild, reinstall, relaunch (after code changes)      |
| `make clean`    | Remove the build directory                             |

## Different firmware revision?

If your buttons don't respond, your report layout may differ. Run:

```sh
make sniff
```

Press each side button and note which byte/bit toggles, then edit the three
constants near the top of `Sources/XiaomiMouseFix.swift`
(`BUTTON_BYTE_INDEX`, `BACK_BIT`, `FORWARD_BIT`) and reinstall. If Back and
Forward are swapped, just swap `BACK_BIT` and `FORWARD_BIT`.

Confirmed layout for the Silent Edition over Bluetooth: report ID at byte 0,
button bitfield at byte 1, with `0x08` = Back and `0x10` = Forward.

## Notes

- Apple's own apps (Finder, Safari, System Settings, App Store, Music, …)
  ignore mouse buttons 3/4, so for them the app sends ⌘[ / ⌘] instead. Apple
  apps where ⌘[ means something else (Xcode, Notes, Mail, Pages…) are skipped.
- Third-party apps get mouse buttons 3/4. Browsers handle them; apps that
  ignore them won't react.
- Permissions are tied to the app's signature/bundle ID. The `.app` bundle keeps
  that identity stable across rebuilds, so you grant the permissions once.

## Credits

- HID descriptor analysis and the original Linux driver: Ilya Skriblovsky
  ([hid-xiaomi](https://github.com/IlyaSkriblovsky/hid-xiaomi), now in mainline).

## License

MIT — see [LICENSE](LICENSE).
