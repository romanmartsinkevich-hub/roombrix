# Cross-Implementation Check — 2026-08-29 Recordings

Four recordings analyzed (all 48 kHz 24-bit WAV, marker confidence 31–39 dB,
no clipping, SNR 36–39 dB): two iPhone built-in (mono), two MV88 (stereo).
Reference: T30 per octave band from an independent implementation of the same
algorithm. Investigation criterion: any band differing by more than 3 %.

## Verdict up front

- **MV88 (500 Hz–4 kHz, +8 % to +35 %): not an algorithm bug in either
  implementation — the two analyses processed different signals.** The
  reference numbers match a stereo-to-mono **downmix**; our engine analyzes
  the **left channel**. Reproducing their channel handling reproduces their
  numbers.
- **iPhone 2 kHz (−5.2 %) and 8 kHz (−7.3 %): no evidence of a bug in either
  implementation.** Both are fitting a bent, cliff-shaped decay where the
  answer is provably fit-window-dependent by ±30 %. The 3 % criterion is not
  meaningful on these bands.
- **Three real defects were found on our side during the investigation — none
  of them the cause of the reported deltas — and all are fixed** (see §4).
- A **ground-truth fixture** is committed so the other implementation can be
  arbitrated properly (§5).

## 1. iPhone built-in (mono) — agreement in all trustworthy bands

Reference vs our T30, take 1 (`iphone mic … 14.42.22.wav`; the reference is
clearly this file — 250 Hz matches to all published digits):

| Band | Ours | Reference | Δ | Assessment |
|---|---|---|---|---|
| 250 Hz | 1.048 s | 1.048 s | **0.0 %** | agree |
| 500 Hz | 0.887 s | 0.905 s | −2.0 % | agree |
| 1 kHz | 0.697 s | 0.714 s | −2.4 % | agree |
| 2 kHz | 0.525 s | 0.554 s | −5.2 % | fit-window sensitivity (below) |
| 4 kHz | 0.471 s | 0.480 s | −1.9 % | agree (our fit r² 0.21 — flagged) |
| 8 kHz | 0.331 s | 0.357 s | −7.3 % | both unmeasurable (below) |

**2 kHz investigation.** Our value is invariant to noise-floor handling:
truncation margin 4 dB → 0.525, 8 dB → 0.525, 12 dB → 0.524, truncation
disabled → 0.527. So noise treatment is not the differentiator. The decay
curve itself is bent (direct-sound cliff at the top: EDT = 0.002 s), and on a
bent curve the "T30" depends on where the fit window sits:

| Fit window | RT60 |
|---|---|
| −5…−25 dB (T20) | 0.424 s |
| −5…−35 dB (T30, ours) | 0.525 s |
| −10…−30 dB | 0.467 s |
| −10…−40 dB | 0.603 s |
| −15…−45 dB | 0.664 s |
| −20…−50 dB | 0.750 s |

The reference's 0.554 sits between our −5…−35 and −10…−40 windows — fully
explained by a slightly different fit-window convention (e.g. endpoint
interpolation or a −10 dB start). On a single-slope decay all windows agree;
here the single-slope assumption both implementations share is violated by
the data. Neither implementation is "wrong"; the band should carry a
curvature warning (ours now does).

**8 kHz.** Our T30 fit has r² = 0.36 and our T20 collapses to 0.001 s on the
direct-sound cliff. Their 0.357 vs our 0.331 are two fits of the same
garbage. Our engine now formally refuses this band (curvature gate, §4).

## 2. MV88 (stereo) — channel handling explains the deltas

Reference vs our T30 under three channel treatments of the same take
(`MV88 iphone … 14.29.59.wav`):

