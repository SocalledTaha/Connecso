package com.connecso.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.net.ConnectivityManager
import android.net.Network
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.net.TrafficStats
import android.os.SystemClock
import android.util.Log
import java.io.File
import libXray.DialerController
import libXray.LibXray
import hev.htproxy.TProxyService
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.URL
import java.util.concurrent.Executors

/**
 * Owns Android's TUN descriptor, HEV tun2socks, and the pinned Xray runtime.
 * This service runs in :vpn_xray to isolate the native Go runtime.
 */
class ConnecsoVpnService : VpnService(), DialerController {
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var tun: ParcelFileDescriptor? = null
    @Volatile private var coreStarted = false
    @Volatile private var activeXrayConfig: String? = null
    @Volatile private var hevStarted = false
    @Volatile private var dnsConfigured = false
    @Volatile private var trafficUploadBaseline = TrafficStats.UNSUPPORTED.toLong()
    @Volatile private var trafficDownloadBaseline = TrafficStats.UNSUPPORTED.toLong()
    @Volatile private var hevUploadBaseline = 0L
    @Volatile private var hevDownloadBaseline = 0L
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var availableNetwork: Network? = null

    override fun onCreate() {
        super.onCreate()
        connectivityManager = getSystemService(ConnectivityManager::class.java)
        registerNetworkCallback()
    }

