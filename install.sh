#!/usr/bin/env bash
# ============================================================================
# SGE — Instalador de Producción
# Uso: bash install.sh
# Requisitos: Debian 13, usuario con sudo
#
# Privilegios:
#   [SISTEMA]  → sudo  — paquetes globales, servicios del SO, usuarios
#   [APP]      → sudo -u sge — configuración, binarios y datos de la aplicación
# ============================================================================
set -euo pipefail

SGE_REPO="terracenter/sge"
MIGRATE_VERSION="4.19.1"
TRAEFIK_VERSION="3.6.10"
NODE_VERSION="22"

# ── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${BOLD}${BLUE}══ $* ══${NC}"; }
step_sys() { echo -e "  ${YELLOW}[SISTEMA]${NC} $*"; }
step_app() { echo -e "  ${GREEN}[APP]${NC}    $*"; }

# ── Verificaciones previas ────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] && error "No ejecutar como root. Usar usuario con sudo."
command -v sudo &>/dev/null || error "sudo no está instalado."
. /etc/os-release
[[ "$ID" == "debian" && "$VERSION_ID" == "13" ]] || \
    warn "Probado en Debian 13. Continuar bajo tu responsabilidad."

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
    if grep -q "avx512f" /proc/cpuinfo 2>/dev/null; then echo "v4"
    elif grep -q "avx2"   /proc/cpuinfo 2>/dev/null; then echo "v3"
    else echo "v2"
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

# Generar contraseñas automáticamente (hex — sin caracteres especiales)
DB_PASSWORD=$(openssl rand -hex 32)
REDIS_PASSWORD=$(openssl rand -hex 32)
info "Contraseñas generadas automáticamente."

# Obtener última versión disponible
SGE_VERSION=$(curl -sf -H "Authorization: token $GH_TOKEN" \
    "https://api.github.com/repos/${SGE_REPO}/releases/latest" \
    | grep '"tag_name"' | cut -d'"' -f4) || \
    error "No se pudo obtener la versión de GitHub. Verificar token."
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

# ============================================================================
# FASE 1 — SISTEMA
# Requiere sudo. Instala paquetes del SO, crea usuarios y estructura de dirs.
# ============================================================================

section "FASE 1/2 — Sistema (sudo)"

# ── 1.1 Paquetes del sistema ──────────────────────────────────────────────────
step_sys "Actualizando sistema e instalando paquetes base..."
sudo apt-get update -qq && sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
    curl wget git ufw fail2ban logrotate unzip rsync \
    ca-certificates gnupg redis-server pgbouncer

# ── 1.2 PostgreSQL 18 ─────────────────────────────────────────────────────────
step_sys "Configurando repositorio PostgreSQL 18..."
if ! psql --version 2>/dev/null | grep -q "18\."; then
    sudo install -d /usr/share/postgresql-common/pgdg
    sudo curl -qo /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list > /dev/null
    sudo apt-get update -qq && sudo apt-get install -y -qq postgresql-18 postgresql-client-18
fi
info "PostgreSQL: $(psql --version)"

# ── 1.3 Node.js 24 LTS (global) ───────────────────────────────────────────────
step_sys "Instalando Node.js ${NODE_VERSION} LTS (global)..."
if ! node --version 2>/dev/null | grep -q "^v${NODE_VERSION}"; then
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | sudo -E bash - > /dev/null
    sudo apt-get install -y -qq nodejs
fi
info "Node.js: $(node --version)"

# ── 1.4 golang-migrate (global) ───────────────────────────────────────────────
step_sys "Instalando golang-migrate ${MIGRATE_VERSION} (global)..."
if ! migrate -version 2>/dev/null | grep -q "${MIGRATE_VERSION}"; then
    wget -q "https://github.com/golang-migrate/migrate/releases/download/v${MIGRATE_VERSION}/migrate.linux-amd64.tar.gz" -O /tmp/migrate.tar.gz
    tar xzf /tmp/migrate.tar.gz -C /tmp
    sudo mv /tmp/migrate /usr/local/bin/migrate
    sudo chmod +x /usr/local/bin/migrate
    rm -f /tmp/migrate.tar.gz
