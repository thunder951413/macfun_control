# FanBar

FanBar is a macOS 14+ menu bar app that monitors CPU temperature and can apply a conservative fan safety curve through AppleSMC.

Fan writes are performed by a separately signed, root LaunchDaemon registered with macOS `SMAppService`. The menu bar app remains unprivileged and communicates with the helper over an authenticated XPC connection.

The popover separates live sensor summaries from settings. Its General section controls menu bar content, the fan-curve temperature source, high-hotspot alerts, and the optional macOS login item. FanBar does not enable launch at login unless the user turns it on.

Battery-area monitoring uses the hottest valid `TB*T` SMC reading (normally `TB0T`, `TB1T`, or `TB2T`). Users can configure a menu bar alert threshold and optionally enable a separate battery curve. CPU and battery curves are combined by taking the higher requested fan target; the battery curve reaches maximum speed at 50°C.

The shared 0.5×–2.0× acceleration factor smoothly reshapes both curves without changing their start or maximum-temperature endpoints. FanBar enters manual mode only when its curve target is meaningfully higher than the target currently reported by macOS. Automatic-mode observations build a private, model-specific history of Apple's target RPM using temperature, power source, system load, and thermal pressure. This learned estimate is only a conservative floor: a manual session never lowers its target, FanBar yields for a real macOS demand audit every 30 seconds while the first six samples are learned and every 60 seconds afterward, and rapid temperature rises or serious thermal pressure bring that audit forward. Each audit keeps the highest of four closely spaced system targets to reject transition noise. Physical RPM increases still pass through the slew limiter; 90°C emergencies request maximum speed immediately.

The Settings tab shows the learned sample count and current estimate. History stays in `~/Library/Application Support/FanBar` and can be exported as a model-specific, repository-ready JSON file. Export is user initiated and excludes serial numbers, user names, host names, file paths, and exact timestamps; FanBar never uploads it automatically. The contribution format is documented in [`Profiles/README.md`](Profiles/README.md).

The Sensor tab reads Apple's power data in the shared sampling cycle. It separately shows the connected adapter's negotiated input capacity, live system load, and real battery-side charging power. Charging power uses Apple's battery telemetry with voltage/current fallback and is hidden as a watt value when the battery is not charging. A newly connected power source temporarily replaces the normal menu bar content with a plug icon and the negotiated watts for two seconds. The Settings tab offers 2-second responsive, 3-second balanced, and 5-second efficient sampling; changing it reschedules the single shared timer immediately without adding a second hardware polling loop.

Fan capability is detected from AppleSMC rather than a model-name list. When `FNum` reports zero controllable fans, FanBar enters temperature-only monitoring mode: it uses a thermometer menu bar icon, removes fan-speed display modes and every fan-control curve, skips privileged-helper registration, and keeps sensor monitoring plus CPU and battery alerts available.

## Safety behavior

- Fresh installs start in **monitor-only mode**. Fan writes require an explicit toggle.
- Manual control starts only above the selected 40–80°C threshold.
- A 3°C hysteresis band prevents repeated mode switching near the threshold.
- A manual target is never lower than the fan's current speed.
- Learned macOS demand can only raise the safety floor; it can never reduce a real or previous target.
- Automatic-demand audits use a 60-second steady-state interval and react sooner to rapid heating or serious system thermal pressure.
- The acceleration factor reshapes desired targets while the asymmetric RPM slew limiter remains authoritative.
- At 90°C, FanBar requests the hardware-reported maximum speed.
- Invalid sensor data, partial multi-fan writes, sleep, disabling control, and normal quit all trigger an automatic-mode restore.
- Restore first reads the current mode and performs no write when macOS already owns the fans.
- If macOS denies SMC writes, FanBar disables control and falls back to monitor-only mode.
- The helper accepts only the signed FanBar client from the same Apple Developer team and validates fan indices and RPM ranges again before writing.
- If automatic control cannot be restored, FanBar shows an alert and cancels normal termination so it can retry.

> AppleSMC is a private, model-dependent interface. FanBar validates all values it uses, probes mode-key variants, supports legacy `fpe2` and Apple Silicon little-endian float values, and verifies writes. The helper restores automatic control when the app disconnects, including force-quit and process crashes, but FanBar still cannot guarantee compatibility with every Mac or protect against firmware faults or another fan-control tool. Do not run multiple fan-control apps together.

## Build and test

Use the complete Xcode toolchain so the Testing framework is available:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release
```

For a locally signed app bundle:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer Scripts/build-app.sh
open .build/app/FanBar.app
```

The app appears only in the menu bar. Opening it does not enable hardware writes on a fresh install.

## Distribution

`Scripts/build-app.sh` requires an Apple Development or Developer ID Application signing identity because macOS will not register an ad-hoc signed privileged helper. Set `FANBAR_VERSION` and `FANBAR_BUILD_NUMBER` to inject bundle versions. Developer ID builds use a trusted timestamp by default; local offline builds may explicitly set `FANBAR_CODESIGN_TIMESTAMP=none`.

## GitHub releases

CI builds and tests every push to `main`. The manual Release workflow creates a signed, notarized Universal app and publishes its ZIP plus a SHA-256 checksum. It intentionally refuses to publish when any signing or notarization secret is missing:

- `DEVELOPER_ID_APPLICATION_P12_BASE64`
- `DEVELOPER_ID_APPLICATION_P12_PASSWORD`
- `APPLE_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `APPLE_TEAM_ID`

The certificate secret must contain a Developer ID Application identity and its private key in PKCS#12 format. Trigger the workflow with matching values such as version `1.0.0` and tag `v1.0.0`.

## Architecture

- `SMCClient` implements the 80-byte AppleSMC ABI, key probing, typed numeric conversion, and read-back verification.
- `FanBarHelper` is the minimal root daemon that owns SMC writes and restores automatic control when the last authenticated client disconnects.
- `FanService` serializes hardware access and owns transactional multi-fan rollback.
- `FanSafetyPolicy` is a pure, unit-tested curve and hysteresis policy.
- `FanController` owns polling, UI state, error fallback, sleep/wake, and shutdown behavior.
