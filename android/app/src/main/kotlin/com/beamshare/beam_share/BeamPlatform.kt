package com.beamshare.beam_share

import android.Manifest
import android.app.Activity
import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaScannerConnection
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.net.wifi.WifiConfiguration
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSpecifier
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.view.WindowManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec
import java.io.FileInputStream
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.security.SecureRandom
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Native Android side of Beam Share.
 *
 * Two channels:
 *  - "beam/platform" (main thread): hotspot / Wi-Fi Direct, joining Wi-Fi,
 *    pickers, misc.
 *  - "beam/files" (background thread): raw reads from content:// URIs, so the
 *    sender streams the *original* bytes of photos/videos/files directly.
 */
class BeamPlatform(private val activity: Activity, messenger: BinaryMessenger) {
    private val ctx: Context = activity.applicationContext
    private val main = Handler(Looper.getMainLooper())
    private val platform = MethodChannel(messenger, "beam/platform")
    private val files = MethodChannel(
        messenger, "beam/files", StandardMethodCodec.INSTANCE, messenger.makeBackgroundTaskQueue()
    )

    private val wifi get() = ctx.getSystemService(Context.WIFI_SERVICE) as WifiManager
    private val connectivity get() = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var p2pManager: WifiP2pManager? = null
    private var p2pChannel: WifiP2pManager.Channel? = null
    private var localHotspot: WifiManager.LocalOnlyHotspotReservation? = null
    private var joinCallback: ConnectivityManager.NetworkCallback? = null
    private var multicastLock: WifiManager.MulticastLock? = null
    private var pendingPick: MethodChannel.Result? = null

    private var pendingPermissions: MethodChannel.Result? = null
    private var requestedPermissions: List<String> = emptyList()

    companion object {
        private const val REQ_DOCS = 7101
        private const val REQ_TREE = 7102
        const val REQ_PERMISSIONS = 7103
    }

    init {
        platform.setMethodCallHandler { call, result -> onPlatformCall(call, result) }
        files.setMethodCallHandler { call, result -> onFilesCall(call, result) }
    }

    fun dispose() {
        stopHotspot()
        leaveWifi()
        multicastLock?.let { if (it.isHeld) it.release() }
        readers.values.forEach { it.close() }
        readers.clear()
    }

    // ------------------------------------------------------------------
    // beam/platform
    // ------------------------------------------------------------------

