package com.connecso.client.tunnel

object VpnDataplaneConfig {
    const val XRAY_SOCKS_HOST = "127.0.0.1"
    const val XRAY_SOCKS_PORT = 10808
    const val DEFAULT_MTU = 1500
    const val IPV4_ADDRESS = "10.111.0.1"
    const val IPV4_PREFIX = 30
    const val IPV6_ADDRESS = "fd00::1"
    const val IPV6_PREFIX = 126
    // Diagnostic toggle: keep IPv6 disabled until the full HEV/Xray IPv6
    // path is proven with real YouTube traffic.
    const val IPV6_ENABLED = false
    const val DNS_SERVER = "1.1.1.1"
    const val TRAFFIC_PROOF_WINDOW_MS = 6_000L
}
