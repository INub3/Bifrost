#!/usr/bin/env bash
# =============================================================================
#  kali - herramientas del atacante para la cadena completa
#
#  Genera ~/bifrost/env.sh a partir de config/lab.env, de modo que la sesion en
#  kali use exactamente los mismos valores que el resto del laboratorio.
#
#  REQUIERE INTERNET (apt, pipx, git). Fase de construccion.
#
#  Ejecucion: ./provision/apply.sh kali
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

log() { printf '\n[bifrost] %s\n' "$*"; }

command -v apt-get >/dev/null 2>&1 || { echo "Esto espera un Kali/Debian." >&2; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# --------------------------------------------------------------------------- #
# 0. Conectividad
# --------------------------------------------------------------------------- #
if ! curl -sfI --max-time 8 https://http.kali.org/ >/dev/null 2>&1; then
    echo "[bifrost] ERROR: sin salida a internet. Activa la NIC NAT durante la construccion." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Paquetes base
# --------------------------------------------------------------------------- #
log "Instalando paquetes base (puede tardar)"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
    openjdk-11-jdk maven git curl netcat-openbsd \
    impacket-scripts python3-pip pipx chisel \
    >/dev/null

$SUDO apt-get install -y -qq netexec >/dev/null 2>&1 \
    || $SUDO apt-get install -y -qq nxc >/dev/null 2>&1 \
    || echo "  (netexec no disponible via apt; se usara impacket como alternativa)"

# --------------------------------------------------------------------------- #
# 2. Herramientas de Python
# --------------------------------------------------------------------------- #
log "Instalando certipy-ad (via pipx)"
pipx ensurepath >/dev/null 2>&1 || true
pipx install certipy-ad >/dev/null 2>&1 || pipx upgrade certipy-ad >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# 3. Espacio de trabajo y variables de sesion
# --------------------------------------------------------------------------- #
log "Preparando ~/bifrost"
mkdir -p "$HOME/bifrost/loot" "$HOME/bifrost/payloads" "$HOME/bifrost/logs"

# Generado desde la unica fuente de verdad: nada de valores incrustados.
cat > "$HOME/bifrost/env.sh" <<EOF
# Generado por provision/kali-tools.sh desde config/lab.env
# No editar a mano: cambia config/lab.env y vuelve a ejecutar apply.sh kali.
export LHOST="$BIFROST_IP_KALI"
export TARGET_SCANNER="$BIFROST_IP_SCANNER"
export TARGET_WEB="$BIFROST_IP_WEB"
export TARGET_APP="$BIFROST_IP_APP"
export TARGET_DC="$BIFROST_IP_DC"
export TARGET_WS="$BIFROST_IP_WS"
export BIFROST_DOMAIN="$BIFROST_DOMAIN"
export BIFROST_NETBIOS="$BIFROST_NETBIOS"
export BIFROST_SVC_USER="$BIFROST_SVC_USER"
export BIFROST_SVC_PASS="$BIFROST_SVC_PASS"
export BIFROST_APP_USER="$BIFROST_APP_USER"
export BIFROST_APP_PASS="$BIFROST_APP_PASS"
export BIFROST_LDAP_PORT="$BIFROST_LDAP_PORT"
export BIFROST_HTTP_PORT="$BIFROST_HTTP_PORT"
export BIFROST_REVSHELL_PORT="$BIFROST_REVSHELL_PORT"
export BIFROST_SOLR_PORT="$BIFROST_SOLR_PORT"
EOF

chmod 600 "$HOME/bifrost/env.sh"

if ! grep -q 'bifrost/env.sh' "$HOME/.bashrc" 2>/dev/null; then
    printf '\n# Bifrost lab\n[ -r "$HOME/bifrost/env.sh" ] && . "$HOME/bifrost/env.sh"\n' >> "$HOME/.bashrc"
fi

# --------------------------------------------------------------------------- #
# 4. Verificacion
# --------------------------------------------------------------------------- #
log "Verificando herramientas"
check() {
    if command -v "$1" >/dev/null 2>&1; then
        printf '  [ OK ] %s\n' "$1"
    else
        printf '  [FALTA] %s\n' "$1"
    fi
}

for tool in java javac mvn git nc chisel; do check "$tool"; done

for script in ntlmrelayx.py PetitPotam.py; do
    if command -v "$script" >/dev/null 2>&1; then
        printf '  [ OK ] %s\n' "$script"
    elif [ -f "/usr/share/doc/impacket/examples/$script" ]; then
        printf '  [ OK ] %s (en /usr/share/doc/impacket/examples)\n' "$script"
    else
        printf '  [FALTA] %s\n' "$script"
    fi
done

if command -v certipy >/dev/null 2>&1; then
    printf '  [ OK ] certipy\n'
else
    printf '  [FALTA] certipy (pipx install certipy-ad)\n'
fi

cat <<EOF

============================================================================
 kali listo
   Variables : source ~/bifrost/env.sh   (ya en .bashrc)
   Workspace : ~/bifrost/{loot,payloads,logs}

 Siguiente:
   cd exploits/log4shell && ./build.sh && ./selftest.sh
============================================================================
EOF
