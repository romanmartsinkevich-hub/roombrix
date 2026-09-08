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

## Repeatability exemption

`room_config.json` marks this room repeatability-exempt: the two
captures are experiment VARIANTS (orientation pair), so their spread is
a between-conditions difference, not method scatter. A proper two-take
pair at one setup is planned for a clean repeatability number.

## Results (harness, V2 reference)

500 Hz +1.8 %, 1 kHz −10.5 %, 2 kHz −4.0 %, 4 kHz −6.9 % — in gate.
250 Hz reads +21/+35 % — investigated to root cause and quarantined in
`known_issues.json`: engine exonerated by the REW-IR round-trip
(0.854 s vs the 0.911 s reference); the phone captures genuinely record
a double-sloped, slower 250 Hz decay in both orientations. The
T20-29 dB vs T20-20 dB window difference between takes is fully
explained by the horizontal take's 4.3 dB higher noise floor at 250 Hz.
Full analysis: `validation/reports/2026-09-08_room4_report.md`.
