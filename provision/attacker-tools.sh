#!/usr/bin/env bash
# =============================================================================
#  attacker - prepara el HOST (ParrotOS) como maquina atacante del laboratorio.
#
#  Se ejecuta LOCALMENTE en el host (no por SSH). Configura ~/bifrost, genera
#  env.sh desde config/lab.env y verifica/instala las herramientas.
#
#  ParrotOS ya trae la mayoria de las herramientas; este script instala lo que
#  falte y deja todo consistente con la configuracion.
#
#  Uso:  bash provision/attacker-tools.sh
# =============================================================================
set -euo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_scan="$_here"
for _ in 1 2 3 4 5; do
    if [ -r "$_scan/config/lab.sh" ]; then
        # shellcheck disable=SC1090
        . "$_scan/config/lab.sh"
        break
    fi
    _scan="$(dirname "$_scan")"
done
if ! command -v bifrost_load_config >/dev/null 2>&1; then
    echo "ERROR: no se encontro config/lab.sh. Ejecuta desde el repositorio." >&2
    exit 1
fi
bifrost_load_config "$_here"

# pipx y los symlinks de herramientas viven en ~/.local/bin
export PATH="$HOME/.local/bin:$PATH"

log() { printf '\n[bifrost] %s\n' "$*"; }

command -v apt-get >/dev/null 2>&1 || { echo "Esto espera un Debian/ParrotOS." >&2; exit 1; }

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# --------------------------------------------------------------------------- #
# 0. Conectividad
# --------------------------------------------------------------------------- #
if ! curl -sfI --max-time 8 https://deb.parrot.sh/ >/dev/null 2>&1; then
    echo "[bifrost] ERROR: sin salida a internet en el host (apt lo necesita)." >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# 1. Paquetes base
# --------------------------------------------------------------------------- #
log "Instalando/verificando paquetes (ParrotOS ya trae varios)"
$SUDO apt-get update -qq
$SUDO apt-get install -y -qq \
    openjdk-11-jdk maven git curl netcat-openbsd \
    impacket-scripts python3-pip pipx chisel \
    >/dev/null 2>&1 || true

# netexec: el nombre del paquete varia segun la version.
$SUDO apt-get install -y -qq netexec >/dev/null 2>&1 \
    || $SUDO apt-get install -y -qq nxc >/dev/null 2>&1 \
    || echo "  (netexec no disponible via apt; se usara impacket como alternativa)"

# --------------------------------------------------------------------------- #
# 2. certipy
# --------------------------------------------------------------------------- #
log "Instalando certipy-ad (via pipx)"
pipx ensurepath >/dev/null 2>&1 || true
pipx install certipy-ad >/dev/null 2>&1 || pipx upgrade certipy-ad >/dev/null 2>&1 || true

# --------------------------------------------------------------------------- #
# 3. Interfaz host-only del atacante
# --------------------------------------------------------------------------- #
log "Verificando interfaz host-only (VMnet1)"
if ip -br a 2>/dev/null | grep -q "$BIFROST_IP_ATTACKER"; then
    echo "  [ OK ] el host ya tiene $BIFROST_IP_ATTACKER en alguna interfaz"
else
    cat <<EOF
  [AVISO] No se detecta $BIFROST_IP_ATTACKER en el host.
  Configura la interfaz host-only (VMnet1) del host con esa IP, por ejemplo:

      sudo ip addr add $BIFROST_IP_ATTACKER/$BIFROST_PREFIX dev vmnet1

  El nombre de la interfaz puede ser vmnet1 u otro: revisa 'ip -br a'.
  Ver GUIDE.md, paso 0.
EOF
fi

# --------------------------------------------------------------------------- #
# 3b. Firewall del host (si ufw esta activo)
# --------------------------------------------------------------------------- #
if command -v ufw >/dev/null 2>&1; then
    log "Permitiendo puertos del laboratorio en ufw"
    for port in "$BIFROST_LDAP_PORT" "$BIFROST_HTTP_PORT" "$BIFROST_PROBE_PORT" \
                "$BIFROST_REVSHELL_PORT" 445; do
        $SUDO ufw allow from "${BIFROST_NETWORK}/${BIFROST_PREFIX}" to any port "$port" proto tcp \
            >/dev/null 2>&1 || true
    done
    echo "  [ OK ] reglas para ${BIFROST_NETWORK}/${BIFROST_PREFIX} (LDAP, HTTP, probe, shell y relay SMB)"
fi

# --------------------------------------------------------------------------- #
# 4. Espacio de trabajo y variables de sesion
# --------------------------------------------------------------------------- #
log "Preparando ~/bifrost"
mkdir -p "$HOME/bifrost/loot" "$HOME/bifrost/payloads" "$HOME/bifrost/logs" "$HOME/bifrost/tools"

# PetitPotam para la coercion de ESC8: no viene en impacket.
if [ ! -f "$HOME/bifrost/tools/PetitPotam/PetitPotam.py" ]; then
    log "Clonando PetitPotam"
    git clone --depth 1 https://github.com/topotam/PetitPotam \
        "$HOME/bifrost/tools/PetitPotam" >/dev/null 2>&1 || true
fi

# En Parrot impacket se instala como impacket-ntlmrelayx, etc. Crea los nombres
# .py que usa la guia si no existen, y deja PetitPotam.py en ~/.local/bin.
mkdir -p "$HOME/.local/bin"
[ -x /usr/bin/impacket-ntlmrelayx ]  && ln -sf /usr/bin/impacket-ntlmrelayx  "$HOME/.local/bin/ntlmrelayx.py"  2>/dev/null || true
[ -x /usr/bin/impacket-secretsdump ] && ln -sf /usr/bin/impacket-secretsdump "$HOME/.local/bin/secretsdump.py" 2>/dev/null || true
[ -x /usr/bin/impacket-psexec ]      && ln -sf /usr/bin/impacket-psexec      "$HOME/.local/bin/psexec.py"      2>/dev/null || true
[ -f "$HOME/bifrost/tools/PetitPotam/PetitPotam.py" ] && \
    ln -sf "$HOME/bifrost/tools/PetitPotam/PetitPotam.py" "$HOME/.local/bin/PetitPotam.py" 2>/dev/null || true
[ -f "$HOME/bifrost/tools/PetitPotam/PetitPotam.py" ] && \
    chmod +x "$HOME/bifrost/tools/PetitPotam/PetitPotam.py" 2>/dev/null || true

# Generado desde la unica fuente de verdad: nada de valores incrustados.
cat > "$HOME/bifrost/env.sh" <<EOF
# Generado por provision/attacker-tools.sh desde config/lab.env
# No editar a mano: cambia config/lab.env y vuelve a ejecutar attacker-tools.sh.
export LHOST="$BIFROST_IP_ATTACKER"
export TARGET_WEB="$BIFROST_IP_WEB"
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
# 5. Verificacion
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

for script in ntlmrelayx.py PetitPotam.py secretsdump.py psexec.py; do
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
 host atacante listo
   Variables : source ~/bifrost/env.sh   (ya en .bashrc)
   Workspace : ~/bifrost/{loot,payloads,logs}

 Siguiente (desde este host):
   cd exploits/log4shell && ./build.sh && ./selftest.sh
============================================================================
EOF
