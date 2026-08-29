# Installing Roombrix on your own iPhone (no developer experience needed)

You'll install two free tools on the Mac, run three copy-paste commands, and
press Run in Xcode. Total ~30–60 minutes the first time (mostly Xcode's
download).

## What you need

- Your Mac (macOS 14 or newer) and your iPhone + its cable.
- A free **Apple ID** (the one you already use is fine). A paid Apple
  Developer account ($99/year) is **not** needed for this step — free
  signing installs the app on your own phone for 7 days at a time
  (re-press Run to renew). We'll only need the paid account later for
  TestFlight/App Store.

## Step 1 — install Xcode (once, ~1 hour download)

1. Open the **App Store** on the Mac, search for **Xcode**, install.
2. Open Xcode once; accept the license; let it install its components.

## Step 2 — get the project and generate it (Terminal, copy-paste)

Open **Terminal** (Cmd-Space, type "Terminal") and paste these lines one at
a time:

```bash
# 1. Homebrew (package manager) — skip if you already have it:
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# 2. Tools: git (usually present) and xcodegen:
brew install xcodegen

# 3. Get the code (use the PR branch) and generate the Xcode project:
git clone -b cursor/roombrix-core-foundation-c271 https://github.com/romanmartsinkevich-hub/roombrix.git
cd roombrix/ios/Roombrix && xcodegen generate && open Roombrix.xcodeproj
```

## Step 3 — signing (once, in Xcode)

1. In Xcode's left sidebar click the blue **Roombrix** project icon → target
   **Roombrix** → **Signing & Capabilities** tab.
2. Tick **Automatically manage signing**, and under **Team** choose your
   Apple ID (add it via Xcode → Settings → Accounts if the list is empty —
   sign in with your Apple ID, it creates a free "Personal Team").

## Step 4 — put it on the iPhone

1. Plug the iPhone into the Mac. Tap **Trust** on the phone if asked.
2. On the iPhone: Settings → **Privacy & Security** → **Developer Mode** →
   on → restart the phone (iOS requires this for self-installed apps).
3. In Xcode's top toolbar, click the device selector and pick your iPhone.
4. Press the **▶ Run** button. First run: on the iPhone go to Settings →
   General → **VPN & Device Management** → trust your developer certificate.
5. The app launches. Allow microphone access when asked.

## Step 5 — what to do in the app, and what to hand back

The phone never plays the test sounds — it is the measuring instrument.
You play two files through your own system.

1. **Send the test files to your system.** On the Measure tab, share both
   files (AirDrop to your Mac, Save to Files, USB stick — whatever suits
   your setup): the **pink noise** (level setting) and the **measurement
   sweep**. They're also visible in the Files app under Roombrix.
2. **Place the phone** at your listening position at ear height — on a
   stand or resting screen-up on a cushion. Don't hold it.
3. **Device check (once):** loop the pink-noise file at a steady,
   comfortable volume, then tap **"Run device check"** (records 8 s and
   verifies the mic's gain control is really off). Share the result text
   back to me — it fills your device's row in the quirks table.
4. **Measure** — the app walks you through three stages:
   - **Background noise (5 s):** stay quiet. The app shows your room's
     noise floor per band and warns if something (HVAC, fridge, traffic)
     should be turned off first.
   - **Level setting:** play the pink-noise file on loop and raise your
     system volume until all bands show green (target ≥ 45 dB headroom;
     loud but never painful). Then STOP the pink noise, leave the volume
     where it is, and tap continue.
   - **Sweep:** play the sweep file at that same volume. Recording is
     already running — walking back to your seat is fine, footsteps don't
     hurt. It stops automatically after the sweep and the room's decay
     (there's also a manual stop button).
5. On the results screen use the two share buttons and send me:
   - the **text report**, and
   - the **raw recording WAV** (upload into `validation/recordings/` as
     before — I'll verify the app's numbers match the CLI bit-for-bit and
     compare against the REW reference we already have).

## If Xcode shows red errors when you press Run

That's on me, not you — this scaffold was written off-device. Copy the
first few error lines (or a screenshot) and send them back; I'll fix and
you just pull and rerun:

```bash
cd roombrix && git pull && cd ios/Roombrix && xcodegen generate && open Roombrix.xcodeproj
```
