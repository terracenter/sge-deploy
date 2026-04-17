# Entorno HA Humanbyte — Docker

Manual paso a paso para desplegar el stack completo de SGE en Docker, configurado
para **humanbyte.net** como cliente propietario del sistema.

Válido para: servidor Linux local, GCP, AWS o Azure.

> **Estado:** Pendiente de validación completa por Freddy.

---

## Arquitectura

```
Internet / LAN
      │
      ▼
  Traefik :80 :443
  (TLS + routing)
      │
      ├─── sge.humanbyte.net ──────────────────────────────────────────────┐
      │         │                                                           │
      │    /api/* ──► sge-backend-1 ─┐                                     │
      │                               ├─► pgbouncer → postgres-primary     │
      │    /*    ──► sge-frontend    ─┘                               │    │
      │                                                     postgres-replica│
      └─── panel-sge.humanbyte.net ──────────────────────────────────┘    │
                │                                                          │
           /api/* ──► sge-panel-backend ──► postgres-primary (directo)    │
           /*    ──► sge-panel-frontend                                    │
                                                                           │
Backing services (red interna):  Redis ── NATS ─────────────────────────┘
```

### Puertos expuestos al host

| Puerto | Servicio |
|--------|----------|
| 80 | Traefik HTTP (redirige a HTTPS) |
| 443 | Traefik HTTPS |
| 8888 | Traefik dashboard (cerrar en prod cuando no se use) |

### Almacenamiento (bind mounts en /srv/ha/)

Los LVs se crean y montan en el **host** bajo `/srv/ha/`. Docker los usa como
bind mounts normales — sin configuración adicional en PostgreSQL ni symlinks.

| Directorio host | Contenedor | LV recomendado |
|-----------------|------------|----------------|
| `/srv/ha/pg-primary-data` | postgres-primary `/var/lib/postgresql/data` | `ha-pg-primary-data` 10G |
| `/srv/ha/pg-primary-wal` | postgres-primary `/var/lib/postgresql/data/pg_wal` | `ha-pg-primary-wal` 2G |
| `/srv/ha/pg-replica-data` | postgres-replica `/var/lib/postgresql/data` | `ha-pg-replica-data` 10G |
| `/srv/ha/pg-replica-wal` | postgres-replica `/var/lib/postgresql/data/pg_wal` | `ha-pg-replica-wal` 2G |
| `/srv/ha/sge-data` | postgres-primary `/srv/sge_data` | `ha-sge-data` 5G |
| `/srv/ha/redis-data` | redis `/data` | `ha-redis-data` 1G |
| `/srv/ha/nats-data` | nats `/data` | `ha-nats-data` 1G |
| `/srv/ha/traefik-certs` | traefik `/etc/traefik/acme` | solo directorio |

> Docker aplica todos los bind mounts antes de iniciar el proceso del contenedor,
> por lo que `/var/lib/postgresql/data/pg_wal` ya existe cuando `initdb` arranca.
> PostgreSQL lo usa directamente como directorio — sin symlinks.

---

## Requisitos previos

### Software

```bash
# Verificar versiones mínimas
docker --version          # ≥ 26.0
docker compose version    # ≥ 2.24 (plugin, no docker-compose standalone)
git --version
```

### Repositorios necesarios (deben estar clonados como hermanos)

```
Sge/
  Sge-Go/       ← backend + frontend SGE
  sge-panel/    ← backend + frontend panel
  Sge-Deploy/   ← este repo (scripts y manual)
```

### Claves criptográficas (deben existir antes de arrancar)

```bash
# JWT RS256 — generadas con: make keygen  (en Sge-Go)
ls Sge-Go/configs/keys/private.pem
ls Sge-Go/configs/keys/public.pem

# Ed25519 — generadas con: make keygen  (en sge-panel)
ls sge-panel/keys/private.pem
ls sge-panel/keys/public.pem
```

