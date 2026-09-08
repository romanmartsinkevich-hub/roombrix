# Device Quirks Table

AVAudioSession `.measurement` mode behavior varies per device model. This
table is a **living deliverable** (brief §5.2 / Milestone 5): every supported
model gets verified before public beta. Fill rows via the Sprint 0 capture
spike on real hardware.

Verification protocol per device (the in-app device check produces all of
this automatically — paste its report into the row):
1. Configure `.record` + `.measurement`, 48 kHz preferred, input pinned:
   built-in mic port selected explicitly, omnidirectional-capable data
   source preferred, omni polar pattern requested. Record requested vs
   **granted** pattern — several iPhone models expose selectable patterns
   including directional ones, which reproduce the MV88 reverb-suppression
   failure mode. Configuration fails loudly if a directional pattern is
   locked in.
2. Loop steady pink noise from an external system; record 8 s; check level
   drift across 1 s blocks (> 1.5 dB drift = gain-riding AGC).
3. Log: input port, selected data source name, polar pattern requested vs
   granted, negotiated sample rate, `.measurement` mode accepted.
4. LF roll-off corner and inter-unit variance where reference gear allows.

| Model | iOS ver. tested | Actual sample rate | AGC off confirmed | LF roll-off (−3 dB) | Correction curve id | Notes |
|---|---|---|---|---|---|---|
| **iPhone 15 Plus (MU183ZD/A)** | 26 (2026-08-29) | 48 000 Hz (as preferred) | `.measurement` accepted; AGC drift check pending re-run | — | — | Primary validation device. Input pinned: MicrophoneBuiltIn, data source "Снизу"/Bottom (1 of 3), polar pattern omnidirectional requested AND granted. Input gain ~12.8 dB below a Shure Motiv reference at identical SPL, but noise floor ~19 dB lower → net usable dynamic range BETTER (58.6 vs 52.4 dB). Do not compensate gain. Validated end-to-end vs REW: 250 Hz–4 kHz within ±10.5 %, repeatability ≤ 2.5 %. |
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

## CLOSED: phone orientation does NOT explain capture deviations (negative result)

Controlled experiment, room 4 office (2026-09-08): same position, same
room, one capture per orientation (vertical vs horizontal):

| band    | vertical | horizontal | delta |
|---------|----------|------------|-------|
| 125 Hz  | 1.314    | 1.386      | +5 %  |
| 250 Hz  | 1.230    | 1.105      | −10 % |
| 500 Hz  | 0.830    | 0.847      | +2 %  |
| 1 kHz   | 0.720    | 0.740      | +3 %  |
| 2 kHz   | 0.692    | 0.704      | +2 %  |
| 4 kHz   | 0.635    | 0.660      | +4 %  |
| 8 kHz   | 0.565    | 0.558      | −1 %  |

Orientation makes no material difference at 500 Hz–8 kHz: every delta sits
inside normal take-to-take spread. The orientation hypothesis — raised for
the garage 500 Hz miss (room 3, ~20 % short vs OmniMic) and the rooms 2/3
low-frequency observations (125 Hz −35 % in room 2, +25 % in room 3) — is
therefore **REJECTED**. The garage 500 Hz quarantine keeps its
non-diffuse-field explanation (concentrated junk-pile absorption →
direction-dependent decay), with orientation now eliminated as a factor.
The LF observations remain open without an orientation component; note
that REW's own third-octave values at 125 Hz scattered 0.51–0.74 s between
takes in room 2, so much of the LF disagreement is field/positioning
variance, not the phone.

Caveat: one capture per orientation only, so within-orientation
repeatability is not established by this experiment; the
between-orientation comparison stands because both captures sit far inside
the take-to-take spread observed across rooms 1–3.

## Internal-mic correction curves

Generic per-model correction curves (labeled "estimated" in the UI) ship as
a data table keyed by `Correction curve id`. Relative metrics (RT60, C50/C80,
decay ratios) do not depend on these curves — only FR shape does; calibration
is never applied to decay metrics (see `MicrophoneCalibration`).

**Substitution method (how built-in curves are generated):** a reference
omnidirectional measurement microphone (with its own calibration file loaded)
and the phone are placed at the same position, and both record the same
stimulus played through the same system, back to back. Both magnitude
responses are computed with identical smoothing (1/3 octave); the phone's
correction curve is the difference `phone response − reference response`,
smoothed and clamped outside 40 Hz–16 kHz where phone data becomes
unreliable. Repeat over ≥ 3 units per model where possible; ship the median
curve and note unit spread in this table.

## External calibrated mics (Pro tier)

- miniDSP UMIK-1 / UMIK-2 over USB (UAC): support the vendor calibration
  file format (frequency/gain text pairs, 0° and 90° variants).
- When an external calibrated mic is active, scores display the narrow
  confidence range (±1 point) and absolute FR becomes first-class.
