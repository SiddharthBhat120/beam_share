import Flutter
import Network
import NetworkExtension
import Photos
import PhotosUI
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "BeamPlatform") {
      BeamPlatform.register(with: registrar)
    }
  }
}

// MARK: - Beam Share native iOS code ("beam/platform" channel)
//
//  * joinWifi: joins the other device's hotspot from the QR code
//    (NEHotspotConfiguration). Needs the paid-only Hotspot entitlement, so the
//    free build doesn't call it; it uses openWifiSettings + manual join.
//  * pickMedia: PHPicker + PHAssetResourceManager. Exports the ORIGINAL
//    resources (HEIC, ProRAW/DNG, MOV, Live Photo video) byte for byte.
//    Never goes through UIImage, so nothing is re-encoded or compressed.
//  * p2p*: iPhone-to-iPhone without any Wi-Fi network, using Apple's
//    peer-to-peer Wi-Fi (AWDL) via Network.framework (includePeerToPeer).
//    Dart's sockets can't use AWDL directly, so we relay: a local loopback
//    port <-> NWConnection over AWDL. TLS still runs end to end in Dart.

final class BeamPlatform: NSObject, FlutterPlugin, PHPickerViewControllerDelegate {
  private var channel: FlutterMethodChannel?
  private var pendingPick: FlutterResult?
  private var joinedSsid: String?
  private let p2p = P2PBridge()

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "beam/platform", binaryMessenger: registrar.messenger())
    let instance = BeamPlatform()
    instance.channel = channel
    instance.p2p.onPeers = { [weak channel] peers in
      DispatchQueue.main.async { channel?.invokeMethod("p2pPeers", arguments: peers) }
    }
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "deviceName":
      result(UIDevice.current.name)
    case "keepScreenOn":
      UIApplication.shared.isIdleTimerDisabled = (args["on"] as? Bool) ?? false
      result(nil)
    case "joinWifi":
      joinWifi(ssid: args["ssid"] as? String ?? "", passphrase: args["passphrase"] as? String ?? "", result: result)
    case "openWifiSettings":
      // Free builds can't join Wi-Fi by themselves: send the user to Settings.
      openFirst(["App-Prefs:root=WIFI", "App-prefs:WIFI", UIApplication.openSettingsURLString])
      result(nil)
    case "leaveWifi":
      if let s = joinedSsid { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: s) }
      joinedSsid = nil
      result(nil)
    case "openFolder":
      // Opens the app's folder in the Files app.
      let path = args["path"] as? String ?? ""
      if let url = URL(string: "shareddocuments://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
        UIApplication.shared.open(url)
      }
      result(nil)
    case "pickMedia":
      pickMedia(result: result)
    case "p2pAdvertise":
      p2p.advertise(name: args["name"] as? String ?? "iPhone",
                    localPort: args["port"] as? Int ?? 0,
                    txt: args["txt"] as? [String: String] ?? [:])
      result(nil)
    case "p2pBrowse":
      p2p.browse()
      result(nil)
    case "p2pStop":
      p2p.stopAll()
      result(nil)
    case "p2pConnect":
      p2p.connect(name: args["name"] as? String ?? "") { port in
        DispatchQueue.main.async {
          if let port = port { result(port) } else { result(FlutterError(code: "p2p_failed", message: "Peer not found", details: nil)) }
        }
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Wi-Fi

  /// Tries each URL in turn until one opens (the Wi-Fi page URL is not
  /// guaranteed on every iOS version; the last one opens this app's settings).
  private func openFirst(_ urls: [String]) {
    guard let first = urls.first else { return }
    guard let url = URL(string: first) else { openFirst(Array(urls.dropFirst())); return }
    UIApplication.shared.open(url, options: [:]) { ok in
      if !ok { self.openFirst(Array(urls.dropFirst())) }
    }
  }

  private func joinWifi(ssid: String, passphrase: String, result: @escaping FlutterResult) {
    let config = passphrase.isEmpty
      ? NEHotspotConfiguration(ssid: ssid)
      : NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
    config.joinOnce = true
    NEHotspotConfigurationManager.shared.apply(config) { [weak self] error in
      DispatchQueue.main.async {
        if let e = error as NSError? {
          let already = e.domain == NEHotspotConfigurationErrorDomain
            && e.code == NEHotspotConfigurationError.alreadyAssociated.rawValue
          if !already { result(false); return }
        }
        self?.joinedSsid = ssid
        result(true)
      }
    }
  }

  // MARK: Photos (original quality)

  private func pickMedia(result: @escaping FlutterResult) {
    if pendingPick != nil {
      result(FlutterError(code: "busy", message: "Picker already open", details: nil))
      return
    }
    // Full or limited access lets us read the original asset resources.
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in
      DispatchQueue.main.async { self.presentPicker(result: result) }
    }
  }

  private func presentPicker(result: @escaping FlutterResult) {
    var config = PHPickerConfiguration(photoLibrary: .shared())
    config.selectionLimit = 0 // unlimited
    config.filter = .any(of: [.images, .videos, .livePhotos])
    config.preferredAssetRepresentationMode = .current // no transcoding
    let picker = PHPickerViewController(configuration: config)
    picker.delegate = self
    guard let vc = topViewController() else {
      result(FlutterError(code: "no_ui", message: "No window", details: nil))
      return
    }
    pendingPick = result
    vc.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let result = pendingPick else { return }
    pendingPick = nil
    let ids = results.compactMap { $0.assetIdentifier }
    if ids.isEmpty {
      result([])
      return
    }
    DispatchQueue.global(qos: .userInitiated).async {
      let items = self.exportOriginals(ids: ids)
      DispatchQueue.main.async { result(items) }
    }
  }

  /// Writes each original resource to a temp folder, keeping the original
  /// file name and setting the file date to the photo's capture date.
  private func exportOriginals(ids: [String]) -> [[String: Any]] {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("BeamExport-\(UUID().uuidString)", isDirectory: true)
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
    let wanted: Set<PHAssetResourceType> = [.photo, .video, .alternatePhoto, .pairedVideo, .audio]
    var out: [[String: Any]] = []
    var usedNames = Set<String>()
    let group = DispatchGroup()
    let lock = NSLock()

    assets.enumerateObjects { asset, _, _ in
      let date = asset.creationDate ?? Date()
      for resource in PHAssetResource.assetResources(for: asset) where wanted.contains(resource.type) {
        lock.lock()
        var name = resource.originalFilename
        var n = 1
        while usedNames.contains(name.lowercased()) {
          let ext = (resource.originalFilename as NSString).pathExtension
          let stem = (resource.originalFilename as NSString).deletingPathExtension
          name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
          n += 1
        }
        usedNames.insert(name.lowercased())
        lock.unlock()
        let url = dir.appendingPathComponent(name)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true // download the original from iCloud if needed
        group.enter()
        PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
          defer { group.leave() }
          if error != nil { return }
          try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
          let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
          lock.lock()
          out.append([
            "kind": "file",
            "rel": name,
            "size": size,
            "mtime": Int64(date.timeIntervalSince1970 * 1000),
            "path": url.path,
          ])
          lock.unlock()
        }
      }
    }
    group.wait()
    return out
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}

