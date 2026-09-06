# ROOMBRIX — Developer Brief (v1.0)
### iOS Room Acoustics Diagnostic & Treatment Planning App
*Prepared for development in Cursor. Owner: Roman / Inception Audio. Date: August 2026.*

---

## 1. Product Vision

**One sentence:** Roombrix measures your room with an iPhone, explains what's acoustically wrong in plain language, gives you a physical treatment plan (what to hang, where, and why), and proves the result with a before/after **Room Score**.

**The loop we own (and nobody else does):**

```
MEASURE → DIAGNOSE → PLAN (physical treatment + placement) → BUY → RE-MEASURE → SCORE DELTA
```

**What Roombrix is NOT:**
- Not another EQ/room-correction app. We do not generate PEQ/FIR filters in v1. DSP correction is a solved, crowded market (Dirac Live, HouseCurve, WiiM, Audyssey, ARC Genesis).
- Not a lab instrument. We are honest about phone-mic limitations and never present estimates as laboratory measurements.
- Not tied to any panel manufacturer. The diagnostic layer is vendor-neutral; recommendations may include products from multiple vendors (future commission model).

**Brand values baked into UX:** honesty about physics and measurement uncertainty. If a problem cannot be fixed with thin decorative panels (e.g., bass below ~250 Hz), the app says so explicitly. This honesty is the moat — the audiophile community destroys products that overclaim.

---

## 2. Market Landscape & the Gap

| Player | What it does | What it does NOT do |
|---|---|---|
| **REW** (free, desktop) | Gold-standard measurement (IR, RT60, waterfall, EQ export) | No interpretation, no recommendations, expert-only UX, needs laptop + mic |
| **HouseCurve** (iOS) | Sweep measurement via AirPlay/BT, target curves, PEQ/FIR export, UMIK support | Frequency-response/EQ focused; no RT60-driven diagnosis, no treatment plan, no placement, no score |
| **Dirac Live** ($259–349 + compatible hardware) | Best-in-class DSP correction; ART reduces bass decay via multi-speaker phase manipulation | Requires compatible AVR/miniDSP + calibrated mic; corrects electronically, cannot fix decay/reflections/flutter for the whole room; no treatment guidance |
| **WiiM / Audyssey / ARC / RoomPerfect** | Built-in auto-EQ in hardware | Same: DSP only, tied to their hardware |
| **Panel vendors (Vicoustic, GIK, Artnovion, Primacoustic)** | Sell absorbers/diffusers/bass traps; some offer human advice services or crude web calculators | No measurement, no verification, advice is a sales channel |

**The confirmed gap:** every software player converges on *electronic* correction of frequency response at the listening position. Nobody diagnoses the *room* (decay times, early reflections, modal behavior, flutter echo) and translates that into a *physical treatment plan with placement*, then closes the loop with a verified re-measurement. DSP cannot fix reverberation or reflections outside the sweet spot; physical treatment vendors have no diagnostic instrument. Roombrix sits exactly in that seam — and is *complementary* to Dirac et al. ("treat the room first, then let DSP polish the rest" is the professionally correct order of operations).

---

## 3. Target Users (MVP priority order)

1. **Hi-fi owner / audiophile** — has invested €2k–50k+ in a system, suspects the room is the weak link, intimidated by REW. Wants: clear diagnosis, credible plan, proof of improvement.
2. **Home studio / content creator** — needs controlled RT60 and clean early reflections for mixing/recording/streaming. Understands some terminology.
3. **(Phase 2) HoReCa operator** — restaurant/café noise problems. Different targets (speech intelligibility, noise buildup), same engine. Do not build UI for this in MVP, but keep the metric engine room-purpose-aware from day one.

---

## 4. Core Concept: Room Score

A single 0–100 composite score per room *purpose* (Listening / Studio / Home Theater; HoReCa later), decomposed into explainable subscores. The score is the brand asset: shareable, comparable before/after, gamified progress.

### 4.1 Subscores (v1 proposal — calibrate during beta)

