package com.connecso.client

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Environment
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import java.util.UUID
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.ConcurrentHashMap
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pendingVpnPermission: MethodChannel.Result? = null
    private val pendingRequests = mutableMapOf<String, PendingRequest>()
    private val ioExecutor = Executors.newCachedThreadPool()
    private val updateTransfers = ConcurrentHashMap<String, AndroidUpdateTransfer>()
    private var vpnReceiverRegistered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ensureVpnNotificationChannel()
        requestNotificationPermissionForFreshInstall()
    }

    private fun ensureVpnNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                "connecso_vpn",
                "VPN connection",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
    }

    private fun requestNotificationPermissionForFreshInstall() {
        if (Build.VERSION.SDK_INT < 33 ||
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        ) return

        val preferences = getSharedPreferences("notification_settings", Context.MODE_PRIVATE)
        if (preferences.getBoolean("permission_requested", false)) return

        preferences.edit().putBoolean("permission_requested", true).apply()
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            NOTIFICATION_PERMISSION_REQUEST,
        )
    }

    private class AndroidUpdateTransfer(
        val id: String,
        val result: MethodChannel.Result,
        @Volatile var paused: Boolean = false,
        @Volatile var cancelled: Boolean = false,
        @Volatile var closed: Boolean = false,
        @Volatile var connection: HttpURLConnection? = null,
    )

    private val vpnReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ConnecsoVpnService.ACTION_RESULT) return
            val requestId = intent.getStringExtra(ConnecsoVpnService.EXTRA_REQUEST_ID) ?: return
            val success = intent.getBooleanExtra(ConnecsoVpnService.EXTRA_SUCCESS, false)
            if (intent.getStringExtra(ConnecsoVpnService.EXTRA_OPERATION) ==
                DestinationPingService.OPERATION_PROGRESS
            ) {
                if (::channel.isInitialized) {
                    channel.invokeMethod(
                        DestinationPingService.OPERATION_PROGRESS,
                        mapOf(
                            "requestId" to requestId,
                            "nodeId" to intent.getStringExtra(DestinationPingService.EXTRA_PROGRESS_NODE_ID),
                            "success" to success,
                            "latencyMs" to intent.getLongExtra(
                                DestinationPingService.EXTRA_PROGRESS_LATENCY_MS,
                                -1L,
                            ),
                        ),
                    )
                }
                return
            }
            val pending = pendingRequests.remove(requestId)
            if (pending == null) {
                // Quick Settings tile requests do not have a Flutter pending
                // call. Forward their completed state to the foreground UI.
                if (::channel.isInitialized) {
                    channel.invokeMethod(
                        "vpnStateChanged",
                        mapOf(
                            "operation" to intent.getStringExtra(ConnecsoVpnService.EXTRA_OPERATION),
                            "success" to success,
                        ),
                    )
                }
                return
            }
            when (pending.operation) {
                DestinationPingService.OPERATION -> {
                    if (!success) {
                        pending.result.error(
                            "DESTINATION_PING_FAILED",
                            intent.getStringExtra(ConnecsoVpnService.EXTRA_ERROR)
                                ?: "Destination RTT batch failed.",
                            null,
                        )
                    } else {
                        val results = org.json.JSONArray(
                            intent.getStringExtra(DestinationPingService.EXTRA_RESULTS) ?: "[]",
                        )
                        pending.result.success(List(results.length()) { index ->
                            val item = results.optJSONObject(index) ?: org.json.JSONObject()
                            mapOf(
                                "nodeId" to item.optString("nodeId"),
                                "success" to item.optBoolean("success"),
                                "latencyMs" to item.optLong("latencyMs", -1L),
                            )
                        })
                    }
                }
                ConnecsoVpnService.OP_PROBE -> pending.result.success(
                    mapOf(
                        "success" to success,
                        "latencyMs" to intent.getLongExtra(ConnecsoVpnService.EXTRA_LATENCY_MS, -1L),
                    ),
                )
                ConnecsoVpnService.OP_VERIFY -> pending.result.success(success)
                ConnecsoVpnService.OP_STATS -> if (success) {
                    pending.result.success(
                        mapOf(
                            "uploadBytes" to intent.getLongExtra(ConnecsoVpnService.EXTRA_UPLOAD_BYTES, 0L),
                            "downloadBytes" to intent.getLongExtra(ConnecsoVpnService.EXTRA_DOWNLOAD_BYTES, 0L),
                        ),
                    )
                } else {
                    pending.result.error("VPN_STATS_UNAVAILABLE", "VPN traffic statistics are temporarily unavailable.", null)
                }
                ConnecsoVpnService.OP_SPEED_TEST -> if (success) {
                    pending.result.success(
                        mapOf(
                            "megabitsPerSecond" to intent.getDoubleExtra(ConnecsoVpnService.EXTRA_SPEED_MBPS, 0.0),
                            "bytes" to intent.getLongExtra(ConnecsoVpnService.EXTRA_SPEED_BYTES, 0L),
                            "seconds" to intent.getDoubleExtra(ConnecsoVpnService.EXTRA_SPEED_SECONDS, 0.0),
                            "connections" to intent.getIntExtra(ConnecsoVpnService.EXTRA_SPEED_CONNECTIONS, 0),
                        ),
                    )
                } else {
                    pending.result.error(
                        "SPEED_TEST_FAILED",
                        intent.getStringExtra(ConnecsoVpnService.EXTRA_ERROR) ?: "Speed test failed.",
                        null,
                    )
                }
                else -> if (success) {
                    pending.result.success(null)
                } else {
                    pending.result.error(
                        "VPN_OPERATION_FAILED",
                        intent.getStringExtra(ConnecsoVpnService.EXTRA_ERROR)
                            ?: "Android VPN operation failed.",
                        null,
                    )
                }
            }
        }
    }

    private data class PendingRequest(
        val operation: String,
        val result: MethodChannel.Result,
    )

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.connecso.client/vpn")
        registerVpnReceiver()
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "traceLog" -> {
                    Log.i("CONNECSO_CONNECT_TRACE", call.arguments?.toString() ?: "")
                    result.success(null)
                }
                "prepareVpn" -> requestVpnPermission(result)
                "openBatterySettings" -> {
                    try {
                        val request = Intent(android.provider.Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
                            .setData(android.net.Uri.parse("package:$packageName"))
                        startActivity(request)
                    } catch (_: Exception) {
                        startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                            .setData(android.net.Uri.parse("package:$packageName")))
                    }
                    result.success(null)
                }
                "coreAvailable" -> result.success(true)
                "cancelDestinationPings" -> {
                    val iterator = pendingRequests.entries.iterator()
                    while (iterator.hasNext()) {
                        val entry = iterator.next()
                        if (entry.value.operation == DestinationPingService.OPERATION) {
                            iterator.remove()
                            runCatching {
                                entry.value.result.error(
                                    "DESTINATION_PING_CANCELLED",
                                    "Destination RTT probe timed out and was stopped.",
                                    null,
                                )
                            }
                        }
                    }
                    stopService(Intent(this, DestinationPingService::class.java))
                    stopService(Intent(this, DestinationPingService2::class.java))
                    result.success(null)
                }
                "androidBuildInfo" -> {
                    @Suppress("DEPRECATION")
                    val info = packageManager.getPackageInfo(packageName, 0)
                    @Suppress("DEPRECATION")
                    val versionCode = if (Build.VERSION.SDK_INT >= 28) {
                        info.longVersionCode
                    } else {
                        info.versionCode.toLong()
                    }
                    result.success(
                        mapOf(
                            "versionName" to (info.versionName ?: "0.0.0"),
                            "versionCode" to versionCode,
                            "primaryAbi" to (Build.SUPPORTED_ABIS.firstOrNull() ?: "universal"),
                        ),
                    )
                }
                "findAndroidUpdate" -> {
                    val name = call.argument<String>("name")
                    if (name.isNullOrBlank() || !isSafeUpdateName(name)) {
                        result.error("INVALID_UPDATE_NAME", "Invalid APK file name.", null)
                    } else {
                        val file = File(updateDirectory(), name)
                        result.success(if (file.exists()) file.absolutePath else null)
                    }
                }
                "androidUpdateDirectory" -> result.success(updateDirectory().absolutePath)
                "startAndroidUpdateDownload" -> {
                    val id = call.argument<String>("id")
                    val name = call.argument<String>("name")
                    val rawUrl = call.argument<String>("url")
                    val sizeBytes = call.argument<Number>("sizeBytes")?.toLong() ?: 0L
                    val useActiveRoute = call.argument<Boolean>("useActiveRoute") ?: true
                    val uri = rawUrl?.let(Uri::parse)
                    val host = uri?.host.orEmpty()
                    if (id.isNullOrBlank() || name.isNullOrBlank() || !isSafeUpdateName(name) ||
                        uri == null || uri.scheme != "https" || host.isBlank() ||
                        !(host == "github.com" || host.endsWith("githubusercontent.com"))) {
                        result.error("INVALID_UPDATE", "Invalid GitHub APK update request.", null)
                    } else {
                        startAndroidUpdateDownload(id, uri.toString(), name, sizeBytes, useActiveRoute, result)
                    }
                }
                "controlAndroidUpdateDownload" -> {
                    val id = call.argument<String>("id")
                    val action = call.argument<String>("action")
                    val transfer = id?.let(updateTransfers::get)
                    if (transfer == null) {
                        result.success(null)
                    } else {
                        when (action) {
                            "pause" -> {
                                transfer.paused = true
                                transfer.connection?.disconnect()
                            }
                            "resume" -> transfer.paused = false
                            "cancel" -> transfer.cancelled = true
                            "close" -> transfer.closed = true
                        }
                        if (action == "cancel" || action == "close") transfer.connection?.disconnect()
                        result.success(null)
                    }
                }
                "installAndroidUpdate", "openAndroidUpdate" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("INVALID_UPDATE_PATH", "APK path is missing.", null)
                    } else {
                        openAndroidUpdate(File(path), result)
                    }
                }
                "quickTileConnection" -> result.success(QuickTileStore.readConnection(this))
                "updateWidgetData" -> {
                    val data = call.arguments as? Map<*, *>
                    if (data == null) {
                        result.error("INVALID_WIDGET_DATA", "Widget data is missing.", null)
                    } else {
                        getSharedPreferences("connecso_widget", Context.MODE_PRIVATE).edit()
                            .putBoolean("connected", data["connected"] == true)
                            .putBoolean("connectionFailed", data["connectionFailed"] == true)
                            .putString("country", data["country"]?.toString().orEmpty())
                            .putString("language", data["language"]?.toString() ?: "en")
                            .putBoolean("darkTheme", data["darkTheme"] == true)
                            .putLong("usedBytes", (data["usedBytes"] as? Number)?.toLong() ?: -1L)
                            .putLong("totalBytes", (data["totalBytes"] as? Number)?.toLong() ?: -1L)
                            .putLong("remainingBytes", (data["remainingBytes"] as? Number)?.toLong() ?: -1L)
                            .putBoolean("unlimited", data["unlimited"] == true)
                            .putBoolean("quotaAvailable", data["quotaAvailable"] == true)
                            .putString("widgetDestinations", data["widgetDestinations"]?.toString() ?: "[]")
                            .putBoolean("widgetHasFavorites", data["widgetHasFavorites"] == true)
                            .apply()
                        ConnecsoWidgetProvider.refresh(this)
                        result.success(null)
                    }
                }
                "speedTest" -> sendVpnCommand(
                    ConnecsoVpnService::class.java,
                    ConnecsoVpnService.ACTION_SPEED_TEST,
                    ConnecsoVpnService.OP_SPEED_TEST,
                    result,
                )
                "requestAddQuickSettingsTile" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                        result.success(false)
                    } else {
                        val statusBar = getSystemService(android.app.StatusBarManager::class.java)
                        statusBar.requestAddTileService(
                            ComponentName(this, QuickSettingsVpnTileService::class.java),
                            "Connecso",
                            android.graphics.drawable.Icon.createWithResource(this, R.drawable.connecso_logo),
                            mainExecutor,
                        ) { status -> result.success(status == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED || status == android.app.StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED) }
                    }
                }
                "requestAddHomeScreenWidget" -> {
                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
                        result.success(false)
                    } else {
                        val manager = getSystemService(AppWidgetManager::class.java)
                        result.success(manager.requestPinAppWidget(
                            ComponentName(this, ConnecsoWidgetProvider::class.java), null, null,
                        ))
                    }
                }
                "installedApplications" -> result.success(installedApplications())
                "openExternalUrl" -> {
                    val rawUrl = call.argument<String>("url")
                    val uri = rawUrl?.let { android.net.Uri.parse(it) }
                    if (uri == null || uri.scheme != "https" || uri.host.isNullOrBlank()) {
                        result.error("INVALID_URL", "An HTTPS URL is required.", null)
                    } else {
                        try {
                            startActivity(Intent(Intent.ACTION_VIEW, uri))
                            result.success(null)
                        } catch (error: Exception) {
                            result.error("URL_OPEN_FAILED", error.message, null)
                        }
                    }
                }
                "fetchDirectSubscription" -> {
                    val rawUrl = call.argument<String>("url")
                    val requestHeaders = call.argument<Map<String, String>>("headers").orEmpty()
                    if (rawUrl.isNullOrBlank()) {
                        result.error("INVALID_URL", "A subscription URL is required.", null)
                    } else {
                        ioExecutor.execute {
                            try {
                                val payload = fetchDirectSubscription(
                                    rawUrl,
                                    useUnderlying = true,
                                    requestHeaders = requestHeaders,
                                )
                                runOnUiThread { result.success(payload) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "DIRECT_FETCH_FAILED",
                                        error.message ?: "Direct subscription fetch failed.",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "fetchCurrentRouteSubscription" -> {
                    val rawUrl = call.argument<String>("url")
                    val requestHeaders = call.argument<Map<String, String>>("headers").orEmpty()
                    if (rawUrl.isNullOrBlank()) {
                        result.error("INVALID_URL", "A subscription URL is required.", null)
                    } else {
                        ioExecutor.execute {
                            try {
                                val payload = fetchDirectSubscription(
                                    rawUrl,
                                    useUnderlying = false,
                                    requestHeaders = requestHeaders,
                                )
                                runOnUiThread { result.success(payload) }
                            } catch (error: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "CURRENT_ROUTE_FETCH_FAILED",
                                        error.message ?: "Current route subscription fetch failed.",
                                        null,
                                    )
                                }
                            }
                        }
                    }
                }
                "applicationIcon" -> {
                    val packageName = call.argument<String>("packageName")
                    if (packageName.isNullOrBlank()) {
                        result.error("INVALID_PACKAGE", "An application package is required.", null)
                    } else {
                        // PackageManager icon rendering and PNG encoding can
                        // take long enough to stall list scrolling. Keep it
                        // off the platform thread, especially during cache warmup.
                        ioExecutor.execute {
                            val icon = applicationIcon(packageName)
                            runOnUiThread { result.success(icon) }
                        }
                    }
                }
                "probeNode" -> {
                    val config = call.argument<String>("config")
                    if (config == null) {
                        result.error(
                            "INVALID_CONFIG",
                            "The requested VPN core is not ready.",
                            null,
                        )
                    } else {
                        sendVpnCommand(
                            ConnecsoVpnService::class.java,
                            ConnecsoVpnService.ACTION_PROBE,
                            ConnecsoVpnService.OP_PROBE,
                            result,
                            mapOf(
                                ConnecsoVpnService.EXTRA_CONFIG to config,
                                ConnecsoVpnService.EXTRA_TRACE_NODE_ID to (call.argument<String>("traceNodeId") ?: "unknown"),
                                ConnecsoVpnService.EXTRA_TRACE_COUNTRY to (call.argument<String>("traceCountry") ?: "unknown"),
                            ),
                        )
                    }
                }
                "pingDestinations" -> {
                    val nodes = call.argument<List<Map<String, String>>>("nodes").orEmpty()
                    val worker = call.argument<Int>("worker") ?: 0
                    val serviceClass = if (worker == 1) {
                        DestinationPingService2::class.java
                    } else {
                        DestinationPingService::class.java
                    }
                    if (nodes.isEmpty()) {
                        result.success(emptyList<Map<String, Any>>())
                    } else {
                        val configs = org.json.JSONArray()
                        nodes.forEach { node ->
                            configs.put(
                                org.json.JSONObject()
                                    .put("nodeId", node["nodeId"] ?: "")
                                    .put("country", node["country"] ?: "")
                                    .put("config", node["config"] ?: ""),
                            )
                        }
                        val requestId = UUID.randomUUID().toString()
                        pendingRequests[requestId] = PendingRequest(
                            DestinationPingService.OPERATION,
                            result,
                        )
                        try {
                            startService(
                                Intent(this, serviceClass)
                                    .setAction(DestinationPingService.ACTION_PING)
                                    .putExtra(DestinationPingService.EXTRA_REQUEST_ID, requestId)
                                    .putExtra(DestinationPingService.EXTRA_CONFIGS, configs.toString()),
                            )
                        } catch (error: Exception) {
                            pendingRequests.remove(requestId)
                            result.error(
                                "DESTINATION_PING_UNAVAILABLE",
                                error.message ?: "Destination ping service could not be started.",
                                null,
                            )
                        }
                    }
                }
                "startVpn" -> {
                    val config = call.argument<String>("config")
                    val nodeId = call.argument<String>("nodeId")
                    val mode = call.argument<String>("splitTunnelMode")
                    val packages = call.argument<List<String>>("splitTunnelPackages")
                    val tunnelEngine = call.argument<String>("tunnelEngine") ?: "AUTO"
                    if (config == null || nodeId == null || mode == null || packages == null) {
                        result.error("INVALID_CONFIG", "VPN start parameters are incomplete.", null)
                    } else {
                        sendVpnCommand(
                            ConnecsoVpnService::class.java,
                            ConnecsoVpnService.ACTION_START,
                            ConnecsoVpnService.OP_START,
                            result,
                            mapOf(
                                ConnecsoVpnService.EXTRA_CONFIG to config,
                                ConnecsoVpnService.EXTRA_NODE_ID to nodeId,
                                ConnecsoVpnService.EXTRA_COUNTRY_NAME to (call.argument<String>("countryName") ?: ""),
                                ConnecsoVpnService.EXTRA_COUNTRY_CODE to (call.argument<String>("countryCode") ?: ""),
                                ConnecsoVpnService.EXTRA_SPLIT_MODE to mode,
                                ConnecsoVpnService.EXTRA_SPLIT_PACKAGES to ArrayList(packages),
                                ConnecsoVpnService.EXTRA_TUNNEL_ENGINE to tunnelEngine,
                            ),
                            foreground = true,
                        )
                    }
                }
                "stopVpn" -> sendVpnCommand(
                    ConnecsoVpnService::class.java,
                    ConnecsoVpnService.ACTION_STOP,
                    ConnecsoVpnService.OP_STOP,
                    result,
                )
                "verifyConnectivity" -> sendVpnCommand(
                    ConnecsoVpnService::class.java,
                    ConnecsoVpnService.ACTION_VERIFY,
                    ConnecsoVpnService.OP_VERIFY,
                    result,
                )
                "readStats" -> sendVpnCommand(
                    ConnecsoVpnService::class.java,
                    ConnecsoVpnService.ACTION_STATS,
                    ConnecsoVpnService.OP_STATS,
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (vpnReceiverRegistered) {
            unregisterReceiver(vpnReceiver)
            vpnReceiverRegistered = false
        }
        pendingRequests.values.forEach {
            it.result.error("ACTIVITY_DESTROYED", "VPN request was interrupted.", null)
        }
        pendingRequests.clear()
        ioExecutor.shutdownNow()
        super.onDestroy()
    }

    private fun fetchDirectSubscription(
        rawUrl: String,
        useUnderlying: Boolean,
        requestHeaders: Map<String, String>,
    ): Map<String, Any> {
        var target = URL(rawUrl)
        if (target.protocol != "https") throw IllegalArgumentException("Subscription URL must use HTTPS.")
        repeat(6) {
            val networkConnection = if (useUnderlying) {
                underlyingNetwork()?.openConnection(target)
            } else {
                null
            }
            val connection = (networkConnection ?: target.openConnection()) as HttpURLConnection
            connection.connectTimeout = 12_000
            connection.readTimeout = 20_000
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.setRequestProperty("Accept-Encoding", "identity")
            val safeHeaders = requestHeaders.filter { (name, value) ->
                name in SUBSCRIPTION_REQUEST_HEADERS &&
                    !name.contains('\r') && !name.contains('\n') &&
                    !value.contains('\r') && !value.contains('\n')
            }
            safeHeaders.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            connection.setRequestProperty("User-Agent", safeHeaders["User-Agent"] ?: "Connecso Client")
            connection.setRequestProperty("X-Device-OS", safeHeaders["X-Device-OS"] ?: "Android")
            connection.setRequestProperty("X-Ver-OS", safeHeaders["X-Ver-OS"] ?: Build.VERSION.RELEASE)
            connection.setRequestProperty(
                "X-Device-Model",
                safeHeaders["X-Device-Model"] ?: "${Build.MANUFACTURER} ${Build.MODEL}".trim(),
            )
            connection.requestMethod = "GET"
            try {
                val code = connection.responseCode
                if (code in 300..399) {
                    val location = connection.getHeaderField("Location")
                        ?: throw IllegalStateException("Subscription redirect has no location.")
                    target = URL(target, location)
                    if (target.protocol != "https") {
                        throw IllegalStateException("Subscription redirects must remain on HTTPS.")
                    }
                    return@repeat
                }
                if (code !in 200..299) {
                    throw IllegalStateException("Subscription server returned $code.")
                }
                val length = connection.contentLengthLong
                if (length > 5L * 1024L * 1024L) {
                    throw IllegalStateException("Subscription response exceeds the 5 MiB limit.")
                }
                val output = ByteArrayOutputStream()
                connection.inputStream.use { input ->
                    val buffer = ByteArray(16 * 1024)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        output.write(buffer, 0, count)
                        if (output.size() > 5 * 1024 * 1024) {
                            throw IllegalStateException("Subscription response exceeds the 5 MiB limit.")
                        }
                    }
                }
                val headers = connection.headerFields
                    .filterKeys { it != null }
                    .mapKeys { it.key!!.lowercase() }
                    .mapValues { it.value.joinToString(";") }
                return mapOf(
                    "bodyBase64" to android.util.Base64.encodeToString(
                        output.toByteArray(),
                        android.util.Base64.NO_WRAP,
                    ),
                    "headers" to headers,
                )
            } finally {
                connection.disconnect()
            }
        }
        throw IllegalStateException("Too many subscription redirects.")
    }

    private fun isSafeUpdateName(name: String): Boolean =
        name.endsWith(".apk", ignoreCase = true) &&
            !name.contains("..") && !name.contains('/') && !name.contains('\\')

    private fun updateDirectory(): File {
        val base = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS) ?: filesDir
        return File(base, "Update Downloads").apply { mkdirs() }
    }

    private fun startAndroidUpdateDownload(
        id: String,
        rawUrl: String,
        name: String,
        expectedSize: Long,
        useActiveRoute: Boolean,
        result: MethodChannel.Result,
    ) {
        val transfer = AndroidUpdateTransfer(id, result)
        if (updateTransfers.putIfAbsent(id, transfer) != null) {
            result.error("UPDATE_IN_PROGRESS", "This update download is already running.", null)
            return
        }
        ioExecutor.execute {
            val output = File(updateDirectory(), name)
            try {
                if (expectedSize > 0 && output.exists() && output.length() >= expectedSize) {
                    output.delete()
                }
                var complete = false
                while (!complete) {
                    if (transfer.cancelled || transfer.closed) break
                    while (transfer.paused && !transfer.cancelled && !transfer.closed) {
                        Thread.sleep(100)
                    }
                    if (transfer.cancelled || transfer.closed) break

                    val target = URL(rawUrl)
                    val connection = (if (!useActiveRoute) {
                        underlyingNetwork()?.openConnection(target)
                    } else {
                        null
                    } ?: target.openConnection()) as HttpURLConnection
                    transfer.connection = connection
                    connection.connectTimeout = 15_000
                    connection.readTimeout = 20_000
                    connection.instanceFollowRedirects = true
                    connection.useCaches = false
                    connection.setRequestProperty("User-Agent", "Connecso Android")
                    connection.setRequestProperty("Accept-Encoding", "identity")
                    val previousLength = if (output.exists()) output.length() else 0L
                    if (previousLength > 0) {
                        connection.setRequestProperty("Range", "bytes=$previousLength-")
                    }
                    try {
                        val status = connection.responseCode
                        if (status !in 200..299) {
                            throw IllegalStateException("GitHub download returned HTTP $status.")
                        }
                        val append = previousLength > 0 && status == 206
                        val baseBytes = if (append) previousLength else 0L
                        val totalBytes = baseBytes + connection.contentLengthLong.coerceAtLeast(0L)
                        if (!append && previousLength > 0) output.delete()
                        var interrupted = false
                        connection.inputStream.use { input ->
                            FileOutputStream(output, append).use { sink ->
                                val buffer = ByteArray(64 * 1024)
                                while (true) {
                                    if (transfer.cancelled || transfer.closed || transfer.paused) {
                                        interrupted = true
                                        break
                                    }
                                    val count = try {
                                        input.read(buffer)
                                    } catch (error: Exception) {
                                        if (transfer.cancelled || transfer.closed || transfer.paused) {
                                            interrupted = true
                                            break
                                        }
                                        throw error
                                    }
                                    if (count < 0) break
                                    sink.write(buffer, 0, count)
                                    val received = sink.channel.position()
                                    runOnUiThread {
                                        channel.invokeMethod(
                                            "androidUpdateProgress",
                                            mapOf(
                                                "id" to id,
                                                "receivedBytes" to received,
                                                "totalBytes" to totalBytes,
                                                "state" to when {
                                                    transfer.paused -> "paused"
                                                    else -> "downloading"
                                                },
                                            ),
                                        )
                                    }
                                }
                            }
                        }
                        if (transfer.cancelled || transfer.closed) break
                        if (transfer.paused || interrupted) continue
                        complete = true
                    } finally {
                        transfer.connection = null
                        connection.disconnect()
                    }
                }

                if (transfer.cancelled) {
                    output.delete()
                    runOnUiThread { result.success(mapOf("status" to "cancelled")) }
                } else if (transfer.closed) {
                    runOnUiThread {
                        result.success(mapOf("status" to "closed", "path" to output.absolutePath))
                    }
                } else {
                    runOnUiThread {
                        result.success(mapOf("status" to "completed", "path" to output.absolutePath))
                    }
                }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("UPDATE_DOWNLOAD_FAILED", error.message ?: "APK download failed.", null)
                }
            } finally {
                updateTransfers.remove(id)
            }
        }
    }

    private fun openAndroidUpdate(file: File, result: MethodChannel.Result) {
        try {
            val expectedDirectory = updateDirectory().canonicalFile
            val canonicalFile = file.canonicalFile
            if (!canonicalFile.path.startsWith(expectedDirectory.path + File.separator) ||
                !canonicalFile.exists() || !canonicalFile.name.endsWith(".apk", ignoreCase = true)) {
                result.error("INVALID_UPDATE_PATH", "The downloaded APK could not be found.", null)
                return
            }
            val uri = Uri.parse(
                "content://$packageName.fileprovider/update/${Uri.encode(canonicalFile.name)}",
            )
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            result.success(null)
        } catch (error: Exception) {
            result.error("UPDATE_INSTALL_FAILED", error.message ?: "Could not open the Android package installer.", null)
        }
    }

    private fun underlyingNetwork(): Network? {
        val manager = getSystemService(ConnectivityManager::class.java) ?: return null
        return manager.allNetworks.firstOrNull { network ->
            val capabilities = manager.getNetworkCapabilities(network) ?: return@firstOrNull false
            capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
    }

    private fun registerVpnReceiver() {
        if (vpnReceiverRegistered) return
        val filter = IntentFilter(ConnecsoVpnService.ACTION_RESULT)
        if (Build.VERSION.SDK_INT >= 33) {
            registerReceiver(vpnReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("DEPRECATION")
            registerReceiver(vpnReceiver, filter)
        }
        vpnReceiverRegistered = true
    }

    private fun sendVpnCommand(
        serviceClass: Class<out VpnService>,
        action: String,
        operation: String,
        result: MethodChannel.Result,
        extras: Map<String, Any> = emptyMap(),
        foreground: Boolean = false,
    ) {
        val requestId = UUID.randomUUID().toString()
        pendingRequests[requestId] = PendingRequest(operation, result)
        val intent = Intent(this, serviceClass)
            .setAction(action)
            .putExtra(ConnecsoVpnService.EXTRA_REQUEST_ID, requestId)
        extras.forEach { (key, value) ->
            when (value) {
                is String -> intent.putExtra(key, value)
                is ArrayList<*> -> intent.putStringArrayListExtra(key, ArrayList(value.filterIsInstance<String>()))
            }
        }
        try {
            if (foreground && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                startForegroundService(intent)
            } else {
                startService(intent)
            }
        } catch (_: Exception) {
            pendingRequests.remove(requestId)
            result.error("VPN_SERVICE_UNAVAILABLE", "Android VPN service could not be started.", null)
        }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val intent = VpnService.prepare(this)
        if (intent == null) {
            Log.i("CONNECSO_CONNECT_TRACE", "vpn_permission already_granted=true")
            result.success(true)
            return
        }
        if (pendingVpnPermission != null) {
            Log.w("CONNECSO_CONNECT_TRACE", "vpn_permission request_already_in_progress=true")
            result.error("PERMISSION_IN_PROGRESS", "VPN permission is already being requested.", null)
            return
        }
        Log.i("CONNECSO_CONNECT_TRACE", "vpn_permission prompt_started=true")
        pendingVpnPermission = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, VPN_PERMISSION_REQUEST)
    }

    @Deprecated("Deprecated in Android, retained for FlutterActivity VPN consent result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
            Log.i(
                "CONNECSO_CONNECT_TRACE",
                "vpn_permission prompt_result_granted=${resultCode == RESULT_OK}",
            )
            pendingVpnPermission?.success(resultCode == RESULT_OK)
            pendingVpnPermission = null
        }
    }

    private fun installedApplications(): List<Map<String, Any>> =
        packageManager.getInstalledApplications(PackageManager.GET_META_DATA)
            .asSequence()
            .filter {
                it.packageName != packageName &&
                    packageManager.getLaunchIntentForPackage(it.packageName) != null
            }
            .map { app ->
                mapOf(
                    "packageName" to app.packageName,
                    "label" to packageManager.getApplicationLabel(app).toString(),
                    "isSystemApp" to (
                        (app.flags and android.content.pm.ApplicationInfo.FLAG_SYSTEM) != 0 &&
                            app.packageName != "com.android.vending" &&
                            !app.packageName.startsWith("com.google.")
                        ),
                )
            }
            .sortedBy { it["label"].toString().lowercase() }
            .toList()

    private fun applicationIcon(packageName: String): ByteArray? = runCatching {
        val lastUpdated = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            packageManager.getPackageInfo(
                packageName,
                PackageManager.PackageInfoFlags.of(0),
            ).lastUpdateTime
        } else {
            @Suppress("DEPRECATION")
            packageManager.getPackageInfo(packageName, 0).lastUpdateTime
        }
        val cacheKey = "$packageName:$lastUpdated"
        val cacheName = MessageDigest.getInstance("SHA-256")
            .digest(cacheKey.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte -> "%02x".format(byte) } + ".png"
        val iconCacheDir = File(filesDir, "split_tunnel_icon_cache")
        val cachedIcon = File(iconCacheDir, cacheName)
        if (cachedIcon.isFile && cachedIcon.length() > 0L) {
            return@runCatching cachedIcon.readBytes()
        }

        val drawable = packageManager.getApplicationIcon(packageName)
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        val iconBytes = ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
            output.toByteArray()
        }
        if (iconBytes.isNotEmpty()) {
            iconCacheDir.mkdirs()
            val temporary = File(iconCacheDir, "$cacheName.tmp")
            temporary.writeBytes(iconBytes)
            if (!temporary.renameTo(cachedIcon)) {
                temporary.delete()
            }
        }
        iconBytes
    }.getOrNull()

    companion object {
        private const val VPN_PERMISSION_REQUEST = 4817
        private const val NOTIFICATION_PERMISSION_REQUEST = 4818
        private val SUBSCRIPTION_REQUEST_HEADERS = setOf(
            "User-Agent",
            "X-HWID",
            "X-Device-OS",
            "X-Ver-OS",
            "X-Device-Model",
        )
    }
}
