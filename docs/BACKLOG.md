# Backlog

## Milestone 5 — speaker-placement recommendations (no LiDAR required)

Concrete, actionable positioning advice from manual dimensions + the
speaker/seat markers the user already places — e.g. "left speaker: 5 cm
forward, 7 cm toward the centre":

- front-wall distance vs SBIR (quarter-wavelength cancellation from the
  wall behind the speakers),
- left/right symmetry (image shift and unequal early reflections),
- listening-triangle geometry (angle and distances),
- speaker/seat positions vs predicted modal distribution (avoid pressure
  maxima/nulls of the strongest axial modes).

LiDAR (RoomPlan) remains input convenience + future visual overlay only;
a LiDAR-equipped tester is being arranged. Every recommendation must work
from manually entered geometry.

## Later / unscheduled

- Multi-point measurement wizard (3–9 positions) — unlocks the
  frequency-response smoothness subscore (currently "not measured").
- UMIK-1/2 USB capture path + calibration file loading (Pro tier).
- Controlled phone-orientation test (vertical/tripod vs horizontal) for
  the LF observation in DEVICE_QUIRKS.
- PDF report export; per-model built-in mic correction curves;
  score-target calibration from the campaign dataset.
