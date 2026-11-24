#!/usr/bin/env bash
# =============================================================================
#  bifrost.sh - control del laboratorio en hosts Linux/macOS.
#
#  Equivalente a bifrost.ps1. Mismos verbos, mismos valores, misma configuracion
#  (config/lab.env). Sirve para construir el laboratorio desde un portatil Linux
#  o un Mac con Fusion sin tocar nada mas.
#
#  Uso:
#      ./bifrost.sh preflight
#      ./bifrost.sh config
#      ./bifrost.sh start all
#      ./bifrost.sh snapshot all
#      ./bifrost.sh reset all
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --------------------------------------------------------------------------- #
# Configuracion
# --------------------------------------------------------------------------- #
# shellcheck disable=SC1091
. "$SCRIPT_DIR/config/lab.sh"
bifrost_load_config "$SCRIPT_DIR"

VM_DIR="$(bifrost_vm_dir)"
SNAPSHOT_LABEL="${BIFROST_SNAPSHOT}"
DISK_BUDGET="${BIFROST_DISK_BUDGET_GB:-100}"

case "$(uname -s)" in
    Darwin) VMWARE_TYPE="${BIFROST_VMWARE_TYPE:-fusion}" ;;
    *)      VMWARE_TYPE="${BIFROST_VMWARE_TYPE:-ws}" ;;
esac
if [ "$VMWARE_TYPE" = "ws" ] && [ "$(uname -s)" = "Darwin" ]; then
    VMWARE_TYPE="fusion"
fi

