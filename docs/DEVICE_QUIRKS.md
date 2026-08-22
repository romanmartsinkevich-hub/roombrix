# Device Quirks Table

AVAudioSession `.measurement` mode behavior varies per device model. This
table is a **living deliverable** (brief §5.2 / Milestone 5): every supported
model gets verified before public beta. Fill rows via the Sprint 0 capture
spike on real hardware.

Verification protocol per device:
1. Configure `.playAndRecord` + `.measurement`, 48 kHz preferred.
2. Record a swept sine from a reference speaker at fixed level; repeat 3×.
3. Check: reported vs actual sample rate, AGC actually disabled (level
   linearity across a 20 dB stimulus sweep), LF roll-off corner, inter-unit
   variance if multiple units available.

| Model | iOS ver. tested | Actual sample rate | AGC off confirmed | LF roll-off (−3 dB) | Correction curve id | Notes |
|---|---|---|---|---|---|---|
| iPhone 12 | — | — | — | — | `ip12-v0` (placeholder) | Minimum supported device; performance budget baseline |
| iPhone 12 mini | — | — | — | — | — | |
| iPhone 13 | — | — | — | — | — | |
| iPhone 14 | — | — | — | — | — | |
| iPhone 15 | — | — | — | — | — | USB-C: verify UAC external mic path |
| iPhone 16 | — | — | — | — | — | |
| iPhone 17 | — | — | — | — | — | |

## Known platform behaviors to verify per model

- `.measurement` mode is documented to disable system signal processing, but
  the *degree* (AGC, HPF) has historically varied by model and iOS release —
  never assume, always measure.
- Preferred sample rate requests can be silently overridden (session reports
  the actual rate; `CaptureEngine` reads it back after activation).
- Bluetooth input routes must be rejected for measurement (codec-processed,
  useless): capture must pin to the built-in or USB (UAC) mic even when a BT
  output route is active.
- Multiple built-in mics: verify which one the default route selects and pin
  it (bottom mic preferred; avoid the noise-cancelling-processed routes).

## Internal-mic correction curves

Generic per-model correction curves (labeled "estimated" in the UI) ship as
a data table keyed by `Correction curve id`. Open question #2 in the brief:
license per-model data, measure in-house against UMIK-1, or crowd-calibrate.
Decision due end of Sprint 0. Relative metrics (RT60, C50/C80, decay ratios)
do not depend on these curves — only absolute FR shape does.

## External calibrated mics (Pro tier)

- miniDSP UMIK-1 / UMIK-2 over USB (UAC): support the vendor calibration
  file format (frequency/gain text pairs, 0° and 90° variants).
- When an external calibrated mic is active, scores display the narrow
  confidence range (±1 point) and absolute FR becomes first-class.