fi
info "migrate: $(migrate -version)"

# ── 1.5 Traefik (global) ──────────────────────────────────────────────────────
step_sys "Instalando Traefik ${TRAEFIK_VERSION} (global)..."
if ! traefik version 2>/dev/null | grep -q "${TRAEFIK_VERSION}"; then
    wget -q "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz" -O /tmp/traefik.tar.gz
    tar xzf /tmp/traefik.tar.gz -C /tmp
    sudo mv /tmp/traefik /usr/local/bin/traefik
    sudo chmod +x /usr/local/bin/traefik
    rm -f /tmp/traefik.tar.gz
fi
info "Traefik: $(traefik version 2>&1 | head -1)"

# ── 1.6 Usuario sge (sistema, sin shell) ──────────────────────────────────────
step_sys "Creando usuario sge (sin shell)..."
if ! id sge &>/dev/null; then
    sudo useradd --system --shell /usr/sbin/nologin --home-dir /opt/sge --create-home sge
fi

# ── 1.7 Usuario traefik (sin shell, solo para el proceso Traefik) ─────────────
step_sys "Creando usuario traefik (sin shell)..."
if ! id traefik &>/dev/null; then
    sudo useradd --system --shell /usr/sbin/nologin --no-create-home traefik
fi
# traefik necesita escribir acme.json → pertenece al grupo sge para logs compartidos
sudo usermod -aG sge traefik

# ── 1.8 Usuario sge-runner (CI/CD, con shell) ─────────────────────────────────
step_sys "Creando usuario sge-runner (CI/CD)..."
if ! id sge-runner &>/dev/null; then
    sudo useradd --system --shell /bin/bash --create-home --home-dir /opt/sge-runner sge-runner
fi

# Sudoers: permisos mínimos por rol
echo 'sge ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend' \
    | sudo tee /etc/sudoers.d/sge-services > /dev/null
echo 'sge-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend, /usr/local/bin/migrate' \
    | sudo tee /etc/sudoers.d/sge-runner > /dev/null
sudo chmod 440 /etc/sudoers.d/sge-services /etc/sudoers.d/sge-runner

# ── 1.8 Estructura FHS (crear dirs, asignar propiedad por rol) ────────────────
step_sys "Creando estructura FHS /etc/sge /opt/sge /var/log/sge /var/lib/sge..."
sudo mkdir -p /etc/sge/keys /etc/sge/traefik/dynamic \
              /opt/sge/bin /opt/sge/frontend \
              /var/log/sge \
              /var/lib/sge/backups /var/lib/sge/data/redis
sudo touch /etc/sge/traefik/acme.json
sudo chmod 600 /etc/sge/traefik/acme.json
sudo chmod 700 /etc/sge/keys
# sge: config general, binarios, datos
sudo chown -R sge:sge /etc/sge /opt/sge /var/lib/sge
# traefik: su propio directorio de configuración (escribe acme.json)
sudo chown -R traefik:traefik /etc/sge/traefik
# /var/log/sge: grupo sge, setgid → sge y traefik escriben aquí
sudo chown -R sge:sge /var/log/sge
sudo chmod 2775 /var/log/sge
info "Estructura FHS lista."

# ── 1.9 UFW — firewall (permitir solo 22, 80, 443) ───────────────────────────
step_sys "Configurando UFW (22/tcp, 80/tcp, 443/tcp)..."
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
info "UFW habilitado: $(sudo ufw status | head -1)"

# ── 1.10 PostgreSQL: usuario y base de datos ──────────────────────────────────
step_sys "Configurando usuario/base de datos en PostgreSQL..."
sudo -u postgres psql -c "CREATE USER sge WITH PASSWORD '$DB_PASSWORD';" 2>/dev/null || \
    sudo -u postgres psql -c "ALTER USER sge WITH PASSWORD '$DB_PASSWORD';"
sudo -u postgres psql -c "CREATE DATABASE sge_platform OWNER sge;" 2>/dev/null || true
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = 'localhost';"
sudo systemctl restart postgresql

