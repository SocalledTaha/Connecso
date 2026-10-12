# Android Build

## Requirements

- Flutter 3.47.5 with Dart 3.10 or newer
- Java 17
- Android SDK / build tools 35 or newer
- Go 1.27.1 and Android NDK 27.2.12479018 only when building the pinned libXray AAR

GitHub Actions builds libXray from commit `50b95979f5db551bd273165cf469e5daaf791341` before Android packaging. The generated AAR is not committed. CI caches `work/artifacts/libXray.aar` with an exact key containing the source commit, Go version, Java/API target, gomobile version, NDK version, and upstream build-script hash. A cache hit is verified before packaging; on a miss, CI installs the native toolchain, builds the AAR, and stores it. UI-only edits do not invalidate this native-core cache.

After the first successful VPN connection, add the **CONNECSO** tile from Android Quick Settings → Edit. It starts or stops the last profile used in the app. If VPN consent has been revoked, open CONNECSO and connect once to grant it again.

## Local Android build

```powershell
flutter create --platforms android --org com.connecso --project-name connecso_client .
flutter pub get
python tool/bootstrap_android.py
flutter analyze
flutter test
flutter build apk --debug
```

The bootstrap expects `work/artifacts/libXray.aar` and `work/artifacts/hev-socks5-tunnel.aar`; it copies their licenses and Android platform sources into Flutter's generated Android project. Build the HEV AAR from its pinned source for API 24 with `python tool/build_hev_android.py`; this uses NDK `27.2.12479018` and all four Android ABIs. It avoids relying on upstream's prebuilt AAR, which declares API 29 as its minimum.

## GitHub Actions

`.github/workflows/android.yml` restores Gradle and pinned libXray caches, then runs Flutter dependency resolution, analysis, tests, Kotlin/Gradle packaging, and creates one universal Android release APK. CI uploads the APK separately from the build-provenance artifact. Its temporary debug key supports private testing only; production distribution and seamless upgrades require an owner-managed signing key. A green build does not replace emulator or physical-device VPN validation.
