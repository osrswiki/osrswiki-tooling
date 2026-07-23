#!/usr/bin/env python3
"""ADB wireless physical-device helper for OSRS Wiki sessions."""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Mapping, Sequence


ENDPOINT_RE = re.compile(r"^(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9_.-]+|\d{1,3}(?:\.\d{1,3}){3}):([0-9]{1,5})$")
EXPORT_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$")


@dataclass(frozen=True)
class AdbResolution:
    adb: Path
    sdk_root: Path | None
    source: str


@dataclass(frozen=True)
class AdbDevice:
    serial: str
    state: str
    properties: dict[str, str]

    @property
    def model(self) -> str:
        return self.properties.get("model", "").replace("_", " ")

    @property
    def is_xperia(self) -> bool:
        return "xperia" in self.model.lower() or "xperia" in self.serial.lower()


@dataclass(frozen=True)
class MdnsService:
    name: str
    service_type: str
    kind: str
    endpoint: str

    @property
    def is_xperia(self) -> bool:
        return "xperia" in self.name.lower() or "xperia" in self.endpoint.lower()


@dataclass(frozen=True)
class VerifiedDevice:
    serial: str
    stable_id: str
    model: str
    manufacturer: str

    @property
    def label(self) -> str:
        parts = [self.manufacturer, self.model]
        return " ".join(part for part in parts if part).strip()


class WirelessDeviceError(RuntimeError):
    pass


def default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def infer_main_repo(repo_root: Path) -> Path | None:
    repo_root = repo_root.resolve()
    if repo_root.parent.name == "sessions":
        candidate = repo_root.parent.parent / "main"
        if candidate.exists():
            return candidate
    candidate = repo_root.parent / "main"
    if candidate.exists() and candidate != repo_root:
        return candidate
    return None


def parse_shell_value(value: str) -> str:
    value = value.strip()
    if not value:
        return ""
    try:
        return shlex.split(value, posix=True)[0]
    except ValueError:
        return value.strip("\"'")