# --------------------------------------------------------------------------- #
# Salida
# --------------------------------------------------------------------------- #
section() {
    local title="$1" width
    width=$((60 - ${#title}))
    [ "$width" -lt 3 ] && width=3
    printf '\n== %s %s\n' "$title" "$(printf '%0.s-' $(seq 1 "$width"))"
}
ok()      { printf '  [ OK ] %s\n' "$1"; }
warn()    { printf '  [WARN] %s\n' "$1"; }
fail()    { printf '  [FAIL] %s\n' "$1"; }
info()    { printf '  [INFO] %s\n' "$1"; }
hint()    { printf '         -> %s\n' "$1"; }

# --------------------------------------------------------------------------- #
# vmrun
# --------------------------------------------------------------------------- #
find_vmrun() {
    local candidates=()

    [ -n "${BIFROST_VMRUN:-}" ] && candidates+=("$BIFROST_VMRUN")
    command -v vmrun >/dev/null 2>&1 && candidates+=("$(command -v vmrun)")
    candidates+=(
        "/usr/bin/vmrun"
        "/usr/lib/vmware/bin/vmrun"
        "/Applications/VMware Fusion.app/Contents/Public/vmrun"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    return 1
}

VMRUN="$(find_vmrun || true)"

vmrun_run() {
    # Devuelve la salida y el codigo en VMRUN_OUT / VMRUN_CODE
    [ -n "$VMRUN" ] || { VMRUN_OUT="vmrun no encontrado"; VMRUN_CODE=127; return 0; }
    VMRUN_OUT="$("$VMRUN" -T "$VMWARE_TYPE" "$@" 2>&1)"
    VMRUN_CODE=$?
}

# --------------------------------------------------------------------------- #
# Inventario
# --------------------------------------------------------------------------- #
list_vms() {
    [ -d "$VM_DIR" ] || return 0
    find "$VM_DIR" -name '*.vmx' -type f 2>/dev/null | sort
}

vm_names() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        basename "$vmx" .vmx
    done <<< "$(list_vms)"
}

vm_path() {
    local name="$1"
    local path
    path="$(list_vms | awk -v n="$name" 'BEGIN{IGNORECASE=0} {
        base=$0; sub(/^.*\//, "", base); sub(/\.vmx$/, "", base);
        if (base == n) { print; exit }
    }')"
    [ -n "$path" ] || return 1
    printf '%s\n' "$path"
}

running_vms() {
    [ -n "$VMRUN" ] || return 0
    "$VMRUN" -T "$VMWARE_TYPE" list 2>/dev/null | tail -n +2
}

vm_snapshots() {
    local vmx="$1"
    [ -n "$VMRUN" ] || return 0
    "$VMRUN" -T "$VMWARE_TYPE" listSnapshots "$vmx" 2>/dev/null | tail -n +2
}

# --------------------------------------------------------------------------- #
# Comandos
# --------------------------------------------------------------------------- #
cmd_config() {
    section "Configuracion ($BIFROST_CONFIG_FILE)"
    local key value
    while IFS='=' read -r key value; do
        case "$key" in ''|\#*) continue ;; esac
        key="$(printf '%s' "$key" | tr -d '[:space:]')"
        value="${value%\"}"; value="${value#\"}"
        case "$key" in
            *PASS*|*SECRET*|*_API_KEY*) value="******" ;;
        esac
        printf '  %-30s %s\n' "$key" "$value"
    done < "$BIFROST_CONFIG_FILE"
    printf '  %-30s %s\n' "BIFROST_VM_DIR (resuelto)" "$VM_DIR"
    printf '  %-30s %s\n' "vmrun" "${VMRUN:-no encontrado}"
}

cmd_preflight() {
    section "Bifrost ${BIFROST_VERSION} preflight"
    local failures=0 warnings=0

    ok "Configuracion: $BIFROST_CONFIG_FILE"

    if [ -n "$VMRUN" ]; then
        ok "vmrun ($VMWARE_TYPE): $VMRUN"
    else
        fail "vmrun no encontrado"
        hint "Instala VMware Workstation/Fusion o define BIFROST_VMRUN"
        failures=$((failures + 1))
    fi

    # Red host-only
    if ls /sys/class/net 2>/dev/null | grep -q '^vmnet' \
        || ifconfig -a 2>/dev/null | grep -q '^vmnet'; then
        ok "Red host-only presente"
    else
        fail "No hay red host-only (vmnet1)"
        hint "vmware-networks --start   o revisa /etc/vmware/networking"
        failures=$((failures + 1))
    fi

    if [ -d "$VM_DIR" ]; then
        ok "Carpeta de VMs: $VM_DIR"
    else
        warn "Carpeta de VMs no existe: $VM_DIR"
        hint "Se crea al construir la primera VM"
        warnings=$((warnings + 1))
    fi

    # Disco
    local probe="$VM_DIR"
    [ -d "$probe" ] || probe="$SCRIPT_DIR"
    local free_gb
    free_gb="$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')"
    if [ -n "$free_gb" ]; then
        if [ "$free_gb" -ge "$DISK_BUDGET" ]; then
            ok "Espacio libre: ${free_gb} GB"
        elif [ "$free_gb" -ge 30 ]; then
            warn "Espacio libre: ${free_gb} GB (el lab completo pide ~${DISK_BUDGET} GB)"
            hint "Alcanza para Lab Lite; apunta BIFROST_VM_DIR a un disco mayor"
            warnings=$((warnings + 1))
        else
            fail "Espacio libre: ${free_gb} GB"
            hint "Mueve BIFROST_VM_DIR a un disco con espacio"
            failures=$((failures + 1))
        fi
    else
        info "No se pudo medir el espacio libre"
    fi

    # RAM
    local ram_gb=""
    if [ -r /proc/meminfo ]; then
        ram_gb="$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)"
    elif command -v sysctl >/dev/null 2>&1; then
        ram_gb="$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1073741824}')"
    fi

    if [ -n "$ram_gb" ]; then
        if [ "$ram_gb" -ge 32 ]; then
            ok "RAM total: ${ram_gb} GB"
        elif [ "$ram_gb" -ge 14 ]; then
            warn "RAM total: ${ram_gb} GB"
            hint "Suficiente con arranque escalonado"
            warnings=$((warnings + 1))
        else
            fail "RAM total: ${ram_gb} GB"
            hint "Menos de 14 GB no sostiene la cadena completa"
            failures=$((failures + 1))
        fi
    else
        info "RAM no verificable en este sistema"
    fi

    # Python
    local python=""
    command -v python3 >/dev/null 2>&1 && python="python3"
    [ -z "$python" ] && command -v python >/dev/null 2>&1 && python="python"

    if [ -n "$python" ]; then
        ok "Python: $(command -v "$python")"
        if "$python" -c 'import requests' >/dev/null 2>&1; then
            ok "requests $("$python" -c 'import requests; print(requests.__version__)')"
        else
            warn "Paquete requests ausente"
            hint "pip install requests"
            warnings=$((warnings + 1))
        fi
    else
        fail "Python no encontrado"
        hint "Necesario para tenable_scan.py"
        failures=$((failures + 1))
    fi

    if command -v ssh >/dev/null 2>&1; then
        ok "Cliente OpenSSH disponible"
    else
        warn "Cliente ssh no encontrado"
        warnings=$((warnings + 1))
    fi

    local count
    count="$(list_vms | wc -l | tr -d ' ')"
    if [ "$count" -gt 0 ]; then
        info "VMs detectadas: $(vm_names | tr '\n' ' ')"
    else
        info "VMs detectadas: ninguna todavia"
    fi

    printf '\n'
    if [ "$failures" -gt 0 ]; then
        printf '  VEREDICTO: %s bloqueante(s), %s advertencia(s).\n' "$failures" "$warnings"
        return 1
    fi
    if [ "$warnings" -gt 0 ]; then
        printf '  VEREDICTO: listo con %s advertencia(s).\n' "$warnings"
        return 0
    fi
    printf '  VEREDICTO: entorno listo.\n'
}

cmd_status() {
    section 'VMs del laboratorio'
    local vms
    vms="$(list_vms)"
    if [ -z "$vms" ]; then
        warn "Sin VMs en $VM_DIR"
        hint "Sigue GUIDE.md"
        return 0
    fi

    local running
    running="$(running_vms)"
    local vmx name state snaps
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        name="$(basename "$vmx" .vmx)"
        if printf '%s\n' "$running" | grep -Fxq "$vmx"; then
            state="ENCENDIDA"
        else
            state="apagada"
        fi
        snaps="$(vm_snapshots "$vmx" | tr '\n' ',' | sed 's/,$//')"
        [ -n "$snaps" ] || snaps="sin snapshots"
        printf '  %-10s %-12s %s\n' "$name" "$state" "$snaps"
    done <<< "$vms"
}

resolve_targets() {
    local target="${1:-}"
    if [ -z "$target" ]; then
        printf 'ERROR: indica una VM o "all".\n' >&2
        return 1
    fi
    if [ "$target" = "all" ]; then
        list_vms
        return 0
    fi
    local vmx
    vmx="$(vm_path "$target")" || {
        printf "ERROR: VM '%s' no encontrada. Disponibles: %s\n" \
            "$target" "$(vm_names | tr '\n' ' ')" >&2
        return 1
    }
    printf '%s\n' "$vmx"
}

cmd_start() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        printf '  encendiendo %s... ' "$(basename "$vmx" .vmx)"
        vmrun_run start "$vmx" nogui
        if [ "$VMRUN_CODE" -eq 0 ]; then printf 'OK\n'; else printf 'FALLO\n    %s\n' "$VMRUN_OUT"; fi
    done <<< "$(resolve_targets "${1:-}")"
}

cmd_stop() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        printf '  apagando %s... ' "$(basename "$vmx" .vmx)"
        vmrun_run stop "$vmx" soft
        [ "$VMRUN_CODE" -ne 0 ] && vmrun_run stop "$vmx" hard
        if [ "$VMRUN_CODE" -eq 0 ]; then printf 'OK\n'; else printf 'FALLO\n    %s\n' "$VMRUN_OUT"; fi
    done <<< "$(resolve_targets "${1:-}")"
}

