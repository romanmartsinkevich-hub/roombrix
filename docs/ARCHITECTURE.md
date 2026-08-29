# Roombrix Architecture

## Design principles

1. **The engine is a pure, platform-independent Swift package.** Everything
   that computes — DSP, metrics, geometry, scoring, diagnosis — lives in
   `RoombrixCore` with zero UIKit/AVFoundation dependencies. It builds and
   tests on Linux, which gives us CI without Macs and keeps the physics
   testable in isolation. The iOS app is a thin shell: capture, UI,
   persistence.
2. **Deterministic and explainable.** No ML. Every subscore and every
   recommendation carries a plain-language sentence. Score and rule engines
   are versioned (`ScoreEngine.version`, `DiagnosisEngine.version`) and the
   version is stored with every result.
3. **Honest physics as a hard constraint, not copy.**
   `DiagnosisEngine.isValidBassTreatment` rejects any treatment with < 20 cm
   depth for sub-250 Hz problems; `Absorption.lowestEffectiveFrequency`
   encodes the quarter-wavelength rule; internal-mic scores are ranges
   (±3 points), calibrated-mic scores ±1.

## Module graph

```
RoombrixDSP          (layer 0: signals — no acoustics knowledge)
    ↑
RoombrixAcoustics    (layer 1: IR → RT60, clarity, flutter, FR)
    ↑                RoombrixGeometry (layer 1: modes, Sabine, image-source)
    ↑                    ↑
RoombrixScoring      (layer 2: Room Score v1)
    ↑
RoombrixDiagnosis    (layer 3: problems → treatment plan)

RoombrixValidation   (side-car: WAV, REW import, diff harness)
roombrix-validate    (CLI over Validation)
```

## Measurement pipeline

```
[ambient capture]           → NoiseFloor.estimate, SNR gate
[stimulus]                  = TimingReference marker + guard + SineSweep (ESS)
[recording]                 → TimingReference.detect  (alignment; confidence ≥ 12 dB required)
aligned recording           → Deconvolution.impulseResponse (harmonics windowed out pre-peak)
impulse response            → RoomAnalyzer.analyze
  ├─ OctaveBand filter (zero-phase) → SchroederIntegration → ReverbTime (T20/T30/EDT)
  ├─ Clarity (C50/C80/D50 from direct-sound arrival)
  ├─ FlutterEcho (detrended log-envelope autocorrelation)
  └─ FrequencyResponse (1/3-oct smoothing, spatial average, LF peak finding)
AcousticReport (+ RoomGeometry) → ScoreEngine.score → RoomScore
                                → DiagnosisEngine.diagnose → Diagnosis (problems + plan)
```

### Playback paths (why the timing marker exists)

AirPlay/Bluetooth latency is variable and system latency reporting is not
trustworthy. Every stimulus therefore starts with a known 1–8 kHz chirp;
`TimingReference.detect` finds it in the recording by matched filtering and
everything downstream aligns to that. The same mechanism makes the
**exported-stimulus-file path** work: the user plays the WAV from their
streamer and the app only listens. That path is implemented first
(`roombrix-validate stimulus` exports it today).

### Key DSP decisions

- **ESS (Farina) over MLS/noise:** harmonic distortion of phone speakers and
  consumer systems deconvolves into negative time and is discarded by the
  pre-peak window in `Deconvolution`.
- **Zero-phase band filtering** (forward-backward biquads) so octave filters
  don't smear decay curves asymmetrically before Schroeder integration.
- **Noise-truncated Schroeder integration** (simplified Lundeby): noise floor
  estimated from the IR tail, integration truncated at noise + 8 dB, otherwise
  RT estimates bias long.
- **Flutter detection on the detrended log-energy envelope:** removing the
  exponential-decay trend first is what prevents every smooth room from
  false-positiving at small lags.
- **Pure-Swift FFT** (no vDSP fast path yet). If device profiling demands it,
  a vDSP-backed implementation can be added behind the same API surface
  (`FFT.transform/convolve/crossCorrelate`) without touching callers.

## Scoring (v1 weights, brief §4.1)

