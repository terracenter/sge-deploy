#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02-validate.sh — Validación completa del entorno HA Docker
#
# Uso (desde Sge-Deploy/docker/ha/):
#   source .env
#   bash scripts/02-validate.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

OK=0
FAIL=0

check() {
    local desc="$1"
    local result="$2"
    if [[ "$result" == "ok" ]]; then
        echo "  ✓ $desc"
        ((OK++))
    else
        echo "  ✗ $desc — $result"
        ((FAIL++))
    fi
}

section() {
    echo ""
    echo "── $1 ──────────────────────────────────────────────────────────"
}

# ─────────────────────────────────────────────────────────────────────────────
section "Contenedores corriendo"
# ─────────────────────────────────────────────────────────────────────────────
for CTR in sge-ha-pg-primary sge-ha-pgbouncer sge-ha-redis sge-ha-nats \
           sge-ha-backend-1 sge-ha-backend-2 sge-ha-frontend \
           sge-ha-panel-backend sge-ha-panel-frontend sge-ha-traefik; do
    STATUS=$(docker inspect --format='{{.State.Status}}' "$CTR" 2>/dev/null || echo "no existe")
    if [[ "$STATUS" == "running" ]]; then
        check "$CTR" "ok"
    else
        check "$CTR" "estado: $STATUS"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "Health checks"
# ─────────────────────────────────────────────────────────────────────────────
for CTR in sge-ha-pg-primary sge-ha-redis sge-ha-nats sge-ha-backend-1 sge-ha-traefik; do
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$CTR" 2>/dev/null || echo "sin healthcheck")
    if [[ "$HEALTH" == "healthy" ]]; then
        check "$CTR health" "ok"
    else
        check "$CTR health" "$HEALTH"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "Almacenamiento (bind mounts LVM)"
# ─────────────────────────────────────────────────────────────────────────────
for DIR in /srv/ha/pg-primary-data /srv/ha/pg-primary-wal \
           /srv/ha/sge-data /srv/ha/redis-data /srv/ha/nats-data; do
    if [[ -d "$DIR" ]]; then
        # Verificar si es un LV montado
        if mountpoint -q "$DIR" 2>/dev/null; then
            FS=$(stat -f -c %T "$DIR" 2>/dev/null || echo "?")
            check "$DIR [LVM+$FS]" "ok"
        else
            check "$DIR [directorio]" "ok"
        fi
    else
        check "$DIR" "no existe"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "PostgreSQL — WAL separado"
# ─────────────────────────────────────────────────────────────────────────────
PG_WAL_LOC=$(docker exec sge-ha-pg-primary \
    psql -U "${DB_USER:-sge}" -d postgres -tAc \
    "SELECT pg_walfile_name(pg_current_wal_lsn());" 2>/dev/null || echo "error")

if [[ "$PG_WAL_LOC" != "error" ]]; then
    check "PostgreSQL WAL accesible" "ok"
else
    check "PostgreSQL WAL accesible" "no se pudo consultar"
fi

# Verificar que pg_wal es un directorio (bind mount del LV, sin symlinks)
WAL_TYPE=$(docker exec sge-ha-pg-primary \
    bash -c "test -d /var/lib/postgresql/data/pg_wal && echo directory || echo missing" \
    2>/dev/null || echo "error")

if [[ "$WAL_TYPE" == "directory" ]]; then
    check "pg_wal es directorio (bind mount LV, sin symlinks)" "ok"
else
    check "pg_wal" "no encontrado: $WAL_TYPE"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Replicación streaming (si réplica está activa)"
# ─────────────────────────────────────────────────────────────────────────────
if docker inspect sge-ha-pg-replica &>/dev/null 2>&1; then
    REPLICA_STATUS=$(docker exec sge-ha-pg-primary \
        psql -U "${DB_USER:-sge}" -d postgres -tAc \
        "SELECT state FROM pg_stat_replication LIMIT 1;" 2>/dev/null || echo "sin réplica")

    if [[ "$REPLICA_STATUS" == "streaming" ]]; then
        check "Replicación streaming" "ok"

        LAG=$(docker exec sge-ha-pg-primary \
            psql -U "${DB_USER:-sge}" -d postgres -tAc \
            "SELECT COALESCE(EXTRACT(EPOCH FROM write_lag)::text, '0') || 's' FROM pg_stat_replication LIMIT 1;" \
            2>/dev/null || echo "?")
        check "Lag de replicación: $LAG" "ok"
    else
        check "Replicación streaming" "estado: $REPLICA_STATUS"
    fi
else
    echo "  — Réplica no levantada (normal si no se ejecutó 01-setup-replication.sh)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Tablespace SGE"
# ─────────────────────────────────────────────────────────────────────────────
TS=$(docker exec sge-ha-pg-primary \
    psql -U "${DB_USER:-sge}" -d sge_platform -tAc \
    "SELECT spcname FROM pg_tablespace WHERE spcname = 'sge_data';" \
    2>/dev/null || echo "")

if [[ "$TS" == "sge_data" ]]; then
    check "Tablespace sge_data" "ok"
else
    check "Tablespace sge_data" "no existe — ejecutar sección 9 del manual"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "Endpoints HTTP"
# ─────────────────────────────────────────────────────────────────────────────
check_http() {
    local url="$1"
    local expected="${2:-200}"
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "$expected" ]]; then
        check "$url → HTTP $HTTP_CODE" "ok"
    else
        check "$url" "HTTP $HTTP_CODE (esperado $expected)"
    fi
}

check_http "http://localhost:8000/livez"
check_http "http://localhost:8000/readyz"
check_http "http://localhost:8090/livez"
check_http "http://localhost:8090/readyz"
check_http "http://localhost:8888/ping" "200"   # Traefik dashboard ping

# ─────────────────────────────────────────────────────────────────────────────
section "Redis"
# ─────────────────────────────────────────────────────────────────────────────
REDIS_PONG=$(docker exec sge-ha-redis \
    redis-cli -a "${REDIS_PASSWORD:-}" ping 2>/dev/null | tr -d '[:space:]' || echo "error")
if [[ "$REDIS_PONG" == "PONG" ]]; then
    check "Redis PING → PONG" "ok"
else
    check "Redis" "respuesta: $REDIS_PONG"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Resumen
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Resultado: $OK OK  |  $FAIL FALLOS"
echo "═══════════════════════════════════════════════════════════════════"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "  Revisar los items marcados con ✗ antes de continuar."
    exit 1
fi
