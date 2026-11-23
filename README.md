# BIFROST — laboratorio de demo

**Charla:** *Del hallazgo al dominio — lo que Tenable reporta y el red team demuestra.*
**Stack congelado:** Tenable One (Vulnerability Management + Attack Path Analysis) · VMware Workstation Pro 17.x / Fusion 13.x · ESC8 como final.

Diseño narrativo completo en [BIFROST-LAB.md](BIFROST-LAB.md). La construcción ordenada con
gates está en [BUILD.md](BUILD.md). Este README es la parte operativa.
Todos los valores del laboratorio viven en [config/lab.env](config/lab.env); el catálogo está en [docs/VALUES.md](docs/VALUES.md).

---

## 0. Requisitos del equipo de construcción

El laboratorio **no está atado a una máquina concreta**: se construye en cualquier
equipo que cumpla esto y luego se opera igual, porque los valores están en un
archivo de configuración y no en los scripts.

| Requisito | Mínimo | Recomendado | Por qué |
|---|---|---|---|
| Hipervisor | VMware Workstation Pro 17.x o Fusion 13.x | ídem | `vmrun` necesita Workstation/Fusion; **Player no sirve** |
| Red host-only | un adaptador `VMnet` | ídem | aislamiento del laboratorio |
| RAM | 14 GB | 32 GB | 6 VMs; con 16 GB hay que escalonar el arranque |
| Disco libre | 40 GB (Lab Lite) | 120 GB | discos thin + snapshots |
| Python | 3.8 con `requests` | 3.10+ | `tenable_scan.py` |
| Cliente SSH | opcional | — | provisioning de Linux |

**El único criterio es el preflight:**

```powershell
.\bifrost.ps1 preflight      # Windows
./bifrost.sh preflight       # Linux/macOS
```

Si dice `entorno listo`, se construye. Si dice `bloqueante`, no se empieza.

### 0.1 Un solo lugar para los valores

[config/lab.env](config/lab.env) alimenta a `bifrost.ps1`, `bifrost.sh`,
`provision/*.sh`, `exploits/log4shell/*.sh`, `tenable/tenable_scan.py` y
`windows/*.ps1`. Ningún script repite IPs, puertos ni contraseñas.

```bash
# comprobar lo que ve cada motor (secretos enmascarados)
.\bifrost.ps1 config
./bifrost.sh config
python tenable/tenable_scan.py --action config
```

Cambiar la red del laboratorio es editar `BIFROST_NETWORK`, `BIFROST_PREFIX`, los
seis `BIFROST_IP_*` y volver a aplicar. Nada más.

### 0.2 Red host-only

1. **Virtual Network Editor** como administrador (`vmnetcfg.exe` en la carpeta de VMware).
2. *Change Settings* → **Add Network** → `VMnet1` → **Host-only**.
3. Desmarcar *Use local DHCP service* (usamos IPs estáticas).
4. Subred y máscara **iguales a `BIFROST_NETWORK` / `BIFROST_PREFIX`** → *Apply*.
5. Verificar: `Get-NetAdapter | Where-Object Name -like 'VMnet*'`.

Si los servicios de VMware no aparecen ni con elevación, repara la instalación antes
de seguir. Un `VMnet1` que no levanta se manifiesta como VMs sin red y demos muertas.

### 0.3 Construcción vs demostración

Los objetivos **no tienen internet**, y eso es parte del diseño. Pero instalar
paquetes sí lo requiere, así que la regla es explícita:

| Fase | NIC del objetivo | Qué se hace |
|---|---|---|
| Construcción | **NAT activa** | instalar, provisionar, verificar |
| Demostración | **NAT retirada** | snapshot `clean`, escaneo y ataque |

El snapshot `clean` se toma **después** de retirar la NIC NAT. Si te lo saltas, el
escaneo verá un host con salida a internet que no representa el escenario.

---

## 1. Arquitectura y direccionamiento

```
192.168.56.0/24   host-only, sin NAT, sin internet
  .10  scanner   Ubuntu + Nessus vinculado a Tenable One  (NIC2 en VMnet8 NAT solo para el link cloud)
  .20  web01     Ubuntu 22.04 + Solr 8.11.0               Log4Shell
  .21  app02     Ubuntu 20.04 + policykit 0.105           PwnKit
  .30  dc01      Server 2019 + AD DS + ADCS HTTP          ESC8
  .31  ws01      Windows 10                                credenciales señuelo
  .66  kali      atacante
```

**Asimetría deliberada:** el atacante solo alcanza `.20:8983`. Todo lo demás se pivota desde `web01`. El escáner, en cambio, ve los seis hosts. Esa diferencia es un argumento de la charla, no un detalle.

**Regla de oro de RAM:** el escaneo y la explotación no ocurren a la vez. Secuencia:

```
1) encender scanner + objetivos  →  escaneo (20 min, se lanza antes de entrar)
2) apagar scanner                →  libera 4 GB
3) encender kali + cadena de ataque
```

---

