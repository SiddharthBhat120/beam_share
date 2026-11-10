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
| `ios/Runner/AppDelegate.swift` | Hotspot join, original photo export, iPhone-to-iPhone peer-to-peer |
| `windows/runner/beam_platform.cpp` | Wi-Fi Direct soft-AP hotspot, keep awake |
| `codemagic.yaml` | Cloud build for iOS → TestFlight (no Mac needed) |
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

## 3. iOS without a Mac (Codemagic + TestFlight)

You need: an **Apple Developer account** (99 USD/year), a GitHub (or GitLab)
account, a free **Codemagic** account. Total time the first time: ~1 hour.

1. **Push this project to GitHub** (private repo is fine):

```bash
git remote add origin https://github.com/YOUR-NAME/beam_share.git
```

```bash
git push -u origin main
```

2. **Create the App ID** at developer.apple.com › Certificates, IDs &
   Profiles › Identifiers › `+` › App IDs › App:
   - Bundle ID (explicit): `com.beamshare.beamShare` (or your own, then also
     change it in `codemagic.yaml` and `ios/Runner.xcodeproj/project.pbxproj`)
   - Capabilities: tick **Hotspot** (needed to join a phone's hotspot from
     the QR code). Save.
3. **Create the app in App Store Connect** (appstoreconnect.apple.com ›
   Apps › `+` › New App): platform iOS, the same bundle ID, any SKU.
   Open *App Information* and copy the numeric **Apple ID**; put it into
   `codemagic.yaml` as `APP_STORE_APPLE_ID`.
4. **Create an App Store Connect API key**: App Store Connect › Users and
   Access › Integrations › App Store Connect API › `+`, role *App Manager*.
   Download the `.p8` file (only possible once) and note the Issuer ID and
   Key ID.
5. **In Codemagic**: sign in with GitHub › Add application › pick the repo ›
   *codemagic.yaml* workflow. Then Teams › your team › Integrations ›
   **App Store Connect** › Connect: upload the `.p8`, Issuer ID, Key ID and
   name it **`BeamShareASC`** (must match `codemagic.yaml`).
6. **Code signing**: in the app's settings › Code signing identities ›
   iOS certificates › *Generate certificate* (Apple Distribution), and in
   iOS provisioning profiles › *Fetch profiles* (Codemagic creates an App
   Store profile for the bundle ID). The `ios_signing` section of
   `codemagic.yaml` then signs automatically.
7. **Start a build**: Start new build › workflow **iOS -> TestFlight**.
   It runs the engine tests, builds the IPA on an M2 Mac and uploads it to
   TestFlight (~20–30 min). If Swift fails to compile, the log shows the line;
   the iOS code was written without a Mac (see KNOWN_LIMITATIONS.md).
8. **Export compliance**: the first upload asks about encryption in App Store
   Connect › TestFlight. Beam Share uses standard TLS only for protecting
   the user's own data. Answer the questionnaire (usually "exempt").
9. **Install on your iPhone 17 Pro**: App Store Connect › TestFlight ›
   Internal Testing › add yourself as a tester. Install the **TestFlight**
   app on the iPhone, accept the invite, tap *Install*.
   First launch: allow **Local Network**, **Camera** and **Photos** when
   asked; they are all needed.

---

## 4. Test an offline transfer between two phones (step by step)

Do this in a place with **no Wi-Fi router involved**, ideally with mobile
data switched off, to prove it's really offline.

### A. Android → Android (or Android → iPhone / PC)

1. Install the APK on both phones. Turn on **Wi-Fi** on both (no need to be
   connected to anything). Turn **mobile data off**.
2. **Phone A (sender):** open Beam Share › **Send** › *Photos & videos* ›
   pick a few photos and one big video › **Next**. Allow "Nearby devices"
   (Android 13+) or "Location" (Android 12 and older).
3. Phone A shows a QR code and the line `Offline Wi-Fi "DIRECT-bs-..." is on`.
4. **Phone B (receiver):** open Beam Share › **Receive** › **Scan QR code** ›
   point at Phone A. Android shows "Connect to DIRECT-bs-...?" › **Connect**.
   (iPhone: "Join Wi-Fi network?" › Join. PC: use *Paste code* with the code
   copied from the sender, or connect both to the same Wi-Fi.)
5. The transfer starts by itself: watch MB/s, time left, files verified.
6. **Test resume:** halfway through, walk away until the speed drops to 0, or
   switch Phone B's Wi-Fi off for 5 seconds and on again. The screen says
   "Reconnecting..." and then continues (within 2 minutes).
7. **Test pause:** tap Pause, wait, tap Resume.
8. At the end: "✅ N files verified, 0 errors". Tap **Open folder**:
   files are in `Download/BeamShare`, photos also appear in the gallery.
9. **Check quality:** compare a photo's details on both phones (size in
   bytes, date, location). They must be identical.

### B. Same Wi-Fi, no QR (nearby devices)

1. Both devices on the same Wi-Fi (or one joined to the other's hotspot).
2. Receiver: **Receive** (it is now "visible").
3. Sender: **Send** › pick files › **Next**: the receiver appears under
   *Nearby devices* › tap it. The receiver taps **Accept**.

### C. iPhone → iPhone (no network at all)

1. Both iPhones: Wi-Fi and Bluetooth **on** (they power Apple's
   peer-to-peer Wi-Fi), no need to join a network.
2. iPhone B: **Receive**. iPhone A: **Send** › pick › **Next** › tap iPhone B
   under *Nearby devices* › iPhone B taps **Accept**.

### D. iPhone → Windows/Android

iPhones cannot create hotspots, so the **receiver** makes the network:
on the receiving Android/PC choose **Receive** › **Show my code**, then on
the iPhone **Send** › pick › **Next** › **Scan receiver's code**.

### What to write down while testing

- Phone models and Android/iOS versions.
- MB/s at 1 m distance and at 5 m.
- Did the hotspot start? (`Offline Wi-Fi ... is on` vs `Using the current Wi-Fi network`)
- Any file with a different size/date on the receiver (there should be none).
