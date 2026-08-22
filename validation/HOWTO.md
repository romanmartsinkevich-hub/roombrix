# Real-Room Validation — How To (for Roman)

You do three things: **play a file, record a WAV, upload files into this
folder.** Everything else (all commands, all analysis, the report) is run by
the agent in its environment.

---

## What you need

- The test-signal file from this repo:
  **`validation/stimulus/roombrix_stimulus_48k.wav`**
  (48 kHz, 24-bit, mono, 15.75 s: a short chirp, half a second of silence,
  a 10-second rising sweep, then 5 seconds of silence)
- Your hi-fi system to play it through (from a streamer, laptop, USB stick —
  anything that plays the file **unmodified**: no EQ, no "room correction",
  no volume normalization)
- A way to record: ideally REW with the UMIK-1 (you need it anyway for the
  reference), or any recorder app that saves **WAV** files. Phone voice-memo
  apps are usually a bad choice — they process the sound. If you use a phone,
  use a recorder app where you can switch OFF gain control / noise reduction.
- A reasonably quiet room (no TV, no dishwasher, no conversations).

## Recording settings

| Setting | Value |
|---|---|
| Format | WAV |
| Sample rate | 48 kHz preferred; 44.1 kHz is also fine |
| Bit depth | 24-bit preferred; 16-bit or 32-bit float also fine |
| Channels | mono or stereo — both work (the left channel is used) |

## Step by step

1. Put the microphone (or phone) at your **listening position**, at ear
   height. Don't hold it — put it on a stand or cushion.
2. Set playback volume: the sweep should be **clearly loud — louder than a
   conversation, but not painful** (roughly 75–85 dB). When in doubt, do a
   quick trial run.
3. **Start the recording first.** Wait 2–3 seconds in silence (this silence
   is used to measure your room's background noise — it is not wasted time).
4. Play `roombrix_stimulus_48k.wav` **from the beginning**. You will hear a
   short chirp, a pause, then the 10-second sweep.
5. Let the file play to the very end (it ends with 5 seconds of silence —
   keep recording through it).
6. Stop the recording. Total length will be around 20 seconds.
7. Check the recording level indicator: if it ever hit **red / 0 dB, lower
   the recording input level (not the playback volume) and redo it.** The
   analysis refuses clipped recordings.

## Naming and where to put files

Recordings go here (one file per take):

```
validation/recordings/YYYY-MM-DD_room_positionA_take1.wav
```

Example: `validation/recordings/2026-08-23_livingroom_positionA_take1.wav`

The REW reference for the same room and position goes here:

```
validation/rew/YYYY-MM-DD_room_positionA_rt60.txt
```

To create that file in REW: measure the room as usual with the UMIK-1, open
the **RT60** graph, then use REW's export function for **RT60 data as text**
(File/Graph → Export). European number format (commas like `0,45`) is fine —
the parser handles it.

For the repeatability check, record **two takes at the same position without
moving anything** (`…_take1.wav` and `…_take2.wav`).

## What happens next (run by the agent, not by you)

For every recording you upload, the agent runs:

```
swift run roombrix-validate measure validation/recordings/<name>.wav \
    --rew validation/rew/<matching name>_rt60.txt
```

The tool first checks the recording and **refuses loudly** (with a plain
explanation) if:

- the recording is clipped,
- the timing chirp can't be found (confidence below 12 dB — usually the
  volume was too low or the wrong file was played),
- the recording is too short (it must contain the chirp, the full sweep,
  and at least 3 seconds after it).

If the recording is usable, it reports: marker confidence, detected playback
latency, clipping check, a signal-to-noise estimate, the per-octave-band
EDT/T20/T30 table, and the comparison against your REW export. Pass/fail is
judged on the **250 Hz–4 kHz bands at ±15 %**; bands below 250 Hz are shown
for information only (phone/consumer mics and single positions are not
reliable that low).

The agent then commits a report per recording to `validation/reports/`.

## Go/no-go gate (from the brief)

RT60 within tolerance in **at least 3 rooms** → proceed. Two takes at the
same position should also land within a Room-Score-equivalent of ≤ 2 points.
