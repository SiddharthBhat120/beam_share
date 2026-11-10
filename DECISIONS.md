# Decisions

Choices made while building Beam Share, and why. Newest thinking wins; if
you change one of these, update this file.

## Architecture

**Flutter app + pure-Dart engine package (`packages/transfer_core`).**
The engine has no Flutter imports, so it runs under `dart test`, can be
benchmarked from the command line, and can later be replaced by Rust
(`flutter_rust_bridge`) without touching any screen.

**The engine runs in a background isolate** (`lib/services/engine_isolate.dart`).
Hashing and TLS for gigabytes is CPU work; on the UI thread it would make
animations stutter. The UI and the engine exchange small map messages.

**State management: plain `ChangeNotifier` + an `InheritedWidget` (`AppScope`).**
No extra packages to learn. Two objects: `AppState` (settings, identity,
history) and `TransferController` (the current transfer).

## Transfer protocol

**Framing:** every message is `[type:1][length:4][payload]`. Type 1 = JSON
control message, type 2 = binary data unit. Length-prefixed frames mean
one copy per frame and no delimiter scanning.

**One control connection + N data connections per "round".** Default N = 3.
The benchmark showed 2–3 streams is the sweet spot (TLS: 1 stream 92 MB/s,
2–3 streams ~117 MB/s, 4 streams slightly slower). Parallel streams also
hide Wi-Fi hiccups on any single TCP connection.

**Units and segments.** A data frame (unit) holds one or more segments. A
segment is either a whole small file (≤ 4 MiB) or one piece of a big file.
Small files are packed into units of up to 4 MiB / 512 files, so 1,000
photos cost no per-file round trips. Big files use 4 MiB pieces, or 8 MiB
for files ≥ 1 GiB (fewer frames, same verification).

**Receiver acknowledges asynchronously.** The sender never waits per file;
the receiver batches "ok" messages every 100 ms. The sender only waits at
the very end until every file is verified.

**Pipelining.** A reader task reads + hashes the next pieces from disk while
workers send the current ones (bounded queue of 6 units ≈ 24–48 MB RAM).
TCP back-pressure (the receiver pauses its socket when > 24 MB are
buffered) keeps memory bounded on a slow disk.

**Large socket buffers:** 4 MiB SO_SNDBUF/SO_RCVBUF + TCP_NODELAY.

## Accuracy (BLAKE3)

**BLAKE3 implemented in pure Dart** (`lib/src/hash/blake3.dart`) and checked
against the official reference (Python `blake3` package vectors in
`test/fixtures_blake3.json`, lengths 0 B to 32 MB). ~500 MB/s per core
(AOT, desktop), so it is never the bottleneck on Wi-Fi. A native package
would add build complexity on three platforms for no real gain.

**Using the BLAKE3 tree.** Piece sizes are a power-of-two number of 1 KiB
BLAKE3 chunks, so each piece's *chaining value* can be computed on its own
and the chaining values merge into exactly the normal BLAKE3 hash of the
whole file (same value as `b3sum`). Result:
- every piece is verified on arrival (wrong piece → only that piece is re-sent),
- pieces can arrive out of order over several connections,
- the full-file hash is still checked, and each side hashes every byte once.

**Small files** are hashed whole; the hash travels with the file.

**Hashes are computed while streaming, not in a pre-pass.** A pre-pass would
read every file twice before the first byte moves (minutes for 50 GB). The
manifest therefore carries path, size, date and piece size; the BLAKE3 hash
of each file travels with its data (small files) or in an `fhash` message
(big files).

**A file is "done" only when its full-file hash matches.** Big files are
written to `name.beampart` and renamed after the root hash matches; small
files are written straight to their final name, but only *after* their hash
matched. Optional `verifyOnDisk` re-reads big files from disk (off by
default: costs a full extra read; disk write errors surface as exceptions).

**Retries:** a piece that fails its hash 5 times fails only its own file
(reported in the summary); the rest of the transfer continues.

## Resume

The receiver keeps, in memory, a bit set of verified pieces per file. When
any connection drops, the dialing side reconnects every 0.3–3 s for up to
2 minutes; the receiver then sends a `state` message (done files + verified
pieces) and the sender skips everything already verified. Heartbeats every
2 s detect a dead link within 20 s even when TCP does not notice.

Not persisted to disk: if either app is *closed*, the transfer starts over
(see KNOWN_LIMITATIONS.md).

## Security

**Standard TLS from dart:io (BoringSSL), not custom crypto.** TLS 1.3 does
the ECDHE key exchange and AES-GCM/ChaCha20 encryption.

**Pairing = certificate pinning.** Each device creates a P-256 key and
self-signed certificate once (`basic_utils`/PointyCastle) and stores it
privately. The QR code carries the SHA-256 fingerprint of that certificate
plus a random one-time token. The scanner only accepts a TLS server whose
certificate matches the fingerprint; the server only auto-accepts a client
that presents the token. Nearby (mDNS) connections without a token must be
accepted by the user ("Accept / Decline" dialog).

**Cost:** TLS roughly halves raw localhost throughput (≈118 MB/s vs
≈218 MB/s plain). That is still faster than typical Wi-Fi Direct links
(30–80 MB/s), so encryption is always on.

**Path safety:** incoming paths are sanitized (`..`, absolute paths, drive
letters rejected; Windows-illegal characters replaced), so a malicious
sender can never write outside the receive folder.

## Connectivity

**QR code first.** It carries everything for a fully offline connection:
hotspot SSID + password, every IP of the host, port, fingerprint, token.
The scanner first tries the IPs on its current network (same Wi-Fi is
fastest), and only joins the hotspot if they are unreachable.