Si no existen, generarlas antes de continuar:

```bash
# En Sge-Go/
make keygen

# En sge-panel/
make keygen
```

### DNS (con IP pública)

Apuntar estos dominios a la IP del servidor **antes** de arrancar Traefik:

```
sge.humanbyte.net       → <IP_PUBLICA>
panel-sge.humanbyte.net → <IP_PUBLICA>
```

Let's Encrypt requiere que el dominio resuelva correctamente antes de solicitar el
certificado.

### Sin IP pública (pruebas locales)

Agregar al `/etc/hosts` del equipo desde el que se accede:

```
<IP_SERVIDOR>   sge.humanbyte.net
<IP_SERVIDOR>   panel-sge.humanbyte.net
```

Y usar `TLS_RESOLVER=selfsigned` en el `.env` (sección 3).

---

## Sección 1 — Clonar y preparar los repositorios

```bash
# Posicionarse en el directorio padre (donde están los repos)
cd /opt   # o el directorio que uses — los repos deben ser hermanos

# Verificar estructura
ls -la
# debe mostrar: Sge-Go/  sge-panel/  Sge-Deploy/
```

```bash
# Ir al directorio de trabajo del entorno HA
cd Sge-Deploy/docker/ha
```

> Todos los comandos del manual se ejecutan desde `Sge-Deploy/docker/ha/`
> salvo que se indique lo contrario.

---

## Sección 2 — Configurar variables de entorno

```bash
cp .env.example .env
```

Editar `.env` con los valores reales:

```bash
# Dominio y TLS
SGE_DOMAIN=sge.humanbyte.net
PANEL_DOMAIN=panel-sge.humanbyte.net

# Con IP pública y DNS configurado:
TLS_RESOLVER=letsencrypt
ACME_EMAIL=terracenter@gmail.com

# Sin IP pública (local):
# TLS_RESOLVER=selfsigned

# Contraseñas — usar valores seguros (≥ 24 caracteres aleatorios)
DB_PASSWORD=<genera con: openssl rand -hex 20>
REPLICATOR_PASSWORD=<genera con: openssl rand -hex 20>
PANEL_DB_PASSWORD=<genera con: openssl rand -hex 20>
REDIS_PASSWORD=<genera con: openssl rand -hex 20>
PANEL_ADMIN_PASSWORD=<tu contraseña de admin del panel>
```

Generador de contraseñas:

```bash
openssl rand -hex 20
```

Cargar las variables en la sesión actual:

```bash
source .env
```

---

## Sección 3 — Preparar almacenamiento

El script detecta automáticamente si hay LVM disponible. Si hay un Volume Group,
crea y formatea los LVs en XFS. Si no, crea directorios normales.

```bash
# Ver si hay VGs disponibles
sudo vgs
```

```bash
# Ejecutar el script (detecta VG automáticamente)
sudo bash scripts/00-setup-lvm.sh

# O especificar el VG manualmente:
sudo bash scripts/00-setup-lvm.sh vg0
```

Verificar salida esperada:

```
✓ Volume Group 'vg0' encontrado
→ Creando LV: ha-pg-primary-data (10G)...
→ Creando LV: ha-pg-primary-wal (2G)...
...
✓ Almacenamiento listo. Continúa con la sección 4 del manual.
```

### Verificación manual

```bash
# Con LVM:
findmnt /srv/ha/pg-primary-data
findmnt /srv/ha/pg-primary-wal

# Sin LVM:
ls -la /srv/ha/
```

---

## Sección 4 — Construir imágenes Docker

Las imágenes se construyen desde los repos fuente usando multi-stage builds.
La primera vez tarda ~10 minutos (descarga de dependencias Go y Node).

```bash
# Construir todas las imágenes definidas en docker-compose.yml
docker compose build

# Verificar que se crearon
docker images | grep -E "sge-"
```

Salida esperada:

```
sge-backend         latest    ...
sge-frontend        latest    ...
sge-panel-backend   latest    ...
sge-panel-frontend  latest    ...
```

> Si alguna imagen falla, ver el log con:
> `docker compose build --no-cache <nombre-servicio>`

---

## Sección 5 — Levantar infraestructura base

Levantar solo PostgreSQL primario, Redis y NATS (sin la aplicación todavía):

```bash
docker compose up -d postgres-primary redis nats
```

Esperar a que el primario esté healthy (~30 segundos):

```bash
watch docker compose ps
# Esperar que postgres-primary muestre: (healthy)
```

Verificar PostgreSQL:

```bash
docker exec sge-ha-pg-primary pg_isready -U "$DB_USER" -d sge_platform
# Debe responder: /var/run/postgresql:5432 - accepting connections
```

Verificar que `pg_wal` es un directorio normal (bind mount del LV, sin symlinks):

```bash
docker exec sge-ha-pg-primary \
  bash -c "ls -la /var/lib/postgresql/data/ | grep pg_wal"
# Debe mostrar: drwx------ ... pg_wal  (directorio, NO symlink)
```

```bash
# Confirmar que el LV del host está montado en ese directorio
findmnt /srv/ha/pg-primary-wal
# Debe mostrar: /srv/ha/pg-primary-wal /dev/vg0/ha-pg-primary-wal xfs ...
```

---

## Sección 6 — Configurar replicación PostgreSQL

```bash
source .env    # asegurarse de que las variables están cargadas
sudo bash scripts/01-setup-replication.sh
```

El script realiza:
1. Crea el usuario `replicator` en el primario
2. Asigna contraseña al usuario `sge_panel`
3. Ajusta permisos en los directorios de réplica
4. Ejecuta `pg_basebackup` con WAL separado (`--waldir=/var/lib/pg_wal`)
5. Verifica que `standby.signal` fue creado

Salida esperada al final:

```
✓ pg_basebackup completado
✓ standby.signal presente
✓ postgresql.auto.conf presente

docker compose --profile replica up -d postgres-replica
```

Levantar la réplica:

```bash
docker compose --profile replica up -d postgres-replica
```

Verificar replicación activa (~15 segundos):

```bash
docker exec sge-ha-pg-primary \
  psql -U "$DB_USER" -d postgres -c "SELECT * FROM pg_stat_replication;"
```

Salida esperada:

```
 pid  | usename    | application_name | state     | ...
------+------------+------------------+-----------+----
 1234 | replicator | walreceiver      | streaming | ...
```

> `state = streaming` confirma que la replicación está activa.

---

## Sección 7 — Levantar pgBouncer

```bash
docker compose up -d pgbouncer
```

```bash
docker compose ps pgbouncer
# Debe mostrar: running
```

---

## Sección 8 — Levantar la capa de aplicación

```bash
# Levantar todo lo que falta (backends, frontends, Traefik)
docker compose up -d
```

Verificar estado de todos los servicios:

```bash
docker compose ps
```

Esperar a que todos los servicios con healthcheck muestren `(healthy)`.
Los backends tardan ~40 segundos en pasar de `starting` a `healthy`.

```bash
# Ver logs en tiempo real mientras esperan
docker compose logs -f sge-backend-1 sge-backend-2
```

---

## Sección 9 — Crear tablespace SGE

El tablespace se crea manualmente (una sola vez) después de que el primario
esté corriendo y `/srv/sge_data` esté montado:

```bash
docker exec sge-ha-pg-primary \
  psql -U "$DB_USER" -d sge_platform -c \
  "CREATE TABLESPACE sge_data OWNER sge LOCATION '/srv/sge_data';"
```

Verificar:

```bash
docker exec sge-ha-pg-primary \
  psql -U "$DB_USER" -d sge_platform -c "\db+"
```

Debe aparecer `sge_data` con ubicación `/srv/sge_data`.

---

## Sección 10 — Aplicar migraciones SGE