// MARK: - Peer-to-peer relay (AWDL)

final class P2PBridge {
  static let serviceType = "_beamp2p._tcp"
  private let queue = DispatchQueue(label: "beam.p2p")
  private var listener: NWListener?
  private var browser: NWBrowser?
  private var endpoints: [String: NWEndpoint] = [:]
  private var relays: [NWListener] = []
  private var pipes: [Pipe] = []
  var onPeers: (([[String: Any]]) -> Void)?

  private func p2pParameters() -> NWParameters {
    let p = NWParameters.tcp
    p.includePeerToPeer = true
    return p
  }

  /// Makes this device discoverable over AWDL; incoming connections are
  /// relayed to the Dart server on 127.0.0.1:localPort.
  func advertise(name: String, localPort: Int, txt: [String: String]) {
    listener?.cancel()
    guard localPort > 0, let l = try? NWListener(using: p2pParameters()) else { return }
    var record = NWTXTRecord()
    for (k, v) in txt { record[k] = v }
    l.service = NWListener.Service(name: name, type: P2PBridge.serviceType, domain: nil, txtRecord: record)
    l.newConnectionHandler = { [weak self] incoming in
      guard let self = self, let port = NWEndpoint.Port(rawValue: UInt16(localPort)) else { return }
      let local = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
      self.addPipe(Pipe(incoming, local))
    }
    l.start(queue: queue)
    listener = l
  }

