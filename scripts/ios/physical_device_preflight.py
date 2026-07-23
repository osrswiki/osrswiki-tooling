#!/usr/bin/env python3
"""Read-only iOS physical-device wireless preflight for OSRS Wiki."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping, Sequence


ACTIVE_TUNNEL_STATES = {"active", "connected", "ready"}
LOCAL_NETWORK_TRANSPORTS = {"localnetwork", "network", "wifi", "wireless"}
IP_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b")


@dataclass(frozen=True)
class IosPhysicalDevice:
    identifier: str
    name: str
    marketing_name: str
    platform: str
    reality: str
    pairing_state: str
    transport_type: str
    tunnel_state: str
    ddi_services_available: bool
    potential_hostnames: tuple[str, ...]
    devicectl_addresses: tuple[str, ...]
    visibility_class: str
    last_connection_date: str

    @property
    def is_paired(self) -> bool:
        return self.pairing_state.lower() == "paired"

    @property
    def is_local_network_known(self) -> bool:
        transport = self.transport_type.lower()
        return transport in LOCAL_NETWORK_TRANSPORTS or bool(self.potential_hostnames or self.devicectl_addresses)

    @property
    def has_active_developer_tunnel(self) -> bool:
        tunnel = self.tunnel_state.lower()
        return tunnel in ACTIVE_TUNNEL_STATES or self.ddi_services_available

    @property
    def can_try_install_launch(self) -> bool:
        return self.is_paired and self.has_active_developer_tunnel


class IosPreflightError(RuntimeError):
    pass


def default_repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


def nested_get(mapping: Mapping[str, Any], *keys: str, default: Any = "") -> Any:
    value: Any = mapping
    for key in keys:
        if not isinstance(value, Mapping):
            return default
        value = value.get(key, default)
    return value


def collect_devicectl_network_values(value: Any, parent_key: str = "") -> set[str]:
    found: set[str] = set()
    key_lc = parent_key.lower()
    if isinstance(value, Mapping):
        for key, child in value.items():
            found.update(collect_devicectl_network_values(child, str(key)))
    elif isinstance(value, list):
        for child in value:
            found.update(collect_devicectl_network_values(child, parent_key))
    elif isinstance(value, str):
        if any(marker in key_lc for marker in ("address", "hostname", "host", "dns", "ip")):
            found.add(value)
        for match in IP_RE.findall(value):
            found.add(match)
    return found


def parse_devices(devicectl_json: Mapping[str, Any]) -> list[IosPhysicalDevice]:
    raw_devices = nested_get(devicectl_json, "result", "devices", default=[])
    devices: list[IosPhysicalDevice] = []
    for raw in raw_devices:
        if not isinstance(raw, Mapping):
            continue
        hardware = raw.get("hardwareProperties", {}) if isinstance(raw.get("hardwareProperties"), Mapping) else {}
        device = raw.get("deviceProperties", {}) if isinstance(raw.get("deviceProperties"), Mapping) else {}
        connection = raw.get("connectionProperties", {}) if isinstance(raw.get("connectionProperties"), Mapping) else {}
        properties = raw.get("properties", {}) if isinstance(raw.get("properties"), Mapping) else {}

        reality = str(hardware.get("reality", ""))
        platform = str(hardware.get("platform", ""))
        if reality.lower() != "physical" or platform.lower() not in {"ios", "ipados"}:
            continue

        potential_hostnames_raw = connection.get("potentialHostnames", [])
        potential_hostnames = tuple(str(item) for item in potential_hostnames_raw if item)
        network_values = collect_devicectl_network_values(connection)
        network_values.update(collect_devicectl_network_values(properties.get("connection", {}), "connection"))
        network_values.update(potential_hostnames)

        devices.append(
            IosPhysicalDevice(
                identifier=str(raw.get("identifier", "")),
                name=str(device.get("name", "")),
                marketing_name=str(hardware.get("marketingName", "")),
                platform=platform,
                reality=reality,
                pairing_state=str(connection.get("pairingState", nested_get(properties, "connection", "pairingState"))),
                transport_type=str(connection.get("transportType", nested_get(properties, "connection", "transportType"))),
                tunnel_state=str(connection.get("tunnelState", nested_get(properties, "connection", "tunnelState"))),
                ddi_services_available=bool(device.get("ddiServicesAvailable", False)),
                potential_hostnames=potential_hostnames,
                devicectl_addresses=tuple(sorted(item for item in network_values if item)),
                visibility_class=str(raw.get("visibilityClass", "")),
                last_connection_date=str(connection.get("lastConnectionDate", "")),
            )
        )
    return devices


def run_devicectl_list(timeout: int = 10) -> Mapping[str, Any]:
    with tempfile.NamedTemporaryFile(suffix=".json", delete=False) as json_file:
        json_path = Path(json_file.name)
    with tempfile.NamedTemporaryFile(suffix=".log", delete=False) as log_file:
        log_path = Path(log_file.name)
    completed = subprocess.run(
        [
            "xcrun",
            "devicectl",
            "list",
            "devices",
            "--timeout",
            str(timeout),
            "--json-output",
            str(json_path),
            "--log-output",
            str(log_path),
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if completed.returncode != 0:
        raise IosPreflightError(
            f"devicectl list devices failed ({completed.returncode}); log: {log_path}\n{completed.stderr.strip()}"
        )
    try:
        return json.loads(json_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise IosPreflightError(f"devicectl wrote invalid JSON to {json_path}: {exc}") from exc


def load_devicectl_json(path: Path | None, timeout: int) -> Mapping[str, Any]:
    if path:
        return json.loads(path.read_text(encoding="utf-8"))
    return run_devicectl_list(timeout=timeout)


def select_devices(devices: Sequence[IosPhysicalDevice], selector: str = "") -> list[IosPhysicalDevice]:
    if not selector:
        return list(devices)
    needle = selector.lower()
    selected: list[IosPhysicalDevice] = []
    for device in devices:
        fields = [
            device.identifier,
            device.name,
            device.marketing_name,
            *device.potential_hostnames,
            *device.devicectl_addresses,
        ]
        if any(needle in field.lower() for field in fields):
            selected.append(device)
    return selected


def device_to_dict(device: IosPhysicalDevice) -> dict[str, Any]:
    return {
        "identifier": device.identifier,
        "name": device.name,
        "marketing_name": device.marketing_name,
        "platform": device.platform,
        "pairing_state": device.pairing_state,
        "transport_type": device.transport_type,
        "tunnel_state": device.tunnel_state,
        "ddi_services_available": device.ddi_services_available,
        "potential_hostnames": list(device.potential_hostnames),
        "devicectl_addresses": list(device.devicectl_addresses),
        "paired": device.is_paired,
        "local_network_known": device.is_local_network_known,
        "active_developer_tunnel": device.has_active_developer_tunnel,
        "can_try_install_launch": device.can_try_install_launch,
        "visibility_class": device.visibility_class,
        "last_connection_date": device.last_connection_date,
    }


def build_install_launch_commands(repo_root: Path, device_identifier: str, derived_data_path: str = "") -> list[str]:
    derived = shlex.quote(derived_data_path) if derived_data_path else '"$(ios_make_derived_data_path physical-device)"'
    app_path = "$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/osrswiki.app"
    return [
        f'REPO_ROOT={shlex.quote(str(repo_root))}',
        'cd "$REPO_ROOT"',
        'source "$REPO_ROOT/scripts/shared/local-artifact-root.sh"',
        '[[ -f "$REPO_ROOT/.osrs-artifacts.env" ]] && source "$REPO_ROOT/.osrs-artifacts.env"',
        'BUNDLE_ID="$(scripts/ios/get-bundle-id.sh)"',
        f'IOS_PHYSICAL_DEVICE_ID="{device_identifier}"',
        f'DERIVED_DATA_PATH={derived}',
        'DERIVED_DATA_PATH="$(osrs_assert_artifact_path "$DERIVED_DATA_PATH")"',
        'mkdir -p "$DERIVED_DATA_PATH"',
        "xcodebuild "
        "-project platforms/ios/osrswiki.xcodeproj "
        "-scheme osrswiki "
        "-configuration Debug "
        "-sdk iphoneos "
        "-destination 'generic/platform=iOS' "
        '-derivedDataPath "$DERIVED_DATA_PATH" '
        "build",
        f'APP_PATH="{app_path}"',
        'xcrun devicectl device install app --device "$IOS_PHYSICAL_DEVICE_ID" "$APP_PATH"',
        'xcrun devicectl device process launch --device "$IOS_PHYSICAL_DEVICE_ID" --terminate-existing "$BUNDLE_ID"',
    ]


def print_device_summary(devices: Sequence[IosPhysicalDevice]) -> None:
    print("iOS physical-device wireless preflight")
    if not devices:
        print("devices: none")
        return
    for device in devices:
        print(f"- {device.name or '(unnamed)'} [{device.identifier}]")
        print(f"  product: {device.marketing_name or 'unknown'}")
        print(f"  pairing: {device.pairing_state or 'unknown'}")
        print(f"  transport: {device.transport_type or 'unknown'}")
        print(f"  tunnel: {device.tunnel_state or 'unknown'}")
        print(f"  ddi_services_available: {str(device.ddi_services_available).lower()}")
        names = ", ".join(device.devicectl_addresses) if device.devicectl_addresses else "none"
        print(f"  devicectl_network_names: {names}")
        print(f"  paired_local_network_known: {str(device.is_paired and device.is_local_network_known).lower()}")
        print(f"  active_developer_tunnel: {str(device.has_active_developer_tunnel).lower()}")
        if device.can_try_install_launch:
            print("  install_launch_state: ready_to_try")
        elif device.is_paired and device.is_local_network_known:
            print("  install_launch_state: paired_on_local_network_but_tunnel_not_active")
        else:
            print("  install_launch_state: not_ready")


def print_prerequisites() -> None:
    print("safe_prerequisites:")
    print("- device appears in `xcrun devicectl list devices --json-output <file>` as physical iOS/iPadOS")
    print("- pairingState is paired")
    print("- Developer Mode is enabled and the device is unlocked")
    print("- the Mac and device are on the same trusted network or connected by USB")
    print("- tunnelState is active/connected/ready or ddiServicesAvailable is true before install/launch")
    print("- Xcode signing can build omiyawaki.osrswiki for this device")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Read-only iOS physical-device wireless preflight.")
    parser.add_argument("--repo-root", type=Path, default=default_repo_root(), help="Repository root.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser("preflight", help="List physical iOS devices from devicectl JSON.")
    preflight.add_argument("--from-json", type=Path, help="Use a saved devicectl JSON file instead of running xcrun.")
    preflight.add_argument("--timeout", type=int, default=10, help="devicectl timeout in seconds.")
    preflight.add_argument("--device", default="", help="Filter by identifier, name, hostname, or address.")
    preflight.add_argument("--json", action="store_true", help="Print machine-readable JSON.")
    preflight.add_argument("--commands", action="store_true", help="Also print build/install/launch commands for selected devices.")

    commands = subparsers.add_parser("commands", help="Print the safe physical-device build/install/launch command path.")
    commands.add_argument("--device", required=True, help="Stable devicectl device identifier, serial, name, or dns name.")
    commands.add_argument("--derived-data-path", default="", help="Optional fixed DerivedData path.")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    repo_root = args.repo_root.resolve()
    try:
        if args.command == "preflight":
            data = load_devicectl_json(args.from_json, args.timeout)
            devices = select_devices(parse_devices(data), args.device)
            if args.json:
                print(json.dumps([device_to_dict(device) for device in devices], indent=2, sort_keys=True))
            else:
                print_device_summary(devices)
                print_prerequisites()
                if args.commands:
                    for device in devices:
                        print("")
                        print(f"commands_for: {device.identifier}")
                        for command in build_install_launch_commands(repo_root, device.identifier):
                            print(command)
            return 0

        if args.command == "commands":
            print_prerequisites()
            print("commands:")
            for command in build_install_launch_commands(repo_root, args.device, args.derived_data_path):
                print(command)
            return 0
    except (IosPreflightError, OSError, json.JSONDecodeError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    parser.error(f"Unhandled command: {args.command}")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
