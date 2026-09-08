# Room 4 — office (2026-09-08)

The worst-treated space in the campaign so far: a live, untreated room.
RT60 ~0.79 s mid-band against a 0.26–0.43 s ideal, Room Score 39–45,
C80 +1.2 dB. Added to the campaign specifically because rooms 1–3 never
stressed the −43 dB usable-range stability floor; this room's long decay
is the candidate to finally do it.

## Captures

Two app captures at the same position, one per phone orientation
(vertical and horizontal) — they double as the room's repeatability pair
AND as the controlled orientation experiment (result: hypothesis
rejected; see `docs/DEVICE_QUIRKS.md`, "CLOSED: phone orientation…").

## Reference selection — V1 IS CLIPPED, USE V2 ONLY

`REW_Office_RT60_V1.txt` header shows **"measurement signal peak level
0.0 dBFS"** — the take clipped and is NOT a valid reference. The second
take (V2, −2 dB) is clean. The harness now detects this automatically
(peak ≥ −0.05 dBFS → export excluded with a warning), so V1 is ignored
without manual intervention; this note records why.

## Expected results (from the session)

Accuracy vs the V2 reference (octave averages of thirds): 500 Hz −5 %,
1 kHz −9 %, 2 kHz −4 %, 4 kHz −8 %, 8 kHz +8 %. 250 Hz reads **+30 % —
out of gate**; the app's own two captures disagree by 10 % there
(1.230 vs 1.105), REW's thirds inside that octave scatter
0.83/0.94/0.80, and the fit window fell back to T20 in one capture with
a different range (29 vs 20 dB). Metric selection differing between
takes at 250 Hz is under investigation as engine behaviour, not a
capture artefact.
