# Protect Ears

[![Build and checks](https://github.com/turnertop/protect-ears/actions/workflows/check.yml/badge.svg)](https://github.com/turnertop/protect-ears/actions/workflows/check.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small native macOS menu-bar app that watches AirPods Max output volume and turns it back down when it exceeds your selected ceiling.

Built for the moment when you switch from loud speakers to headphones and the volume is unexpectedly high, or an app changes the volume. **This app reacts after changes; a brief loud spike can still get through.** See [Limits](#limits) before relying on it.

The default is **4 of 16 volume steps (25%)**. You can select **5 steps (31.25%)**. These percentages describe the system volume setting; they are not calibrated sound-pressure levels or a guarantee of safe listening.

## Run

Requires macOS 13 or later and Apple's Command Line Tools. No packages, accounts, network access, audio recording, Accessibility permission, or microphone permission are needed.

Build from source. If you don't have Apple's Command Line Tools yet, install them with `xcode-select --install` first.

```sh
git clone https://github.com/turnertop/protect-ears.git
cd protect-ears
zsh scripts/build-app.sh
open "dist/Protect Ears.app"
```

Click the ear icon in the menu bar to see the ceiling and connected devices. Enable **Start at login** if you want it to run each time you sign in. Keep the app bundle in a stable location before enabling this. macOS may ask you to allow the login item in System Settings. Login registration uses Apple's `SMAppService` and is off until you enable it.

AirPods Max are recognized by their output-device name. The app remembers their device UID after detection, including across later name changes. If your AirPods were already renamed without “AirPods Max” in the name, select their switch under **Connected outputs** once. Selecting other outputs applies the same ceiling to them.

## What it does

- Monitors all selected connected output devices, including when an app chooses an output independently of the system default.
- Responds to volume notifications, device changes, output-route changes, wake, and Core Audio service restarts.
- Checks output volume every 250 ms as a fallback and checks the device list every second. These intervals are scheduling targets, not real-time deadlines.
- Checks main and individual output-channel controls when exposed by the device, falling back to its virtual main-volume control.
- Lowers values above the ceiling and verifies the result. It never raises a quiet volume or unmutes a device.
- Attempts to mute the selected device if the volume cannot be read, capped, or verified. A warning remains visible after an emergency mute; you must inspect and unmute manually.
- Keeps preferences locally. It does not play any test sounds or send any data.

## Limits

**This is a reactive guard, not a strict audio-path limiter.** Core Audio reports volume changes after they occur. A brief spike can reach the headphones before the app corrects it, especially during connection, route/profile changes, wake, scheduling delays, or a driver failure. A 250 ms fallback does not establish a maximum possible response time.

The guard cannot enforce a ceiling while it is stopped, during startup before it can access a device, or while the AirPods are connected to a different computer/phone. Some device/driver volume controls may not be exposed. A green/running status means the latest volume check passed; it does not prove that no transient sound can pass.

A volume percentage also cannot prevent an app from making its audio louder *within* that setting. A strict signal ceiling requires processing every relevant audio stream before it reaches the headphones, plus control of the downstream device volume; this app does not install such an audio driver.

## Verify without playing sound

```sh
zsh scripts/check.sh
"dist/Protect Ears.app/Contents/MacOS/ProtectEars" --diagnose
```

The check runner simulates device controls, repeated spikes, channel imbalance, UID-based reconnection, renaming, read/write failures, rejected writes, hardware rounding, and emergency muting. It does not change real devices. `--diagnose` lists live output devices and volume controls without changing them.

For a real-device check, pause all playback and keep the headphones off your ears. With the app running and the AirPods selected, check that moving the system-volume slider above the ceiling is corrected. Repeat after reconnecting and when entering/leaving a Discord call. This verifies correction behavior, not absence of a transient; do not test with loud sound.

## Development

`Sources/VolumeGuardCore` contains the serial monitor, Core Audio adapter, and hardware-independent enforcement policy. `Sources/ProtectEars` contains the AppKit menu-bar host and SwiftUI controls. `Checks` contains the simulated-hardware checks and a dependency-free runner, so full Xcode/XCTest is unnecessary.

The build script creates a locally ad-hoc-signed app in `dist`. It is built for the current Mac architecture and is not notarized for distribution. For distribution or a stable signed login-item identity, build and sign with your own Developer ID.

GitHub Actions runs the simulated-hardware checks and verifies the app build on Apple silicon and Intel macOS runners. It cannot verify real Bluetooth behavior; testing with physical headphones is still necessary.

## Contributing

Bug reports and pull requests are welcome. For a bug report, include your macOS version, headphone model, Bluetooth or wired connection, what triggered the volume change, and the status shown in Protect Ears. Avoid posting private device identifiers. Run `zsh scripts/check.sh` before submitting a code change.

## License

[MIT](LICENSE). You can use, modify, and redistribute Protect Ears under the license terms.

References: [Apple's volume-change notification API](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)), [device volume controls](https://developer.apple.com/library/archive/qa/qa1016/), [Bluetooth microphone mode changes](https://support.apple.com/en-us/102217).
