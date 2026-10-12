package com.connecso.client

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

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var pendingVpnPermission: MethodChannel.Result? = null
    private val pendingRequests = mutableMapOf<String, PendingRequest>()
    private val ioExecutor = Executors.newCachedThreadPool()
    private var vpnReceiverRegistered = false

    private val vpnReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != ConnecsoVpnService.ACTION_RESULT) return
            val requestId = intent.getStringExtra(ConnecsoVpnService.EXTRA_REQUEST_ID) ?: return
            val success = intent.getBooleanExtra(ConnecsoVpnService.EXTRA_SUCCESS, false)
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
                "coreAvailable" -> result.success(true)
                "quickTileConnection" -> result.success(QuickTileStore.readConnection(this))
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
                    if (rawUrl.isNullOrBlank()) {
                        result.error("INVALID_URL", "A subscription URL is required.", null)
                    } else {
                        ioExecutor.execute {
                            try {
                                val payload = fetchDirectSubscription(rawUrl, useUnderlying = true)
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
                    if (rawUrl.isNullOrBlank()) {
                        result.error("INVALID_URL", "A subscription URL is required.", null)
                    } else {
                        ioExecutor.execute {
                            try {
                                val payload = fetchDirectSubscription(rawUrl, useUnderlying = false)
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
                        result.success(applicationIcon(packageName))
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
            result.success(true)
            return
        }
        if (pendingVpnPermission != null) {
            result.error("PERMISSION_IN_PROGRESS", "VPN permission is already being requested.", null)
            return
        }
        pendingVpnPermission = result
        @Suppress("DEPRECATION")
        startActivityForResult(intent, VPN_PERMISSION_REQUEST)
    }

    @Deprecated("Deprecated in Android, retained for FlutterActivity VPN consent result compatibility")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_PERMISSION_REQUEST) {
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
        val drawable = packageManager.getApplicationIcon(packageName)
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, size, size)
        drawable.draw(canvas)
        java.io.ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }.getOrNull()

    companion object {
        private const val VPN_PERMISSION_REQUEST = 4817
    }
}
