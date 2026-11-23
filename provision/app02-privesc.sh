#!/usr/bin/env bash
# =============================================================================
#  app02 - servidor interno con escalada local (puente 2)
#
#  Valores: config/lab.env (usuarios, contrasenas, dominio).
#
#  El hallazgo estrella debe ser una CVE real (PwnKit). Se siembra ademas una
#  misconfiguracion de sudo como red de seguridad: si la CVE no aplica en la
#  version instalada, el puente 2 sigue existiendo.
#
#  NO requiere internet: no instala paquetes, solo siembra archivos y consulta
#  versiones con dpkg. Es intencional, porque Ubuntu 20.04 ya no tiene repos
#  vivos y este host debe poder configurarse en una red aislada.
#
#  Ejecucion: ./provision/apply.sh app02
# =============================================================================
set -euo pipefail

# --- carga de configuracion --------------------------------------------------
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

APP_USER="$BIFROST_APP_USER"
APP_PASS="$BIFROST_APP_PASS"

log() { printf '\n[bifrost] %s\n' "$*"; }
die() { printf '[bifrost] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "ejecuta como root (sudo)."

# --------------------------------------------------------------------------- #
# 1. Usuario de aplicacion
# --------------------------------------------------------------------------- #
if ! id "$APP_USER" >/dev/null 2>&1; then
    log "Creando usuario $APP_USER"
    useradd -m -s /bin/bash "$APP_USER"
    echo "${APP_USER}:${APP_PASS}" | chpasswd
fi

# --------------------------------------------------------------------------- #
# 2. Aplicacion de relleno + credenciales de dominio (puente 3)
# --------------------------------------------------------------------------- #
log "Sembrando /opt/app (aplicacion y credenciales)"
mkdir -p /opt/app

cat > /opt/app/config.yml <<EOF
# Aplicacion interna de ejemplo - laboratorio $BIFROST_LAB_NAME
app:
  name: intranet-backup
  port: 8080

database:
  host: 127.0.0.1
  user: app_reader
  password: "Ch4ngeM3-Local"

# TODO: mover a boveda de secretos (pendiente desde 2022)
domain:
  realm: ${BIFROST_DOMAIN^^}
  bind_user: $BIFROST_SVC_USER
  bind_password: "$BIFROST_SVC_PASS"
EOF

chown -R "$APP_USER":"$APP_USER" /opt/app
chmod 640 /opt/app/config.yml

# --------------------------------------------------------------------------- #
# 3. Red de seguridad: sudo mal configurado
# --------------------------------------------------------------------------- #
log "Configurando sudo inseguro (fallback del puente 2)"
cat > /etc/sudoers.d/90-bifrost-app <<EOF
# Permite a operaciones revisar registros sin password.
$APP_USER ALL=(root) NOPASSWD: /usr/bin/less, /usr/bin/tail
EOF
chmod 440 /etc/sudoers.d/90-bifrost-app

# --------------------------------------------------------------------------- #
# 4. Diagnostico de la CVE del puente 2
# --------------------------------------------------------------------------- #
log "Diagnostico de vectores de escalada"

KERNEL=$(uname -r)
echo "  kernel: $KERNEL"

PKEXEC_VERSION=$(dpkg-query -W -f='${Version}' policykit-1 2>/dev/null || echo "ausente")
echo "  policykit-1: $PKEXEC_VERSION"

VECTORES=()

if dpkg --compare-versions "$PKEXEC_VERSION" lt "0.105-26ubuntu1.2" 2>/dev/null; then
    VECTORES+=("CVE-2021-4034 (PwnKit) - policykit $PKEXEC_VERSION")
fi

KMAJOR=$(echo "$KERNEL" | cut -d. -f1)
KMINOR=$(echo "$KERNEL" | cut -d. -f2)
if [ "$KMAJOR" -eq 5 ] && [ "$KMINOR" -ge 8 ] && [ "$KMINOR" -le 16 ]; then
    VECTORES+=("CVE-2022-0847 (Dirty Pipe) - kernel $KERNEL")
fi

echo
if [ ${#VECTORES[@]} -eq 0 ]; then
    echo "  ADVERTENCIA: ninguna CVE de escalada aplica a esta build."
    echo "  El puente 2 queda cubierto solo por el sudo mal configurado."
    echo "  Para recuperar la historia de CVE: reconstruye la VM sin 'apt upgrade'."
else
    echo "  Vectores disponibles:"
    for v in "${VECTORES[@]}"; do echo "    - $v"; done
fi

# --------------------------------------------------------------------------- #
# 5. Senuelos
# --------------------------------------------------------------------------- #
log "Creando senuelos"
mkdir -p /srv/backups
cat > /srv/backups/notas_operaciones.txt <<EOF
Rotacion de backups - pendiente revisar retencion
El usuario de dominio para la copia offsite es $BIFROST_SVC_USER (ver config.yml)
EOF
chmod 644 /srv/backups/notas_operaciones.txt

cat <<EOF

============================================================================
 app02 listo
   usuario app     : $APP_USER / (ver config/lab.env)
   credenciales    : /opt/app/config.yml -> $BIFROST_SVC_USER
   sudo inseguro   : /etc/sudoers.d/90-bifrost-app
   senuelos        : /srv/backups/

 Comprobar el puente 2 (como $APP_USER):
   sudo -l
============================================================================
EOF