**Android: Wi-Fi Direct group owner first, LocalOnlyHotspot as fallback.**
A Wi-Fi Direct group acts as a normal access point for "legacy" clients,
so iPhones and Windows PCs can join with SSID + password. It usually keeps
the phone's normal Wi-Fi connected, supports 5 GHz (requested, falls back to
auto band), and lets us choose the name (`DIRECT-bs-<name>`).
LocalOnlyHotspot works on more devices but often drops the normal Wi-Fi.

**Android joining:** `WifiNetworkSpecifier` (Android 10+) shows a system
"Connect" dialog, then `bindProcessToNetwork` routes the app's sockets over
the offline network (Android otherwise avoids networks without internet).

**iOS, zero cost (default).** No paid Apple account is used. Cloud Macs
(Codemagic free tier or GitHub Actions) build an *unsigned* IPA and
SideStore/AltStore sign it with a free Apple ID (7-day refresh). A free
account can't have the Hotspot Configuration entitlement, so the iPhone
joins the other device's Wi-Fi by itself: the host shows a second, standard
`WIFI:T:WPA;S:...;P:...;;` QR code that the iPhone **Camera app** joins in
one tap, or Beam Share copies the password and opens Settings, then polls
for up to 3 minutes and continues automatically. The automatic
`NEHotspotConfiguration` join is still in the code and is switched on with
`--dart-define=IOS_HOTSPOT=true` for a paid build.

**iOS:** apps cannot create hotspots. iOS joins hotspots via
`NEHotspotConfiguration`; iPhone-to-iPhone uses Apple's peer-to-peer Wi-Fi
(AWDL) through `NWListener/NWBrowser` with `includePeerToPeer = true`. Dart
sockets cannot use AWDL directly, so Swift relays a loopback port to the
AWDL connection; TLS still runs end to end.

**Windows:** hosting uses `WiFiDirectAdvertisementPublisher` with legacy
settings (soft-AP) via C++/WinRT; joining uses `netsh wlan` with a
temporary WPA2 profile (simple, no native code).

**Discovery:** mDNS/Bonjour (`nsd` package, works on all three platforms),
service `_beamshare._tcp`, TXT record with id, name, platform, fingerprint.
Only the *receiver* advertises (the "waiting" screen); senders browse.

**Bluetooth is not used** (CLAUDE.md allows it only for discovery; QR +
mDNS + AWDL cover discovery without extra permissions).

## Original quality

- **Android:** files/photos are picked with the Storage Access Framework
  (`ACTION_OPEN_DOCUMENT` / `OPEN_DOCUMENT_TREE`). Bytes are read straight
  from the content URI by Kotlin (`FileChannel` positional reads on a
  background task queue); no cache copy, no decoding. `ACCESS_MEDIA_LOCATION`
  + `MediaStore.setRequireOriginal` keep GPS EXIF in photos.
  `file_picker` is not used on Android because it copies files into the cache
  first (slow for big videos and loses the modified date).
- **iOS:** `PHPicker` (no transcoding, `.current` representation) to choose,
  then `PHAssetResourceManager.writeData` exports the *original* resources:
  `.photo` (HEIC/JPEG), `.alternatePhoto` (RAW of RAW+JPEG), `.video`,
  `.pairedVideo` (Live Photo motion), `.audio`. Never `UIImage`. iCloud
  originals are downloaded if needed. Exported file dates = capture date.
  Edited photos are sent as their **unedited original** (the edit is
  stored by Photos separately). Changing that means also exporting
  `.fullSizePhoto`.
- **Everywhere:** modified dates are carried in the manifest and restored
  with `setLastModified`. Folder structure and empty folders are kept.

## Where received files go

- Windows: `%USERPROFILE%\Downloads\BeamShare` (changeable in Settings).
- Android: `Download/BeamShare` (visible in the Files app; photos/videos are
  added to the gallery with `MediaScannerConnection`).
- iOS: the app's Documents/Received folder, visible in the Files app
  ("On My iPhone > Beam Share") thanks to `UIFileSharingEnabled`.
- Name clashes get " (1)", " (2)"... nothing is ever overwritten.

## Tooling

- The PC had no Flutter/Android SDK/Visual Studio, although CLAUDE.md lists
  them. Installed (official sources): Flutter stable 3.47.9 → `E:\dev\flutter`,
  Android command-line tools + platform 36 + NDK 28.2 → `E:\dev\android`,
  Microsoft OpenJDK 21 → `E:\dev\jdk21`, Visual Studio 2022 Build Tools
  (C++ workload) via winget. User PATH/ANDROID_HOME/JAVA_HOME were set.
- **No `permission_handler` package.** Its current Android part compiles
  against SDK 37, whose platform package is published as `android-37.0`,
  which the Flutter template's Android Gradle Plugin (9.1) cannot match.
  Runtime permissions are requested by ~30 lines of Kotlin instead
  (`requestPermissions` in BeamPlatform.kt): one dependency fewer.
- `android/gradle.properties` sets `kotlin.incremental=false`: the project is
  on drive E: and the Pub cache on C:, which breaks Kotlin's incremental
  caches ("different roots"). Full compiles are only a few seconds slower.
- The APK is a "fat" APK (all CPU types, ~69 MB, mostly the ML Kit QR
  scanner). `flutter build apk --split-per-abi` makes ~25 MB per-phone APKs.
- Release APK is signed with the debug key (Flutter default) so it installs
  directly. Make your own keystore before publishing to the Play Store.
- Application id / bundle id: `com.beamshare.beam_share` (Android),
  `com.beamshare.beamShare` (iOS). Change them before a store release.