cmd_snapshot() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        local name
        name="$(basename "$vmx" .vmx)"
        if vm_snapshots "$vmx" | grep -Fxq "$SNAPSHOT_LABEL"; then
            warn "$name: el snapshot '$SNAPSHOT_LABEL' ya existe"
            continue
        fi
        printf '  snapshot %s -> %s ... ' "$name" "$SNAPSHOT_LABEL"
        vmrun_run snapshot "$vmx" "$SNAPSHOT_LABEL"
        if [ "$VMRUN_CODE" -eq 0 ]; then printf 'OK\n'; else printf 'FALLO\n    %s\n' "$VMRUN_OUT"; fi
    done <<< "$(resolve_targets "${1:-}")"
}

cmd_reset() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        local name
        name="$(basename "$vmx" .vmx)"

        if ! vm_snapshots "$vmx" | grep -Fxq "$SNAPSHOT_LABEL"; then
            fail "$name: no existe el snapshot '$SNAPSHOT_LABEL'"
            hint "Crealo primero: ./bifrost.sh snapshot $name"
            continue
        fi

        printf '  revirtiendo %s a %s ... ' "$name" "$SNAPSHOT_LABEL"
        if running_vms | grep -Fxq "$vmx"; then
            vmrun_run stop "$vmx" hard
        fi
        vmrun_run revertToSnapshot "$vmx" "$SNAPSHOT_LABEL"
        if [ "$VMRUN_CODE" -eq 0 ]; then printf 'OK\n'; else printf 'FALLO\n    %s\n' "$VMRUN_OUT"; fi
    done <<< "$(resolve_targets "${1:-}")"

    printf '\n'
    info "Las VMs quedan apagadas en el estado del snapshot."
}

