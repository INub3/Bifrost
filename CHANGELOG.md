# Changelog

Historial de versiones del laboratorio Bifrost.
Formato basado en [Keep a Changelog](https://keepachangelog.com/es-ES/1.1.0/) ·
versionado semántico.

## [1.1.1] — 2026-11-24

Correcciones de build y de documentación detectadas en la puesta a punto real
del laboratorio.

### Corregido

- **Log4Shell**: el disparo `curl` se comía las llaves de `${jndi:...}` por el
  globbing de URL. Se añade `-g` en `selftest.sh`, `ldap-serve.sh` y `GUIDE.md`.
  Además, `selftest.sh`/`ldap-serve.sh` matan el `http.server` real (`exec`) para
  no dejar huérfanos en el 8000.
- **dc01**: `Add-ADGroupMember` lanzaba un error terminante si `svc_backup` ya
  era miembro y abortaba la fase 2 antes de la corona. Se elimina la llamada
  redundante.
- **dc01/ADCS**: el chequeo de Web Enrollment miraba `CertEnroll` (lo crea el
  CA) y se saltaba la instalación; ahora comprueba la app `/CertSrv` y resetea
  el role si quedó a medias.
- **ws01**: re-ejecutar el script fallaba con `Instance DefaultGateway already
  exists`; se borra la ruta `0.0.0.0/0` antes de recrear el gateway. El share
  usa el SID de Everyone (funciona en Windows en español) y abre el 445.
- **web01**: `web01-solr.sh` avisa del kernel con mitigación *argv=0* (PwnKit
  necesita el `5.4.0-26`) y del cierre de SSH por ufw.
- **host**: `attacker-tools.sh` permite los puertos del laboratorio en ufw,
  clona PetitPotam y deja los nombres `ntlmrelayx.py`/`secretsdump.py`/
  `psexec.py` para impacket 0.12.
- **bifrost.sh**: `snapshot` acepta etiqueta (`clean`/`pre-demo`); antes siempre
  usaba `BIFROST_SNAPSHOT`.

### Documentación

- `GUIDE.md`: pasos de PwnKit/kernel, ADCS, ws01, escaneo por UI, snapshots y
  troubleshooting ampliados con los fallos reales.
- `.gitignore`: temporales de SO/editor, artefactos (`*.zip`, `*.iso`,
  `*.pcap`, certificados) y logs.

## [1.1.0] — 2026-11-23

Reorganización del laboratorio para simplificar la implementación.

### Cambiado

- **El host es el atacante**: se elimina la VM Kali. El host (ParrotOS) actúa de
  atacante a través de la interfaz host-only (VMnet1). `BIFROST_IP_KALI` pasa a
  `BIFROST_IP_ATTACKER` y `provision/kali-tools.sh` se reemplaza por
  `provision/attacker-tools.sh` (se ejecuta localmente, sin SSH).
- **web01 absorbe app02**: una sola VM Linux concentra Log4Shell, PwnKit y las
  credenciales de dominio. web01 pasa a Ubuntu 20.04 (necesita `policykit 0.105`).
- **Cadena de 3 objetivos**: Log4Shell → PwnKit (root) → lateral (`svc_backup`) →
  ESC8. Se eliminan `BIFROST_IP_APP` y el objetivo app02 del escaneo.

### Documentación

- **Guía maestra única** (`GUIDE.md`) que centraliza diseño, construcción, cadena
  de ataque, directo y troubleshooting en un solo documento secuencial.
- Se eliminan `BIFROST-LAB.md`, `BUILD.md`, `buildsheets/`, `runbook/`,
  `docs/VALUES.md` y `exploits/esc8/README.md` (contenido absorbido por GUIDE.md).
- `README.md` queda como página de aterrizaje.

## [1.0.0] — 2026-11-22

Primera versión estable. **Desarrollo cerrado**: el laboratorio está listo para
construirse e implementarse. Los ajustes posteriores serán de implementación.

### Añadido

- **Configuración única** (`config/lab.env`) con cargadores para bash
  (`config/lab.sh`), PowerShell (`config/lab.ps1`) y Python (parser interno de
  `tenable_scan.py`). Ningún script repite IPs, puertos ni credenciales.
- **Control del laboratorio**: `bifrost.sh` (Linux/macOS) y `bifrost.ps1`
  (Windows) con `preflight`, `config`, `status`, `start/stop`, `snapshot`,
  `reset`, `ip` y `scan`. Descubrimiento automático de `vmrun`.
- **Buildsheets** de las seis VMs: `kali`, `scanner`, `web01`, `app02`, `dc01` y
  `ws01`, con la anotación de en qué host se ejecuta cada paso.
- **Provisioning Linux** (`provision/apply.sh`) y scripts PowerShell de Windows
  (promover DC, instalar ADCS con ESC8, unir ws01 al dominio).
- **Cadena Log4Shell** completa con autoprueba end-to-end (`selftest.sh`), que
  verifica ejecución remota real antes del escenario.
- **Cadena ESC8** documentada (PetitPotam → relay NTLM → certipy → DCSync).
- **Cliente de Tenable One** (`tenable/tenable_scan.py`): crea, lanza, espera,
  exporta `.nessus` y resume los hallazgos a Markdown.
- **Runbook del directo** minuto a minuto, con matriz de contingencias.
- **Verificador del contrato** (`tests/check-consistency.sh`): configuración
  completa, cero literales en scripts, motores alineados y sin secretos sueltos.
- **Guía de construcción** end-to-end (`BUILD.md`) con gates de verificación y
  elección de host.

### Notas de empaquetado

- `.gitattributes` fuerza **LF**: evita que `core.autocrlf` rompa los `.sh` al
  copiarlos a kali/Linux (`/bin/bash^M: bad interpreter`).
- `.gitignore` excluye VMs, artefactos y **secretos del escenario**
  (`*.pfx`, `*.ccache`, `*.kirbi`, `loot/`), pero versiona el fixture de tests.
- La versión del laboratorio vive en `BIFROST_VERSION` (`config/lab.env`) y la
  muestra `bifrost.* preflight`.
