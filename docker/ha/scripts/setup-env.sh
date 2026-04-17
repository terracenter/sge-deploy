#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-env.sh — Configuración interactiva del entorno HA Docker SGE
#
# Genera el archivo .env con todas las variables necesarias.
# Las contraseñas se generan automáticamente (openssl rand).
# Solo se solicitan al usuario los valores que deben elegir conscientemente.
#
# Uso (desde Sge-Deploy/docker/ha/):
#   bash scripts/setup-env.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

ENV_FILE="$(dirname "$0")/../.env"
ENV_EXAMPLE="$(dirname "$0")/../.env.example"

# ─────────────────────────────────────────────────────────────────────────────
# Colores
# ─────────────────────────────────────────────────────────────────────────────
BOLD="\033[1m"
CYAN="\033[1;36m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
RESET="\033[0m"

header() { echo -e "\n${CYAN}══ $1 ══${RESET}"; }
ask()    { echo -e "${BOLD}▶ $1${RESET}"; }
info()   { echo -e "  ${YELLOW}$1${RESET}"; }
ok()     { echo -e "  ${GREEN}✓ $1${RESET}"; }
err()    { echo -e "  ${RED}✗ $1${RESET}"; }

gen_pass() { openssl rand -hex 24; }

# ─────────────────────────────────────────────────────────────────────────────
# Verificar que no exista ya un .env (protección contra sobreescritura)
# ─────────────────────────────────────────────────────────────────────────────
if [[ -f "$ENV_FILE" ]]; then
    echo -e "${RED}Ya existe un archivo .env en:${RESET} $ENV_FILE"
    echo ""
    read -rp "  ¿Sobreescribir? (s/N): " OVERWRITE
    if [[ ! "$OVERWRITE" =~ ^[sS]$ ]]; then
        echo "  Operación cancelada."
        exit 0
    fi
    cp "$ENV_FILE" "${ENV_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
    ok "Backup del .env anterior guardado"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       SGE HA Docker — Configuración del entorno              ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1 — Tipo de instalación
# ─────────────────────────────────────────────────────────────────────────────
header "Paso 1 — Tipo de instalación"
echo ""
echo "  1) IP pública + dominio real (GCP, AWS, Azure, VPS)"
echo "     → Let's Encrypt automático, acceso desde internet"
echo ""
echo "  2) IP local / LAN (pruebas en casa o en la empresa)"
echo "     → Certificado autofirmado, acceso solo en la red local"
echo ""
ask "¿Qué tipo de instalación? [1/2]:"
read -rp "  → " INSTALL_TYPE

case "$INSTALL_TYPE" in
    1) TLS_RESOLVER="letsencrypt" ;;
    2) TLS_RESOLVER="selfsigned" ;;
    *)
        err "Opción inválida. Ejecuta el script de nuevo."
        exit 1
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2 — Dominios
# ─────────────────────────────────────────────────────────────────────────────
header "Paso 2 — Dominios"

if [[ "$INSTALL_TYPE" == "1" ]]; then
    # IP pública
    info "Asegúrate de que los dominios ya apuntan a la IP de este servidor"
    info "antes de arrancar Traefik (Let's Encrypt lo verifica al inicio)."
    echo ""
    ask "Dominio para SGE (ej: sge.humanbyte.net):"
    read -rp "  → " SGE_DOMAIN
    ask "Dominio para sge-panel (ej: panel-sge.humanbyte.net):"
    read -rp "  → " PANEL_DOMAIN
    ask "Email para Let's Encrypt (notificaciones de renovación):"
    read -rp "  → " ACME_EMAIL

else
    # IP local
    DETECTED_IP=$(ip -br a | awk '$2 == "UP" {split($3, a, "/"); print a[1]; exit}')
    info "IP detectada en este equipo: ${DETECTED_IP}"
    echo ""
    ask "¿Usar esta IP para el /etc/hosts? (S/n):"
    read -rp "  → " USE_DETECTED
    if [[ "$USE_DETECTED" =~ ^[nN]$ ]]; then
        ask "Ingresa la IP del host donde correrá Docker:"
        read -rp "  → " HOST_IP
    else
        HOST_IP="$DETECTED_IP"
    fi

    ask "Dominio para SGE (Enter para usar: sge.humanbyte.net):"
    read -rp "  → " SGE_DOMAIN
    SGE_DOMAIN="${SGE_DOMAIN:-sge.humanbyte.net}"

    ask "Dominio para sge-panel (Enter para usar: panel-sge.humanbyte.net):"
    read -rp "  → " PANEL_DOMAIN
    PANEL_DOMAIN="${PANEL_DOMAIN:-panel-sge.humanbyte.net}"

    ACME_EMAIL="terracenter@gmail.com"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3 — Contraseña del admin de sge-panel