    override fun onBind(intent: Intent?): IBinder? = super.onBind(intent)

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        val action = intent.action
        val requestId = intent.getStringExtra(EXTRA_REQUEST_ID).orEmpty()
        when (action) {
            ACTION_START -> {
                enterForeground()
                worker.execute { startVpn(intent, requestId) }
            }
            ACTION_PROBE -> worker.execute {
                val config = intent?.getStringExtra(EXTRA_CONFIG)
                val measurement = runCatching {
                    if (config == null) ProbeMeasurement(false, -1L) else probeNode(config)
                }.getOrDefault(ProbeMeasurement(false, -1L))
                sendResult(
                    requestId,
                    OP_PROBE,
                    success = measurement.success,
                    latencyMs = measurement.latencyMs,
                )
                if (!coreStarted) stopSelf(startId)
            }
            ACTION_VERIFY -> worker.execute {
                val usable = runCatching { verifyUsableConnectivity() }.getOrDefault(false)
                sendResult(requestId, OP_VERIFY, success = usable)
                if (!coreStarted) stopSelf(startId)
            }
            ACTION_STATS -> worker.execute {
                val stats = readStats()
                sendResult(
                    requestId,
                    OP_STATS,
                    success = coreStarted && hevStarted && stats != null,
                    uploadBytes = stats?.first,
                    downloadBytes = stats?.second,
                )
                if (!coreStarted) stopSelf(startId)
            }
            ACTION_STOP -> worker.execute {
                runCatching { QuickTileStore.setActive(this, false) }
                stopCore()
                stopForeground(STOP_FOREGROUND_REMOVE)
                sendResult(requestId, OP_STOP, success = true)
                stopSelf(startId)
            }
            else -> stopSelf(startId)
        }
        return if (action == ACTION_START) START_REDELIVER_INTENT else START_NOT_STICKY
    }

    override fun protectFd(fd: Long): Boolean = protect(fd.toInt())

    override fun onRevoke() {
        worker.execute {
            stopCore()
            runCatching { QuickTileStore.setActive(this, false) }
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    override fun onDestroy() {
        networkCallback?.let { callback ->
            runCatching { connectivityManager?.unregisterNetworkCallback(callback) }
        }
        networkCallback = null
        stopCore()
        runCatching { QuickTileStore.setActive(this, false) }
        worker.shutdown()
        super.onDestroy()
    }

    private fun registerNetworkCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || networkCallback != null) return
        val manager = connectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                availableNetwork = network
                if (tun != null) runCatching { setUnderlyingNetworks(arrayOf(network)) }
                Log.i(TAG, "event=underlying_network_available")
            }

            override fun onLost(network: Network) {
                if (availableNetwork == network) availableNetwork = null
                if (tun != null) runCatching {
                    setUnderlyingNetworks(availableNetwork?.let { arrayOf(it) })
                }
                Log.i(TAG, "event=underlying_network_lost")
            }
        }
        runCatching {
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        }.onFailure {
            Log.w(TAG, "event=network_callback_registration_failed")
        }
    }

    private fun startVpn(intent: Intent, requestId: String) {
        if (coreStarted) {
            stopCore()
        }
        try {
            val configText = intent.getStringExtra(EXTRA_CONFIG)
                ?: throw IllegalArgumentException("Xray configuration is missing.")
            val nodeId = intent.getStringExtra(EXTRA_NODE_ID)
                ?: throw IllegalArgumentException("Active VPN node is missing.")
            val requestedMode = intent.getStringExtra(EXTRA_SPLIT_MODE) ?: SPLIT_EXCLUDE
            val mode = if (requestedMode == SPLIT_OFF) SPLIT_EXCLUDE else requestedMode
            val selectedPackages = if (requestedMode == SPLIT_OFF) emptyList()
                else intent.getStringArrayListExtra(EXTRA_SPLIT_PACKAGES).orEmpty()

            runCatching {
                QuickTileStore.saveConfiguration(
                    this,
                    configText,
                    requestedMode,
                    selectedPackages,
                    nodeId,
                )
            }.onFailure {
                Log.w(TAG, "event=quick_tile_profile_save_failed")
            }
            runCatching { QuickTileStore.setActive(this, true) }

            val builder = Builder()
                .setSession("CONNECSO")
                .setMtu(1500)
                .addAddress("10.111.0.1", 30)
                .addDnsServer(DNS_SERVER)
                .addRoute("0.0.0.0", 0)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            if (mode == SPLIT_INCLUDE) {
                // Keep CONNECSO itself inside the tunnel so the UI can verify
                // the actual VPN data path after the TUN is established.
                (selectedPackages + packageName).toSet().forEach(builder::addAllowedApplication)
            } else {
                selectedPackages.filterNot { it == packageName }
                    .forEach(builder::addDisallowedApplication)
            }

            val descriptor = builder.establish()
                ?: throw IllegalStateException("Android did not establish the VPN interface.")
            tun = descriptor
            runCatching {
                setUnderlyingNetworks(availableNetwork?.let { arrayOf(it) })
            }

            LibXray.registerDialerController(this)
            LibXray.setDNS(this, DNS_ENDPOINT)
            dnsConfigured = true

            invoke("runXray", JSONObject().put("xrayJson", configText))
            coreStarted = true
            activeXrayConfig = configText
            trafficUploadBaseline = TrafficStats.getUidTxBytes(Process.myUid())
            trafficDownloadBaseline = TrafficStats.getUidRxBytes(Process.myUid())

            var ready = false
            for (attempt in 0 until 40) {
                if (xrayRunning()) {
                    ready = true
                    break
                }
                Thread.sleep(250)
            }
            if (!ready) throw IllegalStateException("Xray did not enter its running state.")
            Log.i(TAG, "event=xray.started")

            val hevConfig = File(filesDir, HEV_CONFIG_FILE)
            hevConfig.writeText(HEV_CONFIG)
            if (!TProxyService.TProxyStartService(hevConfig.absolutePath, descriptor.fd)) {
                throw IllegalStateException("HEV tunnel could not start.")
            }
            hevStarted = true
            var tunnelReady = false
            for (attempt in 0 until 20) {
                if (!TProxyService.TProxyIsRunning()) break
                if (attempt >= 2) {
                    tunnelReady = true
                    break
                }
                Thread.sleep(100)
            }
            if (!tunnelReady) throw IllegalStateException("HEV tunnel stopped during startup.")
            val initialStats = TProxyService.TProxyGetStats()
            if (initialStats.size >= 4) {
                hevUploadBaseline = initialStats[1].coerceAtLeast(0)
                hevDownloadBaseline = initialStats[3].coerceAtLeast(0)
            }
            Log.i(TAG, "event=hev.tunnel_started")
            runCatching { QuickTileStore.setActive(this, true) }
            sendResult(requestId, OP_START, success = true)
        } catch (error: Exception) {
            stopCore()
            runCatching { QuickTileStore.setActive(this, false) }
            stopForeground(STOP_FOREGROUND_REMOVE)
            Log.w(TAG, "event=vpn.start_failed failureType=${error.javaClass.simpleName}")
            sendResult(requestId, OP_START, success = false, error = "VPN tunnel could not start.")
            stopSelf()
        }
    }

    private fun verifyUsableConnectivity(): Boolean {
        if (!coreStarted || !hevStarted || !xrayRunning() || !TProxyService.TProxyIsRunning()) return false
        val probes = listOf(
            "https://cp.cloudflare.com/",
            "https://connectivitycheck.gstatic.com/generate_204",
        )
        for (probe in probes) {
            var connection: HttpURLConnection? = null
            try {
                connection = URL(probe).openConnection() as HttpURLConnection
                connection.connectTimeout = 5_000
                connection.readTimeout = 5_000
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.requestMethod = "GET"
                if (connection.responseCode in 200..299) return true
            } catch (_: Exception) {
                // A second independent HTTPS endpoint is tried below.
            } finally {
                connection?.disconnect()
            }
        }
        return false
    }

    private data class ProbeMeasurement(val success: Boolean, val latencyMs: Long)

    private fun probeNode(config: String): ProbeMeasurement {
        if (coreStarted) {
            if (config != activeXrayConfig || !xrayRunning()) {
                return ProbeMeasurement(false, -1L)
            }
            return measureActiveProxy()
        }
        val item = JSONObject()
            .put("xrayJson", config)
            .put("outboundTag", PROXY_TAG)
        val payload = JSONObject()
            .put("configs", JSONArray().put(item))
            .put("timeout", 8)
            .put("url", PING_URL)
        val results = invoke("pingBatch", payload)
            .optJSONObject("data")
            ?.optJSONArray("results")
        val result = results?.optJSONObject(0) ?: return ProbeMeasurement(false, -1L)
        val success = result.optBoolean("success")
        val delay = result.optLong("delay", -1L)
        return ProbeMeasurement(success && delay >= 0 && delay < 10_000, delay)
    }

    /** Measures only the Google HTTP response time through the active Xray SOCKS inbound. */
    private fun measureActiveProxy(): ProbeMeasurement {
        var connection: HttpURLConnection? = null
        val startedAt = SystemClock.elapsedRealtime()
        return try {
            val socksProxy = Proxy(
                Proxy.Type.SOCKS,
                InetSocketAddress("127.0.0.1", SOCKS_PORT),
            )
            connection = URL(PING_URL).openConnection(socksProxy) as HttpURLConnection
            connection.connectTimeout = PING_TIMEOUT_MS
            connection.readTimeout = PING_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.useCaches = false
            connection.requestMethod = "HEAD"
            connection.setRequestProperty("Connection", "close")
            val response = connection.responseCode
            val elapsed = SystemClock.elapsedRealtime() - startedAt
            ProbeMeasurement(response > 0, elapsed)
        } catch (_: Exception) {
            ProbeMeasurement(false, -1L)
        } finally {
            connection?.disconnect()
        }
    }

    private fun xrayRunning(): Boolean = runCatching {
        invoke("getXrayState")
            .optJSONObject("data")
            ?.optBoolean("running") == true
    }.getOrDefault(false)

    private fun readStats(): Pair<Long, Long>? {
        if (!coreStarted) return null
        val nativeStats = readXrayStats()
        if (nativeStats != null) return nativeStats
        val tunnelStats = runCatching { TProxyService.TProxyGetStats() }.getOrNull()
        if (tunnelStats != null && tunnelStats.size >= 4) {
            return (tunnelStats[1] - hevUploadBaseline).coerceAtLeast(0) to
                (tunnelStats[3] - hevDownloadBaseline).coerceAtLeast(0)
        }
        val upload = TrafficStats.getUidTxBytes(Process.myUid())
        val download = TrafficStats.getUidRxBytes(Process.myUid())
        if (trafficUploadBaseline < 0 || trafficDownloadBaseline < 0 || upload < 0 || download < 0) return null
        return (upload - trafficUploadBaseline).coerceAtLeast(0) to
            (download - trafficDownloadBaseline).coerceAtLeast(0)
    }

    private fun readXrayStats(): Pair<Long, Long>? {
        var connection: HttpURLConnection? = null
        return try {
            connection = URL("http://127.0.0.1:$METRICS_PORT/debug/vars")
                .openConnection() as HttpURLConnection
            connection.connectTimeout = 1_000
            connection.readTimeout = 1_000
            val metrics = JSONObject(connection.inputStream.bufferedReader().use { it.readText() })
            val stats = metrics.optJSONObject("stats") ?: return null
            val upload = stats.optLong("inbound>>>$SOCKS_TAG>>>traffic>>>uplink", -1L)
            val download = stats.optLong("inbound>>>$SOCKS_TAG>>>traffic>>>downlink", -1L)
            if (upload < 0 || download < 0) null else upload to download
        } catch (_: Exception) {
            null
        } finally {
            connection?.disconnect()
        }
    }

    private fun stopCore() {
        if (hevStarted || runCatching { TProxyService.TProxyIsRunning() }.getOrDefault(false)) {
            runCatching { TProxyService.TProxyStopService() }
            hevStarted = false
            Log.i(TAG, "event=hev.tunnel_stopped")
        }
        if (coreStarted) {
            runCatching { invoke("stopXray") }
            coreStarted = false
        }
        activeXrayConfig = null
        if (dnsConfigured) {
            runCatching { LibXray.resetDNS() }
            dnsConfigured = false
        }
        runCatching { tun?.close() }
        tun = null
        runCatching { File(filesDir, HEV_CONFIG_FILE).delete() }
    }

    private fun invoke(method: String, payload: JSONObject = JSONObject()): JSONObject {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", method)
            .put("payload", payload)
        val response = JSONObject(LibXray.invoke(request.toString()))
        if (!response.optBoolean("success")) {
            throw IllegalStateException("Pinned Xray runtime request failed.")
        }
        return response
    }

    private fun enterForeground() {
        val manager = getSystemService(Service.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "VPN connection", NotificationManager.IMPORTANCE_LOW),
            )
        }
        val notification = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("CONNECSO")
            .setContentText("VPN connection is active")
            .setOngoing(true)
            .build()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun sendResult(
        requestId: String,
        operation: String,
        success: Boolean,
        error: String? = null,
        uploadBytes: Long? = null,
        downloadBytes: Long? = null,
        latencyMs: Long? = null,
    ) {
        val result = Intent(ACTION_RESULT)
            .setPackage(packageName)
            .putExtra(EXTRA_REQUEST_ID, requestId)
            .putExtra(EXTRA_OPERATION, operation)
            .putExtra(EXTRA_SUCCESS, success)
        if (error != null) result.putExtra(EXTRA_ERROR, error)
        if (uploadBytes != null) result.putExtra(EXTRA_UPLOAD_BYTES, uploadBytes)
        if (downloadBytes != null) result.putExtra(EXTRA_DOWNLOAD_BYTES, downloadBytes)
        if (latencyMs != null) result.putExtra(EXTRA_LATENCY_MS, latencyMs)
        sendBroadcast(result)
    }

    companion object {
        private const val TAG = "CONNECSO/VPN"
        const val ACTION_RESULT = "com.connecso.client.VPN_RESULT"
        const val ACTION_START = "com.connecso.client.VPN_START"
        const val ACTION_PROBE = "com.connecso.client.VPN_PROBE"
        const val ACTION_VERIFY = "com.connecso.client.VPN_VERIFY"
        const val ACTION_STATS = "com.connecso.client.VPN_STATS"
        const val ACTION_STOP = "com.connecso.client.VPN_STOP"

        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_NODE_ID = "nodeId"
        const val EXTRA_SPLIT_MODE = "splitTunnelMode"
        const val EXTRA_SPLIT_PACKAGES = "splitTunnelPackages"
        const val EXTRA_OPERATION = "operation"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"
        const val EXTRA_UPLOAD_BYTES = "uploadBytes"
        const val EXTRA_DOWNLOAD_BYTES = "downloadBytes"
        const val EXTRA_LATENCY_MS = "latencyMs"

        const val OP_START = "start"
        const val OP_PROBE = "probe"
        const val OP_VERIFY = "verify"
        const val OP_STATS = "stats"
        const val OP_STOP = "stop"

        private const val API_VERSION = 3
        private const val PROXY_TAG = "connecso-proxy"
        private const val SOCKS_TAG = "connecso-socks"
        private const val SOCKS_PORT = 10808
        private const val PING_URL = "https://www.google.com/generate_204"
        private const val PING_TIMEOUT_MS = 8_000
        private const val HEV_CONFIG_FILE = "connecso-hev.yml"
        private const val HEV_CONFIG = """
tunnel:
  name: connecso0
  mtu: 1500
  multi-queue: false
  ipv4: 10.111.0.1
  icmp: 'off'
socks5:
  address: 127.0.0.1
  port: 10808
  udp: 'udp'
"""
        private const val METRICS_PORT = 49227
        private const val DNS_SERVER = "1.1.1.1"
        private const val DNS_ENDPOINT = "$DNS_SERVER:53"
        private const val SPLIT_INCLUDE = "includeSelected"
        private const val SPLIT_EXCLUDE = "excludeSelected"
        private const val SPLIT_OFF = "off"
        private const val CHANNEL_ID = "connecso_vpn"
        private const val NOTIFICATION_ID = 6401
    }
}
