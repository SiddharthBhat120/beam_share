# Beam Share

Send files and folders between **Android, iPhone and Windows**, in any
direction, **without internet and without a router**. Original quality (no
compression, dates kept), every byte checked with BLAKE3, encrypted, and it
picks up where it left off if the connection drops.

```
Pick files  ->  show QR (or tap a nearby device)  ->  done
"✅ 1,003 files verified, 0 errors"
```

## What's inside

| Folder | What it is |
| --- | --- |
| `lib/` | The Flutter app (screens, state, platform bridge) |
| `lib/screens/` | Home, Send, Share (QR + nearby), Receive, Scan, Transfer, Finish, History, Settings |
| `lib/services/engine_isolate.dart` | Runs the engine on a background thread |
| `packages/transfer_core/` | The transfer engine: pure Dart, no UI. Protocol, BLAKE3, TLS, resume |
| `android/app/src/main/kotlin/.../BeamPlatform.kt` | Wi-Fi Direct group, LocalOnlyHotspot, joining Wi-Fi, file pickers, raw file reads |
| `ios/Runner/AppDelegate.swift` | Original photo export, iPhone-to-iPhone peer-to-peer, Wi-Fi settings shortcut |
| `windows/runner/beam_platform.cpp` | Wi-Fi Direct soft-AP hotspot, keep awake |
| `codemagic.yaml`, `.github/workflows/` | Free cloud builds of the iPhone app (no Mac needed) |
| `DECISIONS.md` | Why things are built the way they are |
| `KNOWN_LIMITATIONS.md` | What still needs testing on real devices |

How a transfer works: see `packages/transfer_core/lib/src/transfer/sender.dart`
(top comment). Short version: handshake (TLS + pairing token) → manifest →
small files packed together, big files in 4–8 MB pieces over 3 parallel
connections → receiver hashes every piece and asks again only for bad ones →
on disconnect it reconnects and skips what is already verified → summary.

---

## 1. Set up on Windows (one time)

These are already installed on this PC in `E:\dev` (see DECISIONS.md).
On a fresh PC:

1. **Flutter**: `git clone https://github.com/flutter/flutter.git -b stable E:\dev\flutter`,
   then add `E:\dev\flutter\bin` to your user `PATH`.
2. **Android SDK**: install Android Studio (or the command-line tools) and
   run `flutter doctor --android-licenses`.
3. **Visual Studio 2022** (Community or Build Tools) with the
   **"Desktop development with C++"** workload (for the Windows app).
4. **Developer Mode** (needed for Windows builds with plugins):
   Settings › System › For developers › *Developer Mode* = On.
5. Check everything:

```bash
flutter doctor
```

6. Get the packages:

```bash
flutter pub get
```

## 2. Run and test

Run the engine tests (fast, ~15 s):

```bash
cd packages/transfer_core && dart test test/blake3_test.dart test/unit_test.dart
```

The big integration test (1,000 files + 2.2 GB, two forced disconnects;
needs ~5 GB free disk, takes 2 minutes):

```bash
cd packages/transfer_core && dart test test/integration_test.dart
```

Speed benchmark (prints MB/s on localhost):

```bash
cd packages/transfer_core && dart compile exe bin/benchmark.dart -o build/benchmark.exe && build/benchmark.exe
```

App checks:

```bash
flutter analyze
```

```bash
flutter test
```

### Run on Windows

```bash
flutter run -d windows
```

The first time you share, Windows Firewall asks about Beam Share: allow it on
**private networks**, otherwise phones can't reach the PC.

### Run on an Android phone

1. On the phone: Settings › About › tap *Build number* 7 times, then
   Developer options › *USB debugging* on.
2. Plug it in, accept the prompt, then:

```bash
flutter run -d android
```

Or build the APK and copy it to the phone:

```bash
flutter build apk --release
```

The APK is `build/app/outputs/flutter-apk/app-release.apk` (also in
`release/`). Open it on the phone and allow "install unknown apps".

### Build the Windows app

```bash
flutter build windows --release
```

The app is the whole folder `build/windows/x64/runner/Release/` (zip it;
`beam_share.exe` needs the DLLs and `data/` next to it).

---

## 3. iPhone for free (no Mac, no 99 USD Apple account)

Two free pieces: a **cloud Mac** builds the app, and **SideStore/AltStore** on
your Windows PC installs it on the iPhone with your normal Apple ID.

