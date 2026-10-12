# Connecso

Connecso is an Android VPN client for Xray-compatible subscriptions. It simplifies subscription import, server selection, and full-device VPN traffic while preserving provider transport metadata.

> **Status:** `0.1.0` prerelease. Use it for testing and feedback.

## Features

- HTTPS subscription import from clipboard or URL
- Xray-compatible VLESS and supported transports
- WebSocket + TLS, XHTTP + TLS, Reality, and Hysteria2 when supplied by the subscription
- Automatic endpoint selection and country-aware server lists
- Android full-device VPN through `VpnService`
- Split tunneling with excluded applications
- IPv4, IPv6, DNS, TCP, and UDP forwarding where supported
- Quick Settings control for the last active profile
- Connection state, endpoint, protocol, and latency details

## Requirements

- Android 7.0 (API 24) or newer
- An Xray-compatible subscription URL or configuration
- VPN permission granted to Connecso

## Installation

Choose the APK matching the device ABI:

- `arm64-v8a`: most modern Android phones
- `armeabi-v7a`: older 32-bit ARM devices
- `x86_64`: x86_64 emulators
- `universal`: easiest choice when the ABI is unknown

Install the APK, open Connecso, and approve the Android VPN dialog.

## Import a subscription

1. Copy the HTTPS subscription URL.
2. Open Connecso and choose **Import subscription**.
3. Paste the URL or use the clipboard action.
4. Review the imported servers.
5. Choose **Automatic** or an available country/server.
6. Tap **Connect** and approve the VPN permission.

Connecso preserves transport metadata supplied by each node, including TLS server name, ALPN, fingerprint, ECH/Reality data, WebSocket or XHTTP settings, and Hysteria2 parameters.

## Automatic selection

Automatic mode evaluates eligible nodes using the subscription data and endpoint-selection logic. A successful probe alone is not treated as proof that device traffic works; the app verifies the VPN dataplane and local core before reporting Connected.

## Split tunneling

Full-device mode captures device traffic through Android VPN. When exclusions are enabled, selected applications bypass the VPN using Android's disallowed-application rules.

## Privacy and security

- Connecso does not provide VPN servers or subscription accounts.
- Subscription URLs and server credentials are private provider data.
- Never publish UUIDs, passwords, private keys, Reality private material, or subscription URLs in reports.
- Grant VPN permission only to a build you trust.

## Troubleshooting

### Subscription import fails

Confirm the HTTPS URL is reachable in a browser, try another network, and check that the subscription has not expired or reached its limit.

### Connection works but an app does not

Confirm the Android VPN icon is present, temporarily disable split tunneling, reconnect, and try another endpoint using the same protocol. Provider support for UDP/QUIC and IPv6 can vary by node.

### APK installation fails

Use the matching ABI or the universal APK. Android rejects an update signed with a different key; uninstalling the old build removes its data.

## Feedback

Include Android version, device ABI, Connecso version, protocol/transport, selected endpoint, split-tunneling state, and the exact error. Never include subscription URLs or credentials.

## License and acknowledgements

See [`NOTICE`](NOTICE) for third-party notices and licensing information.