  func browse() {
    browser?.cancel()
    let b = NWBrowser(for: .bonjourWithTXTRecord(type: P2PBridge.serviceType, domain: nil), using: p2pParameters())
    b.browseResultsChangedHandler = { [weak self] results, _ in
      guard let self = self else { return }
      var list: [[String: Any]] = []
      self.endpoints.removeAll()
      for r in results {
        guard case let .service(name, _, _, _) = r.endpoint else { continue }
        var txt: [String: String] = [:]
        if case let .bonjour(record) = r.metadata {
          for (k, v) in record.dictionary { txt[k] = v }
        }
        self.endpoints[name] = r.endpoint
        list.append(["name": name, "txt": txt])
      }
      self.onPeers?(list)
    }
    b.start(queue: queue)
    browser = b
  }

  /// Opens a loopback port; whatever Dart sends there goes to the peer.
  func connect(name: String, done: @escaping (Int?) -> Void) {
    queue.async {
      guard let endpoint = self.endpoints[name],
            let relay = try? NWListener(using: .tcp, on: .any) else { done(nil); return }
      relay.newConnectionHandler = { [weak self] local in
        guard let self = self else { return }
        let remote = NWConnection(to: endpoint, using: self.p2pParameters())
        self.addPipe(Pipe(local, remote))
      }
      var reported = false
      relay.stateUpdateHandler = { state in
        if case .ready = state, !reported, let port = relay.port?.rawValue {
          reported = true
          done(Int(port))
        } else if case .failed = state, !reported {
          reported = true
          done(nil)
        }
      }
      relay.start(queue: self.queue)
      self.relays.append(relay)
    }
  }

  private func addPipe(_ p: Pipe) {
    pipes.append(p)
    p.onClose = { [weak self, weak p] in
      self?.queue.async { self?.pipes.removeAll { $0 === p } }
    }
    p.start(queue: queue)
  }

  func stopAll() {
    listener?.cancel()
    listener = nil
    browser?.cancel()
    browser = nil
    relays.forEach { $0.cancel() }
    relays.removeAll()
    pipes.forEach { $0.cancel() }
    pipes.removeAll()
  }
}

/// Copies bytes both ways between two connections (with back-pressure:
/// the next read starts only after the previous write completed).
final class Pipe {
  private let a: NWConnection
  private let b: NWConnection
  private var closed = false
  var onClose: (() -> Void)?

  init(_ a: NWConnection, _ b: NWConnection) {
    self.a = a
    self.b = b
  }

  func start(queue: DispatchQueue) {
    for c in [a, b] {
      c.stateUpdateHandler = { [weak self] state in
        switch state {
        case .failed, .cancelled: self?.cancel()
        default: break
        }
      }
      c.start(queue: queue)
    }
    pump(from: a, to: b)
    pump(from: b, to: a)
  }

  private func pump(from: NWConnection, to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
      guard let self = self, !self.closed else { return }
      if let data = data, !data.isEmpty {
        to.send(content: data, completion: .contentProcessed { sendError in
          if sendError != nil || isComplete { self.cancel(); return }
          self.pump(from: from, to: to)
        })
        return
      }
      if isComplete || error != nil { self.cancel() } else { self.pump(from: from, to: to) }
    }
  }

  func cancel() {
    if closed { return }
    closed = true
    a.cancel()
    b.cancel()
    onClose?()
  }
}