def read_env_file(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        match = EXPORT_RE.match(line)
        if match:
            values[match.group(1)] = parse_shell_value(match.group(2))
    return values


def local_properties_sdk(path: Path) -> Path | None:
    if not path.exists():
        return None
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if line.startswith("sdk.dir="):
            value = line.split("=", 1)[1].strip().replace("\\:", ":")
            if value:
                return Path(value).expanduser()
    return None


def candidate_sdk_roots(repo_root: Path, env: Mapping[str, str]) -> Iterable[tuple[Path, str]]:
    for key in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = env.get(key)
        if value:
            yield Path(value).expanduser(), key

    worktree_local = repo_root / "platforms/android/local.properties"
    sdk_root = local_properties_sdk(worktree_local)
    if sdk_root:
        yield sdk_root, str(worktree_local)

    main_repo = infer_main_repo(repo_root)
    if main_repo:
        main_local = main_repo / "platforms/android/local.properties"
        sdk_root = local_properties_sdk(main_local)
        if sdk_root:
            yield sdk_root, str(main_local)

    for path in (
        Path.home() / "Library/Android/sdk",
        Path.home() / "Android/Sdk",
        Path("/usr/local/share/android-sdk"),
        Path("/opt/android-sdk"),
    ):
        yield path, "common Android SDK location"


def resolve_adb(repo_root: Path, env: Mapping[str, str] | None = None, override: str | None = None) -> AdbResolution:
    env = env or os.environ
    if override:
        adb = Path(override).expanduser()
        if adb.exists() and os.access(adb, os.X_OK):
            return AdbResolution(adb=adb.resolve(), sdk_root=adb.parent.parent, source="--adb")
        raise WirelessDeviceError(f"ADB override is not executable: {override}")

    env_override = env.get("OSRS_ANDROID_ADB")
    if env_override:
        adb = Path(env_override).expanduser()
        if adb.exists() and os.access(adb, os.X_OK):
            return AdbResolution(adb=adb.resolve(), sdk_root=adb.parent.parent, source="OSRS_ANDROID_ADB")

    path_adb = shutil.which("adb", path=env.get("PATH"))
    if path_adb:
        adb = Path(path_adb).resolve()
        sdk_root = adb.parent.parent if adb.parent.name == "platform-tools" else None
        return AdbResolution(adb=adb, sdk_root=sdk_root, source="PATH")

    for sdk_root, source in candidate_sdk_roots(repo_root, env):
        adb = sdk_root / "platform-tools" / "adb"
        if adb.exists() and os.access(adb, os.X_OK):
            return AdbResolution(adb=adb.resolve(), sdk_root=sdk_root.resolve(), source=source)

    raise WirelessDeviceError(
        "adb was not found. Install Android SDK platform-tools, set ANDROID_HOME, "
        "or keep main/platforms/android/local.properties pointed at the SDK."
    )


def is_endpoint(value: str) -> bool:
    match = ENDPOINT_RE.match(value.strip())
    if not match:
        return False
    port = int(match.group(1))
    return 1 <= port <= 65535


def parse_adb_devices(output: str) -> list[AdbDevice]:
    devices: list[AdbDevice] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.lower().startswith("list of devices attached"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        serial, state = fields[0], fields[1]
        properties: dict[str, str] = {}
        for field in fields[2:]:
            if ":" in field:
                key, value = field.split(":", 1)
                properties[key] = value
        devices.append(AdbDevice(serial=serial, state=state, properties=properties))
    return devices


def parse_adb_mdns(output: str) -> list[MdnsService]:
    services: list[MdnsService] = []
    for raw_line in output.splitlines():
        line = raw_line.strip()
        if not line or line.lower().startswith("list of discovered mdns services"):
            continue
        service_match = re.search(r"_adb-tls-(connect|pairing)\._tcp\.?", line)
        if not service_match:
            continue
        endpoint = ""
        for token in reversed(line.split()):
            cleaned = token.strip(",;")
            if is_endpoint(cleaned):
                endpoint = cleaned
                break
        if not endpoint:
            continue
        kind = service_match.group(1)
        name = line[: service_match.start()].strip() or "(unnamed)"
        service_type = service_match.group(0)
        services.append(MdnsService(name=name, service_type=service_type, kind=kind, endpoint=endpoint))
    return services


def redacted(text: str, secrets: Iterable[str] = ()) -> str:
    result = text
    for secret in secrets:
        if secret:
            result = result.replace(secret, "<redacted>")
    result = re.sub(r"(?i)(--pair-code(?:=|\s+))\S+", r"\1<redacted>", result)
    result = re.sub(r"(?i)(ANDROID_ADB_PAIRING_CODE=)\S+", r"\1<redacted>", result)
    result = re.sub(r"(?i)((?:pairing\s+)?code\s*[:=]\s*)\S+", r"\1<redacted>", result)
    return result


def printable_command(args: Sequence[str], secrets: Iterable[str] = ()) -> str:
    return redacted(" ".join(shlex.quote(arg) for arg in args), secrets)


def run_command(args: Sequence[str], secrets: Iterable[str] = (), check: bool = False) -> subprocess.CompletedProcess[str]:
    completed = subprocess.run(args, text=True, capture_output=True, check=False)
    if check and completed.returncode != 0:
        stderr = redacted(completed.stderr.strip(), secrets)
        stdout = redacted(completed.stdout.strip(), secrets)
        raise WirelessDeviceError(
            f"Command failed ({completed.returncode}): {printable_command(args, secrets)}\n{stdout}\n{stderr}".strip()
        )
    return completed


def adb_output(adb: Path, args: Sequence[str], secrets: Iterable[str] = ()) -> str:
    completed = run_command([str(adb), *args], secrets=secrets)
    if completed.returncode != 0:
        raise WirelessDeviceError(redacted(completed.stderr or completed.stdout, secrets).strip())
    return completed.stdout


def inventory(adb: Path) -> tuple[list[AdbDevice], list[MdnsService], str | None]:
    devices = parse_adb_devices(adb_output(adb, ["devices", "-l"]))
    mdns_error: str | None = None
    try:
        services = parse_adb_mdns(adb_output(adb, ["mdns", "services"]))
    except WirelessDeviceError as exc:
        services = []
        mdns_error = str(exc)
    return devices, services, mdns_error


def detect_stale_env(env_values: Mapping[str, str], devices: Sequence[AdbDevice]) -> str | None:
    serial = env_values.get("ANDROID_SERIAL", "")
    if not serial or not is_endpoint(serial):
        return None
    matching = [device for device in devices if device.serial == serial and device.state == "device"]
    if matching:
        return None
    return serial


def get_device_prop(adb: Path, serial: str, prop: str) -> str:
    try:
        return adb_output(adb, ["-s", serial, "shell", "getprop", prop]).strip()
    except WirelessDeviceError:
        return ""


def verify_connected_device(adb: Path, serial: str, expect_model: str = "", expect_stable_id: str = "") -> VerifiedDevice:
    state = adb_output(adb, ["-s", serial, "get-state"]).strip()
    if state != "device":
        raise WirelessDeviceError(f"ADB target {serial} is not ready; get-state returned {state!r}")

    stable_id = get_device_prop(adb, serial, "ro.serialno")
    model = get_device_prop(adb, serial, "ro.product.model")
    manufacturer = get_device_prop(adb, serial, "ro.product.manufacturer")

    if expect_model and expect_model.lower() not in model.lower():
        raise WirelessDeviceError(f"Verified device model {model!r} did not match expected text {expect_model!r}")
    if expect_stable_id and stable_id != expect_stable_id:
        raise WirelessDeviceError(f"Verified device stable id {stable_id!r} did not match expected id")

    return VerifiedDevice(serial=serial, stable_id=stable_id, model=model, manufacturer=manufacturer)


def read_app_id(repo_root: Path) -> str:
    app_id_script = repo_root / "scripts/android/get-app-id.sh"
    if app_id_script.exists():
        completed = subprocess.run([str(app_id_script)], cwd=repo_root, text=True, capture_output=True, check=False)
        if completed.returncode == 0 and completed.stdout.strip():
            return completed.stdout.strip()
    build_file = repo_root / "platforms/android/app/build.gradle.kts"
    text = build_file.read_text(encoding="utf-8")
    match = re.search(r'applicationId\s*=\s*"([^"]+)"', text)
    if not match:
        raise WirelessDeviceError("Could not resolve Android applicationId")
    return match.group(1)


def shell_quote_export(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=path.parent, delete=False) as handle:
        tmp_path = Path(handle.name)
        handle.write(text)
    tmp_path.replace(path)


def write_session_environment(repo_root: Path, resolution: AdbResolution, device: VerifiedDevice) -> None:
    app_id = read_app_id(repo_root)
    now = datetime.now(timezone.utc).isoformat()
    platform_tools = resolution.adb.parent
    sdk_root = resolution.sdk_root or platform_tools.parent
    lines = [
        "# OSRS Wiki Android wireless physical-device session environment",
        "# ANDROID_SERIAL is the current verified adb transport endpoint; rediscover it after Wi-Fi changes.",
        f"export ANDROID_SERIAL={shell_quote_export(device.serial)}",
        f"export APPID={shell_quote_export(app_id)}",
        f"export ANDROID_ADB={shell_quote_export(str(resolution.adb))}",
        f"export ANDROID_HOME={shell_quote_export(str(sdk_root))}",
        f"export ANDROID_SDK_ROOT={shell_quote_export(str(sdk_root))}",
        f"export PATH={shell_quote_export(str(platform_tools))}:$PATH",
        "export ANDROID_WIRELESS_SESSION=true",
        f"export ANDROID_WIRELESS_DEVICE_STABLE_ID={shell_quote_export(device.stable_id)}",
        f"export ANDROID_WIRELESS_DEVICE_MODEL={shell_quote_export(device.model)}",
        f"export ANDROID_WIRELESS_DEVICE_MANUFACTURER={shell_quote_export(device.manufacturer)}",
        f"# Verified at: {now}",
        "",
    ]
    atomic_write(repo_root / ".claude-env", "\n".join(lines))
    atomic_write(repo_root / ".claude-device-serial", f"{device.serial}\n")
    atomic_write(repo_root / ".claude-app-id", f"{app_id}\n")
    atomic_write(
        repo_root / ".claude-android-wireless-device",
        json.dumps(
            {
                "serial": device.serial,
                "stable_id": device.stable_id,
                "model": device.model,
                "manufacturer": device.manufacturer,
                "verified_utc": now,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
    )


def connect_device(
    adb: Path,
    connect_endpoint: str,
    pair_endpoint: str = "",
    pair_code: str = "",
    expect_model: str = "",
    expect_stable_id: str = "",
) -> VerifiedDevice:
    if not is_endpoint(connect_endpoint):
        raise WirelessDeviceError(f"Invalid connect endpoint: {connect_endpoint!r}")
    secrets = [pair_code]
    if pair_endpoint:
        if not is_endpoint(pair_endpoint):
            raise WirelessDeviceError(f"Invalid pair endpoint: {pair_endpoint!r}")
        if not pair_code:
            pair_code = os.environ.get("ANDROID_ADB_PAIRING_CODE", "")
            secrets = [pair_code]
        if not pair_code and sys.stdin.isatty():
            pair_code = getpass.getpass(f"Pairing code for {pair_endpoint}: ")
            secrets = [pair_code]
        if not pair_code:
            raise WirelessDeviceError("Pairing endpoint was supplied but no pairing code was provided")
        completed = run_command([str(adb), "pair", pair_endpoint, pair_code], secrets=secrets)
        if completed.returncode != 0:
            raise WirelessDeviceError(redacted(completed.stderr or completed.stdout, secrets).strip())

    completed = run_command([str(adb), "connect", connect_endpoint], secrets=secrets)
    if completed.returncode != 0:
        raise WirelessDeviceError(redacted(completed.stderr or completed.stdout, secrets).strip())

    return verify_connected_device(adb, connect_endpoint, expect_model=expect_model, expect_stable_id=expect_stable_id)


def inventory_as_dict(
    resolution: AdbResolution,
    devices: Sequence[AdbDevice],
    services: Sequence[MdnsService],
    mdns_error: str | None,
    stale_env_serial: str | None,
) -> dict[str, object]:
    connected_xperia_wireless = [
        device.serial
        for device in devices
        if device.state == "device" and is_endpoint(device.serial) and device.is_xperia
    ]
    xperia_tls_connect_endpoints = [
        service.endpoint for service in services if service.kind == "connect" and service.is_xperia
    ]
    return {
        "adb": str(resolution.adb),
        "adb_source": resolution.source,
        "sdk_root": str(resolution.sdk_root) if resolution.sdk_root else None,
        "devices": [
            {"serial": device.serial, "state": device.state, "properties": device.properties}
            for device in devices
        ],
        "mdns_services": [
            {
                "name": service.name,
                "service_type": service.service_type,
                "kind": service.kind,
                "endpoint": service.endpoint,
                "is_xperia": service.is_xperia,
            }
            for service in services
        ],
        "mdns_error": mdns_error,
        "stale_env_android_serial": stale_env_serial,
        "xperia_tls_connect_endpoints": sorted(set(xperia_tls_connect_endpoints + connected_xperia_wireless)),
    }


def print_preflight(summary: Mapping[str, object]) -> None:
    print("Android wireless physical-device preflight")
    print(f"adb: {summary['adb']} ({summary['adb_source']})")
    sdk_root = summary.get("sdk_root")
    if sdk_root:
        print(f"sdk_root: {sdk_root}")
    stale = summary.get("stale_env_android_serial")
    if stale:
        print(f"stale_env_android_serial: {stale}")
        print("stale_env_action: rediscover mDNS and reconnect before install/launch")

    devices = summary["devices"]
    print("adb_devices:")
    if devices:
        for device in devices:  # type: ignore[assignment]
            props = device["properties"]
            model = props.get("model", "").replace("_", " ")
            model_text = f" model={model}" if model else ""
            print(f"  - {device['serial']} {device['state']}{model_text}")
    else:
        print("  - none")

    services = summary["mdns_services"]
    print("mdns_services:")
    if services:
        for service in services:  # type: ignore[assignment]
            xperia = " xperia=true" if service["is_xperia"] else ""
            print(f"  - {service['kind']} {service['endpoint']} name={service['name']}{xperia}")
    else:
        print("  - none")
    if summary.get("mdns_error"):
        print(f"mdns_error: {summary['mdns_error']}")

    xperia = summary.get("xperia_tls_connect_endpoints") or []
    if xperia:
        print("xperia_tls_pairing: existing paired connect service discovered")
    else:
        print("xperia_tls_pairing: no Xperia connect service discovered")


def env_with_adb_path(env: Mapping[str, str], resolution: AdbResolution) -> dict[str, str]:
    merged = dict(env)
    platform_tools = str(resolution.adb.parent)
    current_path = merged.get("PATH", "")
    if platform_tools not in current_path.split(os.pathsep):
        merged["PATH"] = platform_tools + os.pathsep + current_path
    if resolution.sdk_root:
        merged.setdefault("ANDROID_HOME", str(resolution.sdk_root))
        merged.setdefault("ANDROID_SDK_ROOT", str(resolution.sdk_root))
    return merged


def run_install_launch(repo_root: Path, resolution: AdbResolution) -> int:
    script = repo_root / "scripts/android/quick-test.sh"
    if not script.exists():
        raise WirelessDeviceError(f"Missing existing Android build/install/launch script: {script}")
    completed = subprocess.run([str(script)], cwd=repo_root, env=env_with_adb_path(os.environ, resolution), check=False)
    return completed.returncode


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Manage Android wireless physical-device sessions safely.")
    parser.add_argument("--repo-root", type=Path, default=default_repo_root(), help="Repository root.")
    parser.add_argument("--adb", help="Path to adb. Defaults to PATH, env, SDK roots, or main local.properties.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight", help="Read-only ADB device and mDNS inventory.")
    preflight.add_argument("--json", action="store_true", help="Print machine-readable JSON.")

    connect = subparsers.add_parser("connect", help="Pair/connect to an explicit current endpoint and rewrite session env after verification.")
    connect.add_argument("--connect", required=True, help="Current adb-tls-connect endpoint, for example 192.0.2.10:37199.")
    connect.add_argument("--pair", default="", help="Current adb-tls-pairing endpoint. Optional when already paired.")
    connect.add_argument("--pair-code", default="", help="Pairing code. Never logged or written.")
    connect.add_argument("--expect-model", default="", help="Require verified ro.product.model to contain this text.")
    connect.add_argument("--expect-stable-id", default="", help="Require verified ro.serialno to equal this value.")

    install = subparsers.add_parser("install-launch", help="Verify the wireless target, then run scripts/android/quick-test.sh.")
    install.add_argument("--connect", default="", help="Optional current connect endpoint to verify and save before install/launch.")
    install.add_argument("--pair", default="", help="Optional current pairing endpoint.")
    install.add_argument("--pair-code", default="", help="Pairing code. Never logged or written.")
    install.add_argument("--expect-model", default="", help="Require verified ro.product.model to contain this text.")
    install.add_argument("--expect-stable-id", default="", help="Require verified ro.serialno to equal this value.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    try:
        resolution = resolve_adb(repo_root, override=args.adb)
        if args.command == "preflight":
            devices, services, mdns_error = inventory(resolution.adb)
            stale = detect_stale_env(read_env_file(repo_root / ".claude-env"), devices)
            summary = inventory_as_dict(resolution, devices, services, mdns_error, stale)
            if args.json:
                print(json.dumps(summary, indent=2, sort_keys=True))
            else:
                print_preflight(summary)
            return 0

        if args.command == "connect":
            device = connect_device(
                resolution.adb,
                args.connect,
                pair_endpoint=args.pair,
                pair_code=args.pair_code,
                expect_model=args.expect_model,
                expect_stable_id=args.expect_stable_id,
            )
            write_session_environment(repo_root, resolution, device)
            label = device.label or device.stable_id or device.serial
            print(f"Verified Android wireless device: {label}")
            print("Session environment rewritten: .claude-env")
            return 0

        if args.command == "install-launch":
            if args.connect:
                device = connect_device(
                    resolution.adb,
                    args.connect,
                    pair_endpoint=args.pair,
                    pair_code=args.pair_code,
                    expect_model=args.expect_model,
                    expect_stable_id=args.expect_stable_id,
                )
                write_session_environment(repo_root, resolution, device)
            else:
                env_values = read_env_file(repo_root / ".claude-env")
                serial = env_values.get("ANDROID_SERIAL", "")
                if not serial:
                    raise WirelessDeviceError("ANDROID_SERIAL missing; run preflight, then connect with a current endpoint")
                verify_connected_device(
                    resolution.adb,
                    serial,
                    expect_model=args.expect_model,
                    expect_stable_id=args.expect_stable_id,
                )
            return run_install_launch(repo_root, resolution)

    except WirelessDeviceError as exc:
        print(redacted(str(exc), [getattr(args, "pair_code", "")]), file=sys.stderr)
        return 1

    parser.error(f"Unhandled command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
