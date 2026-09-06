# Roombrix

iOS room-acoustics diagnostic and treatment-planning app.

**The loop:** MEASURE → DIAGNOSE → PLAN (physical treatment + placement) → BUY → RE-MEASURE → SCORE DELTA

Roombrix measures your room with an iPhone, explains what's acoustically wrong
in plain language, gives you a physical treatment plan (what to hang, where,
and why), and proves the result with a before/after **Room Score**.

Roombrix is *not* an EQ/room-correction app and *not* a lab instrument. It is
honest about phone-mic limits and about physics — if a problem cannot be fixed
with thin panels (bass below ~250 Hz), it says so.

## Repository layout

| Path | Contents |
|---|---|
| `RoombrixCore/` | Platform-independent Swift package: the entire measurement, scoring, and diagnosis engine. Builds and tests on macOS **and Linux** (pure-Swift DSP, no Accelerate dependency required). |
| `RoombrixCore/Sources/RoombrixDSP` | FFT, ESS sweep + inverse filter (Farina), deconvolution, acoustic timing reference, biquads, octave-band filterbank |
| `RoombrixCore/Sources/RoombrixAcoustics` | Schroeder integration, RT60 (T20/T30/EDT), C50/C80/D50, flutter-echo detector, frequency response, noise floor |
| `RoombrixCore/Sources/RoombrixGeometry` | Room modes, Schroeder frequency, Sabine absorption, image-source first reflections |
| `RoombrixCore/Sources/RoombrixScoring` | Versioned Room Score v1 with explainable subscores and mic-dependent confidence ranges |
| `RoombrixCore/Sources/RoombrixDiagnosis` | Rule-based problems → treatment plan; generic vendor-neutral product taxonomy |
| `RoombrixCore/Sources/RoombrixValidation` | WAV I/O, REW text-export import, engine-vs-reference diff harness |
| `ios/Roombrix/` | SwiftUI app (XcodeGen project; UI shell + AVAudioSession capture pipeline) |
| `docs/` | Architecture, validation plan, device quirks table, the developer brief |

## Quick start (engine)

Requires Swift 5.10+ (macOS or Linux).

```bash
cd RoombrixCore
swift test                      # 63 unit tests against synthetic ground truth
swift run roombrix-validate stimulus /tmp/stimulus.wav   # export measurement WAV
swift run roombrix-validate rt60 ir.wav --rew rew-rt60.txt  # diff vs REW
```

## Quick start (app)

```bash
brew install xcodegen
cd ios/Roombrix && xcodegen generate && open Roombrix.xcodeproj
```

## Status

Sprint 0 / Milestone 1 engine foundation:

- [x] ESS generation + deconvolution + Schroeder integration → RT60 (validated against synthetic IRs, ±10 %)
- [x] Acoustic timing-reference alignment (variable-latency playback paths)
- [x] Mode prediction from geometry + measured-peak cross-check
- [x] Room Score v1 (versioned, confidence ranges, plain-language subscores)
- [x] Rule-based diagnosis with honest-physics constraints
- [x] REW comparison harness (CLI) — the acceptance-criteria deliverable
- [ ] On-device capture verification across device models (`docs/DEVICE_QUIRKS.md`)
- [ ] Real-room validation vs REW + UMIK-1 (≥ 10 rooms; harness ready)
- [ ] RoomPlan scan integration, multi-point wizard UI, floor-plan placement view

See `docs/ARCHITECTURE.md` for the design and `docs/BRIEF.md` for the full
product brief.
