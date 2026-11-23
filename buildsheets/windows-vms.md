# Buildsheet — VMs Windows (dc01, ws01)

| VM | OS | vCPU | RAM | Disco | IP (de `config/lab.env`) |
|---|---|---|---|---|---|
| dc01 | Windows Server 2019 (Desktop Experience) | 2 | 3 GB | 60 GB thin | `BIFROST_IP_DC` |
| ws01 | Windows 10 Pro 22H2 | 2 | 3 GB | 60 GB thin | `BIFROST_IP_WS` |

> **Dónde se ejecuta:** `host` = equipo de control · `VMware GUI` = Workstation ·
> `dc01`/`ws01` = PowerShell dentro de esa VM (como administrador) · `kali` = sesión SSH en la VM atacante ·
> `host → dc01` = copiar archivos del host a la VM.

Los scripts `windows/*.ps1` toman los valores de `config/lab.env` cuando el repo
está copiado a la VM, o de sus parámetros si no. No hay IPs ni contraseñas
incrustadas en el código.

ISO:

- Server 2019 (evaluación 180 días): <https://www.microsoft.com/en-us/evalcenter/download-windows-server-2019>
- Windows 10: <https://www.microsoft.com/en-us/evalcenter/download-windows-10-enterprise>

> **No instales el "Easy Install" de VMware.** El autounattend que inyecta te deja
> una cuenta rara y sin control. Instalación manual, una vez.

---

## dc01

### 1. Instalación

**En:** `VMware GUI` (crear/arrancar) + consola de `dc01` (instalar el SO).

1. VM nueva → *I will install the operating system later* → Microsoft Windows → **Windows Server 2019**.
2. BIOS, 2 vCPU, 3 GB, red **Custom VMnet1**, disco 60 GB thin.
3. Instala *Windows Server 2019 Standard (Desktop Experience)*.
4. Cuenta `Administrator` con una contraseña del lab (no la de la empresa).
5. Instala **VMware Tools** desde el menú *VM → Install VMware Tools*
   (necesario para `vmrun` y para el reloj, que afecta a Kerberos).

### 2. Ajustes previos al script

**En:** `dc01` (PowerShell como administrador).

- Apaga el cortafuegos del perfil de dominio **no**, déjalo: el lab lo necesita abierto
  para SMB/HTTP. Para evitarte ruido, desactiva el firewall de Windows en los tres perfiles:

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
```

- Desactiva la suspensión y el *fast startup* (si no, los snapshots despiertan raros):

```powershell
powercfg /h off
```

### 3. Ejecutar el script

**En:** `host → dc01` (copiar) y luego `dc01` (ejecutar).

Copia al DC la carpeta `config\` **y** `windows\`, respetando la estructura:

```
C:\Bifrost\config\lab.env
C:\Bifrost\config\lab.ps1
C:\Bifrost\windows\dc01-promote.ps1
C:\Bifrost\windows\adcs-esc8.ps1
```

Así el script resuelve `..\config\lab.ps1` y toma dominio, IPs y contraseñas de la
configuración. Si no copias `config\`, usa parámetros explícitos
(`.\dc01-promote.ps1 -DomainName lab.local -StaticIp 10.0.0.30 ...`) y avisará de
que no encontró el archivo.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force
cd C:\Bifrost
.\dc01-promote.ps1
```

El script hace **dos fases**:

| Fase | Qué hace | Termina |
|---|---|---|
| 1 | red estática, renombra a DC01, instala AD DS, promueve el bosque | reinicia |
| 2 | OU, usuarios, carpeta `C:\Corp\Finanzas`, ajustes de lab | imprime resumen |

Si pide reinicio por el renombrado, reinicia y **vuelve a lanzarlo**: detecta el estado.

Al final verifica — **en `dc01`**:

```powershell
Get-ADDomain | Select-Object Name, DomainMode
Get-ADUser -Filter * | Select-Object Name, SamAccountName
Get-SmbShare
```

### 4. ADCS con ESC8

**En:** `dc01`.

```powershell
.\adcs-esc8.ps1
```

Si pide reinicio, reinicia y relanza. Al terminar comprueba tú mismo la pieza clave:

```powershell
Invoke-WebRequest http://localhost/certsrv/ -UseBasicParsing -ErrorAction SilentlyContinue
# 401 sin credenciales = correcto: existe, pide NTLM, NO exige TLS
```

Y desde kali — **en `kali`**:

```bash
source ~/bifrost/env.sh
curl -sI "http://$TARGET_DC/certsrv/" | head -n 5
```

Si ves `302` hacia `https://`, la configuración de `sslFlags` no quedó: repite la sección 4
del script (en `dc01`).

---

## ws01

### 1. Instalación

**En:** `VMware GUI` + consola de `ws01`.

Igual que dc01 pero Windows 10 Pro, con `BIFROST_IP_WS` como IP y `BIFROST_IP_DC`
como DNS.

### 2. Ajustes

**En:** `ws01`.

```powershell
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
powercfg /h off
```

### 3. Script

**En:** `host → ws01` (copiar) y luego `ws01` (ejecutar).

Copia `config\` y `windows\` a `C:\Bifrost\` (igual que en dc01) y:

```powershell
.\ws01-join.ps1
```

Hace: red estática → une al dominio (reinicia) → siembra la carpeta compartida con
credenciales en claro y una tarea programada que corre como `svc_backup`.

La contraseña del administrador del dominio sale de `BIFROST_DOMAIN_ADMIN_PASS`. Si
falta, el script la pide por consola.

### 4. Verificación

**En:** `ws01`.

```powershell
(Get-CimInstance Win32_ComputerSystem).Domain      # BIFROST_DOMAIN
Get-SmbShare                                        # Compartido
Get-ScheduledTask -TaskName CorpBackupAgent
```

Desde kali, sin escribir credenciales a mano — **en `kali`**:

```bash
source ~/bifrost/env.sh
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
```

---

## Notas de laboratorio

- **Defender** queda desactivado por los scripts (en `dc01` y `ws01`). Es correcto en una VM aislada; si la
  reutilizas para otra cosa, reactívalo: `Set-MpPreference -DisableRealtimeMonitoring $false`.
- **Reloj**: si `dc01` y `ws01` se desfasan más de 5 minutos, Kerberos falla y el puente 4
  se cae sin explicación. Verifica con `w32tm /query /status` en ambos.
- **Snapshots**: el disco thin de Windows crece rápido con snapshots. Revisa el espacio antes
  de cada ensayo.
- **No actives Windows Update** en ninguna de las dos. La premisa de ESC8 es configuración,
  no parche, pero un update puede tocar IIS y romperte el `certsrv`.
