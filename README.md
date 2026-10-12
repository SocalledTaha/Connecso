# CONNECSO Client

**CONNECSO** is an Android-first VPN client built around Xray Core and a real Android `VpnService` dataplane. It imports subscription profiles, preserves transport metadata, selects a healthy endpoint, routes device traffic through a local SOCKS bridge, and reports Connected only after the tunnel is ready.

[![Latest release](https://img.shields.io/github/v/release/SocalledTaha/connecso-client?display_name=tag&sort=semver)](https://github.com/SocalledTaha/connecso-client/releases)
[![Android](https://img.shields.io/badge/platform-Android-3DDC84?logo=android&logoColor=white)](https://github.com/SocalledTaha/connecso-client/releases)

> **Current prerelease: 0.2.0**

## What it does

- Imports and persists multiple subscription profiles.
- Preserves per-node Xray metadata instead of flattening transport details.
- Supports VLESS transports including WebSocket, XHTTP and Hysteria2 profiles when provided by a subscription.
- Preserves TLS server name, ALPN, Chrome fingerprint, ECH, Reality, WebSocket and XHTTP settings.
- Resolves endpoints automatically or within a selected country and connection method.
- Uses Xray Core as the proxy core and a shared Android full-device VPN dataplane.
- Captures IPv4 traffic and supports IPv6 when enabled by the dataplane configuration.
- Keeps UDP forwarding enabled through the local SOCKS inbound for DNS, QUIC and application traffic.
- Provides Split Tunneling with Android excluded-app rules.
- Shows connection readiness, cancellation, reconnect and health states in the UI.
- Provides an Android Quick Settings tile that follows the VPN service state on connect, disconnect and failure.
- Supports English and Persian, light and dark themes, responsive map UI and destination-country presentation.

## Architecture

```text
Subscription import
        ↓
Metadata-preserving parser
        ↓
Destination and endpoint resolver
        ↓
Xray configuration builder
        ↓
Xray local SOCKS inbound (127.0.0.1:10808)
        ↓
Contun tunnel engine (HEV fallback)
        ↓
Android VpnService / TUN
        ↓
VPN server and Internet
```

Country and method selection only constrain endpoint resolution. They do not create separate Android VPN pipelines or change the local bridge endpoint.

## Tunnel engines

- **Contun** is the primary tunnel-engine integration, wrapped behind a CONNECSO-specific interface.
- **HEV** remains available as the fallback engine.
- Only one engine owns the TUN file descriptor at a time.
- The service waits for Xray readiness, establishes TUN, starts the engine, verifies the dataplane and only then reports Connected.
- Native Contun/zeptun-derived components include the upstream MIT attribution in [`NOTICE`](NOTICE) and the bundled license files.

## Download

Download the signed release artifacts from the [GitHub Releases page](https://github.com/SocalledTaha/connecso-client/releases).

| APK | Use case |
| --- | --- |
| `arm64-v8a` | Modern Android phones; recommended |
| `armeabi-v7a` | Older 32-bit ARM phones |
| `x86_64` | x86_64 Android emulators and devices |
| Universal | Devices where ABI is unknown; largest download |

## Requirements

For end users:

- Android device supported by the selected APK ABI.
- A compatible subscription URL or imported profile.
- Android VPN permission granted to CONNECSO.

For development:

- Flutter 3.47.5 or newer
- Dart 3.10 or newer
- Java 17
- Android SDK/build tools 35 or newer
- Android NDK 27.2.12479018 when rebuilding native components

## Build locally

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

For native Android compilation:

```powershell
cd android
./gradlew :app:compileDebugKotlin --offline
```

See [`BUILD.md`](BUILD.md) for the complete native build workflow.

## Validation model

A successful Xray process start or endpoint ping is not treated as proof of a usable VPN. Validation is layered:

1. Xray local SOCKS readiness
2. Android TUN establishment
3. Tunnel-engine startup
4. Dataplane readiness
5. Application-level connectivity checks when enabled by the test workflow

The project includes parser, resolver, connection-manager and Xray configuration tests under [`test/`](test/), plus subscription metadata auditing utilities under [`tool/`](tool/).

## Security and privacy

CONNECSO does not request GPS location or expose the user's physical origin. Do not commit subscription URLs, credentials, UUIDs, private keys, signing material or production secrets. Report security issues privately according to [`SECURITY.md`](SECURITY.md).

## License and attribution

The CONNECSO application source remains all rights reserved unless a separate license is provided. Native components derived from the MIT-licensed zeptun project retain their original attribution and license; see [`NOTICE`](NOTICE) and [`third_party/licenses/zeptun-LICENSE.txt`](third_party/licenses/zeptun-LICENSE.txt).

## Maintainer

**Taha — Connecso Devs**  
[GitHub](https://github.com/SocalledTaha) · [tmosapor74@gmail.com](mailto:tmosapor74@gmail.com)
