#!/usr/bin/env bash
# SGE — Security Hardening Script
# Ejecutar DESPUÉS de setup-server.sh, como root.
# Aplica: SSH hardening, fail2ban agresivo, root hardening
# Ref: deploy/security/
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Ejecutar como root: sudo bash $0"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SECURITY_DIR="$SCRIPT_DIR/../deploy/security"

[[ ! -d "$SECURITY_DIR" ]] && error "No se encontró deploy/security/ — ejecutar desde la raíz del proyecto"

# ── 1. SSH Hardening ─────────────────────────────────────────────────────────
info "Aplicando SSH hardening..."
cp "$SECURITY_DIR/10-sshd-settings.conf" /etc/ssh/sshd_config.d/10-sshd-settings.conf
chmod 644 /etc/ssh/sshd_config.d/10-sshd-settings.conf

cp "$SECURITY_DIR/banner" /etc/ssh/sshd_config.d/banner
chmod 644 /etc/ssh/sshd_config.d/banner

# Validar sintaxis antes de aplicar
sshd -t || error "Error de sintaxis en sshd_config — revisa los cambios"
systemctl reload sshd
info "SSH hardening aplicado y recargado."

# ── 2. fail2ban agresivo ──────────────────────────────────────────────────────
info "Configurando fail2ban..."
cp "$SECURITY_DIR/jail.local" /etc/fail2ban/jail.local
cp "$SECURITY_DIR/filter.d/ufw.aggressive.conf" /etc/fail2ban/filter.d/ufw.aggressive.conf
cp "$SECURITY_DIR/filter.d/postgresql-auth.conf" /etc/fail2ban/filter.d/postgresql-auth.conf

systemctl restart fail2ban
sleep 2
fail2ban-client status
info "fail2ban configurado."

# ── 3. Root hardening ─────────────────────────────────────────────────────────
info "Bloqueando cuenta root..."
passwd -l root
info "Cuenta root bloqueada (password locked)."

# ── 4. sudo timeout ───────────────────────────────────────────────────────────
info "Configurando sudo timeout (5 min)..."
echo 'Defaults env_reset,timestamp_timeout=5' | tee /etc/sudoers.d/timeout > /dev/null
chmod 440 /etc/sudoers.d/timeout
visudo -c || error "Error en sudoers.d/timeout"
info "sudo timeout aplicado."

echo ""
echo "================================================================"
echo -e "${GREEN}Security hardening completo.${NC} Checklist:"
echo "  [ ] Verifica SSH en NUEVA terminal antes de cerrar esta sesión"
echo "  [ ] Confirma: sudo sshd -T | grep -E 'permitrootlogin|passwordauth'"
echo "  [ ] Confirma: sudo fail2ban-client status"
echo "================================================================"
