#!/usr/bin/env bash
# ============================================================================
# SGE — Instalador de Producción
# Uso: bash install.sh
# Requisitos: Debian 13, usuario con sudo
# ============================================================================
set -euo pipefail

SGE_REPO="terracenter/sge"
DEPLOY_REPO="terracenter/sge-deploy"
GO_VERSION="1.26.1"
MIGRATE_VERSION="4.19.1"
TRAEFIK_VERSION="3.6.10"
NODE_VERSION="24"

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }

# ── Verificaciones previas ────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && error "No ejecutar como root. Usar usuario con sudo."
command -v sudo &>/dev/null || error "sudo no está instalado."
. /etc/os-release
[[ "$ID" == "debian" && "$VERSION_ID" == "13" ]] || warn "Este instalador fue probado en Debian 13. Continuar bajo tu responsabilidad."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}"
echo "  ███████╗ ██████╗ ███████╗"
echo "  ██╔════╝██╔════╝ ██╔════╝"
echo "  ███████╗██║  ███╗█████╗  "
echo "  ╚════██║██║   ██║██╔══╝  "
echo "  ███████║╚██████╔╝███████╗"
echo "  ╚══════╝ ╚═════╝ ╚══════╝"
echo -e "${NC}  Sistema de Gestión Empresarial — Instalador v1.0"
echo ""

# ── Detectar CPU level ────────────────────────────────────────────────────────
section "Detección de CPU"
detect_cpu_level() {
    if grep -q "avx512f" /proc/cpuinfo 2>/dev/null; then
        echo "v4"
    elif grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
        echo "v3"
    else
        echo "v2"
    fi
}
CPU_LEVEL=$(detect_cpu_level)
info "CPU detectado: amd64-${CPU_LEVEL} ($(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs))"

# ── Recopilar datos de instalación ───────────────────────────────────────────
section "Configuración de la instalación"

read -rp "$(echo -e ${BOLD})Dominio del servidor (ej: sge.tuempresa.com): $(echo -e ${NC})" SGE_DOMAIN
[[ -z "$SGE_DOMAIN" ]] && error "El dominio es obligatorio."

read -rp "$(echo -e ${BOLD})Email para certificado SSL (Let's Encrypt): $(echo -e ${NC})" ACME_EMAIL
[[ -z "$ACME_EMAIL" ]] && error "El email es obligatorio."

read -rp "$(echo -e ${BOLD})GitHub token (lectura de releases privados): $(echo -e ${NC})" -s GH_TOKEN
echo ""
[[ -z "$GH_TOKEN" ]] && error "El token de GitHub es obligatorio."

# Generar contraseñas automáticamente
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
info "Contraseñas generadas automáticamente (hex, sin caracteres especiales)."

# Obtener última versión disponible
SGE_VERSION=$(curl -sf -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/${SGE_REPO}/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4) || error "No se pudo obtener la versión de GitHub. Verificar token."
info "Versión a instalar: ${SGE_VERSION}"

echo ""
echo -e "${BOLD}Resumen de instalación:${NC}"
echo "  Dominio:  $SGE_DOMAIN"
echo "  Email:    $ACME_EMAIL"
echo "  Versión:  $SGE_VERSION"
echo "  CPU:      amd64-${CPU_LEVEL}"
echo ""
read -rp "¿Continuar? [s/N]: " CONFIRM
[[ "${CONFIRM,,}" != "s" ]] && exit 0

# ── 1. Paquetes del sistema ───────────────────────────────────────────────────
section "1/9 Instalando paquetes del sistema"
sudo apt-get update -qq && sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    curl wget git ufw fail2ban logrotate unzip rsync \
    ca-certificates gnupg postgresql postgresql-client \
    pgbouncer redis-server

# PostgreSQL 18 desde repo oficial
if ! psql --version 2>/dev/null | grep -q "18\."; then
    info "Instalando PostgreSQL 18..."
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -qo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc
    . /etc/os-release
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] \
https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
        | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-18 postgresql-client-18
fi

# Node.js 24 LTS (system-wide)
if ! node --version 2>/dev/null | grep -q "^v24"; then
    info "Instalando Node.js ${NODE_VERSION} LTS..."
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash - > /dev/null
    sudo apt-get install -y -qq nodejs
fi

# ── 2. Golang-migrate ─────────────────────────────────────────────────────────
section "2/9 Instalando golang-migrate"
if ! migrate -version 2>/dev/null | grep -q "${MIGRATE_VERSION}"; then
    wget -q "https://github.com/golang-migrate/migrate/releases/download/v${MIGRATE_VERSION}/migrate.linux-amd64.tar.gz" -O /tmp/migrate.tar.gz
    tar xzf /tmp/migrate.tar.gz -C /tmp && sudo mv /tmp/migrate /usr/local/bin/migrate
    sudo chmod +x /usr/local/bin/migrate && rm /tmp/migrate.tar.gz
