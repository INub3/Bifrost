# Catálogo de valores — `config/lab.env`

Un solo archivo alimenta todo el laboratorio. Esta tabla dice qué significa cada
clave, qué la consume y qué se rompe si la cambias a medias.

**Regla:** si un valor no está aquí, no existe. Los scripts no llevan literales.

---

## Identidad

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_VERSION` | `0.1.0` | preflight | solo informativo |
| `BIFROST_LAB_NAME` | `Bifrost` | docs, mensajes | — |

## Red aislada

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_NETWORK` | `192.168.56.0` | `web01-solr.sh` (ufw), preflight | debe coincidir con la subred de VMnet1 |
| `BIFROST_PREFIX` | `24` | `web01-solr.sh`, `dc01`, `ws01` | máscara en formato CIDR |
| `BIFROST_GATEWAY` | `192.168.56.1` | `dc01`, `ws01` | coherencia; no hay salida real |

> Cambiar de red exige tocar también los seis `BIFROST_IP_*` y el *Virtual Network
> Editor*. El preflight no lo detecta: es el único punto donde hay que tener cuidado.

## Direccionamiento

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_IP_KALI` | `192.168.56.66` | `LHOST` en exploits, `provision/apply.sh kali` | atacante |
| `BIFROST_IP_SCANNER` | `192.168.56.10` | inventario | Nessus scanner |
| `BIFROST_IP_WEB` | `192.168.56.20` | puente 1, objetivos del escaneo | único host alcanzable desde kali |
| `BIFROST_IP_APP` | `192.168.56.21` | puente 2, objetivos | escalada local |
| `BIFROST_IP_DC` | `192.168.56.30` | puente 4, DNS de `ws01` | AD DS + ADCS |
| `BIFROST_IP_WS` | `192.168.56.31` | puente 3, objetivos | estación de trabajo |

Los objetivos del escaneo se **derivan** de estas seis claves: web, app, DC y ws.
No hay una lista de objetivos duplicada en ningún sitio.

## Usuarios de sistema

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_SSH_USER` | `bifrost` | `provision/apply.sh` | usuario de Ubuntu en el lab |
| `BIFROST_KALI_USER` | `kali` | `provision/apply.sh kali` | usuario de Kali |
| `BIFROST_SCANNER_USER` | `bifrost` | inventario | usuario del scanner |

## Dominio

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_DOMAIN` | `corp.local` | `dc01`, `ws01`, ESC8 | el DN se deriva solo (`DC=corp,DC=local`) |
| `BIFROST_NETBIOS` | `CORP` | `dc01` | debe tener ≤15 caracteres |
| `BIFROST_DOMAIN_ADMIN` | `Administrator` | `ws01-join.ps1` | cuenta usada para unir el equipo |
| `BIFROST_DOMAIN_ADMIN_PASS` | `Bifrost-Admin-2026!` | `ws01-join.ps1` | si falta, el script la pide por consola |
| `BIFROST_DSRM_PASS` | `Bifrost-DSRM-2026!` | `dc01-promote.ps1` | contraseña del modo restauración |

## Cuentas del escenario

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_SVC_USER` | `svc_backup` | puente 3, AD, ESC8 | cuenta de servicio **sin privilegios** |
| `BIFROST_SVC_PASS` | `Verano2024!` | idem | aparece en señuelos a propósito |
| `BIFROST_APP_USER` | `svc_app` | `app02-privesc.sh` | usuario local de la app |
| `BIFROST_APP_PASS` | `Bifrost2026!` | idem | — |

> Son credenciales de ficción para una red aislada. **Nunca** reutilices una
> contraseña real aquí, ni siquiera "de prueba".

## Contenido de las VMs Windows

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_CROWN_JEWEL` | `C:\Corp\Finanzas` | `dc01-promote.ps1` | carpeta que se lee al final de la cadena |
| `BIFROST_SHARE_PATH` | `C:\Compartido` | `ws01-join.ps1` | recurso compartido con señuelos |

## Puertos

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_SOLR_PORT` | `8983` | puente 1 | endpoint vulnerable |
| `BIFROST_LDAP_PORT` | `1389` | `ldap-serve.sh`, `selftest.sh` | servidor JNDI |
| `BIFROST_HTTP_PORT` | `8000` | idem | sirve `Exploit.class` |
| `BIFROST_REVSHELL_PORT` | `4444` | `build.sh`, `ldap-serve.sh` | listener de la shell |
| `BIFROST_PROBE_PORT` | `9998` | `selftest.sh` | callback de la autoprueba |

## Componente vulnerable

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_SOLR_VERSION` | `8.11.0` | `web01-solr.sh`, `selftest.sh` | **8.11.1 ya está parcheado**: no subir esta versión |

## Operación del laboratorio

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_VM_DIR` | `./vms` | `bifrost.ps1`, `bifrost.sh` | relativa a la raíz del repo o absoluta |
| `BIFROST_VMWARE_TYPE` | `ws` | `vmrun -T` | `ws` para Workstation, `fusion` para macOS |
| `BIFROST_VMRUN` | *(vacío)* | ambos CLI | vacío = autodetección |
| `BIFROST_SNAPSHOT` | `pre-demo` | `snapshot`, `reset` | etiqueta del estado seguro |
| `BIFROST_DISK_BUDGET_GB` | `100` | preflight | umbral de aviso, no bloquea la construcción |

## Tenable One

| Clave | Default | Consume | Notas |
|---|---|---|---|
| `BIFROST_TENABLE_BASE_URL` | `https://cloud.tenable.com` | `tenable_scan.py` | región UE: `https://cloud.tenable.com` + `TIO_BASE_URL` |
| `BIFROST_TENABLE_POLICY` | `Bifrost-Demo` | `--action run` | nombre exacto de la política en Tenable |
| `BIFROST_TENABLE_KEYS_FILE` | *(vacío)* | `load_keys` | vacío = `~/.bifrost/tenable.json` |

---

## Qué *no* se configura aquí a propósito

| Cosa | Dónde vive | Por qué |
|---|---|---|
| Credenciales de API de Tenable | `~/.bifrost/tenable.json` | secreto, fuera del repo |
| Contraseña de `Administrator` de Windows al instalar | tecleada en el instalador | evita dejar la del lab en la ISO |
| Rutas de los `.vmx` | `BIFROST_VM_DIR` | el descubrimiento es por búsqueda de `*.vmx` |

## Cómo verificar que un cambio se propagó

```bash
./bifrost.sh config                        # bash
.\bifrost.ps1 config                       # PowerShell
python tenable/tenable_scan.py --action config   # Python
```

Los tres deben mostrar el mismo valor y el mismo archivo de origen. Si discrepan,
el script que discrepa no está cargando la configuración.
