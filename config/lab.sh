#!/usr/bin/env bash
# =============================================================================
#  config/lab.sh - carga de config/lab.env para todos los scripts bash.
#
#  Uso en cualquier script del repo:
#
#      . "$(dirname "${BASH_SOURCE[0]}")/../config/lab.sh"
#      bifrost_load_config "$(dirname "${BASH_SOURCE[0]}")"
#
#  Busqueda del archivo, en orden:
#     1. $BIFROST_CONFIG
#     2. config/lab.env subiendo desde el directorio indicado
#     3. /tmp/bifrost-lab.env   (lo deposita provision/apply.sh)
#
#  Falla de forma explicita si no lo encuentra: es preferible un error claro a
#  un laboratorio a medio configurar.
# =============================================================================

if [ -n "${BIFROST_LAB_LOADED:-}" ]; then
    return 0 2>/dev/null || true
fi

BIFROST_REQUIRED_KEYS="
BIFROST_NETWORK
BIFROST_PREFIX
BIFROST_GATEWAY
BIFROST_IP_ATTACKER
BIFROST_IP_SCANNER
BIFROST_IP_WEB
BIFROST_IP_DC
BIFROST_DOMAIN
BIFROST_NETBIOS
BIFROST_SVC_USER
BIFROST_SVC_PASS
BIFROST_APP_USER
BIFROST_APP_PASS
BIFROST_CROWN_JEWEL
BIFROST_SOLR_PORT
BIFROST_LDAP_PORT
BIFROST_HTTP_PORT
BIFROST_REVSHELL_PORT
BIFROST_PROBE_PORT
BIFROST_SOLR_VERSION
BIFROST_VM_DIR
BIFROST_SNAPSHOT
"

bifrost_find_config() {
    local start="${1:-$PWD}"
    local dir="$start"
    local i=0

    if [ -n "${BIFROST_CONFIG:-}" ] && [ -r "${BIFROST_CONFIG}" ]; then
        printf '%s\n' "$BIFROST_CONFIG"
        return 0
    fi

    # Sube como maximo cuatro niveles buscando config/lab.env
    while [ "$i" -lt 5 ]; do
        if [ -r "$dir/config/lab.env" ]; then
            printf '%s\n' "$dir/config/lab.env"
            return 0
        fi
        dir="$(dirname "$dir")"
        i=$((i + 1))
    done

    if [ -r /tmp/bifrost-lab.env ]; then
        printf '%s\n' /tmp/bifrost-lab.env
        return 0
    fi

    return 1
}

bifrost_load_config() {
    local start="${1:-$PWD}"
    local file

    if ! file="$(bifrost_find_config "$start")"; then
        echo "ERROR: no se encontro config/lab.env." >&2
        echo "       Define BIFROST_CONFIG=/ruta/lab.env o ejecuta desde el repo." >&2
        exit 1
    fi

    set -a
    # shellcheck disable=SC1090
    . "$file"
    set +a

    local missing=""
    local key
    for key in $BIFROST_REQUIRED_KEYS; do
        if [ -z "$(eval "printf '%s' \"\${$key:-}\"")" ]; then
            missing="$missing $key"
        fi
    done

    if [ -n "$missing" ]; then
        echo "ERROR: faltan claves obligatorias en $file:$missing" >&2
        exit 1
    fi

    BIFROST_LAB_LOADED="1"
    BIFROST_CONFIG_FILE="$file"
    export BIFROST_LAB_LOADED BIFROST_CONFIG_FILE
}

# Raiz del repo, derivada de la ubicacion del archivo de configuracion.
bifrost_repo_root() {
    local cfg="${BIFROST_CONFIG_FILE:-}"
    if [ -n "$cfg" ]; then
        dirname "$(dirname "$cfg")"
    else
        pwd
    fi
}

# Ruta absoluta del directorio de VMs.
bifrost_vm_dir() {
    case "$BIFROST_VM_DIR" in
        /*) printf '%s\n' "$BIFROST_VM_DIR" ;;
        *)  printf '%s\n' "$(bifrost_repo_root)/${BIFROST_VM_DIR#./}" ;;
    esac
}
