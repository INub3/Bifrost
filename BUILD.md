# BUILD — Guía de construcción end-to-end

Esta es la ruta **ordenada y con gates**: cada fase termina en una comprobación
que, si falla, impide seguir. Los detalles finos de cada VM viven en
[buildsheets/](buildsheets/); aquí está el orden, los comandos y los criterios de
aceptación.

> Todos los valores (IPs, dominio, puertos, credenciales) salen de
> [config/lab.env](config/lab.env). Esta guía muestra los valores **por defecto**;
> si cambias la configuración, ajusta las IPs que aparecen aquí.

---

## Dónde se ejecuta cada cosa

Cada bloque de comandos de esta guía indica el host en el que se teclea. Leyenda:

| Etiqueta | Significado |
|---|---|
| `host` | **Equipo de control**: donde vive el repo. Aquí corren `bifrost.*`, `apply.sh`, `tenable_scan.py` y `check-consistency.sh`. |
| `kali` · `scanner` · `web01` · `app02` · `dc01` · `ws01` | **Dentro de esa VM** (consola directa o sesión SSH). |
| `VMware GUI` | Virtual Network Editor / Workstation — solo existe en el `host`. |
| `Tenable UI` | Navegador con la consola de Tenable One. |
| `host → kali` | Comando **tecleado en `host`**, ejecutado en `kali` vía SSH. |

---

## 0. Qué construyes

| VM | OS | IP | Papel en la cadena |
|---|---|---|---|
| kali | Kali | `BIFROST_IP_KALI` | atacante + control de provisioning |
| scanner | Ubuntu + Nessus | `BIFROST_IP_SCANNER` | enlazado a Tenable One |
| web01 | Ubuntu 22.04 | `BIFROST_IP_WEB` | Solr 8.11 → Log4Shell |
| app02 | Ubuntu 20.04 | `BIFROST_IP_APP` | PwnKit / sudo inseguro |
| dc01 | Server 2019 | `BIFROST_IP_DC` | AD DS + ADCS → ESC8 |
| ws01 | Windows 10 | `BIFROST_IP_WS` | credenciales señuelo |

Regla de aislamiento: solo el scanner tiene NIC adicional (NAT) para hablar con la
nube. Las demás la usan **únicamente durante la construcción** y se la retiran
antes del snapshot `clean`.

---

## 1. Material previo

**En:** `host` (navegador).

Descarga estas ISOs antes de empezar (los enlaces están en cada buildsheet):

| ISO | Para |
|---|---|
| Kali installer | `kali` |
| Ubuntu Server 22.04.5 | `web01`, `scanner` |
| Ubuntu Server 20.04.6 | `app02` |
| Windows Server 2019 (eval) | `dc01` |
| Windows 10 (eval) | `ws01` |
| Nessus scanner OVA | `scanner` (opción A) |

---

## 2. Fase 0 — Preparar el host

**En:** `host` — el paso 1 además toca la `VMware GUI`.

1. Red host-only VMnet1: **`VMware GUI`** → *Virtual Network Editor* (como administrador) → *Add Network* → VMnet1 → *Host-only* → subred = `BIFROST_NETWORK/PREFIX`, sin DHCP.
2. Ajustar `config/lab.env` si cambias algo (ruta de VMs, red, contraseñas): **`host`**.
3. Preflight: **`host`**.

**En:** `host`

```bash
.\bifrost.ps1 preflight      # Windows
./bifrost.sh preflight       # Linux/macOS
```

**Gate 0:** `VEREDICTO: entorno listo` (o "listo con N advertencias"). Si dice
`bloqueante`, se corrige antes de crear la primera VM.

**En:** `host`

```bash
# Y el contrato de estandarización, para confirmar que no hay valores sueltos:
bash tests/check-consistency.sh
```

### 2.1 Qué host elegir

Los scripts existen para las dos plataformas (`bifrost.ps1` y `bifrost.sh`), así que
la decisión no bloquea nada: afecta cuánta fricción tienes al construir.

| Host | Ventaja | Coste |
|---|---|---|
| **Linux (Ubuntu LTS)** — recomendado | bash nativo, sin MSYS, sin antivirus compitiendo con los `.vmdk` | instalar Workstation Pro a mano |
| Windows | suele ser lo que ya tienes; `bifrost.ps1` cubre todo | git-bash, `core.autocrlf`, exclusiones de Defender |
| macOS (Fusion) | bash nativo | **Apple Silicon no corre `dc01`/`ws01`** (x86): solo Mac Intel |

En Windows conviene excluir la carpeta de VMs del antivirus
(`Add-MpPreference -ExclusionPath $env:BIFROST_VM_DIR`) y no activar WSL2/Hyper-V
junto a Workstation.

---

## 3. Fase 1 — kali (primero siempre)

`kali` es el atacante y el punto desde el que se lanza `provision/apply.sh`, así
que va primero.

