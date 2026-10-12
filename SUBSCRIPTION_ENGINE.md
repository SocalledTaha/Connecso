# Subscription Engine

The platform-independent import pipeline is:

```text
URL / clipboard / camera QR / image QR → fetch → format detection → parser → normalization → validation → cache replacement → probe → rank → connect
```

The parser supports Base64 subscription lists, individual VLESS, VMess, Trojan, and Shadowsocks URIs, compatible JSON proxy-outbound configurations, and Clash YAML proxy lists. Each accepted entry is normalized into the internal `VpnNode` model before the Xray configuration builder handles it. Input format does not select a runtime. Parser errors do not include credentials; unsupported proxy types and transports are skipped or rejected explicitly.

The cache replacement method accepts only non-empty, already-parsed node sets. Refresh parses before its single cache write. The previous valid cache therefore survives fetch, decode, and validation failures.

On Android, a WorkManager periodic task refreshes every saved HTTPS subscription with a connected-network constraint, including when the app UI is closed. It reuses the same fetch, parser, quota metadata and per-subscription atomic cache path. Android may defer periodic work to respect power and network policy; opening the app also restores cached nodes immediately and starts an asynchronous refresh.