cmd_ip() {
    local vmx
    while IFS= read -r vmx; do
        [ -n "$vmx" ] || continue
        vmrun_run getGuestIPAddress "$vmx" -wait
        local ip="sin IP (VM apagada o sin VMware Tools)"
        [ "$VMRUN_CODE" -eq 0 ] && ip="$(printf '%s' "$VMRUN_OUT" | head -n1)"
        printf '  %-10s %s\n' "$(basename "$vmx" .vmx)" "$ip"
    done <<< "$(resolve_targets "${1:-}")"
}

cmd_scan() {
    local python=""
    command -v python3 >/dev/null 2>&1 && python="python3"
    [ -z "$python" ] && command -v python >/dev/null 2>&1 && python="python"
    [ -n "$python" ] || { printf 'ERROR: python no encontrado.\n' >&2; return 1; }

    "$python" "$SCRIPT_DIR/tenable/tenable_scan.py" "$@"
}

usage() {
    cat <<'EOF'
Bifrost - control del laboratorio (VMware Workstation / Fusion)

  ./bifrost.sh preflight            Verifica entorno, red y disco
  ./bifrost.sh config               Valores efectivos (secretos ocultos)
  ./bifrost.sh status               VMs y snapshots
  ./bifrost.sh start <vm|all>       Enciende sin GUI
  ./bifrost.sh stop <vm|all>        Apaga
  ./bifrost.sh snapshot <vm|all>    Crea snapshot (etiqueta: BIFROST_SNAPSHOT)
  ./bifrost.sh reset <vm|all>       Revierte al snapshot
  ./bifrost.sh ip <vm|all>          IP de la VM
  ./bifrost.sh scan -- <args>       Pasa argumentos a tenable_scan.py

Valores: config/lab.env  (unica fuente de verdad)
EOF
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
case "${1:-help}" in
    preflight) cmd_preflight ;;
    config)    cmd_config ;;
    status)    cmd_status ;;
    start)     cmd_start "${2:-}" ;;
    stop)      cmd_stop "${2:-}" ;;
    snapshot|snap) cmd_snapshot "${2:-}" ;;
    reset|revert)  cmd_reset "${2:-}" ;;
    ip)        cmd_ip "${2:-}" ;;
    list)      list_vms ;;
    scan)      shift; cmd_scan "$@" ;;
    *)         usage ;;
esac