# ── 1.11 Redis ────────────────────────────────────────────────────────────────
step_sys "Configurando Redis..."
# Agregar solo si no existen (idempotente)
grep -q "^requirepass" /etc/redis/redis.conf 2>/dev/null || \
    printf 'bind 127.0.0.1\nrequirepass %s\nmaxmemory 512mb\nmaxmemory-policy allkeys-lru\n' \
        "$REDIS_PASSWORD" | sudo tee -a /etc/redis/redis.conf > /dev/null
sudo systemctl restart redis-server

# ── 1.12 PgBouncer ───────────────────────────────────────────────────────────
step_sys "Configurando PgBouncer (puerto 5433, modo transacción)..."
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null << PGCONF
[databases]
sge_platform = host=127.0.0.1 port=5432 dbname=sge_platform

[pgbouncer]
listen_addr       = 127.0.0.1
listen_port       = 5433
auth_type         = md5
auth_file         = /etc/pgbouncer/userlist.txt
pool_mode         = transaction
max_client_conn   = 200
default_pool_size = 20
PGCONF
# md5 userlist format: "user" "md5<md5(password+username)>"
PGB_MD5_HASH=$(printf '%s%s' "$DB_PASSWORD" "sge" | md5sum | cut -d' ' -f1)
printf '"%s" "md5%s"\n' "sge" "$PGB_MD5_HASH" | sudo tee /etc/pgbouncer/userlist.txt > /dev/null
sudo chmod 640 /etc/pgbouncer/userlist.txt
sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo systemctl restart pgbouncer

# ── 1.13 Seguridad del SO ─────────────────────────────────────────────────────
step_sys "Aplicando hardening SSH, fail2ban, UFW..."
sudo cp "$SCRIPT_DIR/deploy/security/10-sshd-settings.conf" /etc/ssh/sshd_config.d/
[[ -f "$SCRIPT_DIR/deploy/security/banner" ]] && \
    sudo cp "$SCRIPT_DIR/deploy/security/banner" /etc/ssh/banner
sudo cp "$SCRIPT_DIR/deploy/security/jail.local" /etc/fail2ban/jail.local
[[ -d "$SCRIPT_DIR/deploy/security/filter.d" ]] && \
    sudo cp "$SCRIPT_DIR/deploy/security/filter.d/"* /etc/fail2ban/filter.d/
sudo sshd -t && sudo systemctl reload sshd
sudo systemctl restart fail2ban
info "Hardening aplicado."

# ── 1.14 Systemd services ────────────────────────────────────────────────────
step_sys "Instalando units systemd..."
sudo cp "$SCRIPT_DIR/deploy/sge.service" \
        "$SCRIPT_DIR/deploy/sge-frontend.service" \
        "$SCRIPT_DIR/deploy/sge-traefik.service" \
        /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sge sge-frontend sge-traefik
info "Units instaladas."

# ============================================================================
# FASE 2 — APLICACIÓN
# Corre como usuario sge (sudo -u sge). Escribe en /etc/sge y /opt/sge.
# ============================================================================

section "FASE 2/2 — Aplicación (usuario sge)"

# ── 2.1 Descargar binarios desde GitHub Releases ─────────────────────────────
step_app "Descargando SGE ${SGE_VERSION} amd64-${CPU_LEVEL}..."

_gh_download() {
    local ASSET=$1 DEST=$2
    local URL
    URL=$(curl -sf -H "Authorization: token $GH_TOKEN" \
        "https://api.github.com/repos/${SGE_REPO}/releases/latest" \
        | grep "browser_download_url.*${ASSET}\"" | cut -d'"' -f4)
    [[ -z "$URL" ]] && error "Asset '${ASSET}' no encontrado en el release."
    curl -sfL -H "Authorization: token $GH_TOKEN" -H "Accept: application/octet-stream" "$URL" -o "$DEST"
}

_gh_download "sge-linux-amd64-${CPU_LEVEL}"   /tmp/sge
_gh_download "sgectl-linux-amd64-${CPU_LEVEL}" /tmp/sgectl
_gh_download "sge-frontend.tar.gz"             /tmp/sge-frontend.tar.gz
_gh_download "sge-migrations.tar.gz"           /tmp/sge-migrations.tar.gz

