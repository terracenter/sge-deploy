# SGE — Plan de Producción en Contabo

## Arquitectura

```
Internet
    │
    ▼ :80/:443
┌─────────────────────────────────────────────┐
│  Traefik (nativo, systemd)                  │
│  - SSL automático (Let's Encrypt)           │
│  - Reverse proxy                            │
│  - Headers de seguridad                     │
│  - Rate limiting                            │
└──────────┬──────────────────┬───────────────┘
           │                  │
           ▼ :3000            ▼ :8000
    ┌──────────────┐   ┌──────────────┐
    │  Next.js     │   │  Go backend  │
    │  (systemd)   │   │  (systemd)   │
    └──────────────┘   └──────┬───────┘
                              │
                              ▼ :5433
                    ┌─────────────────┐
                    │   PgBouncer     │
                    │   (systemd)     │
                    └────────┬────────┘
                             │
               ┌─────────────┴──────────┐
               ▼ :5432                  ▼ :6379
    ┌──────────────────┐     ┌──────────────────┐
    │   PostgreSQL     │     │      Redis       │
    │   (systemd/apt)  │     │   (systemd/apt)  │
    └──────────────────┘     └──────────────────┘

GitHub Actions Self-Hosted Runner (systemd)
    → Compila → rsync → systemctl restart
```

---

## Servicios y puertos

| Servicio | Puerto | Acceso | Usuario |
|---|---|---|---|
| Traefik | 80, 443 | Público | traefik (CAP_NET_BIND_SERVICE) |
| Next.js | 3000 | Solo localhost | sge |
| Go backend | 8000 | Solo localhost | sge |
| PgBouncer | 5433 | Solo localhost | sge |
| PostgreSQL | 5432 | Solo localhost | postgres |
| Redis | 6379 | Solo localhost | redis |
| GitHub Runner | — | Solo saliente | sge-runner |

---

## Estructura de directorios

```
/opt/sge/
├── bin/
│   ├── sge          # binario Go backend
│   └── sgectl       # CLI admin (generar seriales, etc.)
├── configs/
│   ├── config.yaml
│   └── keys/
│       ├── private.pem
│       └── public.pem
├── frontend/        # Next.js build (.next/standalone)
├── traefik/
│   ├── traefik.yml
│   ├── dynamic/
│   │   └── routes.yml
│   └── acme.json    # certificados Let's Encrypt (chmod 600)
├── data/
│   └── redis/       # persistencia Redis (si aplica)
├── logs/
│   ├── sge.log
│   ├── sge-error.log
│   ├── traefik.log
│   └── traefik-access.log
├── backups/
│   └── backup.sh
└── .env             # variables de entorno (chmod 600)
```

---

## ⚠️ Fases 1-3 automatizadas

**Las fases 1, 2 y 3 de este documento están completamente automatizadas por `install.sh`.**
Consultar el README del repositorio para el proceso de instalación.

Este documento es referencia de arquitectura y para troubleshooting.

---

## Fase 1 — Prerequisitos en el VPS (referencia — lo hace install.sh)

El implementador ejecuta esto **una sola vez** en el VPS.

### 1.1 Paquetes del sistema

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  curl wget git ufw fail2ban \
  ca-certificates gnupg \
  postgresql postgresql-client \
  redis-server \
  pgbouncer \
  nodejs npm \
  logrotate unzip
```

### 1.2 Swap (el VPS no tiene)

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### 1.3 Go (para compilar en el runner)

```bash
GO_VERSION=1.23.6
wget https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
sudo rm -rf /usr/local/go
sudo tar -C /usr/local -xzf go${GO_VERSION}.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh
source /etc/profile.d/go.sh
go version
```

### 1.4 golang-migrate

```bash
MIGRATE_VERSION=4.18.1
wget https://github.com/golang-migrate/migrate/releases/download/v${MIGRATE_VERSION}/migrate.linux-amd64.tar.gz
tar xzf migrate.linux-amd64.tar.gz
sudo mv migrate /usr/local/bin/migrate
migrate -version
```

### 1.5 Traefik (nativo)

```bash
TRAEFIK_VERSION=3.2.0
wget https://github.com/traefik/traefik/releases/download/v${TRAEFIK_VERSION}/traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz
tar xzf traefik_v${TRAEFIK_VERSION}_linux_amd64.tar.gz
sudo mv traefik /usr/local/bin/traefik
sudo chmod +x /usr/local/bin/traefik
traefik version
```

### 1.6 Usuario sge

```bash
sudo useradd --system \
  --shell /usr/sbin/nologin \
  --create-home \
  --home-dir /opt/sge \
  sge

# Permitir a sge reiniciar sus propios servicios sin password
echo 'sge ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend' \
  | sudo tee /etc/sudoers.d/sge-services
```

### 1.7 Estructura de directorios

```bash
sudo mkdir -p /opt/sge/{bin,configs/keys,frontend,traefik/dynamic,logs,backups,data/redis}
sudo touch /opt/sge/traefik/acme.json
sudo chmod 600 /opt/sge/traefik/acme.json
sudo chown -R sge:sge /opt/sge
sudo chmod 700 /opt/sge/configs/keys
sudo chmod 600 /opt/sge/.env 2>/dev/null || true
```

### 1.8 Firewall

```bash
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp comment 'SSH'
sudo ufw allow 80/tcp comment 'HTTP → Traefik redirect'
sudo ufw allow 443/tcp comment 'HTTPS → Traefik'
sudo ufw --force enable
sudo ufw status verbose
```

### 1.9 fail2ban

```bash
sudo tee /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
sudo systemctl enable --now fail2ban
```

### 1.10 SSH hardening

```bash
sudo sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
sudo systemctl reload sshd
```

---

## Fase 2 — Configuración de servicios

### 2.1 PostgreSQL

```bash
# Crear usuario y base de datos
sudo -u postgres psql <<'SQL'
CREATE USER sge WITH PASSWORD 'CHANGE_ME_STRONG';
CREATE DATABASE sge_platform OWNER sge;
\q
SQL

