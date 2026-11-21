# XiaomiMouseFix

![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-000000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M4%20Pro%20tested-success)
![Swift](https://img.shields.io/badge/Swift-5-orange?logo=swift&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-green)

A tiny menu-bar app that makes the **Back/Forward side buttons** work on the
**Xiaomi Mi Dual Mode Wireless Mouse — Silent Edition** over **Bluetooth** on
macOS. (Over the USB dongle macOS already sees the side buttons, so you don't
need this app; they work in browsers, but Apple's apps ignore them.)

Tested on a MacBook Pro (M4 Pro) with the
[Silent Edition](https://www.mi.com/global/product/mi-dual-mode-wireless-mouse/)
(VID `0x2717`, PID `0x5014`). Other mice or firmware revisions may need
[a small tweak](#buttons-still-do-nothing).

## Install

1. Download the `.dmg` from the
   [latest release](https://github.com/KirillEraser/xiaomi-mouse-macOS-fix/releases/latest).
2. Open it and drag **XiaomiMouseFix** into **Applications**.
3. Launch it. macOS will block it the first time, because the app isn't
   notarized (that needs a paid Apple developer account):
   - Go to **System Settings → Privacy & Security**, scroll down and click
     **Open Anyway**. (On macOS 13–14 you can also right-click the app → **Open**.)
   - If macOS says the app is **"damaged"**, run this once, then open it normally:
     ```sh
     xattr -dr com.apple.quarantine /Applications/XiaomiMouseFix.app
     ```

A mouse icon appears in the menu bar.

## Permissions

The app asks for two permissions, one at a time. Both are in
**System Settings → Privacy & Security**:

1. **Accessibility** (called **Device Control and Data Access** on newer
   macOS) — to send the Back/Forward clicks.
2. **Input Monitoring** — to read the mouse's buttons.

If the buttons don't work right after granting both, quit and reopen the app
from the menu bar icon. The menu shows whether the mouse is connected and
whether each permission is granted. To start the app automatically, enable
**Launch at Login** in the menu.

## What works where

- **Apple's apps** (Finder, Safari, System Settings, App Store, Music, Preview…)
  ignore mouse side buttons, so the app sends **⌘[ / ⌘]** to them instead.
  Apple apps where ⌘[ means something else (Xcode, Notes, Mail, Pages…) are
  left alone.
- **Browsers** (Chrome, Firefox, Arc, Zen…) and most other apps get normal
  Back/Forward mouse buttons. Apps that ignore those won't react.

## Troubleshooting

### Permission switches are on, but the buttons do nothing

macOS ties permissions to the exact build of the app, so after an update or
rebuild the old switches look enabled but don't apply. Reset them, reopen the
app and grant again:

```sh
tccutil reset Accessibility space.roverprinter.xiaomimousefix
tccutil reset ListenEvent space.roverprinter.xiaomimousefix
```

### Buttons still do nothing

Your mouse may report its buttons differently. Build from source (below) and run:

```sh
make sniff
```

Press each side button and note which byte/bit changes, then edit
`BUTTON_BYTE_INDEX`, `BACK_BIT` and `FORWARD_BIT` near the top of
`Sources/XiaomiMouseFix.swift` and reinstall. If Back and Forward are swapped,
swap `BACK_BIT` and `FORWARD_BIT`. (Silent Edition over Bluetooth: byte 1,
`0x08` = Back, `0x10` = Forward.)

### Hiding the menu bar icon

On macOS 26+: **System Settings → Menu Bar → Allow in the Menu Bar**. On older
versions, use [Ice](https://github.com/jordanbaird/Ice).

## Updating and uninstalling

**Update:** quit the app from the menu, replace it in Applications with the new
version, then [reset the permissions](#permission-switches-are-on-but-the-buttons-do-nothing)
and grant them again.

**Uninstall:** turn off **Launch at Login**, quit the app and drag it to the
Trash. To also clear its permission entries, run the two `tccutil` commands above.

## Build from source

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/KirillEraser/xiaomi-mouse-macOS-fix.git
cd xiaomi-mouse-macOS-fix
make install
```

| Command          | What it does                                     |
| ---------------- | ------------------------------------------------ |
| `make install`   | Build, copy to `/Applications`, launch           |
| `make relaunch`  | Same, after code changes                         |
| `make run`       | Run the build in the foreground (testing)        |
| `make sniff`     | Print raw HID reports to find the button layout  |
| `make uninstall` | Remove the app from `/Applications`              |
| `make clean`     | Remove the build folder                          |

Local builds are signed ad-hoc, so **every rebuild needs the permissions
re-granted** (see the `tccutil` commands above).

## How it works

Over Bluetooth, the mouse sends a broken HID report descriptor that tells macOS
it only has 3 buttons, so the side buttons are ignored. (The USB dongle reports
them correctly.) Linux fixes this in the
kernel by rewriting the descriptor
([`hid-xiaomi.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-xiaomi.c)),
but macOS has no hook for that on Bluetooth devices.

The side-button bits are still there in every report, though. So the app:

1. Opens the mouse with `IOHIDManager` without seizing it, so macOS keeps
   handling movement and normal clicks.
2. Reads the raw button byte from each input report.
3. On a side-button press, posts mouse button 4/5 — or ⌘[ / ⌘] if an Apple
   app is in front.

No kext, no DriverKit, no SIP changes.

## Credits

HID descriptor analysis and the original Linux driver: Ilya Skriblovsky
([hid-xiaomi](https://github.com/IlyaSkriblovsky/hid-xiaomi), now in mainline).

## License

MIT — see [LICENSE](LICENSE).
