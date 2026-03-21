#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# SGE — Configuracion de repositorios de dependencias
#
# Este script agrega los repositorios necesarios para instalar SGE en
# Debian 13 (trixie). Debe ejecutarse UNA SOLA VEZ antes de apt install sge.
#
# Uso:
#   curl -fsSL https://packages.humanbyte.net/setup.sh | sudo bash
#
# Repositorios que agrega:
#   - PostgreSQL (pgdg) para postgresql-18
#   - NodeSource para nodejs 24 LTS
#   - Terracenter para el paquete sge
# ─────────────────────────────────────────────────────────────────────────────

set -e

# Solo Debian — no Ubuntu, no derivados
if [ ! -f /etc/debian_version ]; then
    echo "ERROR: Este script es solo para Debian." >&2
    exit 1
fi

DEBIAN_CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
if [ "$DEBIAN_CODENAME" != "trixie" ]; then
    echo "AVISO: Detectado Debian '$DEBIAN_CODENAME'." >&2
    echo "       SGE esta validado en Debian 13 (trixie)." >&2
    echo "       Otras versiones no tienen soporte oficial." >&2
    read -r -p "Continuar de todas formas? [s/N] " resp
    [[ "$resp" =~ ^[sS]$ ]] || exit 1
fi

echo "==> Actualizando lista de paquetes base..."
apt-get update -qq

echo "==> Instalando dependencias del sistema para agregar repos..."
apt-get install -y -qq curl ca-certificates gnupg

# ── PostgreSQL 18 (pgdg) ──────────────────────────────────────────────────────
echo "==> Agregando repositorio PostgreSQL (pgdg)..."
install -d /usr/share/postgresql-common/pgdg
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${DEBIAN_CODENAME}-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list

# ── Node.js 24 LTS (NodeSource) ───────────────────────────────────────────────
echo "==> Agregando repositorio Node.js 24 LTS (NodeSource)..."
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg

echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] \
https://deb.nodesource.com/node_24.x nodistro main" \
    > /etc/apt/sources.list.d/nodesource.list

# ── Terracenter (paquete sge) ─────────────────────────────────────────────────
echo "==> Agregando repositorio Terracenter (SGE)..."
curl -fsSL https://packages.humanbyte.net/gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/terracenter.gpg

echo "deb [signed-by=/usr/share/keyrings/terracenter.gpg] \
https://packages.humanbyte.net/apt stable main" \
    > /etc/apt/sources.list.d/terracenter.list

# ── Actualizar e informar ─────────────────────────────────────────────────────
echo "==> Actualizando lista de paquetes..."
apt-get update -qq

echo ""
echo "Repositorios configurados correctamente."
echo ""
echo "Para instalar SGE ejecute:"
echo "  sudo apt install sge"
echo ""
