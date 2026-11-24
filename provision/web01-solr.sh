#!/usr/bin/env bash
# =============================================================================
#  web01 - unica maquina Linux objetivo del laboratorio.
#
#  Concentra tres puentes:
#    1. Log4Shell  -> Solr 8.11.0 + JDK 11 con trustURLCodebase=true
#    2. PwnKit     -> policykit 0.105 (Ubuntu 20.04) + usuario local svc_app
#    3. Lateral    -> credenciales de dominio svc_backup sembradas en /opt/app
#
#  OS: Ubuntu Server 20.04 SIN actualizar (necesita policykit 0.105).
#
#  Ejecucion normal:
#      ./provision/apply.sh web01
#
#  REQUIERE INTERNET durante la construccion (NIC NAT). Retirar antes del
#  snapshot "clean".
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

APP_USER="$BIFROST_APP_USER"
APP_PASS="$BIFROST_APP_PASS"

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

  Ver GUIDE.md, paso 2.
EOF
    exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Dependencias (Ubuntu 20.04 ya vive en old-releases)
# --------------------------------------------------------------------------- #
log "Configurando apt (20.04 esta en old-releases)"
export DEBIAN_FRONTEND=noninteractive

if ! apt-get update -qq 2>/dev/null; then
    echo "  apt fallo; redirigiendo a old-releases.ubuntu.com..."
    sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
           -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' \
           /etc/apt/sources.list 2>/dev/null || true
    for f in /etc/apt/sources.list.d/*.list; do
        [ -f "$f" ] && sed -i -e 's|archive.ubuntu.com|old-releases.ubuntu.com|g' \
                               -e 's|security.ubuntu.com|old-releases.ubuntu.com|g' "$f"
    done
    apt-get update -qq
fi

log "Instalando JDK 11"
apt-get install -y -qq openjdk-11-jdk-headless curl tar ufw >/dev/null

[ -d "$JAVA_HOME_DIR" ] || die "no aparece $JAVA_HOME_DIR"

# --------------------------------------------------------------------------- #
# 2. Usuario del servicio y descarga de Solr
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
# 3. trustURLCodebase: la deuda tecnica del puente 1
# --------------------------------------------------------------------------- #
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
# 6. Usuario local + senuelos (puentes 2 y 3)
# --------------------------------------------------------------------------- #
if ! id "$APP_USER" >/dev/null 2>&1; then
    log "Creando usuario local $APP_USER"
    useradd -m -s /bin/bash "$APP_USER"
    echo "${APP_USER}:${APP_PASS}" | chpasswd
fi

# Senuelo del puente 3: credenciales de dominio en un deploy legible.
mkdir -p /opt/app
cat > /opt/app/config.yml <<EOF
# Despliegue interno - laboratorio $BIFROST_LAB_NAME
app:
  name: intranet-backup
  port: 8080

# TODO: mover a boveda de secretos
domain:
  realm: ${BIFROST_DOMAIN^^}
  bind_user: $BIFROST_SVC_USER
  bind_password: "$BIFROST_SVC_PASS"
EOF
chmod 644 /opt/app/config.yml

# --------------------------------------------------------------------------- #
# 7. Verificacion de Solr
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

# Credenciales del usuario local dentro de la configuracion del core (puente 2).
CORE_CONF="$SOLR_HOME/server/solr/intranet/conf"
if [ -d "$CORE_CONF" ]; then
    cat > "$CORE_CONF/db.properties" <<EOF
# Conexion de la app de reportes
db.user=$APP_USER
db.password=$APP_PASS
EOF
    chown solr:solr "$CORE_CONF/db.properties"
    chmod 640 "$CORE_CONF/db.properties"
else
    printf '[bifrost] ADVERTENCIA: no existe %s; el puente 2 no tendra credenciales\n' "$CORE_CONF" >&2
fi

# --------------------------------------------------------------------------- #
# 8. Diagnostico de PwnKit (puente 2)
# --------------------------------------------------------------------------- #
log "Diagnostico de PwnKit (CVE-2021-4034)"
PKEXEC_VERSION=$(dpkg-query -W -f='${Version}' policykit-1 2>/dev/null || echo "ausente")
echo "  policykit-1: $PKEXEC_VERSION"

if dpkg --compare-versions "$PKEXEC_VERSION" lt "0.105-26ubuntu1.2" 2>/dev/null; then
    echo "  [ OK ] vulnerable a CVE-2021-4034 (PwnKit)"
else
    echo "  [WARN] policykit parcheado: el puente 2 necesita otra via"
fi

cat <<EOF

============================================================================
 web01 listo
   Solr      : $VERSION
   Endpoint  : http://${BIFROST_IP_WEB}:${SOLR_PORT}/solr/
   JVM       : JDK 11 con trustURLCodebase=true
   Core      : intranet
   Local user: $APP_USER (credenciales en el core 'intranet')
   Domain    : credenciales de $BIFROST_SVC_USER en /opt/app/config.yml
   PwnKit    : ver diagnostico arriba

 Siguiente (desde el HOST atacante):
   cd exploits/log4shell
   ./build.sh
   ./selftest.sh
============================================================================
EOF