1. Crear VM según [buildsheets/linux-vms.md](buildsheets/linux-vms.md), con **NIC NAT activa** durante la construcción: **`VMware GUI`**.
2. Instalar Kali, usuario `kali`: **consola de `kali`**.
3. `open-vm-tools` + IP estática `BIFROST_IP_KALI`: **consola de `kali`**.
4. Provisionar: **`host`**.

**En:** `host`

```bash
bash provision/apply.sh kali
```

**Gate 1:** **`host → kali`** (SSH)

```bash
ssh kali@192.168.56.66 'source ~/bifrost/env.sh && echo $TARGET_DC'
# debe imprimir 192.168.56.30 (BIFROST_IP_DC)
```

---

## 4. Fase 2 — scanner (Tenable One)

Sigue [buildsheets/scanner-tenable-one.md](buildsheets/scanner-tenable-one.md):

1. Despliega el OVA de Nessus o Ubuntu + Nessus: **`VMware GUI`** + **consola de `scanner`**.
2. **Dos NICs**: VMnet1 (`.10`) + NAT (enlace a la nube). Esta NAT **se queda** en el scanner: **`VMware GUI`**.
3. Enlaza con la Linking Key de Tenable One: **`Tenable UI`** (genera la key) + **consola de `scanner`** (`nessuscli managed link`).

**Gate 2:** **`host`**

```bash
python tenable/tenable_scan.py --action scanners
# debe listar el scanner con status=connected
```

**Gate 2b** (política y API keys, mismo buildsheet): **`Tenable UI`** para crearlas, **`host`** para verificarlas.

```bash
python tenable/tenable_scan.py --action policies   # debe existir Bifrost-Demo
```

Si el scanner no queda `Connected`, no tiene sentido seguir: es el único camino
para que Tenable One vea el laboratorio.

---

## 5. Fase 3 — web01 y app02

Ambas según [buildsheets/linux-vms.md](buildsheets/linux-vms.md), con **NAT activa
solo para `web01`** (`app02` no necesita internet, así que puede nacer aislada).

**En:** `host`

```bash
bash provision/apply.sh web01
bash provision/apply.sh app02
```

**Gate 3 (web01):** **`host`** (curl hacia `web01`; también vale desde `kali`)

```bash
curl -s "http://192.168.56.20:8983/solr/admin/info/system?wt=json" | head -c 300
# debe contener "solr-spec-version":"8.11.0"
```

**Gate 4 (app02):** **`host → app02`** (SSH)

```bash
ssh svc_app@192.168.56.21 'sudo -l'
# debe listar (root) NOPASSWD: /usr/bin/less, /usr/bin/tail
```

**Gate 5 (cadena Log4Shell completa):** **`host → kali`** (SSH)

```bash
scp -r . kali@192.168.56.66:~/bifrost/
ssh kali@192.168.56.66 'cd ~/bifrost/exploits/log4shell && chmod +x *.sh && ./build.sh && ./selftest.sh'
# debe terminar en: RESULTADO: cadena completa OK
```

> El Gate 5 es el más importante del laboratorio: demuestra, sin escenario, que el
> objetivo carga y ejecuta código remoto. Si no pasa aquí, no pasará en vivo.

---

## 6. Fase 4 — dc01 y ws01