fi
info "migrate $(migrate -version)"

# ── 3. Traefik ────────────────────────────────────────────────────────────────
section "3/9 Instalando Traefik"
if ! traefik version 2>/dev/null | grep -q "${TRAEFIK_VERSION}"; then
    wget -q "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz" -O /tmp/traefik.tar.gz
    tar xzf /tmp/traefik.tar.gz -C /tmp && sudo mv /tmp/traefik /usr/local/bin/traefik
    sudo chmod +x /usr/local/bin/traefik && rm /tmp/traefik.tar.gz
fi
info "Traefik $(traefik version | head -1)"

# ── 4. Usuarios y estructura FHS ─────────────────────────────────────────────
section "4/9 Usuarios y estructura FHS"
if ! id sge &>/dev/null; then
    sudo useradd --system --shell /usr/sbin/nologin --home-dir /opt/sge sge
fi
if ! id sge-runner &>/dev/null; then
    sudo useradd --system --shell /bin/bash --create-home --home-dir /opt/sge-runner sge-runner
fi

# Sudoers
echo 'sge ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend' \
    | sudo tee /etc/sudoers.d/sge-services > /dev/null
echo 'sge-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend, /usr/local/bin/migrate' \
    | sudo tee /etc/sudoers.d/sge-runner > /dev/null
sudo chmod 440 /etc/sudoers.d/sge-services /etc/sudoers.d/sge-runner

# Estructura FHS
sudo mkdir -p /etc/sge/{keys,traefik/dynamic} /opt/sge/{bin,frontend} \
    /var/log/sge /var/lib/sge/{backups,data/redis}
sudo touch /etc/sge/traefik/acme.json
sudo chmod 600 /etc/sge/traefik/acme.json && sudo chmod 700 /etc/sge/keys
sudo chown -R sge:sge /etc/sge /opt/sge /var/log/sge /var/lib/sge
info "Estructura FHS creada."

# ── 5. Configurar servicios ───────────────────────────────────────────────────
section "5/9 Configurando PostgreSQL, Redis, PgBouncer"

# PostgreSQL
sudo -u postgres psql -c "CREATE USER sge WITH PASSWORD '$DB_PASSWORD';" 2>/dev/null || \
    sudo -u postgres psql -c "ALTER USER sge WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE sge_platform OWNER sge;" 2>/dev/null || true
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = 'localhost';"
sudo systemctl restart postgresql

# Redis
echo "bind 127.0.0.1"            | sudo tee -a /etc/redis/redis.conf > /dev/null
echo "requirepass $REDIS_PASSWORD" | sudo tee -a /etc/redis/redis.conf > /dev/null
echo "maxmemory 512mb"            | sudo tee -a /etc/redis/redis.conf > /dev/null
echo "maxmemory-policy allkeys-lru" | sudo tee -a /etc/redis/redis.conf > /dev/null
sudo systemctl restart redis-server

# PgBouncer
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null << PGCONF
[databases]
sge_platform = host=127.0.0.1 port=5432 dbname=sge_platform

[pgbouncer]
listen_addr       = 127.0.0.1
listen_port       = 5433
auth_type         = scram-sha-256
auth_file         = /etc/pgbouncer/userlist.txt
pool_mode         = transaction
max_client_conn   = 200
default_pool_size = 20
PGCONF

echo "\"sge\" \"$DB_PASSWORD\"" | sudo tee /etc/pgbouncer/userlist.txt > /dev/null
sudo chmod 640 /etc/pgbouncer/userlist.txt && sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo systemctl restart pgbouncer
info "PostgreSQL, Redis, PgBouncer configurados."

# ── 6. Descargar binarios desde GitHub Releases ───────────────────────────────
section "6/9 Descargando SGE ${SGE_VERSION} (amd64-${CPU_LEVEL})"

download_asset() {
    local ASSET=$1
    local DEST=$2
    curl -sfL \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/octet-stream" \
        "$(curl -sf -H "Authorization: token $GH_TOKEN" \
            "https://api.github.com/repos/${SGE_REPO}/releases/latest" \
            | grep "browser_download_url.*${ASSET}\"" | cut -d'"' -f4)" \
        -o "$DEST"
}

download_asset "sge-linux-amd64-${CPU_LEVEL}" /tmp/sge
download_asset "sgectl-linux-amd64-${CPU_LEVEL}" /tmp/sgectl
download_asset "sge-frontend.tar.gz" /tmp/sge-frontend.tar.gz
download_asset "sge-migrations.tar.gz" /tmp/sge-migrations.tar.gz

sudo cp /tmp/sge /opt/sge/bin/sge && sudo cp /tmp/sgectl /opt/sge/bin/sgectl
sudo chmod +x /opt/sge/bin/sge /opt/sge/bin/sgectl
sudo chown sge:sge /opt/sge/bin/sge /opt/sge/bin/sgectl