# ─────────────────────────────────────────────────────────────────────────────
header "Paso 3 — Contraseña del administrador"
info "Esta es la única contraseña que debes definir tú."
info "Las demás (bases de datos, Redis, replicación) se generan automáticamente."
echo ""
ask "Contraseña para el admin del panel (mínimo 12 caracteres):"
while true; do
    read -rsp "  → " PANEL_ADMIN_PASSWORD
    echo ""
    if [[ ${#PANEL_ADMIN_PASSWORD} -lt 12 ]]; then
        err "Demasiado corta. Mínimo 12 caracteres."
    else
        read -rsp "  Confirmar contraseña: " PANEL_ADMIN_PASSWORD_CONFIRM
        echo ""
        if [[ "$PANEL_ADMIN_PASSWORD" != "$PANEL_ADMIN_PASSWORD_CONFIRM" ]]; then
            err "Las contraseñas no coinciden. Intenta de nuevo."
        else
            ok "Contraseña aceptada"
            break
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4 — SMTP (opcional)
# ─────────────────────────────────────────────────────────────────────────────
header "Paso 4 — Configuración SMTP (opcional)"
info "Si no configuras SMTP, los emails del panel van al log del contenedor."
echo ""
ask "¿Configurar SMTP ahora? (s/N):"
read -rp "  → " CONFIGURE_SMTP

SMTP_HOST=""
SMTP_PORT="587"
SMTP_USER=""
SMTP_PASSWORD=""

if [[ "$CONFIGURE_SMTP" =~ ^[sS]$ ]]; then
    ask "Host SMTP (ej: smtp.gmail.com):"
    read -rp "  → " SMTP_HOST
    ask "Puerto SMTP (Enter para 587):"
    read -rp "  → " SMTP_PORT_INPUT
    SMTP_PORT="${SMTP_PORT_INPUT:-587}"
    ask "Usuario SMTP:"
    read -rp "  → " SMTP_USER
    ask "Contraseña SMTP:"
    read -rsp "  → " SMTP_PASSWORD
    echo ""
    ok "SMTP configurado"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Generar contraseñas automáticas
# ─────────────────────────────────────────────────────────────────────────────
header "Generando contraseñas seguras..."
DB_PASSWORD=$(gen_pass)
REPLICATOR_PASSWORD=$(gen_pass)
PANEL_DB_PASSWORD=$(gen_pass)
REDIS_PASSWORD=$(gen_pass)
ok "Contraseñas generadas con openssl rand"

# ─────────────────────────────────────────────────────────────────────────────
# Escribir .env
# ─────────────────────────────────────────────────────────────────────────────
header "Escribiendo .env..."

cat > "$ENV_FILE" <<EOF
# ─────────────────────────────────────────────────────────────────────────────
# SGE HA Docker — Variables de entorno
# Generado por scripts/setup-env.sh el $(date '+%Y-%m-%d %H:%M:%S')
# NUNCA subir este archivo al repositorio.
# ─────────────────────────────────────────────────────────────────────────────

# ─── Dominios ────────────────────────────────────────────────────────────────
SGE_DOMAIN=${SGE_DOMAIN}
PANEL_DOMAIN=${PANEL_DOMAIN}

# ─── TLS ─────────────────────────────────────────────────────────────────────
TLS_RESOLVER=${TLS_RESOLVER}
ACME_EMAIL=${ACME_EMAIL}

# ─── PostgreSQL principal ─────────────────────────────────────────────────────
DB_USER=sge
DB_PASSWORD=${DB_PASSWORD}

# ─── Replicación PostgreSQL ───────────────────────────────────────────────────
REPLICATOR_PASSWORD=${REPLICATOR_PASSWORD}

# ─── PostgreSQL sge-panel ─────────────────────────────────────────────────────
PANEL_DB_USER=sge_panel
PANEL_DB_PASSWORD=${PANEL_DB_PASSWORD}

# ─── Redis ────────────────────────────────────────────────────────────────────
REDIS_PASSWORD=${REDIS_PASSWORD}

# ─── sge-panel admin ──────────────────────────────────────────────────────────
PANEL_ADMIN_USER=admin
PANEL_ADMIN_PASSWORD=${PANEL_ADMIN_PASSWORD}

# ─── SMTP ────────────────────────────────────────────────────────────────────
SMTP_HOST=${SMTP_HOST}
SMTP_PORT=${SMTP_PORT}
SMTP_USER=${SMTP_USER}
SMTP_PASSWORD=${SMTP_PASSWORD}
EOF

chmod 600 "$ENV_FILE"
ok ".env creado con permisos 600 (solo lectura para tu usuario)"

# ─────────────────────────────────────────────────────────────────────────────
# Instrucciones /etc/hosts (solo instalación local)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$INSTALL_TYPE" == "2" ]]; then
    header "Configurar /etc/hosts"
    echo ""
    info "Agrega estas líneas en /etc/hosts de ESTE equipo:"
    echo ""
    echo "    ${HOST_IP}   ${SGE_DOMAIN}"
    echo "    ${HOST_IP}   ${PANEL_DOMAIN}"
    echo ""
    info "Y en cada dispositivo de la LAN desde el que quieras acceder."
    echo ""
    ask "¿Agregar automáticamente al /etc/hosts de este equipo? (s/N):"
    read -rp "  → " ADD_HOSTS
    if [[ "$ADD_HOSTS" =~ ^[sS]$ ]]; then
        echo "${HOST_IP}   ${SGE_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
        echo "${HOST_IP}   ${PANEL_DOMAIN}" | sudo tee -a /etc/hosts > /dev/null
        ok "/etc/hosts actualizado"
    else
        info "Recuerda agregarlo manualmente antes de acceder en el navegador."
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Resumen final
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║                    Configuración completada                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  Tipo:           $([ "$INSTALL_TYPE" == "1" ] && echo "IP pública (Let's Encrypt)" || echo "IP local (autofirmado)")"
echo -e "  SGE:            https://${SGE_DOMAIN}"
echo -e "  Panel:          https://${PANEL_DOMAIN}"
echo -e "  Admin usuario:  admin"
echo -e "  Admin password: ${PANEL_ADMIN_PASSWORD}"
echo ""
echo -e "  Las contraseñas de BD y Redis están en: ${ENV_FILE}"
echo -e "  ${RED}Guarda la contraseña admin en un gestor de contraseñas ahora.${RESET}"
echo ""
echo -e "  Siguiente paso:"
echo -e "  ${CYAN}sudo bash scripts/00-setup-lvm.sh${RESET}"
echo ""
