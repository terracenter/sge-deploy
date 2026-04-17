#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 00-setup-lvm.sh — Preparar almacenamiento para SGE HA Docker
#
# Con LVM disponible: crea LVs, los formatea XFS y los monta como bind mounts.
# Sin LVM:            crea directorios normales con la misma estructura.
#
# Uso:
#   sudo bash scripts/00-setup-lvm.sh               # detecta VG automáticamente
#   sudo bash scripts/00-setup-lvm.sh vg0            # especificar VG manualmente
#
# Tamaños de LV (ajustar según disco disponible):
#   pg-primary-data  10G  — datos PostgreSQL primario
#   pg-primary-wal    2G  — WAL PostgreSQL primario (separado en LV propio)
#   pg-replica-data  10G  — datos PostgreSQL réplica
#   pg-replica-wal    2G  — WAL PostgreSQL réplica
#   sge-data          5G  — tablespace SGE (datos de la empresa)
#   redis-data        1G  — Redis AOF
#   nats-data         1G  — NATS JetStream
#   traefik-certs     -   — solo directorio (pocos MB, no necesita LV)
# Total LVM: ~31G mínimo recomendado
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_DIR="/srv/ha"
VG="${1:-}"

# UID del usuario postgres dentro del contenedor postgres:18-bookworm
PG_UID=999
PG_GID=999

# ─────────────────────────────────────────────────────────────────────────────
# Verificar que se ejecuta como root
# ─────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse con sudo." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Verificar plataforma
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Este script solo funciona en Linux." >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Detectar si LVM está disponible
# ─────────────────────────────────────────────────────────────────────────────
USE_LVM=false

if command -v vgs &>/dev/null; then
    if [[ -n "$VG" ]]; then
        # VG especificado manualmente — verificar que existe
        if vgs "$VG" &>/dev/null; then
            USE_LVM=true
            echo "✓ Volume Group '$VG' encontrado (especificado manualmente)."
        else
            echo "ERROR: El Volume Group '$VG' no existe. Verifica con: sudo vgs" >&2
            exit 1
        fi
    else
        # Detectar automáticamente el primer VG disponible
        DETECTED_VG=$(vgs --noheadings -o vg_name 2>/dev/null | awk '{print $1}' | head -1)
        if [[ -n "$DETECTED_VG" ]]; then
            USE_LVM=true
            VG="$DETECTED_VG"
            echo "✓ Volume Group detectado automáticamente: '$VG'"
            echo "  Para usar otro VG: sudo bash $0 <nombre-vg>"
        fi
    fi
fi

if [[ "$USE_LVM" == "false" ]]; then
    echo ""
    echo "⚠  LVM no disponible o sin Volume Groups configurados."
    echo "   Se crearán directorios normales en $BASE_DIR"
    echo "   (funcionalmente equivalente, sin separación física de I/O)"
    echo ""
fi

# ─────────────────────────────────────────────────────────────────────────────
# Definir volúmenes
# ─────────────────────────────────────────────────────────────────────────────
# Formato: "nombre-lv:tamaño:ruta-host:propietario"
# propietario: "pg" (UID 999) o "root"
declare -A LV_SIZES=(
    ["ha-pg-primary-data"]="10G"
    ["ha-pg-primary-wal"]="2G"
    ["ha-pg-replica-data"]="10G"
    ["ha-pg-replica-wal"]="2G"
    ["ha-sge-data"]="5G"
    ["ha-redis-data"]="1G"
    ["ha-nats-data"]="1G"
)
declare -A LV_PATHS=(
    ["ha-pg-primary-data"]="$BASE_DIR/pg-primary-data"
    ["ha-pg-primary-wal"]="$BASE_DIR/pg-primary-wal"
    ["ha-pg-replica-data"]="$BASE_DIR/pg-replica-data"
    ["ha-pg-replica-wal"]="$BASE_DIR/pg-replica-wal"
    ["ha-sge-data"]="$BASE_DIR/sge-data"
    ["ha-redis-data"]="$BASE_DIR/redis-data"
    ["ha-nats-data"]="$BASE_DIR/nats-data"
)
# LVs que deben pertenecer al usuario postgres del contenedor (UID 999)
PG_LVS=("ha-pg-primary-data" "ha-pg-primary-wal" "ha-pg-replica-data" "ha-pg-replica-wal" "ha-sge-data")

