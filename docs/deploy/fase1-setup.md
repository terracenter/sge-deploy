# Fase 1 — Setup del VPS

Ejecutar en el VPS como usuario `freddy` (con sudo).

## Versiones instaladas (validadas en campo)
- Go 1.26.1
- golang-migrate 4.19.1
- Traefik 3.6.10
- Node.js 24 LTS
- PostgreSQL 18
- Redis 7.x
- PgBouncer 1.25.x

---

## 1.1 Paquetes del sistema

```bash
sudo apt update && sudo apt upgrade -y && sudo apt install -y curl wget git ufw fail2ban logrotate unzip rsync ca-certificates gnupg
```

---

## 1.2 PostgreSQL 18

```bash
sudo apt install curl ca-certificates && sudo install -d /usr/share/postgresql-common/pgdg && sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
```

```bash
. /etc/os-release && sudo sh -c "echo 'deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $VERSION_CODENAME-pgdg main' > /etc/apt/sources.list.d/pgdg.list" && sudo apt update && sudo apt install -y postgresql-18 postgresql-client-18 pgbouncer
```

---

## 1.3 Redis

```bash
sudo apt install -y redis-server
```

---

## 1.4 Node.js 24 LTS (global, system-wide)

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt install -y nodejs && node --version && npm --version
```

---

## 1.5 Go 1.26.1

```bash
wget -q https://go.dev/dl/go1.26.1.linux-amd64.tar.gz -O /tmp/go.tar.gz && sudo rm -rf /usr/local/go && sudo tar -C /usr/local -xzf /tmp/go.tar.gz && rm /tmp/go.tar.gz && echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh && source /etc/profile.d/go.sh && go version
```

---

## 1.6 golang-migrate 4.19.1

```bash
wget -q https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz -O /tmp/migrate.tar.gz && tar xzf /tmp/migrate.tar.gz -C /tmp && sudo mv /tmp/migrate /usr/local/bin/migrate && sudo chmod +x /usr/local/bin/migrate && rm /tmp/migrate.tar.gz && migrate -version
```

---

## 1.7 Traefik 3.6.10

```bash
wget -q https://github.com/traefik/traefik/releases/download/v3.6.10/traefik_v3.6.10_linux_amd64.tar.gz -O /tmp/traefik.tar.gz && tar xzf /tmp/traefik.tar.gz -C /tmp && sudo mv /tmp/traefik /usr/local/bin/traefik && sudo chmod +x /usr/local/bin/traefik && rm /tmp/traefik.tar.gz && traefik version
```

---

## 1.8 Usuarios del sistema

```bash
sudo useradd --system --shell /usr/sbin/nologin --home-dir /opt/sge sge && sudo useradd --system --shell /bin/bash --create-home --home-dir /opt/sge-runner sge-runner && id sge && id sge-runner
```

```bash
echo 'sge ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend' | sudo tee /etc/sudoers.d/sge-services && echo 'sge-runner ALL=(ALL) NOPASSWD: /bin/systemctl restart sge, /bin/systemctl restart sge-frontend, /usr/local/bin/migrate' | sudo tee /etc/sudoers.d/sge-runner && sudo chmod 440 /etc/sudoers.d/sge-services /etc/sudoers.d/sge-runner && sudo visudo -c && echo "sudoers OK"
```

---

## 1.9 Estructura FHS

```bash
sudo mkdir -p /etc/sge/{keys,traefik/dynamic} /opt/sge/{bin,frontend} /var/log/sge /var/lib/sge/{backups,data/redis} && sudo touch /etc/sge/traefik/acme.json && sudo chmod 600 /etc/sge/traefik/acme.json && sudo chmod 700 /etc/sge/keys && sudo chown -R sge:sge /etc/sge /opt/sge /var/log/sge /var/lib/sge && echo "FHS OK"
```

---

## 1.10 Firewall

```bash
sudo ufw --force reset && sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw limit 22/tcp comment 'SSH' && sudo ufw allow 80/tcp comment 'HTTP Traefik' && sudo ufw allow 443/tcp comment 'HTTPS Traefik' && sudo ufw allow 51820/udp comment 'WireGuard' && sudo ufw allow 1194/udp comment 'OpenVPN' && sudo ufw --force enable && sudo ufw status verbose
```

> Nota: `ufw limit` en SSH aplica rate limiting (protección brute force integrada).

---

## 1.11 fail2ban

Copiar desde máquina local:
```bash
rsync -av deploy/security/jail.local deploy/security/filter.d/ freddy@sge.humanbyte.net:/tmp/
```

En el VPS:
```bash
sudo mv /tmp/jail.local /etc/fail2ban/jail.local && sudo mkdir -p /etc/fail2ban/filter.d && sudo mv /tmp/ufw.aggressive.conf /tmp/postgresql-auth.conf /etc/fail2ban/filter.d/ && sudo systemctl restart fail2ban && sudo fail2ban-client status
```

---

## 1.12 SSH hardening

Copiar desde máquina local:
```bash
rsync -av deploy/security/10-sshd-settings.conf deploy/security/banner freddy@sge.humanbyte.net:/tmp/
```

En el VPS:
```bash
sudo mv /tmp/10-sshd-settings.conf /etc/ssh/sshd_config.d/ && sudo mv /tmp/banner /etc/ssh/sshd_config.d/ && sudo sshd -t && sudo systemctl reload sshd && echo "SSH OK"
```

---

## 1.13 Root hardening

```bash
sudo passwd -l root && echo 'Defaults env_reset,timestamp_timeout=5' | sudo tee /etc/sudoers.d/timeout && sudo chmod 440 /etc/sudoers.d/timeout && sudo visudo -c && echo "Root hardening OK"
```

---

## 1.14 Logrotate

```bash
sudo tee /etc/logrotate.d/sge > /dev/null << 'EOF'
/var/log/sge/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 640 sge sge
}
EOF
```

---

## 1.15 Verificación final Fase 1

```bash
go version && migrate -version && traefik version | head -1 && node --version && sudo ls -la /etc/sge/ && sudo ls -la /opt/sge/ && sudo ls -la /var/log/sge/
```