| Subscore | Weight | Source |
|---|---|---|
| Decay (RT60) | 30 % | per-band T30/T20 vs volume-scaled purpose target, LF tolerance widened ×1.5 |
| Decay uniformity | 15 % | LF/mid decay ratio vs purpose limit |
| FR smoothness | 20 % | psychoacoustically weighted std-dev of smoothed curve |
| Modal severity | 15 % | LF peak prominence, cross-checked against predicted modes |
| Clarity | 15 % | C80 vs purpose minimum, flutter penalty |
| Noise floor | 5 % | ambient estimate, informational |

Room purposes (Listening / Studio / Home Theater / **HoReCa**) each carry
their own targets — HoReCa has engine support from day one, no UI in MVP.

## Diagnosis rules (v1)

1. Mid/HF decay above target → required added sabins (Sabine) → m² of 10 cm
   broadband absorption → placement priority. Overdamped rooms get diffusion
   advice instead — honesty cuts both ways.
2. LF/mid ratio above limit or measured modal peaks (geometry-confirmed when
   a reliable scan exists) → **first** a zero-cost positional recommendation,
   **then** corner traps of real depth with the quarter-wavelength honesty
   paragraph and the "DSP is complementary" note.
3. C80 below purpose minimum → treat first-reflection points; exact wall
   coordinates from `ImageSource` when speaker/seat markers exist, mirror-trick
   instructions otherwise. Absorb in small rooms, diffuse in large.
4. Flutter echo → wall pair identified by matching detected spacing to room
   dimensions → treat ONE side.

Every recommendation carries: predicted score impact **range**, cost tier,
effort tier, and a rationale paragraph. The product taxonomy is generic and
vendor-neutral; `Product` rows (with `vendor`, `affiliateURL`, `commission`)
attach to treatment types later without engine changes.

## Geometry

Rectangular approximation with an explicit `irregularityFactor`; above 0.25
the UI must hide modal predictions and show only measured LF data (open
question #4 — threshold to be calibrated in beta). RoomPlan scans (LiDAR) and
manual L×W×H entry both reduce to `RoomGeometry`.

## Product-level measurement policies (binding for app + CLI)

- **Channel handling:** analyze exactly ONE explicit input channel (first
  channel); never sum/downmix channels. Downmixing a stereo or mid-side
  external mic partially cancels reverberant energy and biases decay
  measurements short (verified on MV88 recordings: downmix shifted HF T30 by
  −20…−30 % and produced a physically impossible 8 kHz > 4 kHz decay). The
  iOS capture path reads channel 0 only; the CLI states which channel it
  used.
- **Adaptive RT metric selection:** per band, from the usable decay range
  above the EDC noise plateau (with 10 dB safety margin): ≥ 40 dB → T30,
  25–40 dB → T20, < 25 dB → band reported unmeasurable. The selected metric
  is carried in `BandDecay.selectedMetric` and surfaced in every report.
  Justified on real data: a −43 dB plateau biased T30 +19 % vs REW while T20
  stayed at +3 %.
- **Mic calibration:** correction curves (built-in per-device or user-loaded
  UMIK-style files) apply to frequency-response metrics ONLY, never to decay
  or clarity (relative time-domain metrics). Enforced structurally: the decay
  pipeline has no calibration input. Built-in curves are produced by the
  substitution method (see `docs/DEVICE_QUIRKS.md`).
- **Timing-marker plausibility gates** (confidence alone is not trusted —
  a false lock onto the sweep once reported 24.5 dB confidence): candidate
  positions must leave room for the full stimulus; the start marker must be
  ≥ 6 dB louder than the region preceding it; start/end marker spacing
  implying > 2 000 ppm clock drift is a detection failure.

## App-side responsibilities (not in RoombrixCore)

- `CaptureEngine`: AVAudioSession `.measurement` capture (AGC off), 48 kHz.
  Per-device behavior verified against `docs/DEVICE_QUIRKS.md`.
- `MeasurementCoordinator`: state machine for the measurement flow; runs the
  engine off-main (< 60 s post-capture budget — the engine itself completes in
  seconds).
- Persistence (SwiftData + CloudKit), RoomPlan wrapper, multi-point wizard,
  floor-plan rendering, share cards, PDF reports: Milestones 2–5.

## Privacy invariants

Raw audio never leaves the device and is discarded after deconvolution; only
derived metrics and impulse responses are stored. Room scans stay local unless
the user syncs. No account for the first measurement.
