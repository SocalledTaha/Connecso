"""Build the pinned HEV tun2socks AAR for the app's Android API 24 floor."""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / "work"
SOURCE = WORK / "hev-build-2.18.0"
ARTIFACTS = WORK / "artifacts"
OUTPUT = ARTIFACTS / "hev-socks5-tunnel.aar"
REPOSITORY = "https://github.com/heiher/hev-socks5-tunnel.git"
COMMIT = "d9dca26c7ad0e494492244f0309e80ee583e739e"
NDK_VERSION = "27.2.12479018"
ABIS = ("armeabi-v7a", "arm64-v8a", "x86", "x86_64")
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(args, cwd=cwd, check=True)


def ndk_build_command() -> str:
    sdk = os.environ.get("ANDROID_SDK_ROOT") or os.environ.get("ANDROID_HOME")
    if sdk:
        ndk = Path(sdk) / "ndk" / NDK_VERSION
        suffix = ".cmd" if os.name == "nt" else ""
        candidate = ndk / "ndk-build" if not suffix else ndk / "ndk-build.cmd"
        if candidate.is_file():
            return str(candidate)
    command = shutil.which("ndk-build") or shutil.which("ndk-build.cmd")
    if command:
        return command
    raise SystemExit(
        f"Android NDK {NDK_VERSION} is required; install it in the Android SDK."
    )


