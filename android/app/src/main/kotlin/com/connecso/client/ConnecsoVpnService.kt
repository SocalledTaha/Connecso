package com.connecso.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.widget.RemoteViews
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.os.SystemClock
import android.util.Log
import com.connecso.client.tunnel.ContunTunnelEngine
import com.connecso.client.tunnel.DataplaneState
import com.connecso.client.tunnel.HevTunnelEngine
import com.connecso.client.tunnel.TunnelEngineChoice
import com.connecso.client.tunnel.TunnelEngineConfig
import com.connecso.client.tunnel.TunnelEngineManager
import com.connecso.client.tunnel.VpnDataplaneConfig
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import java.util.concurrent.Executors
import java.util.concurrent.Callable
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Owns Android's TUN descriptor, HEV tun2socks, and the pinned Xray runtime.
 * This service runs in :vpn_xray to isolate the native Go runtime.
 */
class ConnecsoVpnService : VpnService(), DialerController {
    private val worker = Executors.newSingleThreadExecutor()
    // Disconnect must not wait behind a queued probe/health verification.
    private val stopWorker = Executors.newSingleThreadExecutor()
    private val notificationWorker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val pingWorker: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()
    private val speedTestWorker = Executors.newSingleThreadExecutor()
    private val speedTestInProgress = AtomicBoolean(false)
    @Volatile private var notificationRefresh: ScheduledFuture<*>? = null
    @Volatile private var periodicPing: ScheduledFuture<*>? = null
    @Volatile private var tun: ParcelFileDescriptor? = null
    @Volatile private var coreStarted = false
    @Volatile private var activeXrayConfig: String? = null
    @Volatile private var dnsConfigured = false
    @Volatile private var dataplaneState = DataplaneState.IDLE
    private lateinit var tunnelEngineManager: TunnelEngineManager
    private var activeTunnelConfig: TunnelEngineConfig? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var availableNetwork: Network? = null
    @Volatile private var notificationCountryName = ""
    @Volatile private var notificationCountryCode = ""
    @Volatile private var notificationNodeId = ""
    @Volatile private var notificationPing = -1L
    @Volatile private var lastNotificationUpload = -1L
    @Volatile private var lastNotificationDownload = -1L
    @Volatile private var notificationUploadRate = 0L
    @Volatile private var notificationDownloadRate = 0L
    @Volatile private var pingInProgress = false

    override fun onCreate() {
        super.onCreate()
        tunnelEngineManager = TunnelEngineManager(
            contun = ContunTunnelEngine(),
            hev = HevTunnelEngine(filesDir),
        )
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
                notificationCountryName = intent.getStringExtra(EXTRA_COUNTRY_NAME).orEmpty()
                notificationCountryCode = intent.getStringExtra(EXTRA_COUNTRY_CODE).orEmpty()
                notificationNodeId = intent.getStringExtra(EXTRA_NODE_ID).orEmpty()
                notificationPing = -1L
                lastNotificationUpload = -1L
                lastNotificationDownload = -1L
                notificationUploadRate = 0L
                notificationDownloadRate = 0L
                periodicPing?.cancel(false)
                enterForeground()
                worker.execute { startVpn(intent, requestId) }
            }
            ACTION_NOTIFICATION_PING -> worker.execute {
                if (!pingInProgress) {
                    pingInProgress = true
                    try {
                        val startedAt = SystemClock.elapsedRealtime()
                        val result = if (coreStarted && tunnelEngineManager.isRunning()) {
                            measureActiveProxy(notificationNodeId, notificationCountryCode, startedAt)
                        } else ProbeMeasurement(false, -1L)
                        notificationPing = if (result.success) result.latencyMs else -1L
                        updateConnectionNotification()
                    } finally {
                        pingInProgress = false
                    }
                }
            }
            ACTION_PROBE -> worker.execute {
                val config = intent?.getStringExtra(EXTRA_CONFIG)
                val traceNodeId = intent?.getStringExtra(EXTRA_TRACE_NODE_ID) ?: "unknown"
                val traceCountry = intent?.getStringExtra(EXTRA_TRACE_COUNTRY) ?: "unknown"
                Log.i("CONNECSO_CONNECT_TRACE", "ping.probe_requested node=$traceNodeId country=$traceCountry")
                val measurement = runCatching {
                    if (config == null) ProbeMeasurement(false, -1L)
                    else probeNode(config, traceNodeId, traceCountry)
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
                    success = coreStarted && tunnelEngineManager.isRunning() && stats != null,
                    uploadBytes = stats?.first,
                    downloadBytes = stats?.second,
                )
                if (!coreStarted) stopSelf(startId)
            }
            ACTION_SPEED_TEST -> {
                if (!speedTestInProgress.compareAndSet(false, true)) {
                    sendResult(requestId, OP_SPEED_TEST, success = false, error = "A speed test is already running.")
                } else speedTestWorker.execute {
                    if (!coreStarted || !tunnelEngineManager.isRunning() || !xrayRunning()) {
                        sendResult(requestId, OP_SPEED_TEST, success = false, error = "The active Xray connection is not ready.")
                        speedTestInProgress.set(false)
                    } else {
                        try {
                            val measurement = performSpeedTest()
                            sendResult(
                                requestId,
                                OP_SPEED_TEST,
                                success = true,
                                speedMbps = measurement.first,
                                speedBytes = measurement.second,
                                speedSeconds = measurement.third,
                                speedConnections = SPEED_TEST_CONNECTIONS,
                            )
                        } catch (error: Exception) {
                            sendResult(requestId, OP_SPEED_TEST, success = false, error = error.message ?: "Speed test failed.")
                        } finally {
                            speedTestInProgress.set(false)
                        }
                    }
                }
            }
            ACTION_STOP -> stopWorker.execute {
                notificationRefresh?.cancel(false)
                notificationRefresh = null
                periodicPing?.cancel(false)
                periodicPing = null
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
        stopWorker.shutdownNow()
        notificationWorker.shutdownNow()
        pingWorker.shutdownNow()
        speedTestWorker.shutdownNow()
        super.onDestroy()
    }