| Band | Reference | Left (ours) | Right | Downmix (L+R)/2 |
|---|---|---|---|---|
| 250 Hz | 0.959 | 0.966 (+0.7 %) | 0.903 (−5.8 %) | 0.924 (−3.6 %) |
| 500 Hz | 0.734 | 0.793 (+8.0 %) | 0.740 (+0.8 %) | 0.689 (−6.1 %) |
| 1 kHz | 0.596 | 0.704 (+18 %) | 0.622 (+4.4 %) | 0.580 (−2.7 %) |
| 2 kHz | 0.485 | 0.626 (+29 %) | 0.516 (+6.4 %) | 0.472 (−2.7 %) |
| 4 kHz | 0.377 | 0.507 (+34 %) | 0.453 (+20 %) | 0.371 (−1.6 %) |
| 8 kHz | 0.520 | 0.424 (−18 %) | 0.427 (−18 %) | 0.543 (+4.4 %) |

The downmix collapses the 1 kHz–4 kHz disagreements from +18…+34 % to under
3 %, and — decisively — reproduces the reference's physically suspicious
**non-monotonic 8 kHz value (longer than 4 kHz)**: 0.543 vs their 0.520. A
real room's HF decay shortens with frequency (air absorption); the inversion
is an artifact of summing the MV88's two channels, which partially cancels
the side (reverb-rich) content at some frequencies and not others.

**Conclusion:** their implementation downmixed the stereo file; ours used the
left channel. Neither math kernel is buggy, but for room acoustics the
downmix is the methodologically wrong choice for a stereo/M-S microphone —
channel summation acts as a spatial filter that suppresses reverberant energy
and biases RT short (and produced the impossible 8 kHz > 4 kHz result).
Recommendation: both implementations should analyze a single stated channel.
Our CLI uses the left channel and prints so; residual 250/500 Hz differences
in the downmix column reflect that their exact mix coefficients are unknown.

## 3. Repeatability (context)

Take-to-take, usable bands: iPhone ≤ 2.3 % (250 Hz: 1.048/1.072), MV88 ≤
1.9 % (250 Hz: 0.966/0.984; 500 Hz: 0.793/0.801; 2 kHz: 0.626/0.625). Both
capture chains are stable.

## 4. Defects found on our side during this investigation (all fixed)

1. **Marker detector could lock onto the sweep instead of the timing marker**
   in strongly reverberant recordings: raw cross-correlation rewards sheer
   energy, and the ESS out-correlates the marker as it passes through the
   marker's band. Caught by the new ground-truth fixture (detector "found"
   the marker at +9.6 s with 24.5 dB confidence). Fixed with normalized
   cross-correlation (local-energy denominator). All four real recordings
   re-verified: identical marker positions and band values before/after.
2. **T30 could be reported despite a poor T30 fit** — quality gating used
   T20's r² only (e.g. iPhone 8 kHz: T30 r² = 0.36 slipped through). Each
   estimate is now gated by its own r², and a **curvature gate** (T30/T20
   outside 0.5…2) refuses cliff-shaped decays outright, where a steep,
   high-r² line through the cliff yields confident nonsense like
   T20 = 0.001 s.
3. `edc` diagnostic's "disabled truncation" sentinel truncated at the first
   block instead of never (wrong comparison sign). Fixed.

## 5. Ground-truth arbiter for the other implementation

`validation/fixtures/crosscheck_rt60_0.500s.wav` — a synthetic 48 kHz 24-bit
mono "recording" of the standard stimulus through a room with **exactly
RT60 = 0.500 s in every band** (exponential-envelope IR, unit direct sound,
−70 dB noise floor, 1.2 s playback latency).

Our engine on this fixture (T30): 125 Hz 0.523, 250 Hz 0.560, 500 Hz 0.519,
1 kHz 0.502, 2 kHz 0.503, 4 kHz 0.483 — within +12 %/−4 % of truth. (63 Hz is
unreliable by construction — minimal sweep energy below 88 Hz relative to
filter ringing; 8 kHz T20 is cliff-prone because the synthetic direct sound
is strong.)

**Protocol:** run the other implementation on this file, bands 250 Hz–4 kHz.
Within ±15 % of 0.500 s → its kernel is fine and any remaining deltas versus
us are methodological (channel handling, fit windows, filter realization).
Outside ±15 % → it has a real defect and this file is the reproduction case.
