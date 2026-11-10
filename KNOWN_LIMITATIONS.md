# Known limitations

Honest list of what could **not** be verified on this PC (no phones, no Mac,
no second Wi-Fi adapter) and what is not built yet.

## Verified here

- Transfer engine, end to end over localhost with real TLS:
  1,000 small files + 520 MB + 600 MB + 1.1 GB files, byte-for-byte and
  modified-date comparison, 0 errors. Two forced disconnects mid-transfer,
  resumed, 0 errors. Corrupted pieces re-sent (only those pieces).
- BLAKE3 against the official reference implementation.
- `flutter analyze` (0 issues), all unit/widget tests, release builds for
  Android (APK) and Windows.

## Not verified (needs real devices)

1. **Wi-Fi Direct group / LocalOnlyHotspot on real Android phones.** Code
   follows the Android APIs, but OEM behaviour differs a lot (Samsung,
   Xiaomi, OnePlus...). 5 GHz is requested and falls back to auto band.
   Some phones turn off the normal Wi-Fi while a hotspot runs.
2. **Joining from Android 10+** shows the system "Connect to device" dialog;
   whether `bindProcessToNetwork` keeps every socket on the offline network
   on all OEMs is untested. Android 9 and older use the deprecated
   `WifiManager.enableNetwork` path (untested).
3. **iOS code has never been compiled** (no Mac). It is written against
   current Swift/Flutter APIs and will be compiled by Codemagic; expect to
   fix small compile errors on the first cloud build. Specifically untested:
   - The free-build Wi-Fi flow: Camera-app Wi-Fi QR join, the
     "Open Wi-Fi settings" shortcut (it uses an `App-Prefs:` link that some
     iOS versions ignore; then it opens Beam Share's own settings page, and
     you tap back to Settings › Wi-Fi), and auto-continue after joining.
   - Sideloading the unsigned IPA with AltStore/SideStore.
   - iPhone-to-iPhone over AWDL (`includePeerToPeer`) and the loopback relay.
   - `PHAssetResourceManager` export of ProRAW / Live Photos / iCloud items.
4. **Windows Wi-Fi Direct soft-AP** (`WiFiDirectAdvertisementPublisher`
   legacy mode) needs a Wi-Fi adapter/driver that supports it; many do,
   some don't (the app then falls back to "same Wi-Fi" mode and says so).
   Windows Firewall will ask to allow Beam Share on first use: click *Allow*
   (private networks), otherwise phones cannot connect to the PC.
5. **Real-world speed.** Localhost benchmark: ~118 MB/s with TLS,
   ~218 MB/s without (both ends on one PC). Over Wi-Fi Direct expect
   roughly 20–80 MB/s depending on the phones, band and distance. Phone CPUs
   hash/encrypt more slowly than a PC; not measured.
6. **mDNS discovery** on some Android phones needs the multicast lock (done)
   and can still be blocked by the router or "client isolation" on public
   Wi-Fi. QR codes always work.
7. **Android photo picker variants.** Some OEM galleries return URIs that
   cannot be seeked; the code falls back to sequential reads, which is
   slower for resends. Not seen in practice yet.
8. **Unicode/odd file names on FAT32/exFAT SD cards** (e.g. characters that
   SD cards reject) were not tested.

## Free iPhone build limits (Apple's rules)

- A free Apple ID signature lasts **7 days**: refresh in AltStore/SideStore.
- Max 3 sideloaded apps per free Apple ID.
- No automatic Wi-Fi joining (paid-only entitlement): one extra tap with
  the Camera app, or joining in Settings.
- The paid TestFlight route is kept in `codemagic.yaml` but is optional.

## Not implemented yet (roadmap)

- **Resume after the app is closed** (resume state is kept in memory only;
  reconnects within 2 minutes while both apps stay open are handled).
- **Background transfers** (Android foreground service / iOS background
  task). Keep the app open; the screen is kept on during transfers.
- **Multi-device send** (one sender, many receivers) — CLAUDE.md step 5.
- **Free-space check before receiving.** The receiver pre-allocates each
  big file, so a full disk fails fast for that file, but there is no
  up-front "not enough space" warning.
- **Folder modified dates** are not restored (files' dates are). dart:io has
  no API for directory timestamps.
- **Windows → camera QR scanning.** Windows can show a QR code and paste a
  code; it cannot scan one with a webcam.
- **Play Store / App Store release**: the APK is signed with the debug key;
  icons are Flutter defaults.