    private fun registerNetworkCallback() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N || networkCallback != null) return
        val manager = connectivityManager ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                updatePhysicalUnderlyingNetwork()
                Log.i(TAG, "event=underlying_network_available")
            }

            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                updatePhysicalUnderlyingNetwork()
            }

            override fun onLost(network: Network) {
                if (availableNetwork == network) availableNetwork = null
                updatePhysicalUnderlyingNetwork(network)
                Log.i(TAG, "event=underlying_network_lost")
            }
        }
        runCatching {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            manager.registerNetworkCallback(request, callback)
            networkCallback = callback
            updatePhysicalUnderlyingNetwork()
        }.onFailure {
            Log.w(TAG, "event=network_callback_registration_failed")
        }
    }

    private fun updatePhysicalUnderlyingNetwork(lost: Network? = null) {
        val manager = connectivityManager ?: return
        fun physical(network: Network): Boolean {
            if (network == lost) return false
            val capabilities = manager.getNetworkCapabilities(network) ?: return false
            return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
                !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        }
        val active = manager.activeNetwork?.takeIf { physical(it) }
        val candidates = manager.allNetworks.filter { physical(it) }
        val selected = active ?: candidates.firstOrNull {
            manager.getNetworkCapabilities(it)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
        } ?: candidates.firstOrNull()
        availableNetwork = selected
        if (tun != null) {
            runCatching { setUnderlyingNetworks(selected?.let { arrayOf(it) }) }
                .onFailure { Log.w(TAG, "event=underlying_network_update_failed failureType=${it.javaClass.simpleName}") }
        }
        Log.i(TAG, "event=underlying_network_selected physical=${selected != null} network=${selected ?: "system-default"}")
    }

    private fun startVpn(intent: Intent, requestId: String) {
        try {
            val configText = intent.getStringExtra(EXTRA_CONFIG)
                ?: throw IllegalArgumentException("Xray configuration is missing.")
            val nodeId = intent.getStringExtra(EXTRA_NODE_ID)
                ?: throw IllegalArgumentException("Active VPN node is missing.")

            validateAndLogLocalInbound(configText)

            // Every endpoint, regardless of destination country or transport,
            // enters this one startup pipeline. A reconnect always releases
            // the previous engine and TUN before a new session is established.
            stopCore()
            val requestedMode = intent.getStringExtra(EXTRA_SPLIT_MODE) ?: SPLIT_OFF
            val mode = when (requestedMode) {
                SPLIT_INCLUDE -> SPLIT_INCLUDE
                SPLIT_EXCLUDE -> SPLIT_EXCLUDE
                else -> SPLIT_OFF
            }
            val selectedPackages = if (mode == SPLIT_OFF) emptyList()
                else intent.getStringArrayListExtra(EXTRA_SPLIT_PACKAGES).orEmpty()

            runCatching {
                QuickTileStore.saveConfiguration(
                    this,
                    configText,
                    mode,
                    selectedPackages,
                    nodeId,
                    notificationCountryName,
                    notificationCountryCode,
                )
            }.onFailure {
                Log.w(TAG, "event=quick_tile_profile_save_failed")
            }
            val builder = Builder()
                .setSession("CONNECSO")
                .setMtu(VpnDataplaneConfig.DEFAULT_MTU)
                .addAddress(VpnDataplaneConfig.IPV4_ADDRESS, VpnDataplaneConfig.IPV4_PREFIX)
                .addDnsServer(VpnDataplaneConfig.DNS_SERVER)
                .addRoute("0.0.0.0", 0)

            if (VpnDataplaneConfig.IPV6_ENABLED) {
                builder
                    .addAddress(VpnDataplaneConfig.IPV6_ADDRESS, VpnDataplaneConfig.IPV6_PREFIX)
                    .addRoute("::", 0)
            }

            Log.i(TAG, "VPN session starting")
            Log.i(TAG, "VPN MTU=${VpnDataplaneConfig.DEFAULT_MTU} ipv4=${VpnDataplaneConfig.IPV4_ADDRESS}/${VpnDataplaneConfig.IPV4_PREFIX} ipv6=${VpnDataplaneConfig.IPV6_ADDRESS}/${VpnDataplaneConfig.IPV6_PREFIX}")
            Log.i(TAG, "VPN routes ipv4=0.0.0.0/0 ipv6=${if (VpnDataplaneConfig.IPV6_ENABLED) "::/0" else "disabled"} dns=${VpnDataplaneConfig.DNS_SERVER}")

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                builder.setMetered(false)
            }

            val routedPackages = selectedPackages.filterNot { it == packageName }.distinct()
            Log.i(TAG, "VPN app routing mode=$mode selected=${routedPackages.size}")
            when (mode) {
                SPLIT_INCLUDE -> routedPackages.forEach { app ->
                    Log.i(TAG, "VPN allowed package=$app")
                    builder.addAllowedApplication(app)
                }
                SPLIT_EXCLUDE -> routedPackages.forEach { app ->
                    Log.i(TAG, "VPN excluded package=$app")
                    builder.addDisallowedApplication(app)
                }
            }

            dataplaneState = DataplaneState.XRAY_STARTING
            LibXray.registerDialerController(this)
            LibXray.setDNS(this, "${VpnDataplaneConfig.DNS_SERVER}:53")
            dnsConfigured = true

            invoke("runXray", JSONObject().put("xrayJson", configText))
            coreStarted = true
            activeXrayConfig = configText
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
            Log.i("CONNECSO_CONNECT_TRACE", "xray.started")

            if (!waitForLocalInbound()) {
                throw IllegalStateException("Xray local inbound did not become ready.")
            }
            dataplaneState = DataplaneState.XRAY_READY
            Log.i(TAG, "event=xray.local_inbound_ready host=$LOCAL_XRAY_HOST port=$LOCAL_XRAY_PORT protocol=socks")

            dataplaneState = DataplaneState.TUN_ESTABLISHING
            val descriptor = builder.establish()
                ?: throw IllegalStateException("Android did not establish the VPN interface.")
            tun = descriptor
            dataplaneState = DataplaneState.TUN_READY
            Log.i(TAG, "event=tun.interface_established fd=${descriptor.fd}")
            Log.i("CONNECSO_CONNECT_TRACE", "tun.interface_established")
            updatePhysicalUnderlyingNetwork()

            val engineConfig = TunnelEngineConfig(
                socksHost = VpnDataplaneConfig.XRAY_SOCKS_HOST,
                socksPort = VpnDataplaneConfig.XRAY_SOCKS_PORT,
                mtu = VpnDataplaneConfig.DEFAULT_MTU,
                ipv4 = VpnDataplaneConfig.IPV4_ADDRESS,
                ipv6 = VpnDataplaneConfig.IPV6_ADDRESS.takeIf { VpnDataplaneConfig.IPV6_ENABLED },
                udpEnabled = true,
                pipeline = true,
            )
            activeTunnelConfig = engineConfig
            val engineChoice = parseEngineChoice(intent.getStringExtra(EXTRA_TUNNEL_ENGINE))
            dataplaneState = DataplaneState.TUNNEL_ENGINE_STARTING
            if (!tunnelEngineManager.start(this, descriptor, engineConfig, engineChoice)) {
                throw IllegalStateException("No tunnel engine could start.")
            }
            dataplaneState = tunnelEngineManager.state
            Log.i(TAG, "event=tunnel.started engine=${tunnelEngineManager.activeName()} choice=$engineChoice stats=${tunnelEngineManager.stats()}")
            // Promote the foreground placeholder to the live notification as
            // soon as the tunnel engine is up. Full dataplane verification can
            // take several seconds and should not delay the user's controls.
            updateConnectionNotification()

            dataplaneState = DataplaneState.DATAPLANE_VERIFYING
            tunnelEngineManager.markVerifying()
            if (!verifyRealDataplane(engineChoice)) {
                throw IllegalStateException("Android dataplane did not carry traffic.")
            }
            dataplaneState = DataplaneState.CONNECTED
            tunnelEngineManager.markConnected()
            val ipv6State = if (VpnDataplaneConfig.IPV6_ENABLED) "CAPTURED" else "DISABLED"
            Log.i(TAG, "dataplane core=READY tun=READY engine=${tunnelEngineManager.activeName()} tcp=READY udp=ENABLED ipv6=$ipv6State dns=CONFIGURED")
            runCatching { QuickTileStore.setActive(this, true) }
            updateConnectionNotification()
            startNotificationRefresh()
            startPeriodicPing()
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
        if (!coreStarted || !tunnelEngineManager.isRunning() || !xrayRunning()) return false
        return verifyDirectTraffic()
    }

    private fun verifyRealDataplane(choice: TunnelEngineChoice): Boolean {
        // Startup readiness is deliberately structural. Google/YouTube are
        // application-level validation probes and must not block connection;
        // they are run by the post-connect health monitor instead.
        val ready = tun != null && coreStarted && xrayRunning() &&
            tunnelEngineManager.isRunning()
        Log.i(
            TAG,
            "event=dataplane.startup_ready ready=$ready engine=${tunnelEngineManager.activeName()} stats=${tunnelEngineManager.stats()}",
        )
        return ready
    }

    /**
     * Verifies the real device dataplane with independent Google and YouTube
     * HTTPS requests. A generic connectivity check is insufficient here:
     * several transports accepted Google's 204 while YouTube traffic was
     * still being closed by the selected outbound.
     */
    private fun verifyDirectTraffic(): Boolean {
        Log.i(TAG, "event=dataplane_verify_start engine=${tunnelEngineManager.activeName()} stats=${tunnelEngineManager.stats()}")
        val probes = listOf(
            // Keep these as real application endpoints. A generate_204 probe
            // can succeed while the app-facing Google/YouTube response is
            // still blocked or malformed by a transport profile.
            "google_search" to "https://www.google.com/search?q=connecso",
            "youtube_home" to "https://www.youtube.com/",
        )
        val executor = Executors.newFixedThreadPool(probes.size)
        val results = try {
            executor.invokeAll(probes.map { (label, probe) ->
                Callable { verifyTrafficProbe(label, probe) }
            }).map { future -> future.get() }
        } catch (error: Exception) {
            Log.w(TAG, "event=dataplane.probe_batch_failed failureType=${error.javaClass.simpleName}")
            emptyList()
        } finally {
            executor.shutdownNow()
        }
        val googleOk = results.any { it.first == "google_search" && it.second }
        val youtubeOk = results.any { it.first == "youtube_home" && it.second }
        val verified = googleOk && youtubeOk
        Log.i(TAG, "event=dataplane_verify_result google=$googleOk youtube=$youtubeOk verified=$verified engine=${tunnelEngineManager.activeName()} stats=${tunnelEngineManager.stats()}")
        if (verified) {
            Log.i(TAG, "event=dataplane_verify_success engine=${tunnelEngineManager.activeName()}")
        }
        return verified
    }

    private fun verifyTrafficProbe(label: String, probe: String): Pair<String, Boolean> {
            var connection: HttpURLConnection? = null
            try {
                // This request deliberately does not use the local SOCKS
                // proxy. It must enter Android's VPN route, cross the TUN and
                // active engine, then reach Xray's local SOCKS inbound.
                connection = URL(probe).openConnection() as HttpURLConnection
                connection.connectTimeout = 5_000
                connection.readTimeout = 5_000
                connection.instanceFollowRedirects = false
                connection.useCaches = false
                connection.requestMethod = "GET"
                if (connection.responseCode in 200..399) {
                    Log.i(TAG, "event=dataplane.probe_success target=$label url=$probe code=${connection.responseCode}")
                    Log.i("CONNECSO_CONNECT_TRACE", "outbound.probe_success target=$label code=${connection.responseCode}")
                    return label to true
                }
            } catch (error: Exception) {
                Log.w(TAG, "event=dataplane.probe_failed target=$label failureType=${error.javaClass.simpleName}")
            } finally {
                connection?.disconnect()
            }
        return label to false
    }

    private fun validateAndLogLocalInbound(configText: String) {
        val root = JSONObject(configText)
        val inbounds = root.optJSONArray("inbounds")
            ?: throw IllegalStateException("Xray local inbound list is missing.")
        var found = false
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(index) ?: continue
            val host = inbound.optString("listen", "")
            val port = inbound.optInt("port", -1)
            val protocol = inbound.optString("protocol", "")
            Log.i(TAG, "Xray inbound[$index] host=$host port=$port protocol=$protocol tag=${inbound.optString("tag", "")}")
            if (host == LOCAL_XRAY_HOST && port == LOCAL_XRAY_PORT && protocol == "socks") {
                found = true
            }
        }
        if (!found) {
            throw IllegalStateException("Xray local SOCKS inbound does not match HEV upstream.")
        }
        Log.i(TAG, "HEV/Xray bridge invariant host=$LOCAL_XRAY_HOST port=$LOCAL_XRAY_PORT protocol=socks")
    }

    private fun waitForLocalInbound(): Boolean {
        repeat(40) {
            try {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress(LOCAL_XRAY_HOST, LOCAL_XRAY_PORT), 250)
                }
                return true
            } catch (_: Exception) {
                Thread.sleep(100)
            }
        }
        return false
    }

    private data class ProbeMeasurement(val success: Boolean, val latencyMs: Long)

    /** Nodes for which the SOCKS/TLS keep-alive path has already been warmed. */
    private val warmProbeNodes = mutableSetOf<String>()
    private val warmProbeLock = Any()

    private fun probeNode(config: String, nodeId: String, country: String): ProbeMeasurement {
        val startedAt = SystemClock.elapsedRealtime()
        if (coreStarted && config == activeXrayConfig && xrayRunning()) {
            return measureActiveProxy(nodeId, country, startedAt)
        }
        val item = JSONObject()
            .put("xrayJson", config)
            .put("outboundTag", PROXY_TAG)
        val payload = JSONObject()
            .put("configs", JSONArray().put(item))
            // Keep the native probe bounded to the same user-facing budget as
            // EndpointResolver. A dead endpoint must not hold the next
            // country candidate for the old eight-second core timeout.
            .put("timeout", 3)
            .put("url", PING_URL)
        val results = invoke("pingBatch", payload)
            .optJSONObject("data")
            ?.optJSONArray("results")
        val result = results?.optJSONObject(0) ?: return ProbeMeasurement(false, -1L)
        val success = result.optBoolean("success")
        val delay = result.optLong("delay", -1L)
        val total = SystemClock.elapsedRealtime() - startedAt
        val reportedDelay = if (success && delay >= 0 && delay < 10_000) delay else -1L
        Log.i("CONNECSO_CONNECT_TRACE", "ping.raw_result node=$nodeId country=$country pingBatch=${reportedDelay}ms total=${total}ms dns=unknown tcp=unknown tls=unknown ttfb=unknown retries=unknown timeoutContribution=${if (reportedDelay < 0) total else 0}ms")
        // pingBatch is a cold setup measurement. It is valid for reachability
        // only and must never enter the authoritative warm-TTFB latency path.
        // For a non-active destination, pingBatch is the live RTT for that
        // node's own Xray outbound. The active destination uses the warmed
        // HTTP TTFB path above; never discard the result for other countries.
        return ProbeMeasurement(
            success && delay >= 0 && delay < 10_000,
            if (success && delay >= 0 && delay < 10_000) delay else -1L,
        )
    }

    /** Measures only the Google HTTP response time through the active Xray SOCKS inbound. */
    private fun measureActiveProxy(nodeId: String, country: String, startedAt: Long): ProbeMeasurement {
        val needsWarmup = synchronized(warmProbeLock) { warmProbeNodes.contains(nodeId).not() }
        if (needsWarmup) {
            val cold = measureHttpSample(nodeId, country, warmup = true)
            if (!cold.success) return cold
            synchronized(warmProbeLock) { warmProbeNodes.add(nodeId) }
        }
        val warm = measureHttpSample(nodeId, country, warmup = false)
        // A freshly resumed tunnel can produce one transiently slow warm
        // sample while the proxy socket pool settles. Keep the UI latency
        // representative of the hot path by retrying only that outlier and
        // selecting the faster successful warm result. Cold setup is never
        // exposed as the displayed ping.
        if (warm.success && warm.latencyMs >= 500L) {
            val retry = measureHttpSample(nodeId, country, warmup = false)
            if (retry.success && retry.latencyMs < warm.latencyMs) return retry
        }
        return warm
    }

    private fun measureHttpSample(nodeId: String, country: String, warmup: Boolean): ProbeMeasurement {
        var connection: HttpURLConnection? = null
        val startedAt = SystemClock.elapsedRealtime()
        return try {
            val socksProxy = Proxy(
                Proxy.Type.SOCKS,
                InetSocketAddress(LOCAL_XRAY_HOST, LOCAL_XRAY_PORT),
            )
            connection = URL(PING_URL).openConnection(socksProxy) as HttpURLConnection
            connection.connectTimeout = PING_TIMEOUT_MS
            connection.readTimeout = PING_TIMEOUT_MS
            connection.instanceFollowRedirects = false
            connection.useCaches = true
            connection.requestMethod = "HEAD"
            connection.setRequestProperty("Connection", "keep-alive")
            val response = connection.responseCode
            val firstByte = SystemClock.elapsedRealtime() - startedAt
            runCatching { connection.inputStream.use { it.read() } }
            val total = SystemClock.elapsedRealtime() - startedAt
            Log.i("CONNECSO_CONNECT_TRACE", "ping.raw_result node=$nodeId country=$country sample=${if (warmup) "cold" else "warm"} total=${total}ms ttfb=${firstByte}ms reused=${!warmup} nodePing=${if (warmup) "discarded" else firstByte}ms uiPing=pending")
            ProbeMeasurement(response in 200..499, firstByte)
        } catch (error: Exception) {
            Log.i("CONNECSO_CONNECT_TRACE", "ping.sample_failure node=$nodeId country=$country sample=${if (warmup) "cold" else "warm"} elapsed=${SystemClock.elapsedRealtime() - startedAt}ms reason=${error.javaClass.simpleName}")
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
        // Session usage must describe traffic that entered this tunnel's Xray
        // SOCKS inbound. Preserve the original v1 fallback order: when Xray's
        // metrics endpoint is unavailable, use HEV's TUN-interface byte
        // counters. Do not fall back to UID totals, which include unrelated
        // app/control traffic and inflated this value on some devices.
        readXrayStats()?.let { return it }
        val tunnelStats = tunnelEngineManager.stats()
        val contunActive = tunnelEngineManager.activeName() == "Contun"
        val upload = (if (contunActive) tunnelStats.rxBytes else tunnelStats.txBytes) ?: return null
        val download = (if (contunActive) tunnelStats.txBytes else tunnelStats.rxBytes) ?: return null
        return upload to download
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

    /** Runs downloads through the SOCKS inbound owned by this active Xray core. */
    private fun performSpeedTest(): Triple<Double, Long, Double> {
        val started = System.nanoTime()
        val durationMs = 8_000L
        val deadline = started + TimeUnit.MILLISECONDS.toNanos(durationMs)
        val totalBytes = AtomicLong()
        val bytesBySecond = ConcurrentHashMap<Long, AtomicLong>()
        val lastError = AtomicReference("No speed-test endpoint responded.")
        val unavailableEndpoints = ConcurrentHashMap.newKeySet<String>()
        val endpoints = listOf(
            "https://speed.cloudflare.com/__down?bytes=100000000",
            "https://speedtest.tele2.net/5MB.zip",
            "https://proof.ovh.net/files/10Mb.dat",
        )
        val workers = Executors.newFixedThreadPool(SPEED_TEST_CONNECTIONS)
        try {
            val tasks = (0 until SPEED_TEST_CONNECTIONS).map { lane ->
                Callable {
                    var requestNumber = lane
                    val proxy = Proxy(
                        Proxy.Type.SOCKS,
                        InetSocketAddress(LOCAL_XRAY_HOST, LOCAL_XRAY_PORT),
                    )
                    while (System.nanoTime() < deadline && coreStarted) {
                        val available = endpoints.filterNot(unavailableEndpoints::contains)
                        if (available.isEmpty()) break
                        val endpoint = available[requestNumber % available.size]
                        val cacheBuster = "${System.currentTimeMillis()}-$lane-$requestNumber"
                        val separator = if (endpoint.contains('?')) '&' else '?'
                        var connection: HttpURLConnection? = null
                        try {
                            connection = URL("$endpoint$separator" + "cacheBust=$cacheBuster")
                                .openConnection(proxy) as HttpURLConnection
                            connection.connectTimeout = 5_000
                            connection.readTimeout = 5_000
                            connection.instanceFollowRedirects = true
                            connection.useCaches = false
                            connection.setRequestProperty("Cache-Control", "no-cache")
                            connection.setRequestProperty("User-Agent", "Connecso-Mobile-Client")
                            val response = connection.responseCode
                            if (response !in 200..299) {
                                if (response == 403 || response == 429) unavailableEndpoints.add(endpoint)
                                lastError.set(
                                    if (response == 429) "Speed-test endpoint is rate-limiting requests."
                                    else "Speed-test server returned HTTP $response.",
                                )
                            } else {
                                val buffer = ByteArray(64 * 1024)
                                connection.inputStream.use { input ->
                                    while (System.nanoTime() < deadline && coreStarted) {
                                        val count = input.read(buffer)
                                        if (count < 0) break
                                        val bucket = TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - started)
                                        bytesBySecond.computeIfAbsent(bucket) { AtomicLong() }.addAndGet(count.toLong())
                                        totalBytes.addAndGet(count.toLong())
                                    }
                                }
                            }
                        } catch (error: Exception) {
                            lastError.set(error.message ?: "Speed-test request failed.")
                        } finally {
                            connection?.disconnect()
                        }
                        requestNumber += 1
                    }
                }
            }
            workers.invokeAll(tasks, durationMs + 2_000, TimeUnit.MILLISECONDS)
        } finally {
            workers.shutdownNow()
        }

        val elapsedSeconds = (System.nanoTime() - started) / 1_000_000_000.0
        val peakBytesPerSecond = bytesBySecond.values.maxOfOrNull { it.get() } ?: 0L
        if (totalBytes.get() <= 0L || peakBytesPerSecond <= 0L) {
            throw IllegalStateException(lastError.get())
        }
        return Triple(peakBytesPerSecond * 8.0 / 1_000_000.0, totalBytes.get(), elapsedSeconds)
    }

    private fun stopCore() {
        synchronized(warmProbeLock) { warmProbeNodes.clear() }
        runCatching { tunnelEngineManager.stop() }
        runCatching { tun?.close() }
        tun = null
        if (coreStarted) {
            runCatching { invoke("stopXray") }
            coreStarted = false
        }
        activeXrayConfig = null
        if (dnsConfigured) {
            runCatching { LibXray.resetDNS() }
            dnsConfigured = false
        }
        activeTunnelConfig = null
        dataplaneState = DataplaneState.IDLE
    }

    private fun parseEngineChoice(raw: String?): TunnelEngineChoice = when (raw?.uppercase()) {
        "CONTUN" -> TunnelEngineChoice.CONTUN
        "HEV" -> TunnelEngineChoice.HEV
        else -> TunnelEngineChoice.AUTO
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
            .setSmallIcon(R.drawable.connecso_logo)
            .setContentTitle(
                notificationCountryCode.takeIf { it.length == 2 }?.let(::countryFlag)?.let { "$it  $notificationCountryName" }
                    ?: notificationCountryName.ifBlank { "CONNECSO" },
            )
            .setContentText("VPN connection is active")
            .setOngoing(true)
            .setShowWhen(false)
            .setWhen(0)
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

    private fun startNotificationRefresh() {
        notificationRefresh?.cancel(false)
        notificationRefresh = notificationWorker.scheduleAtFixedRate({
            if (!coreStarted || !tunnelEngineManager.isRunning()) return@scheduleAtFixedRate
            val totals = readStats() ?: return@scheduleAtFixedRate
            val uploadRate = if (lastNotificationUpload < 0) 0L else (totals.first - lastNotificationUpload).coerceAtLeast(0)
            val downloadRate = if (lastNotificationDownload < 0) 0L else (totals.second - lastNotificationDownload).coerceAtLeast(0)
            lastNotificationUpload = totals.first
            lastNotificationDownload = totals.second
            notificationUploadRate = uploadRate
            notificationDownloadRate = downloadRate
            updateConnectionNotification(uploadRate, downloadRate)
        }, 0, 2, TimeUnit.SECONDS)
    }

    private fun startPeriodicPing() {
        periodicPing?.cancel(false)
        periodicPing = pingWorker.scheduleAtFixedRate({
            if (!coreStarted || !tunnelEngineManager.isRunning() || pingInProgress) return@scheduleAtFixedRate
            pingInProgress = true
            try {
                val result = measureActiveProxy(
                    notificationNodeId,
                    notificationCountryCode,
                    SystemClock.elapsedRealtime(),
                )
                notificationPing = if (result.success) result.latencyMs else -1L
                updateConnectionNotification()
            } catch (error: Exception) {
                Log.w(TAG, "event=notification_ping_failed failureType=${error.javaClass.simpleName}")
            } finally {
                pingInProgress = false
            }
        }, 0, 10, TimeUnit.SECONDS)
    }

    private fun updateConnectionNotification(
        uploadRate: Long = notificationUploadRate,
        downloadRate: Long = notificationDownloadRate,
    ) {
        val manager = getSystemService(Service.NOTIFICATION_SERVICE) as NotificationManager
        val country = notificationCountryName.ifBlank { "Connected" }
        val code = notificationCountryCode.uppercase().takeIf { it.length == 2 }
        val flag = code?.let(::countryFlag).orEmpty()
        val ping = if (notificationPing >= 0) "${notificationPing} ms" else "—"
        val title = if (flag.isEmpty()) country else "$flag  $country"
        val expanded = "$title\n↑ ${formatRate(uploadRate)}  ↓ ${formatRate(downloadRate)}\nPing: $ping"
        val pingIntent = PendingIntent.getService(
            this, 6402,
            Intent(this, ConnecsoVpnService::class.java).setAction(ACTION_NOTIFICATION_PING),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val stopIntent = PendingIntent.getService(
            this, 6403,
            Intent(this, ConnecsoVpnService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = PendingIntent.getActivity(
            this,
            6404,
            packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
                ?: Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val expandedView = RemoteViews(packageName, R.layout.notification_expanded).apply {
            setTextViewText(R.id.notification_expanded_title, title)
            setTextViewText(
                R.id.notification_expanded_details,
                "↑ ${formatRate(uploadRate)}  ↓ ${formatRate(downloadRate)}     Ping: $ping",
            )
            setImageViewResource(R.id.notification_ping_icon, R.drawable.ic_notification_ping)
            setImageViewResource(R.id.notification_disconnect_icon, R.drawable.ic_notification_disconnect)
            setTextViewText(R.id.notification_ping_label, "Ping")
            setTextViewText(R.id.notification_disconnect_label, "Disconnect")
            setOnClickPendingIntent(R.id.notification_ping_button, pingIntent)
            setOnClickPendingIntent(R.id.notification_disconnect_button, stopIntent)
            val textColor = if ((resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES) {
                android.graphics.Color.WHITE
            } else {
                android.graphics.Color.BLACK
            }
            setTextColor(R.id.notification_expanded_title, textColor)
            setTextColor(R.id.notification_expanded_details, textColor)
            setTextColor(R.id.notification_ping_label, textColor)
            setTextColor(R.id.notification_disconnect_label, textColor)
        }
        val compactView = RemoteViews(packageName, R.layout.notification_compact).apply {
            setTextViewText(R.id.notification_compact_country, title)
            setTextViewText(R.id.notification_compact_upload, "↑ ${formatRate(uploadRate)}")
            setTextViewText(R.id.notification_compact_download, "↓ ${formatRate(downloadRate)}")
            setTextViewText(R.id.notification_compact_ping, "⚡ $ping")
            setImageViewResource(R.id.notification_compact_ping_button, R.drawable.ic_notification_ping)
            setImageViewResource(R.id.notification_compact_disconnect_button, R.drawable.ic_notification_disconnect)
            setOnClickPendingIntent(R.id.notification_compact_ping_button, pingIntent)
            setOnClickPendingIntent(R.id.notification_compact_disconnect_button, stopIntent)
            val textColor = if ((resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) == android.content.res.Configuration.UI_MODE_NIGHT_YES) {
                android.graphics.Color.WHITE
            } else {
                android.graphics.Color.BLACK
            }
            setTextColor(R.id.notification_compact_upload, textColor)
            setTextColor(R.id.notification_compact_download, textColor)
            setTextColor(R.id.notification_compact_ping, textColor)
            setTextColor(R.id.notification_compact_country, textColor)
        }
        val notification = builder
            .setSmallIcon(R.drawable.connecso_logo)
            .setContentTitle(title)
            .setContentText(null)
            .setContentIntent(openIntent)
            .setStyle(Notification.DecoratedCustomViewStyle())
            .setCustomContentView(compactView)
            .setCustomBigContentView(expandedView)
            .setCustomHeadsUpContentView(compactView)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setWhen(0)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
    }

    private fun countryFlag(code: String): String = buildString {
        code.forEach { char -> appendCodePoint(0x1F1E6 + (char.code - 'A'.code)) }
    }

    private fun formatRate(bytesPerSecond: Long): String {
        var value = bytesPerSecond.coerceAtLeast(0).toDouble()
        val units = arrayOf("B/s", "KB/s", "MB/s", "GB/s", "TB/s")
        var unitIndex = 0
        // Promote before rounding so values that would render as 100.00
        // never exceed the requested two-digit display range.
        while (value >= 99.995 && unitIndex < units.lastIndex) {
            value /= 1_000.0
            unitIndex++
        }
        return "${String.format(java.util.Locale.US, "%.2f", value)} ${units[unitIndex]}"
    }

    private fun sendResult(
        requestId: String,
        operation: String,
        success: Boolean,
        error: String? = null,
        uploadBytes: Long? = null,
        downloadBytes: Long? = null,
        latencyMs: Long? = null,
        speedMbps: Double? = null,
        speedBytes: Long? = null,
        speedSeconds: Double? = null,
        speedConnections: Int? = null,
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
        if (speedMbps != null) result.putExtra(EXTRA_SPEED_MBPS, speedMbps)
        if (speedBytes != null) result.putExtra(EXTRA_SPEED_BYTES, speedBytes)
        if (speedSeconds != null) result.putExtra(EXTRA_SPEED_SECONDS, speedSeconds)
        if (speedConnections != null) result.putExtra(EXTRA_SPEED_CONNECTIONS, speedConnections)
        sendBroadcast(result)
    }

    companion object {
        private const val TAG = "CONNECSO/VPN"
        const val ACTION_RESULT = "com.connecso.client.VPN_RESULT"
        const val ACTION_START = "com.connecso.client.VPN_START"
        const val ACTION_PROBE = "com.connecso.client.VPN_PROBE"
        const val ACTION_VERIFY = "com.connecso.client.VPN_VERIFY"
        const val ACTION_STATS = "com.connecso.client.VPN_STATS"
        const val ACTION_SPEED_TEST = "com.connecso.client.VPN_SPEED_TEST"
        const val ACTION_STOP = "com.connecso.client.VPN_STOP"
        const val ACTION_NOTIFICATION_PING = "com.connecso.client.VPN_NOTIFICATION_PING"

        const val EXTRA_REQUEST_ID = "requestId"
        const val EXTRA_CONFIG = "config"
        const val EXTRA_NODE_ID = "nodeId"
        const val EXTRA_COUNTRY_NAME = "countryName"
        const val EXTRA_COUNTRY_CODE = "countryCode"
        const val EXTRA_SPLIT_MODE = "splitTunnelMode"
        const val EXTRA_SPLIT_PACKAGES = "splitTunnelPackages"
        const val EXTRA_OPERATION = "operation"
        const val EXTRA_SUCCESS = "success"
        const val EXTRA_ERROR = "error"
        const val EXTRA_UPLOAD_BYTES = "uploadBytes"
        const val EXTRA_DOWNLOAD_BYTES = "downloadBytes"
        const val EXTRA_LATENCY_MS = "latencyMs"
        const val EXTRA_SPEED_MBPS = "speedMbps"
        const val EXTRA_SPEED_BYTES = "speedBytes"
        const val EXTRA_SPEED_SECONDS = "speedSeconds"
        const val EXTRA_SPEED_CONNECTIONS = "speedConnections"
        const val EXTRA_TRACE_NODE_ID = "traceNodeId"
        const val EXTRA_TRACE_COUNTRY = "traceCountry"
        const val EXTRA_TUNNEL_ENGINE = "tunnelEngine"

        const val OP_START = "start"
        const val OP_PROBE = "probe"
        const val OP_VERIFY = "verify"
        const val OP_STATS = "stats"
        const val OP_SPEED_TEST = "speedTest"
        const val OP_STOP = "stop"

        private const val API_VERSION = 3
        private const val PROXY_TAG = "connecso-proxy"
        private const val SOCKS_TAG = "connecso-socks"
        private const val LOCAL_XRAY_HOST = VpnDataplaneConfig.XRAY_SOCKS_HOST
        private const val LOCAL_XRAY_PORT = VpnDataplaneConfig.XRAY_SOCKS_PORT
        private const val PING_URL = "https://www.google.com/generate_204"
        private const val PING_TIMEOUT_MS = 8_000
        private const val SPEED_TEST_CONNECTIONS = 4
        private const val METRICS_PORT = 49227
        private const val SPLIT_EXCLUDE = "excludeSelected"
        private const val SPLIT_INCLUDE = "includeSelected"
        private const val SPLIT_OFF = "off"
        private const val CHANNEL_ID = "connecso_vpn"
        private const val NOTIFICATION_ID = 6401
    }
}