```bash
# Desde Sge-Go/ (no desde Sge-Deploy/docker/ha/)
cd ../../../Sge-Go

# Las migraciones van directo al primario (no por pgBouncer)
# Ajustar .env de Sge-Go para que DB_HOST apunte al primario:
# DB_HOST=localhost  DB_PORT=5432  (con el primario expuesto en el host)
# O ejecutar desde dentro de la red Docker:

docker exec sge-ha-pg-primary \
  psql -U "$DB_USER" -d sge_platform -c "\dt"
# Verificar si las tablas ya existen

# Si el entorno de Sge-Go tiene make db-migrate-up configurado:
make db-migrate-up
```

> Si las tablas ya están (por una instalación previa), este paso se omite.

---

## Sección 11 — Validación completa

```bash
cd Sge-Deploy/docker/ha
source .env
bash scripts/02-validate.sh
```

Salida esperada:

```
── Contenedores corriendo ──────────────────────────────────────────────
  ✓ sge-ha-pg-primary
  ✓ sge-ha-pgbouncer
  ✓ sge-ha-redis
  ✓ sge-ha-nats
  ✓ sge-ha-backend-1
  ✓ sge-ha-backend-2
  ✓ sge-ha-frontend
  ✓ sge-ha-panel-backend
  ✓ sge-ha-panel-frontend
  ✓ sge-ha-traefik

── Health checks ────────────────────────────────────────────────────────
  ✓ sge-ha-pg-primary health
  ✓ sge-ha-redis health
  ✓ sge-ha-nats health
  ✓ sge-ha-backend-1 health
  ✓ sge-ha-traefik health

── Almacenamiento (bind mounts LVM) ─────────────────────────────────────
  ✓ /srv/ha/pg-primary-data [LVM+xfs]
  ✓ /srv/ha/pg-primary-wal [LVM+xfs]
  ...

── PostgreSQL — WAL separado ────────────────────────────────────────────
  ✓ PostgreSQL WAL accesible
  ✓ pg_wal es symlink → /var/lib/pg_wal

── Replicación streaming (si réplica está activa) ───────────────────────
  ✓ Replicación streaming
  ✓ Lag de replicación: 0s

── Tablespace SGE ───────────────────────────────────────────────────────
  ✓ Tablespace sge_data

── Endpoints HTTP ────────────────────────────────────────────────────────
  ✓ http://localhost:8000/livez → HTTP 200
  ✓ http://localhost:8000/readyz → HTTP 200
  ✓ http://localhost:8090/livez → HTTP 200
  ✓ http://localhost:8090/readyz → HTTP 200

── Redis ─────────────────────────────────────────────────────────────────
  ✓ Redis PING → PONG

═══════════════════════════════════════════════════════════════════
  Resultado: 20 OK  |  0 FALLOS
═══════════════════════════════════════════════════════════════════
```

### Verificación manual en el navegador

| URL | Resultado esperado |
|-----|-------------------|
| `https://sge.humanbyte.net` | Pantalla de login SGE |
| `https://panel-sge.humanbyte.net` | Pantalla de login sge-panel |
| `http://localhost:8888` | Dashboard Traefik |

> Con `TLS_RESOLVER=selfsigned`: el navegador muestra advertencia de certificado.
> Aceptar manualmente o agregar el certificado Traefik como confiable.

---

## Sección 12 — Balanceo de carga (verificar dos backends)

Traefik balancea automáticamente entre `sge-ha-backend-1` y `sge-ha-backend-2`
para todas las rutas `/api/*` de `sge.humanbyte.net`.

Para verificar que ambas instancias reciben tráfico:

```bash
# Ver logs de ambos backends en tiempo real — hacer login en el browser
docker compose logs -f sge-backend-1 sge-backend-2

# Traefik dashboard (tabla de servicios):
# http://localhost:8888 → HTTP → Services → sge-api
# Debe mostrar 2 backends activos
```

