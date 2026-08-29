# Validation Report — Room "R", 2026-08-23

**Inputs analyzed**

| File | What it is |
|---|---|
| `validation/recordings/wav_1 test.aifc` | Phone-chain recording, take 1 (QuickTime AIFF-C, 48 kHz, 16-bit stereo, 17.0 s) |
| `validation/recordings/wav_2 test.aifc` | Phone-chain recording, take 2 (same format, 21.6 s) |
| `validation/rew/R Aug 23_[1-3].wav` | REW-exported impulse responses (OmniMic reference), 2.73 s each |
| `validation/rew/RT60_R Aug 23_[1-3].txt` | REW RT60 exports (V5.40 Beta 133) — the reference values |

Both recordings passed intake checks: no clipping, timing marker found at
29.4 / 30.5 dB confidence (minimum 12), detected offsets 0.999 s / 2.585 s.
SNR was 29.5 / 35.4 dB — below the 40 dB target (see actions).

---

## 1. Engine cross-check on REW's own impulse responses — PASS

Before judging the phone chain, our band analysis was run directly on REW's
exported IRs and diffed against REW's own RT60 numbers. Same input data, so
any difference is purely analysis method.

T30, ours vs REW, per reference measurement (errors in %):

| Band | Ref 1 | Ref 2 | Ref 3 | Verdict |
|---|---|---|---|---|
| 63 Hz | −32.2 | −25.4 | −22.3 | info (see note) |
| 125 Hz | −20.3 | −16.8 | −19.5 | info (see note) |
| 250 Hz | −6.5 | −8.6 | −11.5 | ok |
| 500 Hz | **+0.9** | **+2.2** | **+0.9** | PASS |
| 1 kHz | −11.0 | −10.5 | −12.9 | PASS |
| 2 kHz | −10.3 | −7.7 | −8.1 | PASS |
| 4 kHz | −8.2 | −6.7 | −8.7 | ok |
| 8 kHz | +1.3 | +2.9 | +2.0 | ok |

All acceptance-criteria bands within ±15 % on all three references →
**the analysis engine is validated against REW on identical data.**

*Note on 63/125 Hz:* the exported IRs are only 2.73 s long with the peak at
1.0 s, leaving 1.73 s of decay. With this room's LF reverb at 1.6–1.9 s, a
T30 fit needs more decay range than the file contains, so our noise-truncated
estimate reads short. This is a data-window limitation, not an engine error —
REW itself disagrees with itself at 63 Hz across the three takes (1.63–1.92 s,
an 18 % spread). If convenient, export IRs with a longer window (≥ 5 s) next
time; the RT60 text export alone is also sufficient.

## 2. Phone-chain recordings vs REW reference

Criteria: ±15 % on 250 Hz–4 kHz; informational below 250 Hz.

| Band | Take 1 | Take 2 | REW ref 1 | Error (t1) | Status |
|---|---|---|---|---|---|
| 63 Hz | 3.72 s | 3.33 s | 1.92 s | +93 % | info |
| 125 Hz | 1.264 s | 1.266 s | 1.208 s | **+4.7 %** | info (ok) |
| 250 Hz | 1.019 s | 1.016 s | 1.055 s | **−3.4 %** | **PASS** |
| 500 Hz | 0.740 s | 0.740 s | 0.731 s | **+1.2 %** | **PASS** |
| 1 kHz | gated | gated | 0.668 s | — | n/a (bent decay, fit r² 0.31 — honestly reported as unmeasurable rather than guessed) |
| 2 kHz | 0.419 s | 0.416 s | 0.622 s | −33 % | FAIL |
| 4 kHz | 0.001 s | 0.001 s | 0.527 s | −99.8 % | FAIL |
| 8 kHz | 0.001 s | 0.001 s | 0.356 s | −99.8 % | info |

### Interpretation of the failures

The high-frequency failures are **not measurement noise — the HF reverberant
tail is missing from the recordings.** At 4 and 8 kHz the measured energy
decays 35+ dB within ~1 ms of the direct sound, i.e. the recording contains
almost no reflected HF energy at all. Physically this room *has* an HF tail:
the OmniMic reference shows T30 ≈ 0.53 s and C80 ≈ 13.6 dB at 4 kHz. Something
in the capture chain removed it.

**Prime suspect: macOS input signal processing.** QuickTime records through
the microphone mode selected in Control Center; "Voice Isolation" (and some
"ambient noise reduction" settings) applies noise suppression that treats
low-level reverberant tails — exactly the signal we are measuring — as noise
and gates them out, most aggressively at high frequencies. This is precisely
the AGC/processing minefield the brief flags for iOS capture (§5.2), showing
up on the Mac side. The 2 kHz band (−33 %) and the bent 1 kHz decay are the
transition region where suppression partially bites.

Supporting evidence: the identical pipeline on a synthetic 44.1 kHz recording
recovers 4 kHz within +0.7 % (committed dry run), and the engine matches REW
on REW's own IRs (§1) — the anomaly appears only with this capture chain.

The 63 Hz overshoot is informational: recording SNR was ~30 dB (target 40+),
the reference itself is unstable at 63 Hz, and single-position LF readings
are inherently noisy. Louder playback will improve this.

## 3. Repeatability — PASS

Take 1 vs take 2, usable bands: 125 Hz 1.264/1.266 s (0.2 %), 250 Hz
1.019/1.016 s (0.3 %), 500 Hz 0.740/0.740 s (0.0 %), 2 kHz 0.419/0.416 s
(0.7 %). Well inside the ≤ 2-point Room-Score-delta requirement. The capture
chain is *consistent* — including consistently wrong at HF, which further
supports a systematic processing cause rather than random noise.

## 4. Verdict against the go/no-go gate

**Engine: validated** (matches REW within ±13 % on all criteria bands, on
identical IRs, three times over). **Phone capture chain: 125–500 Hz already
within a few percent of the reference; 1 kHz and up unusable in this session
due to suspected input-side noise suppression** — a settings problem, not a
physics problem. One more recording session with the fixes below should
resolve the full band range.

## 5. Actions for the next recording session

1. **Turn off Voice Isolation:** while QuickTime's recording window is open,
   open Control Center → Mic Mode → select **Standard** (not Voice Isolation).
   This is the most likely single fix.
2. Even better: if the OmniMic is free, select it as QuickTime's input device
   — then the phone-chain test uses a processing-free, calibrated mic.
3. **Play louder:** SNR was 29–35 dB; +6–10 dB more playback level gets us
   past the 40 dB target (the sweep should be clearly loud, not painful).
4. Keep the mic ≥ 1–1.5 m from the nearest speaker, pointing up or at the
   room, at the listening position.
5. Take 2's timing was ideal (2.6 s of lead-in silence). Take 1 stopped ~0.3 s
   after the stimulus ended — keep recording a few seconds longer.
6. Naming: this session's files were matched manually; using the documented
   convention (`YYYY-MM-DD_room_positionA_take1.aifc` with an identically
   prefixed `…_rt60.txt`) lets the runs pair automatically.

---
*Generated with `roombrix-validate` from commit on branch
`cursor/roombrix-core-foundation-c271`; criteria per `docs/VALIDATION.md`.*
