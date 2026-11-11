# Verification checklist

Last updated: **2026-11-11**. Baseline: **v1.0.1**, commit `19102ee`.

This is a backlog for later; nothing here needs to be done immediately. Keep the current four/five-step volume guard and focus on detection, reconnects, and stability.

## Verified so far

- [x] All **38 simulated-hardware checks** passed, including partial discovery failures, fallback device lookup, changed device IDs, and recovery cooldowns.
- [x] Apple silicon and Intel macOS CI builds passed, along with universal download packaging and archive verification. [CI run](https://github.com/turnertop/protect-ears/actions/runs/43116218458).
- [x] A live diagnostic detected the AirPods Max and matched their remembered identity after reinitializing its own Core Audio connection.
- [x] One controlled, silent test verified enforcement by the **actual running app**, with playback paused and headphones muted and off the tester's head:
  - Guard paused: a six-step request remained at **37.5%** after 200 ms.
  - Guard running: output was back to **31.25% (five steps)** by the first measurement, approximately **12.1 ms** later, and stayed there during the short observation.
  - Previous **25%** output and mute setting were restored and checked in Sound settings. The prior Mac speaker output was subsequently restored too.
- [x] The fix was installed locally and published as [v1.0.1](https://github.com/turnertop/protect-ears/releases/tag/v1.0.1).

The live test used a programmatic volume request. It did **not** establish keyboard/Digital Crown behavior, automatic reconnect reliability, a maximum correction time, or prevention of every transient. CI uses simulated hardware, not physical Bluetooth headphones.

## Remaining checks

Check off a scenario only after recording its result below. For each one, verify that the **running app** detects the headphones and enforces the selected ceiling, rather than relying on the menu-bar icon or a separate diagnostic alone.

- [ ] **Automatic reconnect — first priority.** Repeat disconnect/reconnect at least five times, including the normal take-off/put-back-on workflow. With playback paused, observe whether the headphones return automatically without clicking Refresh. Record whether macOS connected automatically or someone manually selected the output; a manual connection does not prove automatic connection works.
- [ ] **Sleep/wake.** Check after sleep while connected and after reconnecting following wake. Confirm the saved ceiling still applies and discovery errors clear.
- [ ] **Discord audio changes.** Check entering/leaving an empty test voice channel and changing between the AirPods microphone and the Mac microphone. Confirm detection and enforcement survive profile/channel changes without leaving a stale error.
- [ ] **Speaker/headphone switching.** Switch both directions using distinguishable, low volume settings. Headphones should get their ceiling; unselected speakers should retain their own setting. Restore the original output afterward.
- [ ] **Keyboard and Digital Crown.** In a silent, controlled test, measure actual output during attempts to exceed five steps. Record correction timing and any sustained overshoot. Compare the on-screen bars with the actual level; the bars alone are not the measurement.
- [ ] **Refresh and recovery in the running app.** Use an instrumented test build to induce a discovery failure. Verify automatic recovery and the Refresh button, including that one broken device does not hide healthy headphones and that a failed recovery shows an error rather than a healthy status.
- [ ] **Restart and login.** Quit/reopen the app, then check a later login with Start at login enabled. Confirm the saved ceiling, remembered headphones, a single running instance, and actual enforcement.
- [ ] **Long session.** Leave the same app process running through a normal day with idle time, reconnects, and wake events. Verify that its monitoring continues working; a newly launched diagnostic is not sufficient evidence.

Additional physical Mac/headphone combinations can be recorded separately. Passing one machine does not establish coverage for all macOS versions or AirPods models.

## How to test and record results

For deliberate above-ceiling requests, pause **all playback**, keep the headphones **off your ears and out of the Smart Case**, and verify mute first. If the AirPods disappear from the audio-device list, reconnect/select them as output while they remain off your ears. Do not raise volume while wearing them or use loud playback as a test. Check the final volume and mute state, and restore any output selection changed for the test.

For ordinary head-on/head-off connection observations, keep playback paused and do not make above-ceiling requests. Mark those observations separately from an enforcement test.

Read-only inventory diagnostics, after building:

```sh
"dist/Protect Ears.app/Contents/MacOS/ProtectEars" --diagnose
```

**That command starts a separate process.** Finding the AirPods there does not prove the already-running guard is healthy. Likewise, an error-free device list does not prove that a volume request is clamped. Record both detection and enforcement evidence when claiming a scenario passed.

Copy this record for each completed scenario:

```text
Date / tester:
App version / commit:
macOS / Mac / headphone model / Bluetooth or wired:
Scenario / repetitions:
Automatic connection or manual output selection:
Detection result / Refresh needed:
Selected ceiling / actual output readings / correction timing:
Error text, including object/property/scope if present:
Final volume, mute, and output restored:
PASS / FAIL / NOT RUN and notes:
```

Leave anything unperformed marked **NOT RUN**. Avoid putting personal device identifiers in public results.

This verifies the behavior of a reactive volume guard. It is not a zero-spike or hearing-safety validation; the [hearing-safety disclaimer](../DISCLAIMER.md) continues to apply.
