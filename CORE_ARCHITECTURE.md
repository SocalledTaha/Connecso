# Core Architecture

CONNECSO Client is an Android-only Xray-core VPN client. `ProxyCore` is the application boundary; `XrayProxyCore` is its only implementation. Subscription retrieval, format parsing, normalization, node selection, health history, and recovery remain independent from Xray configuration generation.

## Connection lifecycle

```text
Subscription → Normalize → Probe → SmartSelector → Generate Xray configuration
  → Start Xray → Establish Android VPN → Verify connectivity → Connected
```

Node failover keeps the same core and changes only the selected normalized node:

```text
Active node failure → Reconnecting → SmartSelector selects another healthy node
  → Generate Xray configuration → Restart Xray session → Verify → Connected
```

The connection manager applies a temporary cooldown to nodes that fail probing, tunnel startup, verification, or active-tunnel recovery. Probe and connection history are recorded per node. No core preference, core-performance ranking, or cross-core recovery is used.

## Android boundary

Flutter owns UI, localization, subscriptions, normalized nodes, probing, selection, Xray configuration generation, and persistence. Kotlin owns Android VPN permission, `VpnService`, TUN descriptor, DNS configuration, per-app routing, platform connectivity verification, and lifecycle calls to libXray. The service runs in the dedicated `:vpn_xray` process. Xray exposes statistics through a loopback-only metrics endpoint, with HEV tunnel counters and Android UID traffic counters as fallbacks.

**Android packet path:** `VpnService TUN → HEV tun2socks → 127.0.0.1:10808 SOCKS5 → Xray outbound`. Kotlin retains ownership of the `ParcelFileDescriptor`; HEV runs in its native worker thread and is stopped before Xray and before the TUN descriptor closes. Xray's outbound sockets continue to use Android `VpnService.protect()` through the registered dialer controller, avoiding a VPN routing loop. Xray is configured with a local SOCKS5 inbound; it does not open the Android TUN itself. Session byte counters prefer Xray SOCKS inbound metrics and fall back to HEV tunnel counters.

The Xray configuration builder maps supported normalized VLESS, VMess, Trojan, and Shadowsocks nodes into Xray outbounds. Mux is explicitly disabled by default; there is no Mux setting in the UI. UDP/443 is passed to the proxy for the QUIC trial. Supported Xray transports include TCP, WebSocket, gRPC, HTTP Upgrade, and XHTTP, with TLS and Reality settings where represented by the normalized node model.

### DNS and IP-family policy

Android advertises `1.1.1.1` as the VPN DNS server. Xray also uses its built-in DNS server with upstream `1.1.1.1` and `queryStrategy: UseIPv4`; routed port 53 traffic enters Xray's DNS outbound. This keeps DNS resolution inside the configured proxy path and makes IPv4 answers the preferred result. The TUN retains both IPv4 and IPv6 default routes to avoid sending IPv6 traffic outside the VPN, while Xray routes IPv6 destinations (`::/0`) to the blackhole outbound. UDP/443 is not blocked, so QUIC can be evaluated with this configuration. If device testing shows that QUIC fails on a particular server, restore a UDP/443 block as a compatibility fallback and compare again.

The TUN and HEV MTU remain 1500. No Xray buffer-size override or HEV TCP buffer override is set; those are measurement-dependent tuning variables and are intentionally not changed by this baseline.

The Android VPN service applies split tunneling through `VpnService.Builder`, starts HEV on the established TUN, and verifies HTTPS connectivity through the resulting route. “Connected” is shown only after this real connectivity check succeeds. Session traffic is measured independently from subscription quota metadata.

## Pinned Xray build inputs

- libXray repository: `XTLS/libXray`
- libXray commit: `50b95979f5db551bd273165cf469e5daaf791341`
- Xray-core: `v26.9.9` (pinned by libXray's `go.mod`)
- Go: `1.27.1`
- gomobile / x/mobile: `v0.0.0-20260908204917-8b95e45f8d3e`
- Android NDK: `27.2.12479018`
- HEV tun2socks: `2.18.0`, commit `d9dca26c7ad0e494492244f0309e80ee583e739e`; submodules `src/core=162dd996299fc2d2bff2dd63728f8a2cd71ed31a`, `hev-task-system=328f35d903221b51811b3d02b277d665dfbdc75f`, `lwip=e22c9d2873cd5a8aade9deb2e518b75dab05170e`, `yaml=efa36117a8646d26d12b58e05bac472d7854a70d`; compiled with Android NDK `27.2.12479018` and `APP_PLATFORM=android-24`, all four ABIs; MIT license.
- Build command: `python3 build/main.py android`
- libXray API version: `3`

CI builds and caches the AAR from these immutable inputs. The generated AAR is not committed. The private universal APK and its larger provenance artifact are separate CI outputs. CI uses a temporary debug signing key; production distribution requires an owner-controlled release key.

## Preserved application services

The Xray-only boundary does not remove the Subscription Engine, supported input parsers, normalized node model, ProbeEngine, SmartSelector, health/stability history, hysteresis, node failover, subscription recovery/control-plane verification, atomic cache replacement, quota parsing, map, animation, localization, themes, redacted logging, or database migrations. Input formats remain supported when their proxy data can be normalized and represented by Xray. JSON proxy outbounds and Clash YAML are parsed as subscription data; neither parser selects or launches a different runtime.

Production recovery remains fail-closed until the owner provides its endpoint and trust configuration. Production APK signing also needs the owner-managed keystore. Physical-device VPN verification remains required.

Authoritative sources:

- [Pinned libXray source and Android integration](https://github.com/XTLS/libXray/tree/50b95979f5db551bd273165cf469e5daaf791341)
- [HEV tun2socks Android/JNI integration](https://github.com/heiher/hev-socks5-tunnel/blob/main/README.md)
- [Pinned HEV source](https://github.com/heiher/hev-socks5-tunnel/tree/d9dca26c7ad0e494492244f0309e80ee583e739e)
- [Xray outbound and Mux configuration](https://xtls.github.io/en/config/outbound.html)
- [Android foreground service types](https://developer.android.com/about/versions/14/changes/fgs-types-required)
- [libXray license](https://github.com/XTLS/libXray/blob/50b95979f5db551bd273165cf469e5daaf791341/LICENSE)
- [Xray-core license](https://github.com/XTLS/Xray-core/blob/v26.9.9/LICENSE)
