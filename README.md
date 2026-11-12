# Protect Ears

[![Build and checks](https://github.com/turnertop/protect-ears/actions/workflows/check.yml/badge.svg)](https://github.com/turnertop/protect-ears/actions/workflows/check.yml)
[![MIT license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A small native macOS menu-bar app that watches AirPods Max output volume and turns it back down when it exceeds your selected ceiling.

Built for the moment when you switch from loud speakers to headphones and the volume is unexpectedly high, or an app changes the volume. **This app reacts after changes; a brief loud spike can still get through.** See [Limits](#limits) before relying on it.

The default is **4 of 16 volume steps (25%)**. You can select **5 steps (31.25%)**. These percentages describe the system volume setting; they are not calibrated sound-pressure levels or a guarantee of safe listening.

**We do not know whether Protect Ears will protect your hearing. It has not been proven to prevent hearing damage. Do not rely on it as hearing protection.** Read the [full disclaimer](DISCLAIMER.md).

## Download and install

Requires **macOS 13 or later**. The universal app supports **Apple silicon and Intel Macs**. No developer tools are needed for the download.

1. Download [Protect Ears for macOS (.dmg)](https://github.com/turnertop/protect-ears/releases/latest/download/Protect-Ears-macOS-universal.dmg) from the [latest release](https://github.com/turnertop/protect-ears/releases/latest).
2. Open the disk image and drag **Protect Ears.app** into **Applications**. Eject the disk image.
3. Open Protect Ears from Applications. Click the ear icon in the menu bar to see the ceiling and connected devices.
4. Optionally enable **Start at login** so it runs each time you sign in. macOS may ask you to allow the login item in System Settings.

A [ZIP download](https://github.com/turnertop/protect-ears/releases/latest/download/Protect-Ears-macOS-universal.zip) and SHA-256 checksums are also available in the release. For the ZIP, extract it and move the app into Applications.

**This release is ad-hoc signed and is not signed with an Apple Developer ID or notarized by Apple.** macOS may block it on first open. Only if you trust the download, follow [Apple's instructions for opening this individual app](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or remove quarantine attributes to install it.

The app does not require an account, network access, audio recording, Accessibility permission, or microphone permission.

## Build from source

Requires Apple's Command Line Tools or Xcode. If needed, install the tools with `xcode-select --install` first. No third-party packages are used.

```sh
git clone https://github.com/turnertop/protect-ears.git
cd protect-ears
zsh scripts/build-app.sh
open "dist/Protect Ears.app"
```

When building from source, keep the app bundle in a stable location before enabling **Start at login**. Login registration uses Apple's `SMAppService` and is off until you enable it.

## Keeping Start at login through updates

From **v1.0.3**, the app saves your On/Off choice. Quit the old app, replace it, and **open the updated app once**. If an update lost its login registration, the app restores your saved On choice. Off stays off. macOS approval requirements still apply; failed registration shows an error and a Retry button.

Versions **1.0.2 and earlier did not save this preference**. When upgrading from those versions, check the switch once after installation. A missing old registration is not treated as permission to enable login automatically.

Removing a login item in System Settings is recognized when the app next opens or becomes active. Locally signed builds cannot reliably distinguish a removal made while the app was closed from registration lost during a manual replacement. Open the existing app once after removing its login item and before replacing it, or use the local update script below, which checks the old registration before replacement. Developer ID signing provides a stable app identity across builds.

## Selecting headphones

AirPods Max are recognized by their output-device name. The app remembers their device UID after detection, including across later name changes. If your AirPods were already renamed without “AirPods Max” in the name, select their switch under **Connected outputs** once. Selecting other outputs applies the same ceiling to them.

## What it does

- Monitors all selected connected output devices, including when an app chooses an output independently of the system default.
- Responds to volume notifications, device changes, output-route changes, wake, and Core Audio service restarts.
- Inspects devices independently, so one unsupported or disappearing virtual device cannot cancel the whole scan. Uses the default outputs and remembered headphone identities as fallback discovery paths.
- Reinitializes this app's Core Audio connection after repeated discovery failures. Refresh requests the same recovery, with a cooldown to prevent reset loops.
- Corrects volume on a dedicated queue using cached headphone controls, independently of full device discovery. Duplicate notifications are combined, and unchanged state does not trigger UI updates.
- Checks selected output volume every 100 ms as a fallback. Discovery runs every five seconds when healthy, every second while waiting/recovering, and on connection/profile changes. Volume polling stops when no selected headphones are connected. These intervals are scheduling targets, not real-time deadlines.
- Checks main and individual output-channel controls when exposed by the device, falling back to its virtual main-volume control.
- Lowers values above the ceiling and verifies the result. It never raises a quiet volume or unmutes a device.
- Attempts to mute the selected device if the volume cannot be read, capped, or verified. A warning remains visible after an emergency mute; you must inspect and unmute manually.
- Keeps preferences locally. It does not play any test sounds or send any data.
- Remembers the Start at login choice and repairs a missing registration once on the first launch of a changed build, without repeatedly registering on activation or overriding pending macOS approval.

## Limits

**This is a reactive guard, not a strict audio-path limiter.** Core Audio reports volume changes after they occur. A brief spike can reach the headphones before the app corrects it, especially during connection, route/profile changes, wake, scheduling delays, or a driver failure. A 100 ms fallback does not establish a maximum possible response time.

The guard cannot enforce a ceiling while it is stopped, during startup before it can access a device, or while the AirPods are connected to a different computer/phone. Some device/driver volume controls may not be exposed. A green/running status means the latest volume check passed; it does not prove that no transient sound can pass.

A volume percentage also cannot prevent an app from making its audio louder *within* that setting. A strict signal ceiling requires processing every relevant audio stream before it reaches the headphones, plus control of the downstream device volume; this app does not install such an audio driver.

## Verify without playing sound

Completed checks and the remaining reconnect, sleep/wake, Discord, and long-session coverage are tracked in the [verification checklist](docs/verification-checklist.md). It can be picked up later, one scenario at a time.

```sh
zsh scripts/check.sh
"dist/Protect Ears.app/Contents/MacOS/ProtectEars" --diagnose
```

The check runner simulates device controls, repeated spikes, channel imbalance, UID-based reconnection, renaming, read/write failures, rejected writes, hardware rounding, and emergency muting. Monitor checks also cover stalled discovery, notification bursts, stale reconnect scans, bounded background work, and recovery serialization. They do not change real devices. `--diagnose` lists live output devices and volume controls without changing them.

If headphones are connected but missing from the app, click Refresh. Version 1.0.1 and later can recover this app's Core Audio connection when discovery fails. An error includes the failing audio object and property so a future report can identify the affected query. If detection is unavailable, the volume ceiling cannot be verified.

For a developer check of the process-local recovery API, run the diagnostic with `--diagnose --reset-audio-client`. It reinitializes only that diagnostic process's Core Audio connection and does not change volume or mute settings.

For a real-device check, pause all playback and keep the headphones off your ears. With the app running and the AirPods selected, check that moving the system-volume slider above the ceiling is corrected. Repeat after reconnecting and when entering/leaving a Discord call. This verifies correction behavior, not absence of a transient; do not test with loud sound.

## Development

`Sources/VolumeGuardCore` contains the volume monitor, background discovery, Core Audio adapter, and hardware-independent enforcement policy. `Sources/ProtectEars` contains the AppKit menu-bar host and SwiftUI controls. `Checks` contains the simulated-hardware checks and a dependency-free runner, so full Xcode/XCTest is unnecessary.

The default build script creates a locally ad-hoc-signed app in `dist` for the current Mac architecture. It is not notarized. For distribution without the unidentified-developer warning or a stable signed login-item identity, build and sign with your own Developer ID and submit it for notarization.

To build a universal app and create the downloadable disk image, ZIP, and checksums:

```sh
zsh scripts/package-release.sh
```

The universal app and release files are written to `dist/release/`, separately from the default local app. The package includes the MIT license, hearing-safety disclaimer, and installation instructions. The app's executable contains both `arm64` and `x86_64` slices with a macOS 13 minimum deployment target.

To update an existing local build, stage the app separately and use the installer:

```sh
zsh scripts/build-app.sh --universal
python3 scripts/install-local.py
```

The installer verifies the staged signature, asks the old app to preserve its login choice and unregister before it is backed up, stops that exact app, installs the replacement, and opens it. This keeps backup copies from accumulating as login items. For the one-time migration from v1.0.2 or earlier, specify `--legacy-login-on` or `--legacy-login-off` to record your known choice. Older copies may already have left duplicate login entries; remove those old entries in System Settings once.

If you have an existing signing certificate, set `PROTECT_EARS_SIGN_IDENTITY` to its exact identity when building or packaging. The build then uses that identity with hardened runtime and a timestamp. The default remains ad-hoc signing. Developer ID signing and notarization are separate distribution steps; the supplied downloads are not notarized.

GitHub Actions runs the simulated-hardware checks and verifies the app build on Apple silicon and Intel macOS runners. It cannot verify real Bluetooth behavior; testing with physical headphones is still necessary.

## Contributing

Bug reports and pull requests are welcome. For a bug report, include your macOS version, headphone model, Bluetooth or wired connection, what triggered the volume change, and the status shown in Protect Ears. Avoid posting private device identifiers. Run `zsh scripts/check.sh` before submitting a code change.

## License

[MIT](LICENSE). You can use, modify, and redistribute Protect Ears under the license terms.

References: [Apple's volume-change notification API](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)), [device volume controls](https://developer.apple.com/library/archive/qa/qa1016/), [Bluetooth microphone mode changes](https://support.apple.com/en-us/102217).
