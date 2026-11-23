# Buildsheet — scanner Tenable One

El scanner es la única VM con **dos interfaces**. Esa es toda la gracia: escanea el
laboratorio por la red aislada y se comunica con Tenable One por la NAT.

> **Dónde se ejecuta:** `host` = equipo de control (donde corre `tenable_scan.py`) ·
> `scanner` = consola/SSH dentro de la VM del scanner · `Tenable UI` = navegador con Tenable One ·
> `VMware GUI` = Workstation (solo en `host`).

| NIC | Red | IP | Para qué |
|---|---|---|---|
| 1 | Custom **VMnet1** | 192.168.56.10 | escanear los objetivos |
| 2 | **NAT (VMnet8)** | DHCP | enlazarse con `cloud.tenable.com` |

Sin la NIC 2 el scanner no aparece *linked*; sin la NIC 1 no ve el lab.

---

## Opción A — OVA oficial de Tenable (recomendada)

1. Entra en <https://www.tenable.com/downloads/nessus-scanners> con tu cuenta de Tenable One: **`Tenable UI`** (o navegador en `host`).
2. Descarga la **Nessus Scanner** para VMware (OVA): **`host`**.
3. VMware Workstation → *File → Open* → selecciona el `.ova` → importa: **`VMware GUI`**.
4. Antes del primer arranque: *Edit settings* → NIC 1 = Custom VMnet1, NIC 2 = NAT: **`VMware GUI`**.
5. Arranca y anota la IP que muestra la consola: **`scanner`**.

El OVA trae el `linking key` como paso de primera ejecución en consola: **`scanner`**.

## Opción B — Ubuntu + Nessus (si el OVA da problemas)

Ubuntu Server 22.04, IP `192.168.56.10`, y luego — **en `scanner`**:

```bash
# paquete Debian de Nessus (pide la descarga en tenable.com/downloads/nessus)
sudo dpkg -i Nessus-*.deb
sudo systemctl enable --now nessusd
```

Interfaz local en `https://192.168.56.10:8834` — se abre en el navegador desde `host`.

---

## Enlazar el scanner a Tenable One

1. Tenable VM → **Settings → Scanners → Add Scanner**: **`Tenable UI`**.
2. Elige **Nessus Scanner** (no "Managed Scanner" genérico): **`Tenable UI`**.
3. Copia la **Linking Key**: **`Tenable UI`**.
4. En la consola del scanner — **`scanner`**:

```bash
sudo nessuscli managed link --key=<LINKING_KEY> --cloud
# si la version no acepta --cloud:
sudo nessuscli managed link --key=<LINKING_KEY> --host=cloud.tenable.com --port=443
```

5. Verifica en **Settings → Scanners**: debe salir `Connected`: **`Tenable UI`**.

> La sintaxis exacta cambia entre versiones. Antes de la charla:
> `nessuscli managed link --help` (**en `scanner`**) y guarda el comando que funcionó en el runbook.
> **No lo descubras en el escenario.**

### Comprobación de conectividad

**En:** `scanner`.

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://cloud.tenable.com   # 200/302/401, no timeout
```

Si falla: la NIC 2 no está en NAT, o el DNS no resuelve. Es el fallo número uno de este montaje.

---

## Política de escaneo

En Tenable VM → **Policies → New Policy → Basic Network Scan**, con el nombre de
`BIFROST_TENABLE_POLICY` (por defecto **`Bifrost-Demo`**): **`Tenable UI`**.

Ajustes que importan para la charla:

| Ajuste | Valor | Por qué |
|---|---|---|
| Scan Type | *Default* | no hace falta "paranoid" |
| **Credentials → SSH** | usuario `bifrost` + sudo | puente 2: sin esto no hay hallazgo de kernel |
| **Credentials → Windows** | `CORP\Administrator` (SMB + WMI) | hallazgos locales en dc01/ws01 |
| Plugins → Web Servers | activado | Log4Shell se detecta por HTTP |
| Discovery | *Port scan: common ports* | 20 minutos, no 2 horas |
| Performance | *Max hosts: 10, Max checks: 5* | suficiente para 4-6 hosts |

El nombre `Bifrost-Demo` es el que consume el script — verificación **en `host`**:

```bash
python tenable/tenable_scan.py --action policies     # confirma que existe
```

Los objetivos del escaneo se derivan de `BIFROST_IP_*`: no hay una lista aparte
que mantener.

---

## API keys

Tenable VM → **Settings → My Account → API Keys → Generate**: **`Tenable UI`**.

Guárdalas fuera del repo — **en `host`**:

```powershell
New-Item -ItemType Directory -Force "$env:USERPROFILE\.bifrost" | Out-Null
@'
{"access_key": "PEGA_AQUI", "secret_key": "PEGA_AQUI"}
'@ | Set-Content "$env:USERPROFILE\.bifrost\tenable.json" -Encoding UTF8
```

```powershell
python tenable\tenable_scan.py --action scanners
```

Debe listar tu scanner en `Connected`. Si esto funciona, el resto del script también.

---

## Prueba de humo antes de cualquier ensayo

**En:** `host`.

```powershell
python tenable\tenable_scan.py --action run --name "Bifrost smoke test" --out out\smoke.nessus
```

Criterio de éxito: termina con `Estado final: completed` y genera `out\smoke.md` con al
menos un hallazgo **Crítico** en `BIFROST_IP_WEB` (Log4Shell).

Para escanear solo un host, `--targets` sobreescribe la lista derivada:

```powershell
python tenable\tenable_scan.py --action run --targets 192.168.56.20 --name "smoke web01"
```

Si el escaneo termina pero el hallazgo no aparece, el problema está en la política
(credenciales o familia de plugins), no en el lab.
