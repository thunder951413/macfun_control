# FanBar

FanBar is a macOS 14+ menu bar app that monitors CPU temperature and can apply a conservative fan safety curve through AppleSMC.

Fan writes are performed by a separately signed, root LaunchDaemon registered with macOS `SMAppService`. The menu bar app remains unprivileged and communicates with the helper over an authenticated XPC connection.

The popover separates live sensor summaries from settings. Its General section controls menu bar content, the fan-curve temperature source, high-hotspot alerts, and the optional macOS login item. FanBar does not enable launch at login unless the user turns it on.

Battery-area monitoring uses the hottest valid `TB*T` SMC reading (normally `TB0T`, `TB1T`, or `TB2T`). Users can configure a menu bar alert threshold and optionally enable a separate battery curve. CPU and battery curves are combined by taking the higher requested fan target; the battery curve reaches maximum speed at 50°C.

The shared 0.5×–2.0× acceleration factor smoothly reshapes both curves without changing their start or maximum-temperature endpoints. Physical RPM changes still pass through the asymmetric slew limiter, so changing the factor cannot make normal control jump directly to a new target.

Fan capability is detected from AppleSMC rather than a model-name list. When `FNum` reports zero controllable fans, FanBar enters temperature-only monitoring mode: it uses a thermometer menu bar icon, removes fan-speed display modes and every fan-control curve, skips privileged-helper registration, and keeps sensor monitoring plus CPU and battery alerts available.

## Safety behavior

- Fresh installs start in **monitor-only mode**. Fan writes require an explicit toggle.
- Manual control starts only above the selected 40–80°C threshold.
- A 3°C hysteresis band prevents repeated mode switching near the threshold.
- A manual target is never lower than the fan's current speed.
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