# Instalar binarios como usuario sge
sudo -u sge cp /tmp/sge    /opt/sge/bin/sge
sudo -u sge cp /tmp/sgectl /opt/sge/bin/sgectl
sudo chmod +x /opt/sge/bin/sge /opt/sge/bin/sgectl

# Extraer frontend como usuario sge
sudo -u sge tar -xzf /tmp/sge-frontend.tar.gz -C /opt/sge/frontend/
info "Binarios instalados en /opt/sge/bin/"

# ── 2.2 Generar JWT keys como usuario sge ────────────────────────────────────
step_app "Generando claves JWT RS256..."
sudo -u sge /opt/sge/bin/sgectl generate-keys \
    --private /etc/sge/keys/private.pem \
    --public  /etc/sge/keys/public.pem
sudo chmod 600 /etc/sge/keys/private.pem
sudo chmod 644 /etc/sge/keys/public.pem
info "Claves JWT generadas en /etc/sge/keys/"

# ── 2.3 Traefik config como usuario sge ──────────────────────────────────────
step_app "Instalando configuración de Traefik..."
sed "s/sge.humanbyte.net/${SGE_DOMAIN}/g" "$SCRIPT_DIR/traefik/dynamic/routes.yml" \
    | sudo -u traefik tee /etc/sge/traefik/dynamic/routes.yml > /dev/null
sed "s/\${ACME_EMAIL}/${ACME_EMAIL}/g" "$SCRIPT_DIR/traefik/traefik.yml" \
    | sudo -u traefik tee /etc/sge/traefik/traefik.yml > /dev/null

# ── 2.4 Archivo .env como usuario sge ────────────────────────────────────────
step_app "Generando /etc/sge/.env..."
sudo -u sge tee /etc/sge/.env > /dev/null << ENV
# SGE Production Environment
# Generado: $(date)
# Versión:  ${SGE_VERSION}

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

# JWT
JWT_PRIVATE_KEY_PATH=/etc/sge/keys/private.pem
JWT_PUBLIC_KEY_PATH=/etc/sge/keys/public.pem
ENV
sudo chmod 600 /etc/sge/.env
info "/etc/sge/.env creado (propietario: sge, modo 600)."

# ── 2.5 Migraciones como usuario sge ─────────────────────────────────────────
step_app "Ejecutando migraciones de base de datos..."
tar -xzf /tmp/sge-migrations.tar.gz -C /tmp/
sudo -u sge PGPASSWORD="$DB_PASSWORD" migrate \
    -path /tmp/migrations \
    -database "postgres://sge:${DB_PASSWORD}@127.0.0.1:5432/sge_platform?sslmode=disable" \
    up
rm -rf /tmp/migrations /tmp/sge-migrations.tar.gz /tmp/sge-frontend.tar.gz /tmp/sge /tmp/sgectl
info "Migraciones completadas."

# ── 2.6 Arrancar servicios (requiere sudo de nuevo) ──────────────────────────
step_sys "Iniciando servicios (sge-traefik, sge, sge-frontend)..."
sudo systemctl start sge-traefik sge sge-frontend
sleep 5

# Health check
if curl -sf "http://127.0.0.1:8000/api/v1/health" > /dev/null; then
    info "Health check OK ✓"
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
echo "  Config:     /etc/sge/          (propietario: sge)"
echo "  Binarios:   /opt/sge/bin/      (propietario: sge)"
echo "  Logs:       /var/log/sge/"
echo "  Backups:    /var/lib/sge/backups/"
echo ""
echo -e "${YELLOW}Próximos pasos:${NC}"
echo "  1. Activar licencia:  https://${SGE_DOMAIN}/settings/licenses"
echo "  2. Configurar SMTP:   https://${SGE_DOMAIN}/settings"
echo "  3. Cambiar contraseña admin inicial"
echo ""
echo -e "${YELLOW}Credenciales guardadas en:${NC} /etc/sge/.env"
echo -e "${RED}¡IMPORTANTE! Guarda las credenciales en tu gestor de contraseñas antes de cerrar esta sesión.${NC}"
