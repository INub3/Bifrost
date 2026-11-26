#!/usr/bin/env bash
# =============================================================================
#  tests/check-consistency.sh - valida el contrato de estandarizacion.
#
#  Comprueba que:
#    1. config/lab.env existe y tiene todas las claves obligatorias.
#    2. Ningun script lleva IPs ni credenciales literales (solo config/ y docs).
#    3. El cargador bash y el parser Python derivan los mismos objetivos.
#    4. No hay secretos del escenario (.pfx/.ccache/.kirbi) dentro del repo.
#
#  Uso:
#      bash tests/check-consistency.sh        # Linux/macOS/git-bash
#
#  Salida: 0 = contrato OK, 1 = algo falla.
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

# Bajo git-bash, $ROOT es una ruta MSYS (/c/...) que el Python de Windows no
# entiende. Se convierte para pasarsela solo a Python; grep/find siguen en MSYS.
ROOT_PY="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
    ROOT_PY="$(cygpath -m "$ROOT")"
fi

# shellcheck disable=SC1090
. "$ROOT/config/lab.sh"
bifrost_load_config "$ROOT"

failures=0
pass() { printf '  [ OK ] %s\n' "$*"; }
fail() { printf '  [FAIL] %s\n' "$*"; failures=$((failures + 1)); }

echo "== Bifrost: verificacion de consistencia =="

# --- 1. Claves obligatorias -------------------------------------------------- #
missing=""
for key in $BIFROST_REQUIRED_KEYS; do
    eval "value=\${$key:-}"
    [ -n "$value" ] || missing="$missing $key"
done
if [ -n "$missing" ]; then
    fail "claves ausentes en config/lab.env:$missing"
else
    pass "config/lab.env completo ($BIFROST_CONFIG_FILE)"
fi

# --- 2. Sin literales en scripts --------------------------------------------- #
hits="$(grep -rnE '10\.10\.0\.|192\.168\.56\.|Verano2024|Bifrost2026|Bifrost-Admin|Bifrost-DSRM' \
    "$ROOT" --include='*.sh' --include='*.ps1' --include='*.py' 2>/dev/null \
    | grep -v '/config/' | grep -v '/tests/' || true)"
if [ -n "$hits" ]; then
    fail "literales encontrados en scripts (deben vivir solo en config/):"
    printf '%s\n' "$hits" | sed 's/^/      /'
else
    pass "ningun literal de IP/credencial en scripts"
fi

# --- 3. Bash vs Python ------------------------------------------------------- #
python=""
if command -v python3 >/dev/null 2>&1; then
    python="python3"
elif command -v python >/dev/null 2>&1; then
    python="python"
fi

if [ -z "$python" ]; then
    pass "python no disponible: se omite la comparacion de motores"
else
    py_targets="$("$python" - "$ROOT_PY/tenable" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import tenable_scan
print(tenable_scan.default_targets())
PY
)"
    bash_targets="$BIFROST_IP_WEB,$BIFROST_IP_DC"

    if [ "$py_targets" = "$bash_targets" ]; then
        pass "bash y Python derivan los mismos objetivos ($bash_targets)"
    else
        fail "discrepancia de objetivos: bash='$bash_targets' python='$py_targets'"
    fi
fi

# --- 4. Sin secretos sueltos ------------------------------------------------- #
secrets="$(find "$ROOT" -type f \( -name '*.pfx' -o -name '*.ccache' -o -name '*.kirbi' \) 2>/dev/null || true)"
if [ -n "$secrets" ]; then
    fail "secretos del escenario dentro del repo (muevelos o ignoralos):"
    printf '%s\n' "$secrets" | sed 's/^/      /'
else
    pass "sin .pfx/.ccache/.kirbi en el repo"
fi

echo
if [ "$failures" -gt 0 ]; then
    printf '  RESULTADO: %s comprobacion(es) fallaron.\n' "$failures"
    exit 1
fi
printf '  RESULTADO: contrato de estandarizacion OK.\n'
