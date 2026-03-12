# sge-deploy

Instalador y herramientas de despliegue para SGE (Sistema de Gestión Empresarial).

## Requisitos previos

Antes de ejecutar el instalador verificar:

1. **Servidor**: Debian 13, mínimo 2 vCPU / 4 GB RAM / 40 GB SSD
2. **Usuario**: con `sudo` (no ejecutar como root)
3. **DNS**: el dominio ya apunta a la IP del servidor (A record)
4. **GitHub token**: con permiso `read:packages` o acceso a releases de `terracenter/sge`
5. **Swap** (recomendado si el VPS tiene ≤ 4 GB RAM):
   ```bash
   sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
   sudo mkswap /swapfile && sudo swapon /swapfile
   echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
   ```

## Instalación

```bash
git clone git@github.com:terracenter/sge-deploy.git
cd sge-deploy
bash install.sh
```

El instalador solicita interactivamente:
- Dominio del servidor (ej: `sge.tuempresa.com`)
- Email para certificado SSL (Let's Encrypt)
- GitHub token (para descargar el release)

El proceso toma ~5 minutos y realiza lo siguiente:

**Fase 1 — Sistema** (requiere sudo)
- Instala PostgreSQL 18, Redis, PgBouncer, Traefik, Node.js 22, golang-migrate
- Crea usuarios del sistema: `sge` (app), `traefik` (proxy), `sge-runner` (CI/CD)
- Crea estructura FHS: `/etc/sge`, `/opt/sge`, `/var/log/sge`, `/var/lib/sge`
- Configura UFW (solo puertos 22, 80, 443)
- Configura PostgreSQL, Redis, PgBouncer
- Aplica hardening SSH + fail2ban
- Instala y habilita units systemd

**Fase 2 — Aplicación** (corre como usuario `sge`)
- Descarga binarios optimizados para el CPU del servidor (amd64-v2/v3/v4)
- Genera claves JWT RS4096 en `/etc/sge/keys/`
- Instala configuración de Traefik con el dominio ingresado
- Genera `/etc/sge/.env` con contraseñas aleatorias
- Ejecuta migraciones de base de datos
- Arranca todos los servicios

Al finalizar, SGE estará corriendo en `https://<dominio>`.

## Post-instalación

### 1. Guardar credenciales

Al terminar el instalador muestra las credenciales generadas. **Guardarlas en un gestor de contraseñas antes de cerrar la sesión.** Están también en `/etc/sge/.env` (solo lectura para `sge`).

### 2. Registrar el GitHub Actions runner

El CI/CD requiere un runner auto-hospedado en el VPS:

```bash
# En GitHub: Settings → Actions → Runners → New self-hosted runner
# Copiar el token de registro y ejecutar:

sudo -u sge-runner bash
cd /opt/sge-runner

# Descargar runner (obtener URL actualizada desde GitHub)
curl -o actions-runner.tar.gz -L https://github.com/actions/runner/releases/latest/download/actions-runner-linux-x64-*.tar.gz
tar xzf actions-runner.tar.gz

# Registrar (reemplazar TOKEN y URL con los de GitHub)
./config.sh --url https://github.com/terracenter/sge --token <TOKEN> --name sge-runner --unattended
./svc.sh install sge-runner
./svc.sh start
```

### 3. Configurar secrets en GitHub

En el repositorio `terracenter/sge` → Settings → Secrets → Actions:

| Secret | Valor |
|--------|-------|
| `DB_PASSWORD` | Desde `/etc/sge/.env` |
| `REDIS_PASSWORD` | Desde `/etc/sge/.env` |
| `JWT_PRIVATE_KEY` | Contenido de `/etc/sge/keys/private.pem` |
| `JWT_PUBLIC_KEY` | Contenido de `/etc/sge/keys/public.pem` |

### 4. Activar licencia

Acceder a `https://<dominio>/settings/licenses` e ingresar el serial de licencia generado con `sgectl`.

## Estructura FHS

```
/etc/sge/              configuración (propietario: sge)
  keys/                claves JWT RS4096
  traefik/             traefik.yml + dynamic/routes.yml + acme.json
  .env                 variables de entorno (modo 600)

/opt/sge/              aplicación (propietario: sge)
  bin/sge              backend Go
  bin/sgectl           CLI admin
  frontend/            Next.js standalone

/var/log/sge/          logs de todos los servicios
/var/lib/sge/backups/  backups de PostgreSQL
```

## Operaciones comunes

```bash
# Estado de servicios
sudo systemctl status sge sge-frontend sge-traefik

# Logs en tiempo real
tail -f /var/log/sge/sge.log
tail -f /var/log/sge/traefik-access.log

# Reiniciar servicios
sudo systemctl restart sge
sudo systemctl restart sge-frontend

# Shell de base de datos
sudo -u postgres psql -d sge_platform

# Generar serial de licencia
/opt/sge/bin/sgectl generate-serial --company-id=1 --type=enterprise
```

## Arquitectura de referencia

Ver `docs/deploy/PRODUCTION_SETUP.md`.