| Subscore | Weight | Based on | Target (Listening room example) |
|---|---|---|---|
| **Decay (RT60)** | 30% | T20/T30 per octave band 125 Hz–4 kHz vs. target range scaled by room volume | ~0.3–0.5 s mid-band, tolerance band widens at LF |
| **Decay uniformity** | 15% | Flatness of RT60 across bands (bass ringing vs mids) | Ratio LF/mid decay < 1.5 |
| **Frequency response smoothness** | 20% | Variance of 1/3-octave smoothed magnitude at listening position, spatially averaged | ± window, psychoacoustically weighted |
| **Modal severity** | 15% | Predicted modes (from geometry) cross-checked against measured LF peaks/nulls and decay | Penalize strong isolated modes < Schroeder frequency |
| **Early reflections / clarity** | 15% | C50/C80 from impulse response; flutter-echo detection (periodic peaks in IR) | C80 > 0 dB for music |
| **Noise floor** | 5% | Background NC estimate | Informational; low weight (phone mic limits) |

Rules:
- Every subscore must be explainable in one plain-language sentence in the UI ("Your bass rings ~2× longer than your midrange — this is why bass sounds boomy and slow").
- Score algorithm versioned (`score_engine_v`); stored with every measurement so historical scores remain comparable after algorithm updates.
- Confidence interval displayed. With internal mic: score shown as a range (e.g., 62–68). With calibrated external mic: narrower range. Never a false-precision single integer with internal mic.

---

## 5. Technical Architecture

### 5.1 Platform & stack

- **iOS 17+ (SwiftUI), iPhone 12 and newer.** iPad support deferred. LiDAR-equipped devices get full RoomPlan geometry; non-LiDAR devices get manual room-dimension entry fallback.
- **All DSP on-device.** Swift + Accelerate/vDSP for FFT, convolution, filtering. No server round-trip for measurement (privacy + speed + offline). Consider a small C/C++ core (wrapped) for the DSP kernel if profiling demands it.
- **Persistence:** SwiftData or Core Data + CloudKit sync (rooms, measurements, plans, scores). Raw impulse responses stored locally, exportable.
- **No account required for first measurement** (activation friction kills this category). Account only for sync/history/plans.

### 5.2 Measurement engine (the hard 40% of the project)

**Stimulus & capture:**
- Exponential sine sweep (ESS, Farina method), ~10–20 Hz to 20 kHz, 5–10 s, plus inverse-filter deconvolution → impulse response. ESS chosen for harmonic-distortion rejection (phone speakers and consumer systems distort; ESS pushes harmonics into negative time where they can be windowed out).
- Also implement MMM (moving-mic measurement with pink noise) as secondary mode for spatially averaged frequency response.
- **Playback path problem (critical):** sweep must play through the *user's speakers*, not the phone. Options, all to be supported:
  1. AirPlay / Bluetooth from the app → **latency is variable and large**; do NOT trust system latency reporting. Solve with an **acoustic timing reference**: prepend a known chirp/marker to the stimulus, detect it in the recording, and align. (This is the industry-standard approach for phone-based measurement; treat it as a required spike in week 1–2.)
  2. Exportable stimulus file (WAV, with embedded timing marker) that the user plays from their streamer/Roon/USB stick — app just listens. Most robust path for audiophile systems; cheap to build; build it first.
  3. Wired output (USB-C dongle/DAC) where available.
