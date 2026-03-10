# Fase 0 — Reset VPS (inicio limpio)

Ejecutar en el VPS. Deja el servidor con binarios instalados pero sin configuración previa de SGE.

> Lo que NO se toca: Go, golang-migrate, Traefik, Node.js, usuarios sge/sge-runner, firewall, fail2ban, SSH hardening.

---

## 0.1 Limpiar directorios anteriores

```bash
sudo rm -rf /opt/sge && sudo rm -rf /etc/sge && sudo rm -rf /var/log/sge && sudo rm -rf /var/lib/sge && echo "Directorios eliminados OK"
```

---

## 0.2 Resetear PostgreSQL

```bash
sudo -u postgres psql -c "DROP DATABASE IF EXISTS sge_platform;" && sudo -u postgres psql -c "DROP USER IF EXISTS sge;" && echo "PostgreSQL reseteado OK"
```

---

## 0.3 Resetear Redis

```bash
sudo cp /etc/redis/redis.conf /etc/redis/redis.conf.bak && sudo grep -v -E "^bind 127|^requirepass|^maxmemory" /etc/redis/redis.conf.bak | sudo tee /etc/redis/redis.conf && sudo systemctl restart redis-server && echo "Redis reseteado OK"
```

---

## 0.4 Resetear PgBouncer

```bash
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null << 'CONF'
[databases]
* =

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type   = md5
auth_file   = /etc/pgbouncer/userlist.txt
CONF
```

```bash
sudo truncate -s 0 /etc/pgbouncer/userlist.txt && sudo systemctl restart pgbouncer && echo "PgBouncer reseteado OK"
```

---

## 0.5 Limpiar sudoers y crons SGE

```bash
sudo rm -f /etc/sudoers.d/sge-services /etc/sudoers.d/sge-runner /etc/sudoers.d/timeout && sudo crontab -u sge -r 2>/dev/null || true && echo "Sudoers y crons OK"
```

---

## 0.6 Verificar estado limpio

```bash
sudo ls /opt/ && sudo ls /etc/ | grep sge || echo "Sin /etc/sge" && sudo systemctl status postgresql redis-server pgbouncer --no-pager | grep -E "Active|●"
```

---

Una vez confirmado el estado limpio → continuar con `fase1-setup.md`.
