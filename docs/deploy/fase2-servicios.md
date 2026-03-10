# Fase 2 — Configuración de Servicios SGE

Ejecutar en el VPS como usuario `freddy` (con sudo).
Cada bloque es un comando completo — copiar y pegar uno a la vez.

---

## 2.1 PostgreSQL

**Crear usuario y base de datos:**
```bash
DB_PASS=$(openssl rand -hex 32) && echo "DB_PASSWORD=$DB_PASS" | sudo tee -a /opt/sge/.env && sudo -u postgres psql -c "CREATE USER sge WITH PASSWORD '$DB_PASS';" && sudo -u postgres psql -c "CREATE DATABASE sge_platform OWNER sge;" && echo "PostgreSQL OK"
```

**Restringir PostgreSQL a localhost:**
```bash
sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses = 'localhost';" && sudo systemctl restart postgresql && echo "PostgreSQL localhost OK"
```

> Nota: usar `openssl rand -hex 32` (no base64) — evita caracteres especiales
> (`/`, `=`) que causan problemas en PgBouncer y en variables de shell.

---

## 2.2 Redis

**Generar contraseña y guardar en .env:**
```bash
REDIS_PASS=$(openssl rand -hex 32) && echo "REDIS_PASSWORD=$REDIS_PASS" | sudo tee -a /opt/sge/.env
```

**Configurar Redis (bind + auth + memoria):**
```bash
echo "bind 127.0.0.1" | sudo tee -a /etc/redis/redis.conf
```
```bash
echo "requirepass $REDIS_PASS" | sudo tee -a /etc/redis/redis.conf
```
```bash
echo "maxmemory 512mb" | sudo tee -a /etc/redis/redis.conf
```
```bash
echo "maxmemory-policy allkeys-lru" | sudo tee -a /etc/redis/redis.conf
```
```bash
sudo systemctl restart redis-server && sudo systemctl status redis-server --no-pager
```

**Verificar que Redis responde:**
```bash
redis-cli -a $REDIS_PASS ping
```

---

## 2.3 PgBouncer

**Configurar PgBouncer (transaction mode, puerto 5433):**

> Notas:
> - `log_file` y `pidfile` no se usan — systemd gestiona logs y PID.
> - `auth_type = scram-sha-256` requiere contraseña sin caracteres especiales en userlist.txt.
>   Por eso en 2.1 se usa `openssl rand -hex 32`.

```bash
sudo tee /etc/pgbouncer/pgbouncer.ini > /dev/null << 'CONF'
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
CONF
```

**Regenerar contraseña hex, actualizar PostgreSQL + .env + userlist (todo en uno):**

> Si ya existe el usuario sge en PostgreSQL, usar este comando que lo actualiza todo de forma atómica.

```bash
NEW_PASS=$(openssl rand -hex 32) && sudo -u postgres psql -c "ALTER USER sge WITH PASSWORD '$NEW_PASS';" && sudo sh -c "grep -v '^DB_PASSWORD=' /opt/sge/.env > /tmp/env.tmp && echo 'DB_PASSWORD='$NEW_PASS >> /tmp/env.tmp && mv /tmp/env.tmp /opt/sge/.env && chmod 600 /opt/sge/.env && chown sge:sge /opt/sge/.env" && echo "\"sge\" \"$NEW_PASS\"" | sudo tee /etc/pgbouncer/userlist.txt && sudo chmod 640 /etc/pgbouncer/userlist.txt && sudo chown postgres:postgres /etc/pgbouncer/userlist.txt && sudo systemctl restart pgbouncer && echo "OK"
```

**Verificar conexión via PgBouncer:**
```bash
DB_PASS=$(sudo grep DB_PASSWORD /opt/sge/.env | cut -d= -f2-) && PGPASSWORD=$DB_PASS psql -h 127.0.0.1 -p 5433 -U sge -d sge_platform -c "SELECT version();"
```

---

## 2.4 Verificación final Fase 2

```bash
sudo systemctl status postgresql redis-server pgbouncer --no-pager
```
