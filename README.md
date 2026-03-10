# sge-deploy

Instalador y herramientas de despliegue para SGE (Sistema de Gestión Empresarial).

## Uso

```bash
git clone git@github.com:terracenter/sge-deploy.git
cd sge-deploy
bash install.sh
```

El instalador:
- Detecta el nivel de CPU (amd64-v2/v3/v4) y descarga el binario optimizado
- Instala y configura PostgreSQL 18, Redis, PgBouncer, Traefik
- Aplica hardening de seguridad (SSH, fail2ban, firewall)
- Ejecuta migraciones y arranca todos los servicios

## Requisitos

- Debian 13
- Usuario con sudo
- GitHub token con acceso a `terracenter/sge` releases
- Dominio apuntando al servidor

## Estructura FHS

```
/etc/sge/          configuración, keys, traefik
/opt/sge/          binarios, frontend
/var/log/sge/      logs
/var/lib/sge/      backups, datos
```
