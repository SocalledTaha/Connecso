from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]
ANDROID = ROOT / "android"
APP = ANDROID / "app"
SOURCE = ROOT / "android-host" / "src" / "main" / "kotlin" / "com" / "connecso" / "client"
DEST = APP / "src" / "main" / "kotlin" / "com" / "connecso" / "client"
CORE_AAR = ROOT / "work" / "artifacts" / "libXray.aar"
CORE_AAR_DEST = APP / "libs" / "libXray.aar"
HEV_AAR = ROOT / "work" / "artifacts" / "hev-socks5-tunnel.aar"
HEV_AAR_DEST = APP / "libs" / "hev-socks5-tunnel.aar"
LICENSE_SOURCE = ROOT / "third_party" / "licenses"
LICENSE_DEST = APP / "src" / "main" / "assets" / "licenses"

if not (APP / "build.gradle.kts").exists():
    raise SystemExit("Expected Flutter's Android Kotlin Gradle project was not generated.")
if not CORE_AAR.is_file():
    raise SystemExit("Pinned libXray AAR is missing; build the Android core artifact before bootstrapping.")
if not HEV_AAR.is_file():
    raise SystemExit("Pinned HEV AAR is missing; run tool/build_hev_android.py before bootstrapping.")

DEST.mkdir(parents=True, exist_ok=True)
for name in ("MainActivity.kt", "ConnecsoVpnService.kt", "QuickSettingsVpnTileService.kt"):
    shutil.copy2(SOURCE / name, DEST / name)

CORE_AAR_DEST.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(CORE_AAR, CORE_AAR_DEST)
shutil.copy2(HEV_AAR, HEV_AAR_DEST)
LICENSE_DEST.mkdir(parents=True, exist_ok=True)
for name in (
    "libXray-LICENSE.txt",
    "Xray-core-LICENSE.txt",
    "hev-socks5-tunnel-LICENSE.txt",
):
    shutil.copy2(LICENSE_SOURCE / name, LICENSE_DEST / name)

gradle = APP / "build.gradle.kts"
text = gradle.read_text(encoding="utf-8")
text = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", text)
text = re.sub(r'namespace\s*=\s*"[^"]+"', 'namespace = "com.connecso.client"', text)
text = re.sub(r'applicationId\s*=\s*"[^"]+"', 'applicationId = "com.connecso.client"', text)
aar_dependency = 'implementation(files("libs/libXray.aar"))'
hev_dependency = 'implementation(files("libs/hev-socks5-tunnel.aar"))'
for dependency in (aar_dependency, hev_dependency):
    if dependency in text:
        continue
    if re.search(r"(?m)^dependencies\s*\{", text):
        text = re.sub(
            r"(?m)^dependencies\s*\{",
            f"dependencies {{\n    {dependency}",
            text,
            count=1,
        )
    else:
        text = text.rstrip() + f"\n\ndependencies {{\n    {dependency}\n}}\n"
if aar_dependency not in text or hev_dependency not in text:
    raise SystemExit("Failed to register the pinned Xray and HEV AARs with the Android app.")
gradle.write_text(text, encoding="utf-8")

manifest = APP / "src" / "main" / "AndroidManifest.xml"
text = manifest.read_text(encoding="utf-8")
text = text.replace('android:label="connecso_client"', 'android:label="CONNECSO"')
permissions = (
    "android.permission.QUERY_ALL_PACKAGES",
    "android.permission.INTERNET",
    "android.permission.ACCESS_NETWORK_STATE",
    "android.permission.FOREGROUND_SERVICE",
    "android.permission.FOREGROUND_SERVICE_SPECIAL_USE",
)
missing_permissions = [
    permission for permission in permissions if permission not in text
]
if missing_permissions:
    declarations = "".join(
        f'    <uses-permission android:name="{permission}" />\n'
        for permission in missing_permissions
    )
    text = text.replace("<application", declarations + "    <application", 1)
if "com.connecso.client.ConnecsoVpnService" not in text:
    text = text.replace(
        "</application>",
        '        <service\n'
        '            android:name="com.connecso.client.ConnecsoVpnService"\n'
        '            android:permission="android.permission.BIND_VPN_SERVICE"\n'
        '            android:process=":vpn_xray"\n'
            '            android:foregroundServiceType="specialUse"\n'
            '            <property\n'
            '                android:name="android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE"\n'
            '                android:value="vpn" />\n'
        '            android:exported="true">\n'
        '            <intent-filter>\n'
        '                <action android:name="android.net.VpnService" />\n'
        '            </intent-filter>\n'
        '        </service>\n'
        '    </application>',
        1,
    )
if 'android:allowBackup="false"' not in text:
    text = text.replace(
        "<application",
        '<application android:allowBackup="false"',
        1,
    )
if "com.connecso.client.QuickSettingsVpnTileService" not in text:
    text = text.replace(
        "    </application>",
        '        <service\n'
        '            android:name="com.connecso.client.QuickSettingsVpnTileService"\n'
        '            android:label="CONNECSO"\n'
        '            android:icon="@mipmap/ic_launcher"\n'
        '            android:permission="android.permission.BIND_QUICK_SETTINGS_TILE"\n'
        '            android:exported="true">\n'
        '            <intent-filter>\n'
        '                <action android:name="android.service.quicksettings.action.QS_TILE" />\n'
        '            </intent-filter>\n'
        '            <meta-data\n'
        '                android:name="android.service.quicksettings.ACTIVE_TILE"\n'
        '                android:value="true" />\n'
        '        </service>\n'
        '    </application>',
        1,
    )
manifest.write_text(text, encoding="utf-8")