## 2. Por qué no hay Vagrant/Packer/Ansible

En Windows, Vagrant con proveedor VMware exige el plugin `vagrant-vmware-desktop` y su licencia; Ansible **no corre nativamente** en Windows (necesita WSL, que además pelea con el hipervisor de VMware). Para una charla en vivo eso es superficie de fallo sin retorno.

Sustituto, mismo nivel de reproducibilidad:

| Necesidad | Herramienta aquí |
|---|---|
| Crear VMs | Buildsheets guiados (`buildsheets/`) — una vez, ~10 min por VM |
| Configurar Linux | Scripts bash idempotentes en `provision/`, ejecutados por SSH |
| Configurar Windows | Scripts PowerShell en `windows/` |
| Ciclo de vida y snapshots | `bifrost.ps1` (envuelve `vmrun`) |
| Escaneo | `tenable/tenable_scan.py` (API de Tenable One) |

La reproducibilidad real la da **el snapshot**, no el tooling: `.\bifrost.ps1 reset all` deja el lab idéntico a `pre-demo` en menos de 60 s.

---

## 3. Quickstart

```powershell
# 1. Entorno (una vez)
pip install requests
.\bifrost.ps1 preflight          # "entorno listo" o no se empieza

# 2. Construir VMs (en este orden)
#    buildsheets/linux-vms.md            -> kali, web01, app02
#    buildsheets/scanner-tenable-one.md  -> scanner enlazado a Tenable One
#    buildsheets/windows-vms.md          -> dc01 (AD + ADCS), ws01

# 3. Provisionar Linux (desde el equipo de control: lee config/lab.env)
bash provision/apply.sh kali
bash provision/apply.sh web01
bash provision/apply.sh app02

# 4. Copiar el repo a kali y verificar la cadena (gate previo a cualquier ensayo)
#    (192.168.56.66 = BIFROST_IP_KALI, la unica IP explicita del quickstart)
scp -r . kali@192.168.56.66:~/bifrost/
ssh kali@192.168.56.66 'cd ~/bifrost/exploits/log4shell && chmod +x *.sh && ./build.sh && ./selftest.sh'

# 5. Escanear (política y objetivos salen de config/lab.env)
python tenable\tenable_scan.py --action run --name "Bifrost pre-demo"

# 6. Ensayo: snapshot y reset
.\bifrost.ps1 snapshot all clean
.\bifrost.ps1 reset all
```

Los pasos 3, 5 y 6 no llevan ni una IP ni una contraseña escrita a mano: todo sale
de `config/lab.env`. El paso 4 usa una IP explícita (`BIFROST_IP_KALI`) porque es la
primera conexión, antes de que exista la sesión con variables cargadas.

---

## 4. Mapa de archivos

| Ruta | Qué hace |
|---|---|
| `config/lab.env` | **Única fuente de verdad**: IPs, dominio, puertos, credenciales, rutas |
| `config/lab.sh` / `config/lab.ps1` | Cargadores de esa configuración (bash y PowerShell) |
| `BIFROST-LAB.md` | Diseño narrativo, cadena de ataque, guion, riesgos |
| `BUILD.md` | Guía de construcción end-to-end con gates de verificación |
| `bifrost.ps1` | Windows: `preflight` · `config` · `status` · `start/stop` · `snapshot` · `reset` · `ip` · `scan` |
| `bifrost.sh` | Los mismos verbos en Linux/macOS |
| `buildsheets/` | `linux-vms.md` · `windows-vms.md` · `scanner-tenable-one.md` |
| `provision/` | `apply.sh` + scripts idempotentes (Solr vulnerable, privesc, kali) |
| `windows/` | PowerShell: promover DC, instalar ADCS con ESC8, unir ws01 |
| `exploits/log4shell/` | `Exploit.java.tmpl`, `build.sh`, `ldap-serve.sh`, `selftest.sh` |
| `exploits/esc8/` | Cadena PetitPotam → relay → certipy → DCSync |
| `tenable/tenable_scan.py` | API: crea, lanza, espera, exporta `.nessus`, resume a Markdown |
| `runbook/DEMO-RUNBOOK.md` | Guion minuto a minuto con comandos copy/paste |
| `docs/VALUES.md` | Catálogo de cada valor de configuración y quién lo consume |
| `tests/` | `check-consistency.sh` (contrato de valores) + fixture `.nessus` |
| `.gitignore` | Excluye VMs, artefactos y secretos del escenario |

---

## 5. Reglas de seguridad del lab

- Red **host-only, sin NAT** en las VMs objetivo. Solo el scanner tiene una segunda NIC con salida, y únicamente hacia `cloud.tenable.com`.
- Dominio falso `corp.local`, usuarios inventados, señuelos sin datos reales.
- **Nunca** reutilizar credenciales de la empresa, ni siquiera "de prueba".
- Snapshots `clean` y `pre-demo` obligatorios antes de cada ensayo.
- Todo el contenido es para infraestructura propia y autorizada; sin datos de terceros.