Sigue [buildsheets/windows-vms.md](buildsheets/windows-vms.md). Copia `config\` y
`windows\` a `C:\Bifrost\` en cada VM: **`host → dc01`** y **`host → ws01`**
(carpeta compartida, arrastrar en Workstation o USB).

**dc01** (dos pasadas, reiniciando entre medias): **consola de `dc01`** (PowerShell como administrador)

```powershell
.\dc01-promote.ps1     # fase 1 -> reinicia
.\dc01-promote.ps1     # fase 2
.\adcs-esc8.ps1        # ADCS con ESC8
```

**ws01:** **consola de `ws01`** (PowerShell como administrador)

```powershell
.\ws01-join.ps1        # reinicia y relanzar si pide union
```

**Gate 6 (dc01):** **`dc01`**

```powershell
Get-ADDomain | Select-Object Name
# corp.local
Invoke-WebRequest http://localhost/certsrv/ -UseBasicParsing -ErrorAction SilentlyContinue
# 401 sin credenciales = correcto: existe, pide NTLM, NO exige TLS
```

**Gate 7 (ws01):** **`ws01`**

```powershell
(Get-CimInstance Win32_ComputerSystem).Domain   # corp.local
Get-SmbShare                                    # Compartido
```

Desde kali, sin escribir credenciales a mano: **`kali`** (sesión SSH)

```bash
source ~/bifrost/env.sh
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
```

---

## 7. Fase 5 — Verificación integral de la cadena

Antes de ensayar nada, valida los cuatro puentes por separado:

| Puente | Verificación | Dónde |
|---|---|---|
| 1 Log4Shell | `selftest.sh` → OK | `kali` (lanzado desde `host`) |
| 2 privesc | `sudo -l` y diagnóstico de CVE | `app02` |
| 3 movimiento lateral | `nxc smb --shares` contra ws01 | `kali` |
| 4 ESC8 | `certsrv` responde 401 sobre HTTP | `dc01` |

La cadena ESC8 completa (PetitPotam → relay → certipy → DCSync) está en
[exploits/esc8/README.md](exploits/esc8/README.md) y corre entera en **`kali`**.
**Ensáyala una vez** en esta fase, no en el escenario.

---

## 8. Fase 6 — Snapshots y ensayo

1. **Retira la NIC NAT** de `kali` y `web01` (ya no la necesitan): **`VMware GUI`**.
2. Confirma que no hay salida a internet desde los objetivos: **`host → kali`**

```bash
ssh kali@192.168.56.66 'curl -s -o /dev/null -w "%{http_code}" --max-time 3 https://cloud.tenable.com'
# debe quedar en timeout / 000
```

3. Snapshots: **`host`**

```bash
.\bifrost.ps1 snapshot all clean      # estado base
.\bifrost.ps1 snapshot all pre-demo   # estado de ensayo (tras el escaneo pre-lanzado)
```

4. Prueba de humo del escaneo completo: **`host`**

```bash
python tenable/tenable_scan.py --action run --name "Bifrost smoke" --out out/smoke.nessus
# debe terminar en completed y out/smoke.md con un Critico en BIFROST_IP_WEB
```

5. Sigue [runbook/DEMO-RUNBOOK.md](runbook/DEMO-RUNBOOK.md) para los ensayos (mezcla `host`, `kali` y `Tenable UI`).

**Gate final:** `.\bifrost.ps1 reset all` (**`host`**) deja todo idéntico a
`pre-demo` en menos de 60 segundos, y `selftest.sh` (**`kali`**) sigue en OK
después del reset.

---

## 9. Gates maestro (resumen)

| # | Dónde | Gate | Comando | Señal de éxito |
|---|---|---|---|---|
| 0 | `host` | Host listo | `preflight` | `entorno listo` |
| — | `host` | Contrato de valores | `check-consistency.sh` | `contrato de estandarizacion OK` |
| 1 | `host → kali` | kali provisionado | `echo $TARGET_DC` | IP del DC |
| 2 | `host` | Scanner enlazado | `--action scanners` | `connected` |
| 3 | `host` | Solr vulnerable | `curl .../system` | `8.11.0` |
| 4 | `host → app02` | app02 escalable | `sudo -l` | `less, tail NOPASSWD` |
| 5 | `host → kali` | Log4Shell RCE | `selftest.sh` | `cadena completa OK` |
| 6 | `dc01` | DC + ADCS | `Get-ADDomain` + `certsrv` 401 | dominio + HTTP sin TLS |
| 7 | `ws01` | ws01 en dominio | `nxc smb --shares` | `Compartido` listado |
| 8 | `host` | Escaneo | `--action run` | `completed` + Crítico |
| 9 | `host` | Reset | `reset all` | `selftest` sigue OK |

---

## 10. Troubleshooting rápido

| Dónde | Síntoma | Causa más probable | Arreglo |
|---|---|---|---|
| `host` | `preflight` dice `bloqueante` por red | VMnet1 no existe | Virtual Network Editor → Add Network |
| `host` | `apply.sh` no conecta | VM apagada / IP mal / SSH sin clave | `.\bifrost.ps1 ip <vm>`, `ping` |
| `web01` | `web01-solr.sh` se detiene con "sin internet" | falta la NIC NAT de construcción | activarla, reejecutar, retirar antes de `clean` |
| `kali` | `selftest.sh` FALLO | `trustURLCodebase` o ruta de red | el script imprime 4 pasos de diagnóstico |
| `scanner` | Scanner `disconnected` | NIC NAT del scanner caída | `curl https://cloud.tenable.com` desde el scanner |
| `host` | `--action run` sin hallazgo Crítico | política sin credenciales / familia de plugins | revisar `scanner-tenable-one.md` §política |
| `kali` | ESC8: relay no recibe | `certsrv` redirige a HTTPS | repetir sección 4 de `adcs-esc8.ps1` (en `dc01`) |
| `dc01`/`ws01` | Kerberos falla en el puente 4 | reloj desincronizado | `w32tm /resync` en dc01 y ws01 |

---

## Duración estimada

| Fase | Tiempo |
|---|---|
| Descargas + Fase 0 | 1–2 h |
| Fase 1–3 (Linux) | 2–3 h (más `mvn`/`apt` la primera vez) |
| Fase 4 (Windows) | 2–3 h (reinicios de por medio) |
| Fase 5–6 (verificación + snapshots) | 1–2 h |
| **Total primera vez** | **~1 día con calma** |

La segunda vez (reconstrucción o nueva red) es cuestión de editar `config/lab.env`
y relanzar `apply.sh` sobre máquinas ya instaladas.