**Free-account limits (Apple's rules, not ours):**
- The app must be **refreshed every 7 days** (AltServer/SideStore does it in
  one tap, or automatically when the PC and iPhone are on the same Wi-Fi).
  Your files are kept when it refreshes.
- Max 3 sideloaded apps at a time.
- The app can't join Wi-Fi by itself, so the iPhone joins the other device's
  offline Wi-Fi with the **Camera app** (scan the "iPhone Wi-Fi" code, tap
  Join) or in Settings. Beam Share guides you and continues on its own.

### Step 1: Put the project on GitHub (free)

Create a free account at github.com, make a new **private** repository
`beam_share` (empty, no README), then:

```bash
cd "E:\CLAUDE AI\beam_share"
```

```bash
git remote add origin https://github.com/YOUR-NAME/beam_share.git
```

```bash
git push -u origin main
```

### Step 2: Build the iPhone app in the cloud (pick ONE, both free)

**Option A: Codemagic** (500 free Mac minutes/month, no credit card):
1. codemagic.io › *Sign up with GitHub* › choose the free personal plan.
2. *Add application* › GitHub › pick `beam_share` › project type
   *Flutter App (via codemagic.yaml)*.
3. *Start new build* › workflow **iOS (free, unsigned IPA)** › Start.
4. After ~10–15 minutes open the build › *Artifacts* › download
   **BeamShare-unsigned.ipa** to your PC.

**Option B: GitHub Actions** (already in the repo):
1. GitHub › your repo › *Actions* tab › enable workflows if asked.
2. **iOS unsigned IPA** › *Run workflow*.
3. When it's green, open the run › *Artifacts* › download
   `BeamShare-unsigned-ipa` (a .zip containing the .ipa; unzip it).

If the build fails, copy the red error lines from the log and send them to
Claude: the Swift code was written without a Mac, so a small fix may be
needed on the first build.

### Step 3: Install on the iPhone with AltStore (free)

AltStore is a well-known free, open-source sideloading tool (altstore.io).
It signs the app with *your* Apple ID through Apple's own free developer
service. Use an Apple ID you're comfortable with; some people make a
separate free Apple ID just for this.

1. On the PC install, **from Apple's website (not the Microsoft Store)**:
   iTunes and iCloud for Windows. AltServer needs them.
2. Download **AltServer for Windows** from altstore.io and install it.
   It appears as a diamond icon in the system tray (bottom right).
3. Plug the iPhone in with a cable, unlock it, tap **Trust This Computer**.
4. Tray icon › *Install AltStore* › choose your iPhone › enter your Apple ID.
5. On the iPhone: Settings › General › VPN & Device Management › your Apple
   ID › **Trust**. On iOS 16 or newer also: Settings › Privacy & Security ›
   **Developer Mode** › On (the iPhone restarts).
6. Copy `BeamShare-unsigned.ipa` to the iPhone (iCloud Drive, or the Files
   app via cable) › open **AltStore** › *My Apps* › `+` › pick the .ipa.
   AltStore signs and installs Beam Share.
7. Open Beam Share and allow **Local Network**, **Camera** and **Photos**.
8. **Every few days**: open AltStore › *My Apps* › *Refresh All* while the PC
   (with AltServer running) is on the same Wi-Fi. If you forget for 7 days,
   the app just won't open until you refresh; nothing is lost.

(*SideStore*, sidestore.io, is a free alternative that refreshes from the
iPhone itself without the PC after the first setup.)

### Optional: paid route later

If you ever buy the Apple Developer Program, the `ios-testflight-paid`
workflow in `codemagic.yaml` builds for TestFlight (no 7-day refresh) and
enables joining Wi-Fi automatically. The comments in that file list the
steps. You never need it for the app to work.

---

## 4. Test offline transfers step by step

Mobile data **off**, Wi-Fi **on** on every device (it doesn't need to be
connected to anything). Write down phone models, MB/s and any error.

### A. Android → Android
1. Phone A: **Send** › *Photos & videos* › pick ~20 photos + 1 big video ›
   **Next**. Allow "Nearby devices"/"Location". It should say
   `Offline Wi-Fi "DIRECT-bs-…" is on`.
2. Phone B: **Receive** › **Scan QR code** › tap **Connect** in the popup.
3. Halfway: turn Phone B's Wi-Fi off for 5 s and on again → "Reconnecting…",
   then it continues.
4. End: "✅ N files verified, 0 errors" › **Open folder**. Compare a photo's
   size/date/location with the original.

### B. iPhone → iPhone (no Wi-Fi network at all)
1. Both iPhones: Wi-Fi and Bluetooth **on** in Control Center (they power
   Apple's peer-to-peer Wi-Fi). Keep both unlocked and close.
2. iPhone B: **Receive**.
3. iPhone A: **Send** › pick › **Next** › tap iPhone B under *Nearby devices*.
4. iPhone B: **Accept**.

### C. Android or Windows → iPhone
1. Android/PC: **Send** › pick › **Next**. Wait for `Offline Wi-Fi … is on`.
2. Tap **iPhone Wi-Fi** above the QR code.
3. iPhone: open the **Camera app** (not Beam Share), point at the code, tap
   the *Join "DIRECT-bs-…"* banner.
4. On the Android/PC tap **Beam Share code**.
5. iPhone: Beam Share › **Receive** › **Scan QR code** › scan it. The
   transfer starts.
   (If you scan the Beam Share code first, the app shows the Wi-Fi name, copies
   the password, and offers **Open Wi-Fi settings**; join there, come back,
   and it continues by itself.)

### D. iPhone → Android or Windows
The iPhone can't create a Wi-Fi network, so the receiver makes it:
1. Android/PC: **Receive** › **Show my code**. Wait for `Offline Wi-Fi … is on`.
2. Tap **iPhone Wi-Fi** › iPhone Camera app › scan › *Join*.
3. Android/PC: tap **Beam Share code**.
4. iPhone: Beam Share › **Send** › pick › **Next** › **Scan receiver's code** ›
   scan. (Or, now that both are on the same network, the receiver appears
   under *Nearby devices*: tap it and accept on the receiver.)

### E. Android ↔ Windows, and same-Wi-Fi without QR
- **Offline:** like A. A PC can't scan with a camera, so on the phone tap
  **Copy code**, send it to the PC (e.g. a USB cable or a note), and use
  **Receive › Paste code** on the PC.
- **Easier:** put both on the same home Wi-Fi. Receiver: **Receive**. Sender:
  **Send** › pick › **Next** › tap the receiver under *Nearby devices* ›
  **Accept**.