    private fun onPlatformCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "sdkInt" -> result.success(Build.VERSION.SDK_INT)
                "requestPermissions" -> requestPermissions(call.argument<List<String>>("permissions") ?: emptyList(), result)
                "openAppSettings" -> {
                    activity.startActivity(
                        Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + ctx.packageName))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    )
                    result.success(null)
                }
                "deviceName" -> result.success(
                    Settings.Global.getString(ctx.contentResolver, Settings.Global.DEVICE_NAME) ?: Build.MODEL
                )
                "downloadsDir" -> result.success(
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
                )
                "keepScreenOn" -> {
                    if (call.argument<Boolean>("on") == true) {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "multicastLock" -> {
                    val on = call.argument<Boolean>("on") == true
                    val lock = multicastLock ?: wifi.createMulticastLock("beam-mdns").also {
                        it.setReferenceCounted(false)
                        multicastLock = it
                    }
                    if (on && !lock.isHeld) lock.acquire()
                    if (!on && lock.isHeld) lock.release()
                    result.success(null)
                }
                "scanMedia" -> {
                    val paths = call.argument<List<String>>("paths") ?: emptyList()
                    MediaScannerConnection.scanFile(ctx, paths.toTypedArray(), null, null)
                    result.success(null)
                }
                "openFolder" -> {
                    openFolder(call.argument<String>("path") ?: "")
                    result.success(null)
                }
                "pickDocuments" -> pickDocuments(call.argument<String>("mime") ?: "*/*", result)
                "pickFolder" -> pickFolder(result)
                "startHotspot" -> startHotspot(call.argument<String>("name") ?: "Beam", result)
                "stopHotspot" -> {
                    stopHotspot()
                    result.success(null)
                }
                "joinWifi" -> joinWifi(
                    call.argument<String>("ssid") ?: "", call.argument<String>("passphrase") ?: "", result
                )
                "leaveWifi" -> {
                    leaveWifi()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message, null)
        }
    }

    private fun openFolder(path: String) {
        // Try to open the exact folder in the Files app, else the Downloads view.
        val downloads = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS).absolutePath
        val root = Environment.getExternalStorageDirectory().absolutePath
        try {
            if (path.startsWith(root)) {
                val rel = path.removePrefix(root).trimStart('/')
                val uri = DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents", "primary:$rel"
                )
                val intent = Intent(Intent.ACTION_VIEW).apply {
                    setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                }
                activity.startActivity(intent)
                return
            }
        } catch (_: Exception) {
        }
        try {
            activity.startActivity(Intent(DownloadManager.ACTION_VIEW_DOWNLOADS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (_: Exception) {
            android.util.Log.w("Beam", "No app to open $downloads")
        }
    }

    // ------------------------------------------------------------------
    // Runtime permissions (e.g. "android.permission.CAMERA")
    // ------------------------------------------------------------------

    private fun requestPermissions(perms: List<String>, result: MethodChannel.Result) {
        val missing = perms.filter { ctx.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) {
            result.success(perms.associateWith { true })
            return
        }
        if (pendingPermissions != null) {
            result.error("busy", "A permission request is already open", null)
            return
        }
        pendingPermissions = result
        requestedPermissions = perms
        activity.requestPermissions(missing.toTypedArray(), REQ_PERMISSIONS)
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != REQ_PERMISSIONS) return false
        val result = pendingPermissions ?: return true
        pendingPermissions = null
        result.success(requestedPermissions.associateWith {
            ctx.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
        })
        return true
    }

    // ------------------------------------------------------------------
    // Pickers (Storage Access Framework: original files, no copies)
    // ------------------------------------------------------------------

    private fun pickDocuments(mime: String, result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        pendingPick = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            val types = mime.split(",").map { it.trim() }.filter { it.isNotEmpty() }
            if (types.size > 1) {
                type = "*/*"
                putExtra(Intent.EXTRA_MIME_TYPES, types.toTypedArray())
            } else {
                type = types.firstOrNull() ?: "*/*"
            }
        }
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, REQ_DOCS)
    }

    private fun pickFolder(result: MethodChannel.Result) {
        if (pendingPick != null) {
            result.error("busy", "A picker is already open", null)
            return
        }
        pendingPick = result
        @Suppress("DEPRECATION")
        activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQ_TREE)
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_DOCS && requestCode != REQ_TREE) return false
        val result = pendingPick ?: return true
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Any>())
            return true
        }
        Thread {
            try {
                val list = if (requestCode == REQ_DOCS) describeDocuments(data) else walkTree(data.data!!)
                main.post { result.success(list) }
            } catch (e: Exception) {
                main.post { result.error("pick_failed", e.message, null) }
            }
        }.start()
        return true
    }

    private fun describeDocuments(data: Intent): List<Map<String, Any?>> {
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri) }
        if (uris.isEmpty()) data.data?.let { uris.add(it) }
        val out = mutableListOf<Map<String, Any?>>()
        for (uri in uris) {
            try {
                ctx.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } catch (_: Exception) {
            }
            var name = uri.lastPathSegment ?: "file"
            var size = -1L
            var modified = 0L
            ctx.contentResolver.query(uri, null, null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    val m = c.getColumnIndex(DocumentsContract.Document.COLUMN_LAST_MODIFIED)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                    if (m >= 0 && !c.isNull(m)) modified = c.getLong(m)
                }
            }
            if (size < 0) size = measure(uri)
            if (modified <= 0) modified = System.currentTimeMillis()
            out.add(mapOf("kind" to "uri", "rel" to name, "size" to size, "mtime" to modified, "uri" to uri.toString()))
        }
        return out
    }

    /** Size by reading, for providers that don't report it. */
    private fun measure(uri: Uri): Long =
        ctx.contentResolver.openFileDescriptor(uri, "r")?.use { it.statSize } ?: 0L

    private fun walkTree(tree: Uri): List<Map<String, Any?>> {
        try {
            ctx.contentResolver.takePersistableUriPermission(tree, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (_: Exception) {
        }
        val rootId = DocumentsContract.getTreeDocumentId(tree)
        var rootName = "Folder"
        var rootModified = System.currentTimeMillis()
        ctx.contentResolver.query(
            DocumentsContract.buildDocumentUriUsingTree(tree, rootId),
            arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_LAST_MODIFIED),
            null, null, null
        )?.use { c ->
            if (c.moveToFirst()) {
                rootName = c.getString(0) ?: rootName
                if (!c.isNull(1)) rootModified = c.getLong(1)
            }
        }
        val out = mutableListOf<Map<String, Any?>>()
        out.add(mapOf("kind" to "dir", "rel" to rootName, "size" to 0L, "mtime" to rootModified))
        walk(tree, rootId, rootName, out)
        return out
    }

    private fun walk(tree: Uri, parentId: String, prefix: String, out: MutableList<Map<String, Any?>>) {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        val dirs = mutableListOf<Pair<String, String>>()
        ctx.contentResolver.query(children, cols, null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                val mime = c.getString(2) ?: ""
                val size = if (c.isNull(3)) 0L else c.getLong(3)
                val modified = if (c.isNull(4)) System.currentTimeMillis() else c.getLong(4)
                val rel = "$prefix/$name"
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    out.add(mapOf("kind" to "dir", "rel" to rel, "size" to 0L, "mtime" to modified))
                    dirs.add(id to rel)
                } else {
                    val uri = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                    out.add(mapOf("kind" to "uri", "rel" to rel, "size" to size, "mtime" to modified, "uri" to uri.toString()))
                }
            }
        }
        for ((id, rel) in dirs) walk(tree, id, rel, out)
    }

    // ------------------------------------------------------------------
    // Offline network: Wi-Fi Direct group (preferred) or LocalOnlyHotspot.
    //
    // A Wi-Fi Direct group owner works like a normal access point for
    // "legacy" clients: iPhones, Windows PCs and other phones join it with
    // SSID + password from the QR code. No SIM, no internet, no router.
    // ------------------------------------------------------------------

    private fun randomPassphrase(): String {
        val chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        val r = SecureRandom()
        return (1..12).map { chars[r.nextInt(chars.length)] }.joinToString("")
    }

    private fun startHotspot(name: String, result: MethodChannel.Result) {
        var replied = false
        val reply: (Map<String, Any?>?, String?) -> Unit = { info, err ->
            main.post {
                if (!replied) {
                    replied = true
                    if (info != null) result.success(info) else result.error("hotspot_failed", err, null)
                }
            }
        }
        startWifiDirectGroup(name, { info -> reply(info, null) }) { err ->
            android.util.Log.w("Beam", "Wi-Fi Direct group failed ($err), trying LocalOnlyHotspot")
            startLocalOnlyHotspot({ info -> reply(info, null) }) { err2 -> reply(null, "$err / $err2") }
        }
    }

    private fun hasWifiPermission(): Boolean {
        val perm = if (Build.VERSION.SDK_INT >= 33) Manifest.permission.NEARBY_WIFI_DEVICES
        else Manifest.permission.ACCESS_FINE_LOCATION
        return ctx.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    }

    @Suppress("MissingPermission")
    private fun startWifiDirectGroup(
        name: String, onOk: (Map<String, Any?>) -> Unit, onFail: (String) -> Unit
    ) {
        if (!hasWifiPermission()) return onFail("permission missing")
        val mgr = ctx.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
            ?: return onFail("no Wi-Fi Direct")
        val ch = p2pChannel ?: mgr.initialize(ctx, Looper.getMainLooper(), null)
        p2pManager = mgr
        p2pChannel = ch
        val safe = name.filter { it.isLetterOrDigit() }.take(12).ifEmpty { "Beam" }

        fun readGroup(attempt: Int) {
            mgr.requestGroupInfo(ch) { group ->
                if (group != null && group.isGroupOwner && !group.passphrase.isNullOrEmpty()) {
                    onOk(mapOf("ssid" to group.networkName, "passphrase" to group.passphrase, "mode" to "wifi-direct"))
                } else if (attempt < 20) {
                    main.postDelayed({ readGroup(attempt + 1) }, 300)
                } else {
                    onFail("group info not available")
                }
            }
        }

        fun create(band5: Boolean) {
            val listener = object : WifiP2pManager.ActionListener {
                override fun onSuccess() = readGroup(0)
                override fun onFailure(reason: Int) {
                    if (band5) create(false) else onFail("createGroup failed ($reason)")
                }
            }
            if (Build.VERSION.SDK_INT >= 29) {
                val config = WifiP2pConfig.Builder()
                    .setNetworkName("DIRECT-bs-$safe")
                    .setPassphrase(randomPassphrase())
                    .enablePersistentMode(false)
                    .setGroupOperatingBand(
                        if (band5) WifiP2pConfig.GROUP_OWNER_BAND_5GHZ else WifiP2pConfig.GROUP_OWNER_BAND_AUTO
                    )
                    .build()
                mgr.createGroup(ch, config, listener)
            } else {
                mgr.createGroup(ch, listener)
            }
        }

        // Remove any old group first (ignore the result).
        mgr.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() = create(true)
            override fun onFailure(reason: Int) = create(true)
        })
    }

    @Suppress("MissingPermission", "DEPRECATION")
    private fun startLocalOnlyHotspot(onOk: (Map<String, Any?>) -> Unit, onFail: (String) -> Unit) {
        if (!hasWifiPermission()) return onFail("permission missing")
        try {
            wifi.startLocalOnlyHotspot(object : WifiManager.LocalOnlyHotspotCallback() {
                override fun onStarted(reservation: WifiManager.LocalOnlyHotspotReservation) {
                    localHotspot = reservation
                    var ssid: String? = null
                    var pass: String? = null
                    if (Build.VERSION.SDK_INT >= 30) {
                        val c = reservation.softApConfiguration
                        ssid = if (Build.VERSION.SDK_INT >= 33) c.wifiSsid?.toString()?.trim('"') else c.ssid
                        pass = c.passphrase
                    } else {
                        reservation.wifiConfiguration?.let {
                            ssid = it.SSID?.trim('"')
                            pass = it.preSharedKey?.trim('"')
                        }
                    }
                    if (ssid != null) onOk(mapOf("ssid" to ssid, "passphrase" to (pass ?: ""), "mode" to "local-only"))
                    else onFail("no hotspot config")
                }

                override fun onFailed(reason: Int) = onFail("LocalOnlyHotspot failed ($reason)")
            }, main)
        } catch (e: Exception) {
            onFail(e.message ?: "LocalOnlyHotspot error")
        }
    }

    private fun stopHotspot() {
        try {
            val mgr = p2pManager
            val ch = p2pChannel
            if (mgr != null && ch != null) mgr.removeGroup(ch, null)
        } catch (_: Exception) {
        }
        try {
            localHotspot?.close()
        } catch (_: Exception) {
        }
        localHotspot = null
    }

    // ------------------------------------------------------------------
    // Joining the other device's network (from the QR code)
    // ------------------------------------------------------------------

    @Suppress("DEPRECATION", "MissingPermission")
    private fun joinWifi(ssid: String, passphrase: String, result: MethodChannel.Result) {
        leaveWifi()
        if (Build.VERSION.SDK_INT >= 29) {
            val spec = WifiNetworkSpecifier.Builder().setSsid(ssid).apply {
                if (passphrase.isNotEmpty()) setWpa2Passphrase(passphrase)
            }.build()
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .removeCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .setNetworkSpecifier(spec)
                .build()
            var replied = false
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    // Route this app's sockets over the offline network (it
                    // has no internet, so Android would otherwise avoid it).
                    connectivity.bindProcessToNetwork(network)
                    main.post { if (!replied) { replied = true; result.success(true) } }
                }

                override fun onUnavailable() {
                    main.post { if (!replied) { replied = true; result.success(false) } }
                }
            }
            joinCallback = cb
            // Shows the system "Connect to device" dialog.
            connectivity.requestNetwork(request, cb, 60_000)
        } else {
            val conf = WifiConfiguration().apply {
                SSID = "\"$ssid\""
                if (passphrase.isEmpty()) allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE)
                else preSharedKey = "\"$passphrase\""
            }
            val id = wifi.addNetwork(conf)
            if (id < 0) {
                result.success(false)
                return
            }
            wifi.disconnect()
            val ok = wifi.enableNetwork(id, true)
            wifi.reconnect()
            result.success(ok)
        }
    }

    private fun leaveWifi() {
        joinCallback?.let {
            try {
                connectivity.unregisterNetworkCallback(it)
            } catch (_: Exception) {
            }
        }
        joinCallback = null
        try {
            connectivity.bindProcessToNetwork(null)
        } catch (_: Exception) {
        }
    }

    // ------------------------------------------------------------------
    // beam/files: raw random-access reads (runs on a background thread)
    // ------------------------------------------------------------------

    private class Reader(val pfd: ParcelFileDescriptor) {
        val stream = FileInputStream(pfd.fileDescriptor)
        val channel: FileChannel = stream.channel
        var position = 0L

        fun close() {
            try { channel.close() } catch (_: Exception) {}
            try { stream.close() } catch (_: Exception) {}
            try { pfd.close() } catch (_: Exception) {}
        }
    }

    private val readers = ConcurrentHashMap<Int, Reader>()
    private val nextHandle = AtomicInteger(1)

    private fun onFilesCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "open" -> {
                    var uri = Uri.parse(call.argument<String>("uri"))
                    uri = requireOriginal(uri)
                    val pfd = ctx.contentResolver.openFileDescriptor(uri, "r")
                        ?: throw IllegalStateException("cannot open $uri")
                    val h = nextHandle.getAndIncrement()
                    readers[h] = Reader(pfd)
                    result.success(h)
                }
                "read" -> {
                    val r = readers[call.argument<Int>("h")!!] ?: throw IllegalStateException("closed")
                    val offset = (call.argument<Number>("offset")!!).toLong()
                    val length = call.argument<Int>("length")!!
                    result.success(read(r, offset, length))
                }
                "close" -> {
                    readers.remove(call.argument<Int>("h")!!)?.close()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("io_error", e.message, null)
        }
    }

    /** Asks MediaStore for the unredacted original (keeps GPS in photos). */
    private fun requireOriginal(uri: Uri): Uri {
        if (Build.VERSION.SDK_INT < 29) return uri
        if (ctx.checkSelfPermission(Manifest.permission.ACCESS_MEDIA_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            return uri
        }
        return try {
            val media = if (uri.authority == MediaStore.AUTHORITY) uri else MediaStore.getMediaUri(ctx, uri)
            if (media != null) MediaStore.setRequireOriginal(media) else uri
        } catch (_: Exception) {
            uri
        }
    }

    private fun read(r: Reader, offset: Long, length: Int): ByteArray {
        val buf = ByteBuffer.allocate(length)
        try {
            // Positional read: works for normal (seekable) files.
            var pos = offset
            while (buf.hasRemaining()) {
                val n = r.channel.read(buf, pos)
                if (n < 0) break
                pos += n
            }
        } catch (e: Exception) {
            // Streaming-only providers: fall back to sequential reads.
            buf.clear()
            if (offset < r.position) throw e
            var skip = offset - r.position
            while (skip > 0) {
                val s = r.stream.skip(skip)
                if (s <= 0) break
                skip -= s
            }
            val arr = buf.array()
            var filled = 0
            while (filled < length) {
                val n = r.stream.read(arr, filled, length - filled)
                if (n < 0) break
                filled += n
            }
            r.position = offset + filled
            return if (filled == length) arr else arr.copyOf(filled)
        }
        val n = buf.position()
        return if (n == length) buf.array() else buf.array().copyOf(n)
    }
}
