#!/usr/bin/env bash
# =============================================================================
#  web01 - Solr 8.11.0 vulnerable a Log4Shell (CVE-2021-44228)
#  Puente 1 del laboratorio Bifrost.
#
#  Valores: config/lab.env (version, puerto, red permitida).
#
#  Ejecucion normal (recomendada):
#      ./provision/apply.sh web01
#
#  Ejecucion manual:
#      BIFROST_CONFIG=./config/lab.env sudo -E bash provision/web01-solr.sh
#
#  REQUIERE INTERNET durante la construccion (paquetes y tarball). La regla del
#  laboratorio es: NIC NAT activa mientras se construye, retirada antes del
#  snapshot "clean". Si no hay salida, el script lo dice y se detiene.
# =============================================================================
set -euo pipefail

# --- carga de configuracion (repo o provision/apply.sh) ----------------------
_here="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"
_scan="$_here"
for _ in 1 2 3 4 5; do
    if [ -r "$_scan/config/lab.sh" ]; then
        # shellcheck disable=SC1090
        . "$_scan/config/lab.sh"
        break
    fi
    _scan="$(dirname "$_scan")"
done
if ! command -v bifrost_load_config >/dev/null 2>&1 && [ -r /tmp/bifrost-lab.sh ]; then
    # shellcheck disable=SC1091
    . /tmp/bifrost-lab.sh
fi
if ! command -v bifrost_load_config >/dev/null 2>&1; then
    echo "ERROR: no se encontro config/lab.sh. Usa provision/apply.sh." >&2
    exit 1
fi
bifrost_load_config "$_here"

SOLR_VERSION="$BIFROST_SOLR_VERSION"
SOLR_PORT="$BIFROST_SOLR_PORT"
SOLR_HOME="/opt/solr"
SOLR_DATA="/var/solr"
SOLR_URL="https://archive.apache.org/dist/lucene/solr/${SOLR_VERSION}/solr-${SOLR_VERSION}.tgz"
JAVA_HOME_DIR="/usr/lib/jvm/java-11-openjdk-amd64"

