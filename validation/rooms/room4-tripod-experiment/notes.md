# Room 4 tripod experiment (folder prepared, captures pending)

Tests the leading hypothesis for the office 250 Hz quarantine: a
structural resonance of the rigid tripod (mechanical coupling, not
acoustic) producing the long narrow-band late tail the OmniMic never
sees. Full background: `docs/DEVICE_QUIRKS.md` and
`2026-09-08-room4-office/known_issues.json`.

## Protocol

Same room, same position, four captures plus a REW reference:

1. Two captures with the phone on the TRIPOD (as in rooms 2–4).
2. Two captures with the phone resting on a folded towel or cushion on
   a stable surface at the same height.
3. One (or two) REW + OmniMic reference takes — keep the measurement
   peak at or below −3 dBFS (the harness warns above that).

## File naming

Rename the app's exports with a condition suffix before uploading, the
same way the orientation pair was renamed:

    roombrix_capture_<timestamp>_TRIPOD.wav   (×2)
    roombrix_capture_<timestamp>_DAMPED.wav   (×2)

`room_config.json` in this folder already maps the suffixes to the two
variant groups: the harness gates repeatability WITHIN each pair (6 %
gate at 250/500 Hz, 4 % at ≥ 1 kHz) and reports the per-band delta
BETWEEN the tripod and damped group means as the experiment's result.

## Readout

- 250 Hz tripod ≈ damped, both ≈ REW → tripod hypothesis rejected;
  fallback (position-coupled modal tail) becomes leading.
- 250 Hz tripod LONG, damped ≈ REW → hypothesis confirmed; the office
  quarantine resolves into a product requirement (warn against rigid
  tripods / recommend damping), and the rooms 2–3 LF observations get
  re-read in that light.
