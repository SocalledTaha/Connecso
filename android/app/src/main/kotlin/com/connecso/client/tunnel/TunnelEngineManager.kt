package com.connecso.client.tunnel

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Log

class TunnelEngineManager(
    private val contun: TunnelEngine,
    private val hev: TunnelEngine,
) {
    @Volatile var activeEngine: TunnelEngine? = null
        private set
    @Volatile var state: DataplaneState = DataplaneState.IDLE
        private set

    fun start(
        service: VpnService,
        tun: ParcelFileDescriptor,
        config: TunnelEngineConfig,
        choice: TunnelEngineChoice,
    ): Boolean = synchronized(this) {
        stop()
        state = DataplaneState.TUNNEL_ENGINE_STARTING
        val candidates = when (choice) {
            TunnelEngineChoice.CONTUN -> listOf(contun)
            TunnelEngineChoice.HEV -> listOf(hev)
            TunnelEngineChoice.AUTO -> listOf(contun, hev)
        }
        for (engine in candidates) {
            Log.i(TAG, "event=tunnel.try engine=${engine.name} choice=$choice")
            if (engine.start(service, tun, config)) {
                activeEngine = engine
                state = if (engine === contun) DataplaneState.CONTUN_ACTIVE else DataplaneState.HEV_ACTIVE
                Log.i(TAG, "event=tunnel.active engine=${engine.name}")
                return true
            }
            engine.stop()
            Log.w(TAG, "event=tunnel.start_failed engine=${engine.name}")
        }
        state = DataplaneState.FAILED
        false
    }

    fun fallbackToHev(
        service: VpnService,
        tun: ParcelFileDescriptor,
        config: TunnelEngineConfig,
    ): Boolean = synchronized(this) {
        if (activeEngine === hev && hev.isRunning()) return true
        Log.w(TAG, "event=contun.unhealthy fallback=HEV stats=${stats()}")
        activeEngine?.stop()
        activeEngine = null
        val started = hev.start(service, tun, config)
        if (started) {
            activeEngine = hev
            state = DataplaneState.HEV_ACTIVE
        } else {
            state = DataplaneState.FAILED
        }
        started
    }

    fun isRunning(): Boolean = activeEngine?.isRunning() == true
    fun stats(): TunnelEngineStats = activeEngine?.stats() ?: TunnelEngineStats()
    fun activeName(): String = activeEngine?.name ?: "none"

    fun markVerifying() { state = DataplaneState.DATAPLANE_VERIFYING }
    fun markConnected() { state = DataplaneState.CONNECTED }
    fun markFailed() { state = DataplaneState.FAILED }

    fun stop() = synchronized(this) {
        activeEngine?.stop()
        activeEngine = null
        state = DataplaneState.IDLE
    }

    companion object {
        private const val TAG = "CONNECSO/Tunnel"
    }
}
