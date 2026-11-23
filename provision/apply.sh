#!/usr/bin/env bash
# =============================================================================
#  provision/apply.sh - aplica la configuracion a un host del laboratorio.
#
#  Se ejecuta en el equipo de control (el que tiene el repo y acceso SSH a la
#  red del laboratorio). Resuelve la IP desde config/lab.env, copia la
#  configuracion al host y ejecuta el script con sudo.
#
#  Uso:
#      ./provision/apply.sh web01
#      ./provision/apply.sh app02
#      ./provision/apply.sh kali
#      ./provision/apply.sh web01 --dry-run
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../config/lab.sh"
bifrost_load_config "$SCRIPT_DIR"

TARGET="${1:-}"
DRY_RUN=0
[ "${2:-}" = "--dry-run" ] && DRY_RUN=1

case "$TARGET" in
    web01) IP="$BIFROST_IP_WEB";  USER="$BIFROST_SSH_USER";  SCRIPT="web01-solr.sh";    SUDO="sudo" ;;
    app02) IP="$BIFROST_IP_APP";  USER="$BIFROST_SSH_USER";  SCRIPT="app02-privesc.sh"; SUDO="sudo" ;;
    kali)  IP="$BIFROST_IP_KALI"; USER="$BIFROST_KALI_USER"; SCRIPT="kali-tools.sh";    SUDO="" ;;
    *)
        echo "Uso: $0 <web01|app02|kali> [--dry-run]" >&2
        echo "     (Windows se configura con windows/*.ps1 dentro de la VM)" >&2
        exit 1
        ;;
esac

LOCAL_SCRIPT="$SCRIPT_DIR/$SCRIPT"
[ -f "$LOCAL_SCRIPT" ] || { echo "ERROR: no existe $LOCAL_SCRIPT" >&2; exit 1; }

echo "[bifrost] host=$TARGET ip=$IP usuario=$USER script=$SCRIPT"

if [ "$DRY_RUN" -eq 1 ]; then
    echo "[bifrost] dry-run: no se ejecuta nada"
    exit 0
fi

# La configuracion viaja al host: los scripts la cargan de /tmp.
scp -q "$SCRIPT_DIR/../config/lab.env" "$USER@$IP:/tmp/bifrost-lab.env" || {
    echo "ERROR: no se pudo copiar lab.env a $IP (SSH? red? VM apagada?)" >&2
    exit 1
}
scp -q "$SCRIPT_DIR/../config/lab.sh" "$USER@$IP:/tmp/bifrost-lab.sh" || {
    echo "ERROR: no se pudo copiar lab.sh a $IP" >&2
    exit 1
}

# El script se ejecuta en el host y lee la configuracion de /tmp.
ssh "$USER@$IP" "${SUDO:+$SUDO }bash -s" < "$LOCAL_SCRIPT"
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
    echo "[bifrost] $TARGET configurado correctamente"
else
    echo "[bifrost] $TARGET FALLO (exit $STATUS)" >&2
fi
exit "$STATUS"
