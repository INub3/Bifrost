# Bifrost

**Laboratorio de demo:** *Del hallazgo al dominio — lo que Tenable reporta y el
red team demuestra.* Tenable One (Vulnerability Management + Attack Path Analysis)
· VMware Workstation Pro 17.x / Fusion 13.x · ESC8 como final.

**Versión:** v1.1.1 — host como atacante, web01 concentra Log4Shell + PwnKit,
guía única. Historial en [CHANGELOG.md](CHANGELOG.md).

---

## Empezar aquí

Todo está en **una sola guía maestra, secuencial**: [GUIDE.md](GUIDE.md).

Cubre, en orden: arquitectura → requisitos → configuración → construcción paso a
paso (host → scanner → web01 → dc01 → ws01) → la cadena de ataque → el directo →
contingencias → troubleshooting → catálogo de valores.

---

## Arquitectura (resumen)

```
VMnet1 host-only 10.10.0.0/24 (sin internet)
  .66  host (ParrotOS)   <- atacante y control
  .10  scanner           Nessus enlazado a Tenable One
  .20  web01             Ubuntu 20.04: Solr 8.11 (Log4Shell) + PwnKit + credenciales
  .30  dc01              AD DS + ADCS (ESC8)
  .31  ws01              credenciales señuelo
```

Cadena: **Log4Shell → root (PwnKit) → lateral (svc_backup) → ESC8 → Domain Admin**.

---

## Mapa de archivos

| Ruta | Qué es |
|---|---|
| [GUIDE.md](GUIDE.md) | **Guía maestra** (construcción + explotación, secuencial) |
| [ATTACK.md](ATTACK.md) | **Guion de ataque comando a comando** (lógica del red team + speech + contraste con Nessus) |
| [config/lab.env](config/lab.env) | Única fuente de verdad (IPs, dominio, puertos, credenciales) |
| `config/lab.sh` / `config/lab.ps1` | Cargadores de la configuración (bash / PowerShell) |
| `bifrost.sh` / `bifrost.ps1` | Ciclo de vida: `preflight` · `config` · `status` · `snapshot` · `reset` · `scan` |
| `provision/` | `attacker-tools.sh` (host) · `apply.sh` + `web01-solr.sh` |
| `windows/` | `dc01-promote.ps1` · `adcs-esc8.ps1` · `ws01-join.ps1` |
| `exploits/` | Cadena Log4Shell (build/ldap-serve/selftest) |
| `tenable/tenable_scan.py` | API de Tenable One: crea, lanza, exporta `.nessus`, resume a Markdown |
| `tests/` | `check-consistency.sh` (contrato de valores) + fixture |
| [CHANGELOG.md](CHANGELOG.md) | Historial de versiones |

---

## Reglas de seguridad

- Red **host-only, sin NAT** en los objetivos. Solo el scanner tiene NAT (hacia `cloud.tenable.com`).
- Dominio falso `corp.local`, usuarios y señuelos inventados. Sin datos reales.
- **Nunca** reutilizar credenciales reales de la empresa.
- Snapshots `clean` y `pre-demo` antes de cada ensayo.
- Todo el contenido es para infraestructura propia y autorizada.