log() { printf '\n[bifrost] %s\n' "$*"; }
die() { printf '[bifrost] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "ejecuta como root (sudo)."

# --------------------------------------------------------------------------- #
# 0. Conectividad (fase de construccion)
# --------------------------------------------------------------------------- #
if ! curl -sfI --max-time 8 https://archive.apache.org/ >/dev/null 2>&1; then
    cat >&2 <<EOF
[bifrost] ERROR: sin salida a internet en este host.

  El laboratorio es aislado por diseno, pero la CONSTRUCCION necesita paquetes:
    - activa una segunda NIC en NAT (VMnet8) solo para esta fase
    - ejecuta este script
    - retira o desactiva la NIC NAT antes del snapshot "clean"

  Ver buildsheets/linux-vms.md, seccion "Construccion vs demostracion".
EOF
    exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Dependencias
# --------------------------------------------------------------------------- #
log "Instalando JDK 11"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq openjdk-11-jdk-headless curl tar ufw >/dev/null

[ -d "$JAVA_HOME_DIR" ] || die "no aparece $JAVA_HOME_DIR"

# --------------------------------------------------------------------------- #
# 2. Usuario y descarga
# --------------------------------------------------------------------------- #
if ! id solr >/dev/null 2>&1; then
    log "Creando usuario solr"
    useradd --system --home-dir "$SOLR_HOME" --shell /usr/sbin/nologin solr
fi

if [ ! -x "$SOLR_HOME/bin/solr" ]; then
    log "Descargando Solr ${SOLR_VERSION}"
    curl -fsSL -o /tmp/solr.tgz "$SOLR_URL"

    if [ -n "${SOLR_SHA512:-}" ]; then
        echo "${SOLR_SHA512}  /tmp/solr.tgz" | sha512sum -c - || die "checksum no coincide"
    else
        echo "  (sin verificacion de checksum: define SOLR_SHA512 para activarla)"
    fi

    tar xzf /tmp/solr.tgz -C /opt
    mv "/opt/solr-${SOLR_VERSION}" "$SOLR_HOME"
    chown -R solr:solr "$SOLR_HOME"
else
    log "Solr ya instalado en $SOLR_HOME"
fi

mkdir -p "$SOLR_DATA/logs"
chown -R solr:solr "$SOLR_DATA"

# --------------------------------------------------------------------------- #
# 3. La deuda tecnica que hace posible el puente
# --------------------------------------------------------------------------- #
# Solr 8.11 corre en JDK 11, donde la carga remota de clases por JNDI esta
# desactivada por defecto. Esta bandera la reactiva: el tipo de opcion legacy
# que un administrador deja puesta "por compatibilidad".
SOLR_IN_SH="$SOLR_HOME/bin/solr.in.sh"

if ! grep -q 'trustURLCodebase' "$SOLR_IN_SH"; then
    log "Anadiendo trustURLCodebase (la vulnerabilidad del laboratorio)"
    cat >> "$SOLR_IN_SH" <<'EOF'

# LEGACY: compatibilidad con integraciones antiguas basadas en JNDI.
SOLR_OPTS="$SOLR_OPTS -Dcom.sun.jndi.ldap.object.trustURLCodebase=true"
EOF
fi

if ! grep -q '^SOLR_JAVA_MEM=' "$SOLR_IN_SH"; then
    echo 'SOLR_JAVA_MEM="-Xms512m -Xmx512m"' >> "$SOLR_IN_SH"
fi

# --------------------------------------------------------------------------- #
# 4. Servicio
# --------------------------------------------------------------------------- #
log "Instalando servicio systemd"
cat > /etc/systemd/system/solr.service <<EOF
[Unit]
Description=Bifrost Solr (lab)
After=network.target

[Service]
Type=simple
User=solr
Group=solr
Environment=SOLR_PID_DIR=${SOLR_DATA}
ExecStart=${SOLR_HOME}/bin/solr start -f -p ${SOLR_PORT}
ExecStop=${SOLR_HOME}/bin/solr stop -p ${SOLR_PORT}
Restart=on-failure
RestartSec=5
LimitNOFILE=65000

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable solr >/dev/null 2>&1 || true
systemctl restart solr

# --------------------------------------------------------------------------- #
# 5. Firewall: solo la red del laboratorio
# --------------------------------------------------------------------------- #
log "Aplicando reglas de ufw"
ufw allow from "${BIFROST_NETWORK}/${BIFROST_PREFIX}" to any port "$SOLR_PORT" proto tcp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# 6. Verificacion
# --------------------------------------------------------------------------- #
log "Esperando a que Solr levante"
for _ in $(seq 1 30); do
    curl -sf -o /dev/null "http://127.0.0.1:${SOLR_PORT}/solr/" && break
    sleep 2
done

curl -sf -o /dev/null "http://127.0.0.1:${SOLR_PORT}/solr/" \
    || die "Solr no responde. Revisa: journalctl -u solr -n 50"

VERSION=$(curl -s "http://127.0.0.1:${SOLR_PORT}/solr/admin/info/system?wt=json" \
    | grep -o '"solr-spec-version":"[^"]*"' | cut -d'"' -f4 || echo "?")

if [ "$VERSION" != "$SOLR_VERSION" ]; then
    printf '[bifrost] ADVERTENCIA: version %s, se esperaba %s\n' "$VERSION" "$SOLR_VERSION" >&2
fi

if ! curl -sf -o /dev/null "http://127.0.0.1:${SOLR_PORT}/solr/intranet/admin/ping"; then
    su -s /bin/bash solr -c "$SOLR_HOME/bin/solr create -c intranet -p $SOLR_PORT" >/dev/null 2>&1 || true
fi

# Credenciales del servidor interno dentro de la configuracion del core: es el
# puente 3. Un operador que ya tiene shell en web01 las lee en un segundo.
CORE_CONF="$SOLR_HOME/server/solr/intranet/conf"
if [ -d "$CORE_CONF" ]; then
    cat > "$CORE_CONF/db.properties" <<EOF
# Conexion de la app de reportes
db.host=$BIFROST_IP_APP
db.user=$BIFROST_APP_USER
db.password=$BIFROST_APP_PASS
EOF
    chown solr:solr "$CORE_CONF/db.properties"
    chmod 640 "$CORE_CONF/db.properties"
else
    printf '[bifrost] ADVERTENCIA: no existe %s; el puente 3 no tendra credenciales\n' "$CORE_CONF" >&2
fi

cat <<EOF

============================================================================
 web01 listo
   Solr      : $VERSION
   Endpoint  : http://${BIFROST_IP_WEB}:${SOLR_PORT}/solr/
   JVM       : JDK 11 con trustURLCodebase=true
   Core      : intranet

 Siguiente (en kali):
   cd exploits/log4shell
   ./build.sh
   ./selftest.sh
============================================================================
EOF
