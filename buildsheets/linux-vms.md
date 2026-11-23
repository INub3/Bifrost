# Buildsheet — VMs Linux (kali, web01, app02)

Todas las VMs VMware: **Workstation 17.x / Fusion 13.x**, *Custom (advanced)*, disco **thin**, red **Custom: VMnet1**.
Nunca "NAT" ni "Bridged" en un objetivo, salvo la excepción de §0.

> **Dónde se ejecuta:** `host` = equipo de control (donde vive el repo) · `VMware GUI` = Workstation /
> Virtual Network Editor (solo en `host`) · `kali`/`web01`/`app02` = consola dentro de esa VM ·
> `host → kali` = tecleado en `host`, ejecutado por SSH.

Las IPs de la tabla son las de [config/lab.env](../config/lab.env). Si cambias el
direccionamiento, cambia en ese archivo y ajusta el netplan de §2.

| VM | OS | vCPU | RAM | Disco | IP (de `config/lab.env`) |
|---|---|---|---|---|---|
| kali | Kali Linux (última) | 2 | 3 GB | 40 GB | `BIFROST_IP_KALI` |
| web01 | Ubuntu Server 22.04.5 | 2 | 3 GB | 20 GB | `BIFROST_IP_WEB` |
| app02 | Ubuntu Server 20.04.6 | 2 | 2 GB | 20 GB | `BIFROST_IP_APP` |
| scanner | ver `scanner-tenable-one.md` | 2 | 4 GB | 40 GB | `BIFROST_IP_SCANNER` |

> **Ubuntu 20.04 ya no tiene repos vivos.** `app02` se queda en 20.04 a propósito
> (necesita `policykit 0.105` para PwnKit), pero **no ejecutes `apt upgrade`**: el
> script de provisioning no instala nada, solo siembra archivos y consulta
> versiones con `dpkg`. En `web01` usamos 22.04 para tener repos sanos.

ISOs:

- Kali: <https://www.kali.org/get-kali/#kali-installer-images>
- Ubuntu 22.04.5: <https://releases.ubuntu.com/22.04/>
- Ubuntu 20.04.6: <https://old-releases.ubuntu.com/releases/20.04/>

---

## 0. Construcción vs demostración

Las VMs objetivo viven en una red sin salida. Pero **instalar paquetes requiere
internet**, y de ahí la única excepción a la regla de aislamiento:

| Fase | NIC de la VM | Qué se hace |
|---|---|---|
| Construcción | VMnet1 **+ VMnet8 (NAT)** | instalar el OS, `provision/apply.sh`, verificar |
| Snapshots | solo VMnet1 | retirar la NIC NAT **antes** de `clean` y `pre-demo` |
| Demostración | solo VMnet1 | escanear, atacar, resetear |

`provision/web01-solr.sh` y `provision/kali-tools.sh` comprueban la salida a
internet y se detienen con un mensaje claro si la NIC NAT no está puesta. No es
un fallo: es la fase de construcción reclamando lo que necesita.

Tras provisionar, **en `VMware GUI`**: *Edit settings* → NIC 2 → **Remove**, y
recién entonces, **en `host`**: `./bifrost.sh snapshot all clean`.

---

## 1. Crear la VM (igual para las tres)

**En:** `VMware GUI` (en el `host`).

