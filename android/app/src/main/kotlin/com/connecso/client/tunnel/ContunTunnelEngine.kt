package com.connecso.client.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log
import android.os.Build

class ContunTunnelEngine : TunnelEngine {
    override val name: String = "Contun"
    @Volatile private var started = false

    override fun start(
        service: VpnService,
        tun: ParcelFileDescriptor,
        config: TunnelEngineConfig,
    ): Boolean = synchronized(this) {
        stop()
        // The upstream native engine currently uses a syscall that Android's
        // x86 emulator seccomp profile rejects (SIGSYS).  Refuse it before
        // entering JNI so AUTO can safely select HEV; arm64 remains the
        // primary production path.
        if (Build.SUPPORTED_ABIS.any { it == "x86" || it == "x86_64" }) {
            Log.w(TAG, "event=contun.unsupported_abi abi=${Build.SUPPORTED_ABIS.joinToString(",")}")
            return false
        }
        val result = runCatching {
            ContunNative.nativeStart(service, tun.fd, buildConfig(config, tun.fd))
        }.onFailure {
            Log.w(TAG, "event=contun.native_start_failed failureType=${it.javaClass.simpleName}")
        }.getOrDefault(-1)
        started = result == 0
        if (started) {
            Log.i(TAG, "event=contun.started version=${runCatching { ContunNative.nativeVersion() }.getOrDefault("unknown")}")
        } else {
            Log.w(TAG, "event=contun.start_rejected code=$result")
        }
        started
    }

    override fun stop() {
        synchronized(this) {
            if (!started) return
            runCatching { ContunNative.nativeStop() }
                .onFailure { Log.w(TAG, "event=contun.stop_failed failureType=${it.javaClass.simpleName}") }
            started = false
            Log.i(TAG, "event=contun.stopped")
        }
    }

    override fun isRunning(): Boolean {
        if (!started) return false
        val nativeRunning = runCatching { ContunNative.nativeIsRunning() }.getOrDefault(false)
        if (!nativeRunning) {
            Log.w(TAG, "event=contun.worker_stopped code=${runCatching { ContunNative.nativeLastError() }.getOrDefault(-1)}")
            started = false
        }
        return nativeRunning
    }

    override fun stats(): TunnelEngineStats {
        if (!started) return TunnelEngineStats()
        fun counter(index: Int): Long = runCatching { ContunNative.nativeCounter(index) }
            .getOrDefault(0L)
            .coerceAtLeast(0L)
        return TunnelEngineStats(
            rxPackets = counter(0),
            txPackets = counter(2),
            tcpOpened = counter(13),
            tcpFailed = counter(17),
            udpSessions = counter(19),
        )
    }

    private fun buildConfig(config: TunnelEngineConfig, tunFd: Int): String {
        val addresses = buildList {
            add("\"${config.ipv4}/30\"")
            config.ipv6?.let { add("\"$it/126\"") }
        }.joinToString(", ")
        return """
preset = "mobile"
log_level = "warn"

[tun]
fd = $tunFd
mtu = ${config.mtu}
address = [$addresses]

[stack]
tcp_idle_timeout_ms = 300000
udp_idle_timeout_ms = 60000
udp = ${config.udpEnabled}

[handler]
kind = "socks5"

[handler.socks5]
server = "${config.socksHost}:${config.socksPort}"
udp = ${config.udpEnabled}
udp_mode = "udp"
pipeline = ${config.pipeline}

[route]
auto_route = false
""".trimIndent()
    }

    companion object {
        private const val TAG = "CONNECSO/Contun"
    }
}
