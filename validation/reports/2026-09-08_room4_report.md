# Campaign Report — Room 4 (2026-09-08, office)

The worst-treated space in the campaign: a live, untreated office.
RT60 ~0.79 s mid-band against a 0.26–0.43 s ideal, Room Score 39–45,
C80 +1.2 dB. Two captures at one position forming the ORIENTATION PAIR
(one vertical, one horizontal) — repeatability-exempt via
`room_config.json` because their spread is between-conditions, not
method scatter. REW V5.31.1 + OmniMic reference.

## Reference validity: first real catch for the clipping check

`REW_Office_RT60_V1.txt` header shows **measurement signal peak level
0.0 dBFS** — the take clipped, and the harness excluded it
automatically (the warning prints in the room summary). V2 (−2 dB) is
the sole reference; note its own header reads −0.2 dBFS — formally
clean but with only 0.2 dB of headroom. Future reference takes should
aim for ≥ 3 dB.

## Result: PASS (250 Hz quarantined as a documented known issue)

| Band | Vertical | Horizontal | Reference (thirds avg) | Worst err | Between-cond. delta |
|---|---|---|---|---|---|
| 250 Hz | 1.230 | 1.105 | 0.911 | **+35.0 %** ⚠︎ | 11.3 % |
| 500 Hz | 0.830 | 0.847 | 0.832 | +1.8 % | 2.1 % |
| 1 kHz | 0.720 | 0.740 | 0.805 | −10.5 % | 2.8 % |
| 2 kHz | 0.692 | 0.704 | 0.721 | −4.0 % | 1.6 % |
| 4 kHz | 0.635 | 0.660 | 0.682 | −6.9 % | 4.0 % |

Orientation experiment: hypothesis REJECTED — 500 Hz–8 kHz deltas
(+2/+3/+2/+4/−1 %) all inside normal take-to-take spread. Closed in
`DEVICE_QUIRKS.md`; the garage 500 Hz quarantine keeps its
non-diffuse-field explanation with orientation eliminated.

## The 250 Hz failure: investigated to root cause (no gate widening)

1. **Not window/metric selection:** both captures read long at 250 Hz
   in the EARLIEST, cleanest window (−5…−25 dB, far above noise):
   1.150 s vertical, 1.105 s horizontal. No window choice reaches the
   0.911 s reference.
2. **The take-to-take metric difference is deterministic SNR response,
   not instability:** the vertical take's 250 Hz noise floor sits at
   −44.7 dB (usable 34 dB → T20 over −5…−34, the "29 dB range"); the
   horizontal take's floor is 4.3 dB higher at −40.4 dB (usable 25 dB →
   T20 over −5…−25, the "20 dB range"). Same rules, different SNR —
   the office was noisier during the second sweep.
3. **Decisive experiment:** this engine run on **REW's own OmniMic
   impulse response** (converted from `REW_Office_impulse_V2_-2dB.txt`)
   reads 250 Hz at **0.854 s** — within 3 % of REW's center-third
   T20/T30 (0.863/0.832) and −6 % of the thirds-averaged 0.911 s
   reference, comfortably in gate. **Engine exonerated; capture-chain
   deviation confirmed.**
4. **Shape of the deviation:** the phone's 250 Hz EDC is double-sloped
   — EDT 0.69–0.74 s (close to REW's 0.825 s EDT), then a slow ~1.5 s
   late tail (fits lengthen monotonically with window depth at
   r² ≈ 0.995, so the curvature gate rightly stays silent). The OmniMic
   sees no such tail. It appears in BOTH orientations, so orientation
   is eliminated; suspected position-coupled modal tail in the
   177–354 Hz band, where a few-cm placement offset couples differently
   to long-decaying room modes.

Quarantine: `known_issues.json` excludes 250 Hz from the gate but
prints the full root cause in every report. Pending: a proper two-take
pair at one setup (clean repeatability number), ideally with the phone
at the exact OmniMic spot.

## The −43 dB floor: ENGAGED at last — at 8 kHz

The long decay + quiet tail finally exercised `fitWindowEndFloorDB`:
at 8 kHz both captures had noise floors near −71 dB (usable range
62 dB), and the window end was **clamped at exactly −43 dB**
(−25…−43 and −20…−43, Topt) instead of the −52 dB the noise would have
allowed. The two takes then agreed within 1.2 % (0.565/0.558 s) —
across two different orientations — which is the stability the floor
was derived to protect. Retrospective: room 3's 8 kHz windows also
ended at −43 (unnoticed then); room 1's 8 kHz start sat at −40 from a
deep direct cliff, so the minimum-span rule correctly waived the floor.
In the criteria bands (250 Hz–4 kHz) the floor has still never been the
binding constraint — the standard −35 dB T30 end is reached first
there; it can only bind a criteria band under a deep direct cliff with
very high SNR.

## Per-constant verdicts (updates from room 4)

| Constant | Verdict | Room 4 evidence |
|---|---|---|
| `fitWindowEndFloorDB` (−43 dB) | **ENGAGED and VINDICATED (8 kHz)** | Clamped ends that noise would have let run to −52 dB; takes agreed within 1.2 % across two orientations. Still never binding in criteria bands (standard −35 dB end reached first). |
| Reference validity check (peak ≥ −0.05 dBFS) | **FIRST REAL CATCH** | V1 clipped at 0.0 dBFS, auto-excluded; campaign ran on V2 alone with the warning printed. |
| Repeatability gates (4 %/6 %) | **N/A this room (exempt)** | Captures are the orientation pair; between-conditions deltas 1.6–4 % at 500 Hz–4 kHz would have passed anyway; 250 Hz (11.3 %) is part of the quarantined deviation. |
| Anchor offset/grid/time, span policy | **HELD** | 500 Hz–2 kHz got identical clean-top −5…−35 T30 windows in both captures; 4 kHz identical −10…−35. Window differences appear only where SNR genuinely differed (250 Hz) — deterministic. |
| Noise-floor estimator + 10 dB plateau margin | **HELD, explains the take difference** | 250 Hz floors −44.7 vs −40.4 dB → usable 34 vs 25 dB → the exact "29 vs 20 dB range" difference flagged by the owner. |
| Curvature/cliff gates | **HELD (correctly silent)** | The 250 Hz double slope keeps r² ≈ 0.995 per window — linearity per window is genuinely high; this failure mode is detectable only against an external reference, which is what the campaign is for. |
| `RoomPurpose.rt60Target` | **PROVISIONAL, strongest data point yet** | The untreated live room scores 39–45 with RT60 ~0.79 s vs the 0.26–0.43 s listening target — the score separates it cleanly from the treated rooms. |

## Campaign status after room 4

Rooms 1–4: PASS (garage 500 Hz and office 250 Hz quarantined as
documented capture-chain deviations, both proven engine-exonerated by
REW-IR round-trips). Orientation hypothesis closed. Open questions for
the next room: a clean office two-take pair, and any room where a
criteria band could stress the −43 dB floor (deep cliff + high SNR).
