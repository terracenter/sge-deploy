#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 00-setup-docker-lvm.sh — LVM dedicado para Docker en el VG del sistema operativo
#
# Crea dos LVs en el VG del SO y los monta ANTES de instalar Docker:
#   docker-containerd  2G → /var/lib/containerd  (image store)
#   docker-data        6G → /var/lib/docker       (volúmenes y datos)
#
# IMPORTANTE: ejecutar ANTES de instalar Docker Engine.
# Si Docker ya está instalado, detenerlo primero con: sudo systemctl stop docker
#
# Uso:
#   sudo bash scripts/00-setup-docker-lvm.sh <vg-del-so>
#   Ejemplo: sudo bash scripts/00-setup-docker-lvm.sh vg0
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Este script debe ejecutarse con sudo." >&2
    exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: Este script solo funciona en Linux." >&2
    exit 1
fi

if [[ -z "${1:-}" ]]; then
    echo "ERROR: Debes especificar el VG del sistema operativo." >&2
    echo "Uso: sudo bash $0 <vg-nombre>" >&2
    echo "VGs disponibles:" >&2
    vgs --noheadings -o vg_name 2>/dev/null | awk '{print "  " $1}' >&2
    exit 1
fi

VG="$1"

if ! vgs "$VG" &>/dev/null; then
    echo "ERROR: El Volume Group '$VG' no existe." >&2
    echo "VGs disponibles:" >&2
    vgs --noheadings -o vg_name | awk '{print "  " $1}'
    exit 1
fi

if ! command -v mkfs.xfs &>/dev/null; then
    echo "ERROR: mkfs.xfs no encontrado. Instalar con: sudo apt install -y xfsprogs" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Definir LVs de Docker
# ─────────────────────────────────────────────────────────────────────────────
declare -A DOCKER_LVS=(
    ["docker-containerd"]="6G:/var/lib/containerd"
    ["docker-data"]="6G:/var/lib/docker"
)

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  Configurando LVM para Docker en VG: $VG"
echo "═══════════════════════════════════════════════════════════════════"
echo ""

for LV_NAME in "${!DOCKER_LVS[@]}"; do
    IFS=':' read -r SIZE MOUNT_PATH <<< "${DOCKER_LVS[$LV_NAME]}"
    DEV="/dev/$VG/$LV_NAME"

    # Crear LV si no existe
    if lvs "$DEV" &>/dev/null; then
        echo "  LV $LV_NAME ya existe — omitiendo creación."
    else
        echo "→ Creando LV: $LV_NAME ($SIZE)..."
        lvcreate -L "$SIZE" -n "$LV_NAME" "$VG"

        echo "  Formateando XFS ($LV_NAME)..."
        mkfs.xfs \
            -b size=4096 \
            -l size=64m,lazy-count=1 \
            -d agcount=4 \
            "$DEV"
    fi

    # Crear punto de montaje
    mkdir -p "$MOUNT_PATH"

    # Montar si no está montado
    if mountpoint -q "$MOUNT_PATH"; then
        echo "  Ya montado: $MOUNT_PATH"
    else
        mount -o noatime,nodiratime,allocsize=64m "$DEV" "$MOUNT_PATH"
        echo "  Montado: $DEV → $MOUNT_PATH"
    fi

    # Agregar a fstab si no está
    if ! grep -q "/dev/$VG/$LV_NAME" /etc/fstab; then
        echo "/dev/$VG/$LV_NAME $MOUNT_PATH xfs noatime,nodiratime,allocsize=64m 0 0" >> /etc/fstab
        echo "  Entrada agregada a /etc/fstab"
    fi

    echo "  ✓ $LV_NAME listo"
    echo ""
done

# ─────────────────────────────────────────────────────────────────────────────
# Verificación final
# ─────────────────────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════════════"
echo "  Verificación"
echo "═══════════════════════════════════════════════════════════════════"

ALL_OK=true
for LV_NAME in "${!DOCKER_LVS[@]}"; do
    IFS=':' read -r SIZE MOUNT_PATH <<< "${DOCKER_LVS[$LV_NAME]}"
    if mountpoint -q "$MOUNT_PATH"; then
        FS=$(df -T "$MOUNT_PATH" | tail -1 | awk '{print $2}')
        SIZE_ACTUAL=$(df -h "$MOUNT_PATH" | tail -1 | awk '{print $2}')
        echo "  ✓ [LVM+$FS] $MOUNT_PATH ($SIZE_ACTUAL)"
    else
        echo "  ✗ NO montado: $MOUNT_PATH" >&2
        ALL_OK=false
    fi
done

echo ""
if [[ "$ALL_OK" == "true" ]]; then
    echo "✓ LVM para Docker listo. Continúa instalando Docker Engine."
else
    echo "✗ Hay errores. Revisar antes de continuar." >&2
    exit 1
fi