# Restringir acceso solo a localhost
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = 'localhost'/" \
  /etc/postgresql/*/main/postgresql.conf
sudo systemctl restart postgresql
```

### 2.2 Redis

```bash
# Habilitar autenticación y restringir a localhost
sudo tee -a /etc/redis/redis.conf <<'EOF'
bind 127.0.0.1
requirepass CHANGE_ME_REDIS_PASSWORD
maxmemory 512mb
maxmemory-policy allkeys-lru
EOF
sudo systemctl restart redis-server
```

### 2.3 PgBouncer

```bash
sudo tee /etc/pgbouncer/pgbouncer.ini <<'EOF'
[databases]
sge_platform = host=127.0.0.1 port=5432 dbname=sge_platform

[pgbouncer]
listen_addr     = 127.0.0.1
listen_port     = 5433
auth_type       = scram-sha-256
auth_file       = /etc/pgbouncer/userlist.txt
pool_mode       = transaction
max_client_conn = 200
default_pool_size = 20
log_file        = /opt/sge/logs/pgbouncer.log
pidfile         = /var/run/pgbouncer/pgbouncer.pid
EOF

# Crear userlist (password en MD5 o SCRAM)
echo '"sge" "CHANGE_ME_STRONG"' | sudo tee /etc/pgbouncer/userlist.txt
sudo chmod 640 /etc/pgbouncer/userlist.txt
sudo chown postgres:postgres /etc/pgbouncer/userlist.txt
sudo systemctl enable --now pgbouncer
```

### 2.4 Traefik

Ver archivo `traefik/traefik.yml` en el repositorio.

```bash
sudo cp /tmp/sge-deploy/traefik/traefik.yml /opt/sge/traefik/
sudo cp /tmp/sge-deploy/traefik/dynamic/routes.yml /opt/sge/traefik/dynamic/
sudo chown -R sge:sge /opt/sge/traefik/
```

---

## Fase 3 — Systemd services

Ver directorio `deploy/` en el repositorio. Instalar todos los services:

```bash
sudo cp /tmp/sge-deploy/deploy/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable sge sge-frontend sge-traefik
```

---

## Fase 4 — GitHub Actions Self-Hosted Runner

```bash
# Crear usuario dedicado para el runner
sudo useradd --system \
  --shell /bin/bash \
  --create-home \
  --home-dir /opt/sge-runner \
  sge-runner

# El runner necesita poder reiniciar servicios
echo 'sge-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend, /usr/local/bin/migrate' \
  | sudo tee /etc/sudoers.d/sge-runner

# Descargar runner (versión desde GitHub → Settings → Actions → Runners)
sudo -u sge-runner bash <<'EOF'
cd /opt/sge-runner
curl -o actions-runner.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.322.0/actions-runner-linux-x64-2.322.0.tar.gz
tar xzf actions-runner.tar.gz
# Registrar con token de GitHub (ver Fase 5)
EOF
```

---

## Fase 5 — Pipeline CI/CD

Ver archivo `.github/workflows/deploy.yml` en el repositorio.

**Secrets requeridos en GitHub → Settings → Secrets:**
```
DB_PASSWORD         contraseña de PostgreSQL
REDIS_PASSWORD      contraseña de Redis
JWT_PRIVATE_KEY     contenido del private.pem
JWT_PUBLIC_KEY      contenido del public.pem
SMTP_PASSWORD       contraseña SMTP
```

**Flujo del pipeline:**
```
git push main
    ↓ GitHub notifica al runner en el VPS
Runner ejecuta:
    1. go test ./...
    2. go build → bin/sge
    3. npm ci && npm run build
    4. migrate up (migraciones pendientes)
    5. rsync binario + frontend
    6. systemctl restart sge sge-frontend
    7. health check → curl https://sge.humanbyte.net/api/v1/health
```

---

## Fase 6 — Primer arranque

```bash
# En el VPS, una sola vez
cd /opt/sge
sudo -u sge migrate \
  -path /tmp/sge-migrations \
  -database "postgres://sge:PASSWORD@localhost:5432/sge_platform?sslmode=disable" \
  up

sudo systemctl start sge-traefik sge sge-frontend
sudo systemctl status sge sge-frontend sge-traefik
```

---

## Actualizaciones futuras

```bash
# En tu laptop — trigger del deploy
git push origin main
# El runner hace todo automáticamente en ~45 segundos
```

---

## Escalado futuro (multi-VPS)

Cuando el tráfico crezca, la arquitectura escala sin cambiar el código:

```
VPS-1 (app):    Go backend + Next.js
VPS-2 (db):     PostgreSQL primario + PgBouncer
VPS-3 (db-ha):  PostgreSQL réplica (streaming replication)
VPS-4 (cache):  Redis Sentinel
VPS-5 (proxy):  Traefik como load balancer
```

Solo se cambian IPs en `.env` y configs de PgBouncer/Traefik.

---

## Backup y recuperación

Backup diario automático a las 2am:
```bash
# /opt/sge/backups/backup.sh (cron del usuario sge)
pg_dump -U sge -h 127.0.0.1 -p 5432 sge_platform | gzip > backup_$(date +%Y%m%d).sql.gz
```

Restore:
```bash
gunzip -c backup_20260101.sql.gz | psql -U sge -h 127.0.0.1 -p 5432 sge_platform
```