1. *File → New Virtual Machine → Custom (advanced)*.
2. *I will install the operating system later* (evita el "Easy Install", que mete cosas raras).
3. Guest OS: Linux → Ubuntu 64-bit (Kali: Debian 11.x 64-bit).
4. Nombre y ruta: `E:\Bifrost-VMs\kali\kali.vmx` (o `.\vms\` si vas por Lite).
5. Firmware **BIOS**, 2 vCPU, RAM según tabla.
6. Red: **Custom → VMnet1**.
7. Controladora: LSI Logic. Disco: **SCSI**, thin, tamaño de la tabla.
8. *Finish*, luego *Edit settings → CD/DVD → Use ISO image*.

**No instales VMware Tools a mano**: Ubuntu y Kali traen `open-vm-tools` (lo activamos abajo). Es lo que permite `vmrun getGuestIPAddress` y el apagado suave.

---

## 2. Instalación de Ubuntu Server

**En:** consola de la VM (`web01` o `app02`); el asistente de instalación se maneja desde `VMware GUI`.

Durante el instalador:

- Idioma: inglés (menos fricción con `apt` y logs).
- Perfil: usuario `bifrost`, contraseña del lab, **sin** "Install OpenSSH server" marcado… sí, márcalo. Lo necesitamos.
- *Featured server snaps*: ninguno. **No** instales Docker.
- Particionado: *Use an entire disk*, sin LVM (simplifica snapshots y `df`).

Al terminar: reinicia, quita la ISO del lector y arranca.

### Red estática (netplan)

**En:** consola de la VM (`web01` o `app02`).

> Los valores del bloque (`192.168.56.20`, `.1`, `.30`) son `BIFROST_IP_WEB`,
> `BIFROST_GATEWAY` y `BIFROST_IP_DC` por defecto. Ajusta por VM según
> `config/lab.env`.

```bash
sudo tee /etc/netplan/00-bifrost.yaml >/dev/null <<'EOF'
network:
  version: 2
  ethernets:
    ens33:
      dhcp4: false
      addresses: [192.168.56.20/24]
      routes:
        - to: default
          via: 192.168.56.1
      nameservers:
        addresses: [192.168.56.30]
EOF
sudo chmod 600 /etc/netplan/00-bifrost.yaml
sudo netplan apply
```

Cambia `ens33` por el nombre real (`ip -br a`) y la IP según la VM.
El DNS (`192.168.56.30`) solo resuelve cuando `dc01` exista; mientras tanto deja `1.1.1.1` o vacío.

### Herramientas de VMware

**En:** consola de la VM.

```bash
sudo apt update && sudo apt install -y open-vm-tools
```

### Verificación

**En:** consola de la VM.

```bash
ip -br a                      # debe mostrar la IP estática
ping -c1 192.168.56.66        # valor de BIFROST_IP_KALI
```

---

## 3. kali

**En:** `VMware GUI` (crear/arrancar) + consola de `kali` (instalar y configurar).

Instalador gráfico estándar, *Guided - use entire disk*, usuario `kali`.

Post-instalación, **en `kali`**:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y open-vm-tools open-vm-tools-desktop
```

Red estática con el mismo netplan (Kali usa NetworkManager; el panel de
conexiones es más rápido: *Wired → IPv4 → Manual*), usando `BIFROST_IP_KALI`.

Luego, **en `host`** (el que tiene el repo):

```bash
bash provision/apply.sh kali
```

Eso instala las herramientas y genera `~/bifrost/env.sh` en kali con los valores
de `config/lab.env`. Nada de IPs escritas a mano.

> **Ojo con el disco de Kali**: 40 GB thin suele materializar ~12 GB. Si eliges 20 GB,
> `apt full-upgrade` puede quedarse corto.

---

## 4. web01 — Solr vulnerable

Ubuntu 22.04.5.

**En:** `host`

```bash
bash provision/apply.sh web01
```

El script instala JDK 11 y Solr en la versión de `BIFROST_SOLR_VERSION`, lo deja
como servicio y añade `-Dcom.sun.jndi.ldap.object.trustURLCodebase=true`. Al final
imprime la versión detectada y crea el core `intranet`.

**Verificación (no la saltes)** — **en `host`** (curl hacia `web01`; también vale desde `kali`):

```bash
curl -s "http://192.168.56.20:8983/solr/admin/info/system?wt=json" | head -c 300
```

Debe responder un JSON con `"solr-spec-version":"8.11.0"` (o el valor configurado).

---

## 5. app02 — escalada local

Ubuntu 20.04.6 **sin actualizar**.

**En:** `host`

```bash
bash provision/apply.sh app02
```

Lee con atención el diagnóstico final: te dice si aplica **PwnKit**, **Dirty Pipe** o
solo el `sudo` mal configurado. Esa línea decide qué comandos usas en el puente 2.

**Verificación** (usando el usuario y la IP de `config/lab.env`) — **`host → app02`**:

```bash
ssh svc_app@192.168.56.21 'sudo -l'     # debe listar less y tail sin password
```

---

## 6. Orden de arranque (RAM)

**En:** `host` (`bifrost.ps1` / `bifrost.sh`).

No enciendas las seis VMs a la vez salvo que tengas 32 GB de host:

```
Escaneo : scanner + web01 + app02 + dc01 + ws01   (~14 GB)  -> apaga scanner al terminar
Ataque  : kali + web01 + app02                    (~8 GB)
Final   : kali + dc01                             (~6 GB)
```
