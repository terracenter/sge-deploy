#!/usr/bin/env bash
# SGE — Server Setup Script (Fase 1: prerequisitos)
# Ejecutar UNA SOLA VEZ en el VPS como root.
# Ref: docs/deploy/PRODUCTION_SETUP.md
set -euo pipefail

GO_VERSION="1.23.6"
MIGRATE_VERSION="4.18.1"
TRAEFIK_VERSION="3.2.0"

# ── Colors ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Ejecutar como root: sudo bash $0"

# ── 1.1 Paquetes del sistema ────────────────────────────────────────────────────
info "Actualizando sistema..."
apt-get update -qq && apt-get upgrade -y -qq
apt-get install -y -qq \
  curl wget git ufw fail2ban \
  ca-certificates gnupg \
  postgresql postgresql-client \
  redis-server \
  pgbouncer \
  nodejs npm \
  logrotate unzip rsync

# ── 1.2 Swap 2GB ────────────────────────────────────────────────────────────────
if ! swapon --show | grep -q /swapfile; then
  info "Creando swap 2GB..."
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  sysctl -p -q
else
  info "Swap ya existe, omitiendo."
fi

# ── 1.3 Go ──────────────────────────────────────────────────────────────────────
if ! command -v go &>/dev/null || [[ "$(go version 2>/dev/null | awk '{print $3}')" != "go${GO_VERSION}" ]]; then
  info "Instalando Go ${GO_VERSION}..."
  wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
  rm -rf /usr/local/go
  tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
  echo 'export PATH=$PATH:/usr/local/go/bin' > /etc/profile.d/go.sh
  source /etc/profile.d/go.sh
  go version
else
  info "Go ${GO_VERSION} ya está instalado."
fi

# ── 1.4 golang-migrate ─────────────────────────────────────────────────────────
if ! command -v migrate &>/dev/null; then
  info "Instalando golang-migrate ${MIGRATE_VERSION}..."
  wget -q "https://github.com/golang-migrate/migrate/releases/download/v${MIGRATE_VERSION}/migrate.linux-amd64.tar.gz" -O /tmp/migrate.tar.gz
  tar xzf /tmp/migrate.tar.gz -C /tmp
  mv /tmp/migrate /usr/local/bin/migrate
  chmod +x /usr/local/bin/migrate
  rm /tmp/migrate.tar.gz
  migrate -version
else
  info "golang-migrate ya está instalado."
fi

# ── 1.5 Traefik (nativo) ────────────────────────────────────────────────────────
if ! command -v traefik &>/dev/null; then
  info "Instalando Traefik ${TRAEFIK_VERSION}..."
  wget -q "https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz" -O /tmp/traefik.tar.gz
  tar xzf /tmp/traefik.tar.gz -C /tmp
  mv /tmp/traefik /usr/local/bin/traefik
  chmod +x /usr/local/bin/traefik
  rm /tmp/traefik.tar.gz
  traefik version
else
  info "Traefik ya está instalado."
fi

# ── 1.6 Usuario sge ─────────────────────────────────────────────────────────────
if ! id sge &>/dev/null; then
  info "Creando usuario sge..."
  useradd --system --shell /usr/sbin/nologin --create-home --home-dir /opt/sge sge
fi

# sudoers para que sge pueda reiniciar sus propios servicios sin password
cat > /etc/sudoers.d/sge-services <<'EOF'
sge ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend
EOF
chmod 440 /etc/sudoers.d/sge-services

# ── 1.7 Usuario sge-runner (GitHub Actions) ────────────────────────────────────
if ! id sge-runner &>/dev/null; then
  info "Creando usuario sge-runner..."
  useradd --system --shell /bin/bash --create-home --home-dir /opt/sge-runner sge-runner
fi

cat > /etc/sudoers.d/sge-runner <<'EOF'
sge-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend, /usr/local/bin/migrate
EOF
chmod 440 /etc/sudoers.d/sge-runner

# ── 1.8 Estructura de directorios (FHS) ────────────────────────────────────────
info "Creando estructura FHS para SGE..."
# /etc/sge/  → configuración
mkdir -p /etc/sge/{keys,traefik/dynamic}
touch /etc/sge/traefik/acme.json
chmod 600 /etc/sge/traefik/acme.json
chmod 700 /etc/sge/keys
chown -R sge:sge /etc/sge

# /opt/sge/  → binarios y frontend
mkdir -p /opt/sge/{bin,frontend}
chown -R sge:sge /opt/sge

# /var/log/sge/ → logs
mkdir -p /var/log/sge
chown -R sge:sge /var/log/sge
chmod 750 /var/log/sge

# /var/lib/sge/ → datos persistentes
mkdir -p /var/lib/sge/{backups,data/redis}
chown -R sge:sge /var/lib/sge

# ── 1.9 Firewall ────────────────────────────────────────────────────────────────
info "Configurando ufw..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment 'SSH'
ufw allow 80/tcp  comment 'HTTP → Traefik redirect'
ufw allow 443/tcp comment 'HTTPS → Traefik'
ufw --force enable
ufw status verbose

# ── 1.10 fail2ban ──────────────────────────────────────────────────────────────
info "Configurando fail2ban..."
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
systemctl enable --now fail2ban

# ── 1.11 SSH hardening ─────────────────────────────────────────────────────────
info "Aplicando SSH hardening..."
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/'                   /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/'     /etc/ssh/sshd_config
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/'                          /etc/ssh/sshd_config
systemctl reload sshd

# ── Logrotate ──────────────────────────────────────────────────────────────────
cat > /etc/logrotate.d/sge <<'EOF'
/var/log/sge/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 640 sge sge
    postrotate
        systemctl kill --signal=SIGUSR1 sge 2>/dev/null || true
    endscript
}
EOF

# ── Backup cron ────────────────────────────────────────────────────────────────
cat > /var/lib/sge/backups/backup.sh <<'BACKUP'
#!/usr/bin/env bash
# Backup diario de PostgreSQL
set -euo pipefail
BACKUP_DIR="/var/lib/sge/backups"
DATE=$(date +%Y%m%d_%H%M%S)
source /etc/sge/.env 2>/dev/null || true

pg_dump -U sge -h 127.0.0.1 -p "${DB_PORT:-5433}" sge_platform \
  | gzip > "${BACKUP_DIR}/sge_${DATE}.sql.gz"

# Retener solo los últimos 14 backups
find "${BACKUP_DIR}" -name 'sge_*.sql.gz' -mtime +14 -delete
BACKUP
chmod +x /var/lib/sge/backups/backup.sh
chown sge:sge /var/lib/sge/backups/backup.sh

# Cron para usuario sge (2am diario)
(crontab -u sge -l 2>/dev/null || true; echo "0 2 * * * /var/lib/sge/backups/backup.sh >> /var/log/sge/backup.log 2>&1") \
  | sort -u | crontab -u sge -

echo ""
echo "================================================================"
echo -e "${GREEN}Fase 1 completa.${NC} Estructura FHS creada:"
echo "  /etc/sge/          → configuración, keys, traefik"
echo "  /opt/sge/          → binarios, frontend"
echo "  /var/log/sge/      → logs"
echo "  /var/lib/sge/      → backups, datos"
echo ""
echo "Próximos pasos:"
echo "  1. Ejecutar Fase 2: PostgreSQL, Redis, PgBouncer"
echo "  2. Ejecutar Fase 3: rsync configs + systemd services"
echo "  3. Configurar GitHub Actions runner (Fase 4)"
echo "================================================================"