# ─────────────────────────────────────────────────────────────────────────────
# Crear directorio base
# ─────────────────────────────────────────────────────────────────────────────
mkdir -p "$BASE_DIR"
mkdir -p "$BASE_DIR/traefik-certs"  # solo directorio, sin LV
chmod 700 "$BASE_DIR/traefik-certs"
echo "✓ Directorio base creado: $BASE_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Crear LVs o directorios
# ─────────────────────────────────────────────────────────────────────────────
for LV_NAME in "${!LV_SIZES[@]}"; do
    SIZE="${LV_SIZES[$LV_NAME]}"
    MOUNT_PATH="${LV_PATHS[$LV_NAME]}"
    DEV="/dev/$VG/$LV_NAME"

    if [[ "$USE_LVM" == "true" ]]; then
        # Verificar si el LV ya existe
        if lvs "$DEV" &>/dev/null; then
            echo "  LV $LV_NAME ya existe — omitiendo creación."
        else
            echo "→ Creando LV: $LV_NAME ($SIZE)..."
            lvcreate -L "$SIZE" -n "$LV_NAME" "$VG"

            echo "  Formateando XFS ($LV_NAME)..."
            mkfs.xfs \
                -b size=4096 \
                -l size=128m,lazy-count=1 \
                -d agcount=4 \
                "$DEV"
        fi

        # Crear punto de montaje
        mkdir -p "$MOUNT_PATH"

        # Montar si no está montado
        if ! mountpoint -q "$MOUNT_PATH"; then
            mount -o noatime,nodiratime,allocsize=64m "$DEV" "$MOUNT_PATH"
            echo "  Montado: $DEV → $MOUNT_PATH"
        else
            echo "  Ya montado: $MOUNT_PATH"
        fi

        # Agregar a fstab si no está
        if ! grep -q "$LV_NAME" /etc/fstab; then
            echo "/dev/$VG/$LV_NAME $MOUNT_PATH xfs noatime,nodiratime,allocsize=64m 0 0" >> /etc/fstab
            echo "  Entrada agregada a /etc/fstab"
        fi

    else
        # Sin LVM — solo directorio
        mkdir -p "$MOUNT_PATH"
        echo "  Directorio creado: $MOUNT_PATH"
    fi

    # Permisos según tipo de volumen
    if printf '%s\n' "${PG_LVS[@]}" | grep -q "^${LV_NAME}$"; then
        chown "$PG_UID:$PG_GID" "$MOUNT_PATH"
        chmod 700 "$MOUNT_PATH"
        echo "  Permisos: postgres ($PG_UID:$PG_GID) → $MOUNT_PATH"
    else
        chmod 755 "$MOUNT_PATH"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Verificación final
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Verificación de montajes"
echo "═══════════════════════════════════════════════════════════════════"

ALL_OK=true
for LV_NAME in "${!LV_PATHS[@]}"; do
    MOUNT_PATH="${LV_PATHS[$LV_NAME]}"
    if [[ -d "$MOUNT_PATH" ]]; then
        OWNER=$(stat -c "%U:%G" "$MOUNT_PATH")
        if [[ "$USE_LVM" == "true" ]] && mountpoint -q "$MOUNT_PATH"; then
            echo "  ✓ [LVM] $MOUNT_PATH ($OWNER)"
        elif [[ "$USE_LVM" == "false" ]]; then
            echo "  ✓ [dir] $MOUNT_PATH ($OWNER)"
        else
            echo "  ✗ NO montado: $MOUNT_PATH" >&2
            ALL_OK=false
        fi
    else
        echo "  ✗ No existe: $MOUNT_PATH" >&2
        ALL_OK=false
    fi
done

echo ""
if [[ "$ALL_OK" == "true" ]]; then
    echo "✓ Almacenamiento listo. Continúa con la sección 4 del manual."
else
    echo "✗ Hay errores en el almacenamiento. Revisar antes de continuar." >&2
    exit 1
fi