### Simular falla de un backend

```bash
# Detener backend-1
docker compose stop sge-backend-1

# Verificar que el sistema sigue respondiendo (solo con backend-2)
curl -sk https://sge.humanbyte.net/api/v1/health || true

# Restaurar
docker compose start sge-backend-1
```

---

## Sección 13 — SSL: resumen de opciones

### Opción A — Let's Encrypt (IP pública + DNS)

En `.env`:
```
TLS_RESOLVER=letsencrypt
ACME_EMAIL=terracenter@gmail.com
```

Traefik solicita el certificado automáticamente al arrancar.
El archivo `acme.json` se guarda en `/srv/ha/traefik-certs/acme.json`.

### Opción B — Certificado autofirmado (sin IP pública)

En `.env`:
```
TLS_RESOLVER=selfsigned
```

Traefik genera un certificado autofirmado. El navegador mostrará advertencia.
Para producción en nube privada, usar `step-ca` o `mkcert` en su lugar.

---

## Sección 14 — Operación y mantenimiento

### Comandos frecuentes

```bash
# Ver estado de todos los servicios
docker compose ps

# Ver logs de un servicio específico
docker compose logs -f sge-backend-1

# Reiniciar un servicio sin afectar los demás
docker compose restart sge-backend-1

# Detener todo
docker compose down

# Detener todo incluyendo réplica
docker compose --profile replica down

# Actualizar imágenes (después de cambios en el código)
docker compose build sge-backend-1 sge-backend-2
docker compose up -d --no-deps sge-backend-1 sge-backend-2
```

### Backup manual de PostgreSQL

```bash
# Dump completo
docker exec sge-ha-pg-primary \
  pg_dump -U "$DB_USER" sge_platform \
  > backup_sge_$(date +%Y%m%d_%H%M%S).sql

# Dump comprimido
docker exec sge-ha-pg-primary \
  pg_dump -U "$DB_USER" -Fc sge_platform \
  > backup_sge_$(date +%Y%m%d_%H%M%S).dump
```

### Escalar a la nube (GCP / AWS / Azure)

Este entorno Docker está diseñado para trasladarse a la nube con mínimos cambios:

1. **Provisionar VM** (Debian 13, ≥ 4 vCPU, ≥ 8 GB RAM)
2. **Agregar disco adicional** para LVM (≥ 50 GB)
3. **Clonar los repos** en `/opt/`
4. **Ejecutar `00-setup-lvm.sh`** con el VG del disco extra
5. **Configurar `.env`** con la IP pública y dominios reales
6. **Abrir puertos**: 80, 443 en el firewall de la nube
7. **Apuntar DNS** → IP pública
8. **`docker compose up -d`** + `01-setup-replication.sh`

En GCP, el disco adicional aparece como `/dev/sdb` → `pvcreate /dev/sdb` → `vgcreate vg0 /dev/sdb`.

---

## Referencia rápida de archivos

```
Sge-Deploy/docker/ha/
├── .env.example               ← plantilla de configuración
├── .env                       ← configuración real (no al repo)
├── docker-compose.yml         ← stack completo
├── traefik/
│   └── traefik.yml            ← Traefik: entrypoints, TLS, providers
├── postgres/
│   ├── postgresql.conf        ← configuración del primario
│   ├── pg_hba.conf            ← autenticación PostgreSQL
│   └── init/
│       └── 01-sge-init.sql    ← bases de datos y extensiones
└── scripts/
    ├── 00-setup-lvm.sh        ← crear y montar almacenamiento
    ├── 01-setup-replication.sh ← configurar streaming replication
    └── 02-validate.sh         ← validación completa del entorno

sge-panel/
├── Dockerfile.backend         ← imagen Go del panel
└── Dockerfile.frontend        ← imagen Next.js del panel
```

---

*SGE Ecosystem — Entorno HA Docker Humanbyte · 2026-04-16*
