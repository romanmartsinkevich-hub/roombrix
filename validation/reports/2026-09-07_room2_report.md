# Campaign Report — Room 2 (2026-09-07, second domestic room, different system)

Phone on a tripod, vertical, bottom mic down. Reference: REW V5.31.1 +
OmniMic, two takes, averaged. Approx dimensions 4.2 × 3.75 × 2.6 m.

## Why CI was red (diagnosis)

Neither (a) nor (b) alone — the upload landed **inside room 1's folder**,
so the harness treated four captures from two different rooms as one room,
and (b) also fired: the REW impulse WAVs (`impulse_V1/V2.wav`) were parsed
as captures and failed marker detection, aborting the room. Fixed both
ways: room 2 moved to its own folder, and the harness now recognizes only
`roombrix_capture_*.wav` as captures, averages all `*rt60*.txt` references,
and ignores everything else (HOWTO updated). The Node.js deprecation
warning was indeed noise.

## Result: PASS (accuracy and repeatability)

| Band | Take 1 | Take 2 | Reference (avg of 2) | Worst err | Spread |
|---|---|---|---|---|---|
| 250 Hz | 0.688 | 0.727 | 0.720 | −4.3 % | 5.6 % |
| 500 Hz | 0.608 | 0.630 | 0.589 | +7.0 % | 3.6 % |
| 1 kHz | 0.638 | 0.631 | 0.664 | −4.9 % | 1.0 % |
| 2 kHz | 0.658 | 0.673 | 0.647 | +4.0 % | 2.2 % |
| 4 kHz | 0.635 | 0.617 | 0.619 | +2.6 % | 3.1 % |

Identical fit windows across takes in every band. Agrees closely with the
owner's independent implementation (±9 % band-wise on the default window).

## Repeatability gate re-derived (the one [ROOM1] constant that failed)

The flat 3 % gate tripped at 250 Hz (5.6 %) and marginally at 4 kHz
(3.1 %). Evidence for the new gate:
- the REW + OmniMic reference ITSELF spread **5.6 / 4.5 / 3.7 / 2.5 /
  0.2 %** (250 Hz → 4 kHz) between its own two takes in the same air —
  sub-2 kHz short-interval nonstationarity of ±2–5 % is real even for a
  lab-grade chain;
- the phone chain's intrinsic HF spread measured 2–3 % in both rooms with
  identical windows — a 3 % gate flags measured noise, not defects;
- the defects the gate exists to catch (window-selection instability)
  manifested as 7–44 % before the anchored-window fix — far above 4 %.

New gate: **≤ 4 % at ≥ 1 kHz, ≤ 6 % at 250/500 Hz** (`RoomCampaign.
repeatabilityTolerance`, provenance `[ROOM1+ROOM2]`).

## Per-constant verdict ([ROOM1] entries in Calibration.swift)

| Constant | Verdict | Evidence in room 2 |
|---|---|---|
| `cliffAnchorOffsetDB` (+3 dB) | **HELD** | Windows identical across takes; accuracy ±7 %. Room 2 has shallow cliffs (different system/distance), so the anchored policy converges toward the standard window — and matches the owner's default-window check. |
| `fitWindowGridDB` (5 dB) | **HELD** | No window flips between takes in any band. |
| `cliffAnchorTimeSeconds` (5 ms) | **HELD** | Same evidence. |
| `preferredSpanDB` (25 dB) | **HELD** | Accuracy within ±7 % at all criteria bands. |
| `fitWindowEndFloorDB` (−43 dB) | **HELD (not stressed)** | Shallow-cliff room rarely reaches the floor; no adverse effect. Needs the hard-surfaced restaurant room for a real test. |
| `endFloorMinimumSpanDB` (18 dB) | **HELD (not stressed)** | Same. |
| `minimumPlausibleDecaySeconds` (20 ms) | **HELD** | No artifacts reported in any band. |
| `perBandDirectGateDB` (45 dB) | **HELD** | No false excessive-level warning on healthy captures. |
| `pinkNoiseTargetSNRdB` (27 dB) | **HELD** | Level stage produced healthy captures on a different system. |
| repeatability gate (3 %) | **FAILED → re-derived** | See above; now 4 %/6 % band-dependent. |
| `RoomPurpose.rt60Target` ("ideal 0.28–0.47 s") | **STILL PROVISIONAL** | Drives the decay subscore and the top problem in both rooms; not measurable against REW (it is a preference target, not a physical quantity). Stays [ROOM1] until the campaign dataset supports calibration. |
| Flutter detector thresholds | **PENDING** | "Flutter, surfaces ~1.0 m apart" flagged as top problem in both takes; owner will clap-verify. If inaudible → these captures become false-positive regression fixtures. |

## Also noted

- **Informational LF bands read 35–40 % short vs REW** in this room while
  250 Hz–4 kHz is spot-on. Logged in DEVICE_QUIRKS as a possible
  vertical-orientation / bottom-mic-vs-tripod interaction; controlled
  orientation test recommended. (REW's own thirds scatter 0.51–0.74 s at
  125 Hz here, so the reference is soft too.)
- **Mode-display confusion fixed:** matched modes are now named with their
  type, predicted frequency, and axes ("matches a predicted tangential
  mode at 80.3 Hz (along width + height)") so the axial-only list below
  no longer reads as a contradiction.
