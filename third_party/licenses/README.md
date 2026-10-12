# Third-party notices

The generated Android `libXray.aar` contains XTLS/libXray and XTLS/Xray-core.
The authoritative license texts for the pinned Android build are included here:

- [`libXray-LICENSE.txt`](libXray-LICENSE.txt) — MIT License
- [`Xray-core-LICENSE.txt`](Xray-core-LICENSE.txt) — Mozilla Public License 2.0
- [`hev-socks5-tunnel-LICENSE.txt`](hev-socks5-tunnel-LICENSE.txt) — MIT License

The HEV Android AAR is built from `heiher/hev-socks5-tunnel` commit
`d9dca26c7ad0e494492244f0309e80ee583e739e`, including the exact submodule
revisions pinned by that commit. CI compiles it against Android API 24 with the
pinned NDK, retaining Android 7.0+ compatibility without overriding the
upstream Android 10+ prebuilt AAR's minimum-version declaration.

Build inputs and provenance are recorded in [`CORE_ARCHITECTURE.md`](../../CORE_ARCHITECTURE.md).
