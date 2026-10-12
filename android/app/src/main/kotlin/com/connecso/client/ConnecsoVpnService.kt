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
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.Process
import android.net.TrafficStats
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

/**
 * Owns Android's TUN descriptor, HEV tun2socks, and the pinned Xray runtime.
 * This service runs in :vpn_xray to isolate the native Go runtime.
 */
class ConnecsoVpnService : VpnService(), DialerController {
    private val worker = Executors.newSingleThreadExecutor()
    // Disconnect must not wait behind a queued probe/health verification.
    private val stopWorker = Executors.newSingleThreadExecutor()
    @Volatile private var tun: ParcelFileDescriptor? = null
    @Volatile private var coreStarted = false
    @Volatile private var activeXrayConfig: String? = null
    @Volatile private var dnsConfigured = false
    @Volatile private var trafficUploadBaseline = TrafficStats.UNSUPPORTED.toLong()
    @Volatile private var trafficDownloadBaseline = TrafficStats.UNSUPPORTED.toLong()
    @Volatile private var dataplaneState = DataplaneState.IDLE
    private lateinit var tunnelEngineManager: TunnelEngineManager
    private var activeTunnelConfig: TunnelEngineConfig? = null
    private var connectivityManager: ConnectivityManager? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var availableNetwork: Network? = null

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
                enterForeground()
                worker.execute { startVpn(intent, requestId) }
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
            ACTION_STOP -> stopWorker.execute {
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
            // CONNECSO uses exclusion-based split tunneling.  Older builds
            // could persist `includeSelected`, which turns Android's VPN into
            // an allowlist and silently bypasses every other application.
            // Normalize every enabled mode to full-device VPN plus explicit
            // exclusions so stale policies cannot narrow capture.
            val mode = if (requestedMode == SPLIT_OFF) SPLIT_OFF else SPLIT_EXCLUDE
            val selectedPackages = if (mode == SPLIT_OFF) emptyList()
                else intent.getStringArrayListExtra(EXTRA_SPLIT_PACKAGES).orEmpty()

            runCatching {
                QuickTileStore.saveConfiguration(
                    this,
                    configText,
                    mode,
                    selectedPackages,
                    nodeId,
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

            val excludedPackages = if (mode == SPLIT_EXCLUDE) {
                selectedPackages.filterNot { it == packageName }.distinct()
            } else {
                emptyList()
            }
            Log.i(TAG, "VPN app routing mode=${if (excludedPackages.isEmpty()) "FULL" else "SPLIT_EXCLUDE"}")
            if (excludedPackages.isEmpty()) {
                Log.i(TAG, "VPN excluded packages=none")
            } else {
                excludedPackages.forEach { packageName ->
                    Log.i(TAG, "VPN excluded package=$packageName")
                    builder.addDisallowedApplication(packageName)
                }
            }

            dataplaneState = DataplaneState.XRAY_STARTING
            LibXray.registerDialerController(this)
            LibXray.setDNS(this, "${VpnDataplaneConfig.DNS_SERVER}:53")
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
        return ProbeMeasurement(success && delay >= 0 && delay < 10_000, -1L)
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
        val nativeStats = readXrayStats()
        if (nativeStats != null) return nativeStats
        if (tunnelEngineManager.isRunning()) {
            val tunnelStats = tunnelEngineManager.stats()
            if (tunnelStats.rxPackets > 0 || tunnelStats.txPackets > 0) {
                return tunnelStats.txPackets to tunnelStats.rxPackets
            }
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
        const val EXTRA_TRACE_NODE_ID = "traceNodeId"
        const val EXTRA_TRACE_COUNTRY = "traceCountry"
        const val EXTRA_TUNNEL_ENGINE = "tunnelEngine"

        const val OP_START = "start"
        const val OP_PROBE = "probe"
        const val OP_VERIFY = "verify"
        const val OP_STATS = "stats"
        const val OP_STOP = "stop"

        private const val API_VERSION = 3
        private const val PROXY_TAG = "connecso-proxy"
        private const val SOCKS_TAG = "connecso-socks"
        private const val LOCAL_XRAY_HOST = VpnDataplaneConfig.XRAY_SOCKS_HOST
        private const val LOCAL_XRAY_PORT = VpnDataplaneConfig.XRAY_SOCKS_PORT
        private const val PING_URL = "https://www.google.com/generate_204"
        private const val PING_TIMEOUT_MS = 8_000
        private const val METRICS_PORT = 49227
        private const val SPLIT_EXCLUDE = "excludeSelected"
        private const val SPLIT_OFF = "off"
        private const val CHANNEL_ID = "connecso_vpn"
        private const val NOTIFICATION_ID = 6401
    }
}
