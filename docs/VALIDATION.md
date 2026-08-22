# Validation Plan

Acceptance criteria (from the brief, §5.2) and how each is verified.

## Acceptance criteria

| Criterion | Verification | Status |
|---|---|---|
| RT60 (500 Hz–2 kHz) within ±10–15 % of REW + UMIK-1 across ≥ 10 real rooms | `roombrix-validate rt60 <ir.wav> --rew <export.txt>` per room; harness emits per-band verdict and exit code | Harness ready; real-room campaign pending |
| Modal peak frequencies within ±3 Hz below 200 Hz | `RoomModes.matchPeaks(toleranceHz: 3)` + `FrequencyResponse.lowFrequencyPeaks`; synthetic test recovers a 100 Hz mode | Synthetic pass; real-room pending |
| Repeatability: consecutive measurements → score delta ≤ 2 points | `ReverbTimeTests.testRepeatability` (synthetic analog); device repeatability test in beta protocol | Synthetic pass |
| Full measurement → score < 60 s post-capture on iPhone 12 | Engine pipeline is O(n log n); Linux benchmark: full analysis of a 3 s 48 kHz IR ≈ seconds. Device profiling once app shell captures | Pending device run |

## Synthetic ground truth (unit tests)

The DSP kernel is tested against synthetic impulse responses with *exact*
known answers (`Tests/RoombrixAcousticsTests/SyntheticIR.swift`):

- **Exponential decays** with envelope `10^(−3t/RT)` → RT60 recovery within
  ±10 % (±15 % with a −45 dB noise floor injected).
- **Band-dependent decays** (bass 2× mids) → LF/mid ratio and per-band RT.
- **Analytic C80**: for a pure exponential decay,
  `C80 = 10·log10(10^(0.48/RT) − 1)`; measured within ±1 dB.
- **Flutter**: periodic spike train at 20 ms → period within ±2 ms, spacing
  within ±0.4 m; smooth decays must *not* trigger detection.
- **Modal IR**: 100 Hz decaying sinusoid → LF peak found within ±8 Hz of truth
  (grid-limited; the ±3 Hz criterion applies to the dedicated LF analysis on
  real measurements, to be tightened with a zoom FFT below 300 Hz).
- **FFT vs naive DFT**, convolution vs direct sum, round-trips.
- **Timing marker** recovered within ±2 samples at −6 dB SNR into noise;
  pure noise stays below the confidence gate.
- **Clock drift**: end-of-stimulus marker spacing recovers 0 ppm and an
  injected +1000 ppm within ±100 ppm; alignment resolves to the *start*
  marker even when the end marker correlates more strongly.

### Known limitation: `TimingReference.confidenceDB` threshold

The 12 dB minimum-confidence gate (`TimingReference.minimumConfidenceDB`)
was tuned on **marker + noise synthetics only**. On real recordings the ESS
payload is present in the correlation signal and inflates the correlation
RMS (the denominator of the peak-to-RMS confidence metric), which deflates
`confidenceDB` for perfectly good detections. **Re-tune this threshold on
real sweep recordings during the Sprint 0 capture spike** — either by
excluding the payload region from the RMS estimate or by recalibrating the
threshold empirically across the device-quirks test matrix. Until then,
treat marginal confidence failures on real hardware as suspect-threshold,
not suspect-recording.

Run: `cd RoombrixCore && swift test` (63 tests).

## REW comparison harness

`roombrix-validate` is the acceptance-criteria deliverable:

```bash
# Export the measurement stimulus for playback from a streamer/USB stick:
swift run roombrix-validate stimulus stimulus.wav --duration 10 --rate 48000

# Analyze an impulse response (WAV) and diff against REW's RT60 text export:
swift run roombrix-validate rt60 room-ir.wav --rew rew-rt60-export.txt
# exit 0 = PASS (all 500 Hz–2 kHz bands within ±15 %), exit 2 = FAIL
```

`REWImport` parses REW "export as text" frequency-response files and RT60
tables. Add `.mdat`-derived exports per room to a `validation-data/` folder
(git-LFS if large) as the real-room campaign runs.

## Real-room campaign protocol (Sprint 0 gate)

For each of ≥ 10 rooms (varied size/furnishing):

1. Reference: REW + UMIK-1, ESS sweep, same positions.
2. Roombrix: same sweep via the exported-stimulus path, phone at the
   reference mic position (internal mic).
3. Export REW RT60 text; run the harness; archive the verdict.
4. Repeat Roombrix measurement without moving anything → score delta ≤ 2.

**Go/no-go gate:** RT60 within tolerance on the internal mic in ≥ 3 rooms.
