#!/usr/bin/env python3
"""
Bifrost - cliente de la API de Tenable One / Tenable Vulnerability Management.

Crea un escaneo a partir de una politica existente, lo lanza, espera, exporta el
.nessus y produce un resumen en Markdown listo para las diapositivas.

Uso rapido
----------
    # credenciales (no quedan en el historial de shell)
    mkdir -p ~/.bifrost
    cat > ~/.bifrost/tenable.json <<'JSON'
    {"access_key": "xxxx", "secret_key": "yyyy"}
    JSON

    python tenable_scan.py --action policies
    python tenable_scan.py --action scanners
    python tenable_scan.py --action run --name "Bifrost pre-demo"
    python tenable_scan.py --action summary --file out/scan.nessus --out out/scan.md

    # --targets, --policy y --base-url son opcionales: por defecto salen de
    # config/lab.env. Solo se pasan para sobreescribir algo puntual.

Variables de entorno alternativas: TIO_ACCESS_KEY / TIO_SECRET_KEY / TIO_BASE_URL
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

# Import perezoso: la accion 'summary' debe funcionar sin red ni dependencias,
# porque es la que se usa para fabricar las diapositivas.
try:
    import requests
except ImportError:  # pragma: no cover
    requests = None  # type: ignore[assignment]

REQUESTS_HINT = "Falta el paquete 'requests'. Instala con:  pip install requests"

# --------------------------------------------------------------------------- #
# Configuracion del laboratorio (config/lab.env)
# --------------------------------------------------------------------------- #

def _find_lab_env() -> Path | None:
    override = os.environ.get("BIFROST_CONFIG")
    if override:
        candidate = Path(override).expanduser()
        if candidate.is_file():
            return candidate

    here = Path(__file__).resolve().parent
    for candidate in (here.parent / "config" / "lab.env", here / "config" / "lab.env"):
        if candidate.is_file():
            return candidate
    return None


def load_lab_config() -> dict[str, str]:
    """Parser minimo del mismo archivo que consumen bash y PowerShell."""
    path = _find_lab_env()
    if not path:
        return {}

    data: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        data[key.strip()] = value

    data["__PATH__"] = str(path)
    return data


LAB = load_lab_config()

TERMINAL_STATES = {"completed", "canceled", "aborted", "imported", "error"}

SEVERITY = {0: "Info", 1: "Bajo", 2: "Medio", 3: "Alto", 4: "Critico"}

TARGET_KEYS = ("BIFROST_IP_WEB", "BIFROST_IP_DC", "BIFROST_IP_WS")


def default_base_url() -> str:
    return (os.environ.get("TIO_BASE_URL")
            or LAB.get("BIFROST_TENABLE_BASE_URL")
            or "https://cloud.tenable.com")


def default_keys_file() -> Path:
    configured = LAB.get("BIFROST_TENABLE_KEYS_FILE", "")
    if configured:
        return Path(configured).expanduser()
    return Path.home() / ".bifrost" / "tenable.json"


def default_targets() -> str:
    ips = [LAB[key] for key in TARGET_KEYS if LAB.get(key)]
    return ",".join(ips)


class TenableError(RuntimeError):
    """Error de API o de red."""


# --------------------------------------------------------------------------- #
# Cliente
# --------------------------------------------------------------------------- #

class Tenable:
    def __init__(self, access_key: str, secret_key: str, base_url: str | None = None,
                 timeout: int = 90, verbose: bool = False):
        if requests is None:
            raise TenableError(REQUESTS_HINT)
        self.base = (base_url or default_base_url()).rstrip("/")
        self.timeout = timeout
        self.verbose = verbose
        self.session = requests.Session()
        self.session.headers.update({
            "X-ApiKeys": f"accessKey={access_key}; secretKey={secret_key}",
            "Accept": "application/json",
            "User-Agent": "bifrost-lab/1.0",
        })

    # -- transporte ---------------------------------------------------------- #

    def request(self, method: str, path: str, *, as_json: bool = True,
                retries: int = 5, **kwargs):
        url = f"{self.base}{path}"
        last_error = ""

        for attempt in range(retries):
            try:
                response = self.session.request(method, url, timeout=self.timeout, **kwargs)
            except requests.RequestException as exc:
                last_error = str(exc)
                if attempt == retries - 1:
                    raise TenableError(f"Error de red en {method} {path}: {last_error}")
                time.sleep(2 ** attempt)
                continue

            if response.status_code == 429 or 500 <= response.status_code < 600:
                wait = float(response.headers.get("Retry-After", 2 ** attempt))
                if self.verbose:
                    print(f"    [{response.status_code}] reintento en {wait:.0f}s", file=sys.stderr)
                time.sleep(min(wait, 30))
                continue

            if response.status_code >= 400:
                raise TenableError(
                    f"{method} {path} -> HTTP {response.status_code}\n{response.text[:600]}")

            if self.verbose:
                print(f"    {method} {path} -> {response.status_code}", file=sys.stderr)

            if as_json:
                if not response.content:
                    return {}
                return response.json()
            return response.content

        raise TenableError(f"Reintentos agotados en {method} {path}: {last_error}")

    # -- endpoints ----------------------------------------------------------- #

    def policies(self):
        return self.request("GET", "/policies").get("policies", [])

    def scanners(self):
        return self.request("GET", "/scanners").get("scanners", [])

    def scans(self):
        return self.request("GET", "/scans").get("scans", [])

    def find_policy(self, name: str):
        candidates = [p for p in self.policies() if p.get("name", "").lower() == name.lower()]
        if not candidates:
            names = "\n  ".join(sorted(p.get("name", "?") for p in self.policies()))
            raise TenableError(f"No existe la politica '{name}'. Disponibles:\n  {names}")
        return candidates[0]

    def create_scan(self, policy_uuid: str, name: str, targets: str,
                    scanner_id: int | None = None, description: str = "Bifrost lab"):
        settings = {
            "name": name,
            "description": description,
            "text_targets": targets,
            "enabled": True,
            "launch": "ON_DEMAND",
        }
        if scanner_id is not None:
            settings["scanner_id"] = int(scanner_id)

        body = {"uuid": policy_uuid, "settings": settings}
        return self.request("POST", "/scans", json=body)

    def launch(self, scan_id: int):
        return self.request("POST", f"/scans/{scan_id}/launch")

    def scan_info(self, scan_id: int):
        return self.request("GET", f"/scans/{scan_id}")

    def delete_scan(self, scan_id: int):
        return self.request("DELETE", f"/scans/{scan_id}")

    def export_nessus(self, scan_id: int, poll_seconds: int = 5, timeout: int = 900) -> bytes:
        created = self.request("POST", f"/scans/{scan_id}/export", json={"format": "nessus"})
        file_id = created.get("file") or created.get("token")
        if not file_id:
            raise TenableError(f"Respuesta de exportacion inesperada: {created}")

        deadline = time.time() + timeout
        while time.time() < deadline:
            status = self.request("GET", f"/scans/{scan_id}/export/{file_id}/status").get("status")
            if status == "READY":
                return self.request("GET", f"/scans/{scan_id}/export/{file_id}/download",
                                    as_json=False)
            if status in {"ERROR", "FAILED"}:
                raise TenableError(f"Exportacion fallida con estado {status}")
            time.sleep(poll_seconds)

        raise TenableError("Timeout esperando la exportacion del .nessus")

    def wait(self, scan_id: int, poll_seconds: int = 15, timeout: int = 3600) -> str:
        deadline = time.time() + timeout
        while time.time() < deadline:
            info = self.scan_info(scan_id).get("info", {})
            status = info.get("status", "unknown")
            print(f"    estado: {status}", file=sys.stderr)
            if status in TERMINAL_STATES:
                return status
            time.sleep(poll_seconds)
        raise TenableError("Timeout esperando el escaneo")


# --------------------------------------------------------------------------- #
# Resumen del .nessus
# --------------------------------------------------------------------------- #

def _strip_namespaces(root: ET.Element) -> None:
    for element in root.iter():
        if isinstance(element.tag, str) and "}" in element.tag:
            element.tag = element.tag.split("}", 1)[1]


def parse_nessus(path: Path) -> list[dict]:
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        raise TenableError(f"{path} no es un .nessus valido: {exc}")

    root = tree.getroot()
    _strip_namespaces(root)

    rows: list[dict] = []
    for host in root.iter("ReportHost"):
        ip = fqdn = ""
        for tag in host.findall("HostProperties/tag"):
            if tag.get("name") == "host-ip":
                ip = (tag.text or "").strip()
            elif tag.get("name") == "host-fqdn":
                fqdn = (tag.text or "").strip()

        for item in host.findall("ReportItem"):
            try:
                severity = int(item.get("severity", "0"))
            except ValueError:
                severity = 0
            rows.append({
                "host": ip or fqdn or host.get("name", "?"),
                "fqdn": fqdn,
                "port": item.get("port", ""),
                "protocol": item.get("protocol", ""),
                "svc": item.get("svc_name", ""),
                "plugin_id": item.get("pluginID", ""),
                "plugin": item.get("pluginName", ""),
                "family": item.get("pluginFamily", ""),
                "severity": severity,
                "severity_label": SEVERITY.get(severity, "?"),
            })
    return rows


def render_summary(rows: list[dict], title: str = "Bifrost") -> str:
    lines: list[str] = [f"# Hallazgos - {title}", ""]

    if not rows:
        lines.append("_Sin hallazgos en el export._")
        return "\n".join(lines)

    hosts = sorted({r["host"] for r in rows})
    counts = {s: sum(1 for r in rows if r["severity"] == s) for s in (4, 3, 2, 1, 0)}

    lines.append(f"Hosts: **{len(hosts)}** | Hallazgos: **{len(rows)}**")
    lines.append("")
    lines.append("| Critico | Alto | Medio | Bajo | Info |")
    lines.append("|---|---|---|---|---|")
    lines.append("| {4} | {3} | {2} | {1} | {0} |".format(
        counts[0], counts[1], counts[2], counts[3], counts[4]))
    lines.append("")

    lines.append("## Por host")
    lines.append("")
    lines.append("| Host | Critico | Alto | Medio | Total |")
    lines.append("|---|---|---|---|---|")
    for host in hosts:
        host_rows = [r for r in rows if r["host"] == host]
        lines.append("| {0} | {1} | {2} | {3} | {4} |".format(
            host,
            sum(1 for r in host_rows if r["severity"] == 4),
            sum(1 for r in host_rows if r["severity"] == 3),
            sum(1 for r in host_rows if r["severity"] == 2),
            len(host_rows)))
    lines.append("")

    lines.append("## Hallazgos (Alto y Critico)")
    lines.append("")
    lines.append("| Sev | Host | Puerto | Plugin | Hallazgo |")
    lines.append("|---|---|---|---|---|")
    for row in sorted(rows, key=lambda r: (-r["severity"], r["host"], r["plugin"])):
        if row["severity"] < 3:
            continue
        port = f"{row['port']}/{row['protocol']}" if row["port"] else "-"
        name = row["plugin"].replace("|", "\\|")
        lines.append(f"| {row['severity_label']} | {row['host']} | {port} | "
                     f"{row['plugin_id']} | {name} |")

    return "\n".join(lines)


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def load_keys(args) -> tuple[str, str]:
    access = args.access_key or os.environ.get("TIO_ACCESS_KEY")
    secret = args.secret_key or os.environ.get("TIO_SECRET_KEY")
    if access and secret:
        return access, secret

    keys_file = Path(args.keys_file).expanduser() if args.keys_file else default_keys_file()
    if keys_file.is_file():
        try:
            data = json.loads(keys_file.read_text(encoding="utf-8"))
            return data["access_key"], data["secret_key"]
        except (KeyError, ValueError) as exc:
            raise TenableError(f"{keys_file} mal formado: {exc}")

    raise TenableError(
        "Sin credenciales. Usa --access-key/--secret-key, TIO_ACCESS_KEY/TIO_SECRET_KEY "
        f"o crea {keys_file} con {{\"access_key\": \"...\", \"secret_key\": \"...\"}}")


def cmd_list(client: Tenable) -> None:
    for scan in client.scans():
        print(f"  id={scan.get('id'):<6} status={scan.get('status', '?'):<12} {scan.get('name', '')}")


def cmd_policies(client: Tenable) -> None:
    for policy in client.policies():
        print(f"  uuid={policy.get('uuid')}  {policy.get('name')}")


def cmd_scanners(client: Tenable) -> None:
    for scanner in client.scanners():
        print(f"  id={scanner.get('id'):<4} {scanner.get('name'):<30} "
              f"status={scanner.get('status', '?')}  {scanner.get('platform', '')}")


def cmd_summary(args) -> None:
    path = Path(args.file)
    if not path.is_file():
        raise TenableError(f"No existe {path}")
    rows = parse_nessus(path)

    if args.plugin:
        wanted = {p.strip() for p in args.plugin.split(",")}
        rows = [r for r in rows if r["plugin_id"] in wanted]
        print(f"Filtrado a plugins {sorted(wanted)}: {len(rows)} hallazgo(s)")

    markdown = render_summary(rows, title=args.title)
    if args.out:
        out_path = Path(args.out)
        out_path.parent.mkdir(parents=True, exist_ok=True)
        out_path.write_text(markdown + "\n", encoding="utf-8")
        print(f"Resumen escrito en {out_path}")
    else:
        print(markdown)


def cmd_show_config(args) -> None:
    if not LAB:
        print("No se encontro config/lab.env. Define BIFROST_CONFIG=/ruta/lab.env.")
        return

    print(f"Configuracion: {LAB.get('__PATH__')}")
    masked = ("PASS", "SECRET", "_API_KEY")
    for key in sorted(k for k in LAB if not k.startswith("__")):
        value = "******" if any(m in key for m in masked) else LAB[key]
        print(f"  {key:<30} {value}")

    print(f"  {'objetivos (resueltos)':<30} {default_targets()}")
    print(f"  {'politica':<30} {LAB.get('BIFROST_TENABLE_POLICY', '')}")
    print(f"  {'keys file':<30} {default_keys_file()}")


def cmd_run(client: Tenable, args) -> None:
    policy_name = args.policy or LAB.get("BIFROST_TENABLE_POLICY")
    targets = args.targets or default_targets()

    if not targets:
        raise TenableError(
            "Sin objetivos: define BIFROST_IP_* en config/lab.env o pasa --targets")

    if args.policy_uuid:
        policy_uuid = args.policy_uuid
    elif policy_name:
        policy = client.find_policy(policy_name)
        policy_uuid = policy["uuid"]
        print(f"Politica: {policy.get('name')} ({policy_uuid})")
    else:
        raise TenableError("Indica --policy o --policy-uuid (o define BIFROST_TENABLE_POLICY)")

    created = client.create_scan(
        policy_uuid=policy_uuid,
        name=args.name,
        targets=targets,
        scanner_id=args.scanner_id,
        description=args.description,
    )
    scan_id = created.get("id")
    print(f"Escaneo creado: id={scan_id} nombre='{args.name}'")

    client.launch(scan_id)
    print("Escaneo lanzado. Esperando resultados...")

    status = client.wait(scan_id, poll_seconds=args.poll, timeout=args.timeout)
    print(f"Estado final: {status}")

    if status != "completed":
        raise TenableError(f"El escaneo termino en '{status}', no hay export que valga")

    payload = client.export_nessus(scan_id)
    out_path = Path(args.out or "out/scan.nessus")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(payload)
    print(f"Export escrito: {out_path} ({len(payload) / 1024:.0f} KB)")

    rows = parse_nessus(out_path)
    summary_path = out_path.with_suffix(".md")
    summary_path.write_text(render_summary(rows, title=args.name) + "\n", encoding="utf-8")
    print(f"Resumen: {summary_path}")

    if args.cleanup:
        client.delete_scan(scan_id)
        print(f"Escaneo {scan_id} eliminado")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Bifrost - Tenable One / Vulnerability Management desde la terminal",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Acciones: list | policies | scanners | run | summary")

    parser.add_argument("--action", required=True,
                        choices=["list", "policies", "scanners", "run", "summary", "config"])
    parser.add_argument("--access-key", help="Access key (o TIO_ACCESS_KEY)")
    parser.add_argument("--secret-key", help="Secret key (o TIO_SECRET_KEY)")
    parser.add_argument("--keys-file", help="Ruta del JSON de claves (default: config o ~/.bifrost/)")
    parser.add_argument("--base-url", help="URL base de Tenable (default: config/lab.env)")
    parser.add_argument("--verbose", action="store_true")

    group = parser.add_argument_group("accion run")
    group.add_argument("--policy", help="Nombre exacto de la politica (default: config/lab.env)")
    group.add_argument("--policy-uuid")
    group.add_argument("--name", default="Bifrost pre-demo")
    group.add_argument("--description", default="Bifrost lab scan")
    group.add_argument("--targets", help="Objetivos (default: IPs de config/lab.env)")
    group.add_argument("--scanner-id", type=int)
    group.add_argument("--out", help="Ruta del .nessus exportado (default: out/scan.nessus)")
    group.add_argument("--poll", type=int, default=15)
    group.add_argument("--timeout", type=int, default=3600)
    group.add_argument("--cleanup", action="store_true")

    group = parser.add_argument_group("accion summary")
    group.add_argument("--file", default="out/scan.nessus")
    group.add_argument("--plugin", help="IDs de plugin separados por coma, p.ej. 155999")
    group.add_argument("--title", default="Bifrost")

    args = parser.parse_args()

    try:
        if args.action == "config":
            cmd_show_config(args)
            return 0

        if args.action in {"list", "policies", "scanners", "run"}:
            access, secret = load_keys(args)
            client = Tenable(access, secret, args.base_url, verbose=args.verbose)
        else:
            client = None  # type: ignore[assignment]

        if args.action == "list":
            cmd_list(client)
        elif args.action == "policies":
            cmd_policies(client)
        elif args.action == "scanners":
            cmd_scanners(client)
        elif args.action == "summary":
            cmd_summary(args)
        elif args.action == "run":
            cmd_run(client, args)
    except TenableError as exc:
        print(f"\nERROR: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("\nInterrumpido.", file=sys.stderr)
        return 130

    return 0


if __name__ == "__main__":
    sys.exit(main())