- **Capture:** AVAudioSession in `.measurement` mode (disables Apple's AGC/processing). 48 kHz float. Verify per-device behavior — this is a known minefield; maintain a device quirks table.

**Microphone strategy:**
- Internal mic: sufficient for RT60, decay, mid/HF response shape, modal peak identification below 300 Hz (peaks are 6–15 dB — far above mic uncertainty). Known limitations: LF roll-off, unit variance, no absolute SPL trust.
- Ship a **generic per-model correction curve** set (iPhone 12…current), applied transparently, clearly labeled "estimated."
- **External calibrated mic support (USB Audio Class via USB-C, e.g., miniDSP UMIK-1/2) is a must for the Pro tier** — it's the credibility feature for the exact community that will review this app. Support loading the mic's calibration file.
- Room-acoustic parameters (RT60, C50/C80, decay ratios) are *relative* metrics — inherently robust to mic imperfections. Lead with these; treat absolute FR as secondary with internal mic. This is our honest-physics advantage over FR-centric competitors.

**Derived metrics (per measurement):**
IR → octave/third-octave filtered decay curves (Schroeder backward integration) → T20/T30, EDT; C50/C80; spatially averaged magnitude response (multi-point wizard: 3–9 positions around listening area); flutter-echo detector (autocorrelation of IR tail); background noise estimate.

**Validation requirement (acceptance criteria):**
- RT60 (500 Hz–2 kHz bands) within ±10–15% of REW + UMIK-1 reference across ≥10 real rooms of varied size/furnishing.
- Modal peak frequencies identified within ±3 Hz of reference below 200 Hz.
- Repeatability: two consecutive measurements, same position → Room Score delta ≤ 2 points.
- Build an automated comparison harness early: import REW `.mdat`-exported data (or text export) and diff against our engine. This harness is a deliverable, not an afterthought.

### 5.3 Geometry engine

- **RoomPlan API** (LiDAR devices): capture room dimensions, wall/window/door positions, large furniture. Store as parametric model.
- Fallback: manual L×W×H entry + guided photos.
- From geometry compute: axial/tangential/oblique modes (rectangular approximation with disclaimers for irregular rooms), Schroeder frequency, surface areas per boundary, estimated total absorption (Sabine baseline from furnishing questionnaire), **first-reflection points** via image-source method for user-marked speaker + listening positions (user drops speaker/seat markers onto the scanned floor plan).

### 5.4 Diagnosis & recommendation engine (rule-based v1 — no ML)

Deterministic, explainable rules mapping metric patterns → named problems → treatment prescriptions:

- Long mid/HF decay → total absorption deficit → required added Sabins per band → m² of absorption at specified coefficient class → placement priority list.
- LF decay ≫ mid decay + measured modal peaks matching predicted modes → bass problem → **honest output:** corner/wall-boundary bass traps of real depth, porous absorber thickness vs. frequency table shown to user; explicitly state thin panels won't fix this; suggest positional fixes (speaker/seat moves along modal distribution) as zero-cost first step; note DSP (Dirac/PEQ) as complementary for remaining LF peaks.
- Poor C80 + strong discrete early reflections → treat first-reflection points (absorb or diffuse depending on room size and taste profile) → exact wall coordinates from image-source calc, drawn on the room plan.
- Flutter echo detected between parallel bare walls → identified wall pair → absorb/diffuse one side.
- Every recommendation carries: predicted Room Score impact (range), cost tier, effort tier, and a "why" paragraph.

**Product database:** start with a neutral internal catalog of *generic* treatment types (broadband absorber 5/10/20 cm, corner trap, diffuser, thick curtain, rug, bookshelf) with published absorption coefficients (ISO 354 data where available). Vendor-specific SKUs (Vicoustic/GIK/Artnovion/own-brand) are a data layer added later — architect the recommendation engine against the generic taxonomy so vendor catalogs plug in without engine changes. Affiliate/commission links are Phase 2; design the product model with `vendor`, `affiliate_url`, `commission` fields now.

### 5.5 Placement & AR

- MVP: 2D floor-plan view with treatment placements marked + measurement positions. This is enough to ship.
- Phase 2: ARKit overlay ("hold up phone, see panels on your wall"). Do not block MVP on AR — it's the demo-wow feature, not the value core.

### 5.6 Before/after & reporting

- Guided re-measurement at the *same positions* (app stores positions on floor plan, guides user back).
- Delta view: score, subscores, RT60 curves, FR overlay. One-tap shareable report card (image) — organic-growth engine.
- Exportable PDF report (Phase 1.5): full metrics, plan, before/after. This doubles as the deliverable for Roman's hands-on consulting service — the app should generate the consultant-grade report from day one of paid tiers.

---

## 6. Monetization (build the seams now, activate later)

| Tier | Contents |
|---|---|
| **Free** | Measure, Room Score + subscores, top-1 problem diagnosis, share card |
| **Pro (subscription or one-time)** | Full diagnosis, treatment plan with placement, before/after history, external mic support, PDF reports, multi-room |
| **Commission layer (Phase 2)** | Vendor product recommendations with affiliate links; later: lead-gen to installers |
| **B2B/HoReCa (Phase 2+)** | Speech-intelligibility/noise targets, multi-zone, white-label reports |

---

## 7. Build Order (spikes first — de-risk the physics before UI polish)

**Sprint 0 — feasibility spikes (2–3 weeks, throwaway code allowed):**
1. AVAudioSession `.measurement` capture pipeline; verify AGC actually off across 3+ device models.
2. ESS generation + deconvolution + Schroeder integration → RT60 in a known room; diff vs REW/UMIK.
3. Acoustic timing-reference alignment over AirPlay/BT (variable latency).
4. RoomPlan scan → mode prediction → compare predicted vs measured LF peaks.
   *Go/no-go gate: RT60 within tolerance on internal mic in ≥3 rooms.*

**Milestone 1 — Measurement core:** stimulus file export path + phone-connected playback; multi-point wizard; metric engine; validation harness vs REW.
**Milestone 2 — Score & diagnosis:** Room Score v1, subscores, plain-language diagnosis, versioned scoring.
**Milestone 3 — Plan:** geometry engine, image-source reflection points, rule-based recommendations with generic product taxonomy, floor-plan placement view.
**Milestone 4 — Loop closure:** before/after flow, share card, history, free/pro gating.
**Milestone 5 — Credibility pack:** UMIK external mic + calibration files, PDF report, device quirks table hardening. → public beta on audio forums.

---

## 8. Non-Functional Requirements & Guardrails

- **Honesty UX (hard requirement):** confidence ranges on scores with internal mic; "estimate, not a lab measurement" framing; recommendation engine physically constrained (never prescribe thin panels for <250 Hz problems). Copy tone: expert, calm, zero marketing hype.
- **Privacy/GDPR:** all audio processed on-device and discarded — only derived metrics + IRs stored; room scans stay local unless user syncs; explicit mic-permission rationale; no audio content ever uploaded. Privacy manifest per current App Store requirements.
- **Performance:** full measurement → score in < 60 s post-capture on iPhone 12.
- **Localization:** EN first; RU/FR/DE structure in place (string catalogs from day one).
- **Testing:** DSP kernel fully unit-tested against synthetic IRs with known RT60/modes (generate synthetic rooms — exact ground truth); device-farm capture sanity checks.
- **Legal/claims:** app describes acoustic *estimates* and *recommendations*; absorption data cited to vendor/ISO 354 sources; no guaranteed-outcome language anywhere.

## 9. Explicit Out of Scope (v1)

PEQ/FIR filter generation and export (revisit later as "polish with DSP" handoff, possibly exporting to HouseCurve/REW-compatible formats rather than competing); Android; iPad-optimized UI; AR placement; vendor marketplace/checkout; multi-user/teams; HoReCa UI; ML-based anything.

## 10. Open Questions (decide during Sprint 0)

1. Score calibration: what measured deltas map to what score deltas so that a typical €500 treatment ≈ +10–15 points (perceptible progress, honest scale)?
2. Internal-mic correction curves: license/buy per-model data, measure in-house against UMIK, or crowd-calibrate later?
3. Sweep level guidance UX: how to get users to safe-but-sufficient SPL (~75–85 dB) without a calibrated meter — relative SNR check before measurement?
4. Rectangular-approximation limits: threshold of room irregularity beyond which modal prediction is hidden and only measured LF data shown?
5. Naming/trademark check for "Roombrix" and "Room Score" in EU/US before public beta.