def checkout_source() -> None:
    WORK.mkdir(parents=True, exist_ok=True)
    if not (SOURCE / ".git").is_dir():
        if SOURCE.exists():
            raise SystemExit(f"Refusing to overwrite non-Git source path: {SOURCE}")
        run("git", "clone", "--filter=blob:none", "--no-checkout", REPOSITORY, str(SOURCE))
    run("git", "-C", str(SOURCE), "fetch", "--depth", "1", "origin", COMMIT)
    run("git", "-C", str(SOURCE), "checkout", "--detach", COMMIT)
    run("git", "-C", str(SOURCE), "submodule", "update", "--init", "--recursive")
    current = subprocess.check_output(
        ["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True
    ).strip()
    if current != COMMIT:
        raise SystemExit(f"Expected HEV commit {COMMIT}; received {current}.")
    status = subprocess.check_output(
        ["git", "-C", str(SOURCE), "submodule", "status", "--recursive"],
        text=True,
    )
    if any(line[:1] in {"-", "+", "U"} for line in status.splitlines()):
        raise SystemExit("HEV submodules do not match the pinned source commit.")
    resolve_windows_symlink_placeholders()


def resolve_windows_symlink_placeholders() -> None:
    if os.name != "nt":
        return
    for submodule in (
        "src/core",
        "third-part/hev-task-system",
        "third-part/lwip",
        "third-part/yaml",
    ):
        base = SOURCE / submodule
        listing = subprocess.check_output(
            ["git", "-C", str(base), "ls-files", "-s"], text=True
        )
        for line in listing.splitlines():
            mode, _, _, relative = line.split(None, 3)
            if mode != "120000":
                continue
            link_file = base / relative
            target_text = subprocess.check_output(
                ["git", "-C", str(base), "show", f"HEAD:{relative}"],
                text=True,
            ).strip()
            target = (link_file.parent / target_text).resolve()
            if not target.is_file() or SOURCE.resolve() not in target.parents:
                raise SystemExit(f"Invalid pinned HEV source link: {link_file}")
            target_bytes = target.read_bytes()
            if link_file.read_bytes() != target_bytes:
                link_file.write_bytes(target_bytes)


def build_native() -> None:
    application_mk = SOURCE / "Application.mk"
    content = application_mk.read_text(encoding="utf-8")
    expected = "APP_PLATFORM := android-29"
    if expected in content:
        application_mk.write_text(
            content.replace(expected, "APP_PLATFORM := android-24"),
            encoding="utf-8",
        )
    elif "APP_PLATFORM := android-24" not in content:
        raise SystemExit("Unexpected HEV Application.mk platform setting.")
    processor_count = os.cpu_count() or 1
    run(
        ndk_build_command(),
        f"NDK_PROJECT_PATH={SOURCE}",
        f"APP_BUILD_SCRIPT={SOURCE / 'Android.mk'}",
        f"NDK_APPLICATION_MK={application_mk}",
        f"-j{processor_count}",
        cwd=SOURCE,
    )


def package_aar() -> str:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="connecso-hev-aar-") as temporary:
        staging = Path(temporary)
        class_output = staging / "classes"
        class_output.mkdir()
        class_source = SOURCE / "android" / "hev" / "htproxy" / "TProxyService.java"
        classes_jar = staging / "classes.jar"
        run(
            shutil.which("javac") or "javac",
            "-source",
            "8",
            "-target",
            "8",
            "-d",
            str(class_output),
            str(class_source),
        )
        run(
            shutil.which("jar") or "jar",
            "cf",
            str(classes_jar),
            "-C",
            str(class_output),
            ".",
        )
        manifest = ET.Element(
            "manifest",
            {
                "xmlns:android": "http://schemas.android.com/apk/res/android",
                "package": "hev.socks5.tunnel",
            },
        )
        ET.SubElement(
            manifest, "uses-sdk", {ANDROID_NS + "minSdkVersion": "24"}
        )
        manifest_bytes = (
            b'<?xml version="1.0" encoding="utf-8"?>\n'
            + ET.tostring(manifest, encoding="utf-8")
        )
        native_paths = {
            abi: SOURCE / "libs" / abi / "libhev-socks5-tunnel.so" for abi in ABIS
        }
        for native in native_paths.values():
            if not native.is_file():
                raise SystemExit(f"Missing compiled HEV library: {native}")
        with ZipFile(OUTPUT, "w", ZIP_DEFLATED) as archive:
            archive.writestr(
                "AndroidManifest.xml", manifest_bytes, compress_type=ZIP_DEFLATED
            )
            archive.write(classes_jar, "classes.jar")
            archive.writestr(
                "proguard.txt",
                "-keep class hev.htproxy.TProxyService { *; }\n",
                compress_type=ZIP_DEFLATED,
            )
            for abi, native in native_paths.items():
                archive.write(native, f"jni/{abi}/libhev-socks5-tunnel.so")
    with ZipFile(OUTPUT) as archive:
        if archive.testzip() is not None:
            raise SystemExit("The generated HEV AAR failed ZIP integrity checks.")
        manifest = ET.fromstring(archive.read("AndroidManifest.xml"))
        minimum = manifest.find("uses-sdk")
        if minimum is None or minimum.attrib.get(ANDROID_NS + "minSdkVersion") != "24":
            raise SystemExit("The HEV AAR does not declare the API 24 minimum.")
        entries = set(archive.namelist())
    with ZipFile(OUTPUT) as archive, tempfile.TemporaryDirectory() as temporary:
        classes_file = Path(temporary) / "classes.jar"
        classes_file.write_bytes(archive.read("classes.jar"))
        listing = subprocess.check_output(
            [shutil.which("jar") or "jar", "tf", str(classes_file)], text=True
        )
        if "hev/htproxy/TProxyService.class" not in listing.splitlines():
            raise SystemExit("The HEV JNI binding is missing from the generated AAR.")
        for abi in ABIS:
            if f"jni/{abi}/libhev-socks5-tunnel.so" not in entries:
                raise SystemExit(f"The HEV AAR is missing the {abi} binary.")
    digest = hashlib.sha256(OUTPUT.read_bytes()).hexdigest()
    print(f"HEV Android AAR ready: {OUTPUT} (SHA-256 {digest})")
    return digest


def main() -> None:
    checkout_source()
    build_native()
    package_aar()


if __name__ == "__main__":
    main()
