#!/bin/bash
# =============================================================================
# SGE — Script de instalación
# Terracenter C.A. — https://humanbyte.net
#
# Prerequisitos (instalar manualmente ANTES de ejecutar este script):
#   - PostgreSQL 18 corriendo con timescaledb y pg_stat_statements habilitados
#   - Node.js 24 LTS instalado
#   - Ver: docs/deploy/implementador.md
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/terracenter/sge-deploy/main/packaging/install.sh \
#     -o /tmp/sge-install.sh && sudo bash /tmp/sge-install.sh
#
# Para una versión específica:
#   sudo bash /tmp/sge-install.sh --version v0.2.0
#
# Después de este script, ejecutar:
#   sudo sgectl setup
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}==>${NC} $1"; }
warn()  { echo -e "${YELLOW}AVISO:${NC} $1"; }
fatal() { echo -e "${RED}ERROR:${NC} $1" >&2; exit 1; }

# ── Argumentos ────────────────────────────────────────────────────────────────
VERSION_PIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION_PIN="$2"; shift 2 ;;
        *) fatal "Argumento desconocido: $1" ;;
    esac
done

# ── Root ──────────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || fatal "Ejecutar como root: sudo bash $0"

# ── Sistema operativo ─────────────────────────────────────────────────────────
info "Verificando sistema operativo..."
[ -f /etc/os-release ] || fatal "No se puede determinar el sistema operativo."
. /etc/os-release

[ "$ID" = "debian" ] || fatal "SGE solo soporta Debian. Detectado: $ID $VERSION_ID"

if [ "$VERSION_CODENAME" != "trixie" ]; then
    warn "SGE validado en Debian 13 (trixie). Detectado: $VERSION_CODENAME ($VERSION_ID)"
    read -r -p "¿Continuar? [s/N]: " resp
    [[ "$resp" =~ ^[sS]$ ]] || exit 1
fi

info "Sistema: Debian $VERSION_ID ($VERSION_CODENAME) ✓"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
info "Verificando prerequisitos..."
CHECKS_FAILED=0

# PostgreSQL 18 instalado y corriendo
if ! command -v pg_isready > /dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} PostgreSQL 18: no instalado"
    echo -e "       Ver: https://docs.humanbyte.net/deploy sección 1.2"
    CHECKS_FAILED=1
elif ! pg_isready -q 2>/dev/null; then
    echo -e "  ${RED}✗${NC} PostgreSQL: instalado pero NO está corriendo"
    echo -e "       Ejecutar: sudo systemctl start postgresql@18-main"
    CHECKS_FAILED=1
else
    PG_VER=$(psql --version 2>/dev/null | grep -oP '\d+' | head -1)
    if [ "${PG_VER:-0}" -ne 18 ]; then
        echo -e "  ${RED}✗${NC} PostgreSQL: versión ${PG_VER} detectada, se requiere 18"
        CHECKS_FAILED=1
    else
        echo -e "  ${GREEN}✓${NC} PostgreSQL 18 corriendo"
    fi
fi

# TimescaleDB disponible en PostgreSQL
if pg_isready -q 2>/dev/null; then
    TSDB=$(runuser -u postgres -- psql -tAc \
        "SELECT name FROM pg_available_extensions WHERE name = 'timescaledb';" 2>/dev/null || true)
    if [ "${TSDB:-}" = "timescaledb" ]; then
        echo -e "  ${GREEN}✓${NC} TimescaleDB disponible"
    else
        echo -e "  ${RED}✗${NC} TimescaleDB: no disponible en PostgreSQL"
        echo -e "       Instalar: apt install timescaledb-2-postgresql-18"
        echo -e "       Luego:    timescaledb-tune --memory 4GB --cpus 2 --max-conns 50 --quiet --yes"
        echo -e "                 systemctl restart postgresql@18-main"
        CHECKS_FAILED=1
    fi
fi