# Frontend
sudo mkdir -p /opt/sge/frontend
sudo tar -xzf /tmp/sge-frontend.tar.gz -C /opt/sge/frontend/
sudo chown -R sge:sge /opt/sge/frontend/
info "Binarios instalados."

# ── 7. Archivo .env ───────────────────────────────────────────────────────────
section "7/9 Generando configuración"
sudo tee /etc/sge/.env > /dev/null << ENV
# SGE Production Environment
# Generado: $(date)
# Versión: ${SGE_VERSION}

# Servidor
SGE_DOMAIN=${SGE_DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

# Base de datos (via PgBouncer)
DB_HOST=127.0.0.1
DB_PORT=5433
DB_NAME=sge_platform
DB_USER=sge
DB_PASSWORD=${DB_PASSWORD}
DB_SSL_MODE=disable

# Redis
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}

# App
APP_BASE_URL=https://${SGE_DOMAIN}
APP_NAME=SGE

# JWT (generar llaves con: make generate-keys)
JWT_PRIVATE_KEY_PATH=/etc/sge/keys/private.pem
JWT_PUBLIC_KEY_PATH=/etc/sge/keys/public.pem
ENV
sudo chmod 600 /etc/sge/.env && sudo chown sge:sge /etc/sge/.env

# ── 8. Systemd + Traefik ──────────────────────────────────────────────────────
section "8/9 Instalando services y Traefik"

# Actualizar dominio en routes.yml
sed -i "s/sge.humanbyte.net/${SGE_DOMAIN}/g" "$SCRIPT_DIR/traefik/dynamic/routes.yml"

sudo cp "$SCRIPT_DIR/deploy/sge.service" \
        "$SCRIPT_DIR/deploy/sge-frontend.service" \
        "$SCRIPT_DIR/deploy/sge-traefik.service" \
        /etc/systemd/system/

sudo cp "$SCRIPT_DIR/traefik/traefik.yml" /etc/sge/traefik/traefik.yml
sudo cp "$SCRIPT_DIR/traefik/dynamic/routes.yml" /etc/sge/traefik/dynamic/routes.yml
sudo chown -R sge:sge /etc/sge/traefik/

sudo systemctl daemon-reload
sudo systemctl enable sge sge-frontend sge-traefik
info "Services instalados y habilitados."

# ── 8b. Seguridad ─────────────────────────────────────────────────────────────
sudo cp "$SCRIPT_DIR/deploy/security/10-sshd-settings.conf" /etc/ssh/sshd_config.d/
sudo cp "$SCRIPT_DIR/deploy/security/banner" /etc/ssh/sshd_config.d/
sudo cp "$SCRIPT_DIR/deploy/security/jail.local" /etc/fail2ban/jail.local
sudo cp "$SCRIPT_DIR/deploy/security/filter.d/"* /etc/fail2ban/filter.d/
sudo sshd -t && sudo systemctl reload sshd
sudo systemctl restart fail2ban
info "Seguridad aplicada."

# ── 9. Migraciones y arranque ─────────────────────────────────────────────────
section "9/9 Migraciones y arranque"

tar -xzf /tmp/sge-migrations.tar.gz -C /tmp/
PGPASSWORD=$DB_PASSWORD migrate \
    -path /tmp/migrations \
    -database "postgres://sge:${DB_PASSWORD}@127.0.0.1:5433/sge_platform?sslmode=disable" \
    up
rm -rf /tmp/migrations /tmp/sge-migrations.tar.gz /tmp/sge-frontend.tar.gz /tmp/sge /tmp/sgectl

sudo systemctl start sge-traefik sge sge-frontend
sleep 5

# Health check
if curl -sf "http://127.0.0.1:8000/api/v1/health" > /dev/null; then
    info "Health check OK"
else
    warn "Health check falló — revisar: sudo journalctl -u sge -n 50"
fi

# ── Resumen final ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  SGE ${SGE_VERSION} instalado correctamente!${NC}"
echo -e "${BOLD}${GREEN}════════════════════════════════════════════${NC}"
echo ""
echo "  URL:        https://${SGE_DOMAIN}"
echo "  CPU:        amd64-${CPU_LEVEL}"
echo "  Config:     /etc/sge/"
echo "  Binarios:   /opt/sge/bin/"
echo "  Logs:       /var/log/sge/"
echo "  Backups:    /var/lib/sge/backups/"
echo ""
echo -e "${YELLOW}Próximos pasos:${NC}"
echo "  1. Generar JWT keys: /opt/sge/bin/sgectl generate-keys"
echo "  2. Activar licencia: https://${SGE_DOMAIN}/settings/licenses"
echo "  3. Configurar SMTP:  https://${SGE_DOMAIN}/settings"
echo ""
echo -e "${YELLOW}Credenciales guardadas en:${NC} /etc/sge/.env"
echo -e "${RED}¡IMPORTANTE! Guarda las credenciales en tu gestor de contraseñas.${NC}"
