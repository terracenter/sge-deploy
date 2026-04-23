#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 01-setup-replication.sh — Configurar replicación streaming PostgreSQL 18
#
# Prerrequisitos:
#   - postgres-primary en ejecución y healthy
#   - /srv/ha/pg-replica-data y /srv/ha/pg-replica-wal montados y vacíos
#   - .env cargado (source .env)
#
# Uso (desde Sge-Deploy/docker/ha/):
#   source .env
#   bash scripts/01-setup-replication.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NETWORK="sge-ha-network"
PG_IMAGE="postgres:18-bookworm"
PRIMARY_CONTAINER="sge-ha-pg-primary"
PG_UID=999

# ─────────────────────────────────────────────────────────────────────────────
# Verificar variables de entorno
# ─────────────────────────────────────────────────────────────────────────────
for VAR in DB_USER DB_PASSWORD REPLICATOR_PASSWORD; do
    if [[ -z "${!VAR:-}" ]]; then
        echo "ERROR: Variable $VAR no está definida. Ejecuta: source .env" >&2
        exit 1
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Verificar que el primario está corriendo
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Verificando que postgres-primary está healthy..."
if ! docker exec "$PRIMARY_CONTAINER" pg_isready -U "$DB_USER" -d sge_platform &>/dev/null; then
    echo "ERROR: postgres-primary no responde. Levántalo primero:" >&2
    echo "  docker compose up -d postgres-primary" >&2
    exit 1
fi
echo "  ✓ postgres-primary healthy"

# ─────────────────────────────────────────────────────────────────────────────
# Verificar que los directorios de réplica están vacíos
# ─────────────────────────────────────────────────────────────────────────────
REPLICA_DATA="/srv/ha/pg-replica-data"
REPLICA_WAL="/srv/ha/pg-replica-wal"

for DIR in "$REPLICA_DATA" "$REPLICA_WAL"; do
    if [[ ! -d "$DIR" ]]; then
        echo "ERROR: $DIR no existe. Ejecuta primero: sudo bash scripts/00-setup-lvm.sh" >&2
        exit 1
    fi
done

if [[ -n "$(ls -A "$REPLICA_DATA" 2>/dev/null)" ]]; then
    echo "ERROR: $REPLICA_DATA no está vacío."
    echo "  Para reiniciar desde cero: sudo rm -rf $REPLICA_DATA/* $REPLICA_WAL/*"
    exit 1
fi
echo "  ✓ Directorios de réplica vacíos"

# ─────────────────────────────────────────────────────────────────────────────
# Paso 1: Crear usuario replicator en el primario
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Paso 1 — Crear usuario replicator en postgres-primary..."

docker exec -e PGPASSWORD="$DB_PASSWORD" "$PRIMARY_CONTAINER" \
    psql -U "$DB_USER" -d postgres -c \
    "DO \$\$
     BEGIN
       IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'replicator') THEN
         CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '${REPLICATOR_PASSWORD}';
         RAISE NOTICE 'Usuario replicator creado';
       ELSE
         ALTER ROLE replicator WITH PASSWORD '${REPLICATOR_PASSWORD}';
         RAISE NOTICE 'Contraseña de replicator actualizada';
       END IF;
     END \$\$;"

echo "  ✓ Usuario replicator listo"

# ─────────────────────────────────────────────────────────────────────────────
# Paso 2: Asignar contraseña al usuario sge_panel
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Paso 2 — Asignar contraseña a sge_panel..."

docker exec -e PGPASSWORD="$DB_PASSWORD" "$PRIMARY_CONTAINER" \
    psql -U "$DB_USER" -d postgres -c \
    "ALTER ROLE sge_panel WITH PASSWORD '${PANEL_DB_PASSWORD:-PANEL_PASS_NO_DEFINIDA}';"

echo "  ✓ Usuario sge_panel listo"

# ─────────────────────────────────────────────────────────────────────────────
# Paso 3: Ajustar permisos del directorio WAL de réplica
# (pg_basebackup necesita escribir ahí como usuario postgres UID 999)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Paso 3 — Ajustar permisos en directorios de réplica..."
chown "$PG_UID:$PG_UID" "$REPLICA_DATA" "$REPLICA_WAL"
chmod 700 "$REPLICA_DATA" "$REPLICA_WAL"
echo "  ✓ Permisos ajustados (UID $PG_UID)"

# ─────────────────────────────────────────────────────────────────────────────
# Paso 4: pg_basebackup en contenedor temporal
# Clona el primario al directorio de réplica con WAL en /var/lib/pg_wal
# -R: crea standby.signal + postgresql.auto.conf con primary_conninfo
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Paso 4 — Ejecutando pg_basebackup (puede tomar 1–5 minutos)..."
echo "  Fuente: postgres-primary"
echo "  Destino data: $REPLICA_DATA"
echo "  Destino WAL:  $REPLICA_WAL"

docker run --rm \
    --network "$NETWORK" \
    -e PGPASSWORD="$REPLICATOR_PASSWORD" \
    -v "$REPLICA_DATA:/var/lib/postgresql/data" \
    -v "$REPLICA_WAL:/var/lib/postgresql/pg_wal" \
    "$PG_IMAGE" \
    bash -c "
        chown -R $PG_UID:$PG_UID /var/lib/postgresql/data /var/lib/postgresql/pg_wal && \
        su -c \"pg_basebackup \
            -h $PRIMARY_CONTAINER \
            -p 5432 \
            -U replicator \
            -D /var/lib/postgresql/data \
            --waldir=/var/lib/postgresql/pg_wal \
            -P \
            -R \
            --wal-method=stream \
            --checkpoint=fast\" postgres
    "

echo "  ✓ pg_basebackup completado"

# ─────────────────────────────────────────────────────────────────────────────
# Paso 5: Verificar que standby.signal fue creado por pg_basebackup -R
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Paso 5 — Verificando archivos de réplica..."

if [[ -f "$REPLICA_DATA/standby.signal" ]]; then
    echo "  ✓ standby.signal presente"
else
    echo "  ✗ standby.signal NO encontrado — pg_basebackup pudo haber fallado" >&2
    exit 1
fi

if [[ -f "$REPLICA_DATA/postgresql.auto.conf" ]]; then
    echo "  ✓ postgresql.auto.conf presente"
    echo ""
    echo "  Contenido primary_conninfo:"
    grep "primary_conninfo" "$REPLICA_DATA/postgresql.auto.conf" || echo "  (no encontrado)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Resumen
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Replicación configurada. Siguiente paso:"
echo ""
echo "  docker compose --profile replica up -d postgres-replica"
echo ""
echo "  Verificar replicación activa:"
echo "  docker exec sge-ha-pg-primary psql -U $DB_USER -c \"SELECT * FROM pg_stat_replication;\""
echo "═══════════════════════════════════════════════════════════════════"