# pg_stat_statements en shared_preload_libraries
if pg_isready -q 2>/dev/null; then
    PRELOAD=$(runuser -u postgres -- psql -tAc \
        "SHOW shared_preload_libraries;" 2>/dev/null || true)
    if echo "${PRELOAD:-}" | grep -q "pg_stat_statements"; then
        echo -e "  ${GREEN}✓${NC} pg_stat_statements en shared_preload_libraries"
    else
        echo -e "  ${RED}✗${NC} pg_stat_statements: no está en shared_preload_libraries"
        echo -e "       Actual: ${PRELOAD:-<vacío>}"
        echo -e "       Ejecutar: sudo sed -i \"s/shared_preload_libraries = 'timescaledb'/shared_preload_libraries = 'timescaledb,pg_stat_statements'/\" /etc/postgresql/18/main/postgresql.conf"
        echo -e "       Luego:    sudo systemctl restart postgresql@18-main"
        CHECKS_FAILED=1
    fi
fi

# Node.js 24+
if ! command -v node > /dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} Node.js: no instalado"
    echo -e "       Instalar: curl -fsSL https://deb.nodesource.com/setup_24.x | bash - && apt install nodejs"
    CHECKS_FAILED=1
else
    NODE_MAJOR=$(node --version 2>/dev/null | grep -oP '(?<=v)\d+' | head -1)
    if [ "${NODE_MAJOR:-0}" -ge 24 ]; then
        echo -e "  ${GREEN}✓${NC} Node.js $(node --version)"
    else
        echo -e "  ${RED}✗${NC} Node.js $(node --version): se requiere v24 o superior"
        echo -e "       Ver: https://docs.humanbyte.net/deploy sección 1.8"
        CHECKS_FAILED=1
    fi
fi

if [ "$CHECKS_FAILED" -ne 0 ]; then
    echo ""
    fatal "Hay prerequisitos faltantes. Ver: https://docs.humanbyte.net/deploy"
fi

info "Todos los prerequisitos verificados ✓"

# ── Consultar GitHub Releases ─────────────────────────────────────────────────
info "Consultando GitHub Releases..."

REPO="terracenter/sge-deploy"

if [ -n "$VERSION_PIN" ]; then
    API_URL="https://api.github.com/repos/${REPO}/releases/tags/${VERSION_PIN}"
else
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
fi

RELEASE_JSON=$(curl -fsSL --max-time 30 \
    -H "Accept: application/vnd.github+json" \
    "$API_URL") || fatal "No se pudo conectar con GitHub API (timeout o red)."

# Parsear con python3
PARSED=$(python3 - "$RELEASE_JSON" <<'PYEOF'
import sys, json

data = json.loads(sys.argv[1])

if "message" in data:
    print(f"ERROR: {data['message']}", file=sys.stderr)
    sys.exit(1)

for asset in data.get("assets", []):
    name = asset.get("name", "")
    if name.endswith("_amd64.deb") and name.startswith("sge_"):
        print(name)
        print(asset["browser_download_url"])
        sys.exit(0)

print("ERROR: no se encontró _amd64.deb en el release", file=sys.stderr)
sys.exit(1)
PYEOF
) || fatal "No se encontró el release o el asset .deb. Verificar: https://github.com/${REPO}/releases"

DEB_NAME=$(echo "$PARSED" | head -1)
DOWNLOAD_URL=$(echo "$PARSED" | tail -1)
VERSION=$(echo "$DEB_NAME" | sed 's/sge_//;s/_amd64\.deb//')

info "Versión: ${BOLD}${VERSION}${NC}"

# ── Descargar el .deb ─────────────────────────────────────────────────────────
info "Descargando ${DEB_NAME}..."

curl -fL --max-time 300 \
    "$DOWNLOAD_URL" \
    -o "/tmp/${DEB_NAME}" \
    --write-out "Descargados: %{size_download} bytes\n"

# Verificar magic bytes del .deb (!<arch>)
MAGIC=$(od -An -tx1 -N4 "/tmp/${DEB_NAME}" | tr -d ' \n')
echo "$MAGIC" | grep -qi "213c6172" \
    || fatal "Archivo inválido (${MAGIC}). Tamaño: $(wc -c < "/tmp/${DEB_NAME}") bytes"

info "Descarga verificada ✓"

# ── Instalar ──────────────────────────────────────────────────────────────────
info "Instalando SGE ${VERSION}..."
apt-get install -y "/tmp/${DEB_NAME}"
rm -f "/tmp/${DEB_NAME}"

# ── Finalizado ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  SGE ${VERSION} instalado correctamente              ${NC}"
echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════${NC}"
echo ""
echo "  Para completar la configuración ejecute:"
echo ""
echo -e "    ${BOLD}sudo sgectl setup${NC}"
echo ""
