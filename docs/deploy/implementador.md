# Guía del Implementador — SGE

Este documento debe leerse **completo antes de instalar**. La instalación es irreversible en algunos pasos (generación de claves, configuración de BD).

---

## ¿Qué es el implementador?

El implementador es la persona (socio de Terracenter o técnico autorizado) responsable de instalar y poner en producción SGE en el servidor del cliente. No es el administrador del sistema del cliente — es quien hace la instalación inicial.

---

## Requisitos previos

Antes de comenzar verifique **todos** los puntos:

### Servidor
| Requisito | Mínimo | Recomendado |
|---|---|---|
| Sistema operativo | Debian 13 (trixie) | Debian 13 (trixie) |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disco | 40 GB SSD | 80 GB SSD |
| Arquitectura | amd64 | amd64 |

> SGE **solo** tiene soporte oficial en Debian Estable (actualmente Debian 13). No instalar en Ubuntu, Debian testing/unstable ni derivados.

### Red y DNS
- El dominio del cliente ya debe **apuntar a la IP del servidor** (registro A en DNS)
- Verificar antes de instalar: `dig +short sge.empresa.com` debe devolver la IP del VPS
- Los puertos 80 y 443 deben estar libres y accesibles desde internet
- El servidor necesita salida a internet (para descargar certificados SSL de Let's Encrypt)

### Acceso
- Usuario con `sudo` en el servidor (no instalar como root directamente)
- Acceso SSH al servidor

---

## Decisión: ¿Con LVM o Sin LVM?

Esta es la decisión más importante antes de instalar. **Debe tomarse antes de crear el servidor**, ya que LVM requiere configuración de disco desde el inicio.

### Con LVM — Producción real

**Ventajas:**
- Snapshots instantáneos antes de cada actualización (rollback en segundos)
- Resize de volúmenes en caliente sin downtime
- Backups consistentes mientras la BD está activa

**Cuándo usar:**
- Clientes empresariales con datos críticos
- Servidores propios (no VPS básico)
- Cuando hay contrato de SLA

**Preparación adicional** (antes de `apt install sge`):

```bash
# Ejemplo con disco /dev/sdb dedicado a datos SGE
sudo pvcreate /dev/sdb
sudo vgcreate sge-vg /dev/sdb

# Crear volúmenes lógicos
sudo lvcreate -L 20G -n db   sge-vg   # datos PostgreSQL
sudo lvcreate -L 10G -n data sge-vg   # backups y datos Redis
sudo lvcreate -L 5G  -n logs sge-vg   # logs

# Formatear
sudo mkfs.ext4 /dev/sge-vg/db
sudo mkfs.ext4 /dev/sge-vg/data
sudo mkfs.ext4 /dev/sge-vg/logs

# Montar (agregar a /etc/fstab para que persista)
sudo mkdir -p /var/lib/postgresql /var/lib/sge /var/log/sge

echo '/dev/sge-vg/db   /var/lib/postgresql ext4 defaults 0 2' | sudo tee -a /etc/fstab
echo '/dev/sge-vg/data /var/lib/sge        ext4 defaults 0 2' | sudo tee -a /etc/fstab
echo '/dev/sge-vg/logs /var/log/sge        ext4 defaults 0 2' | sudo tee -a /etc/fstab

sudo mount -a
```

---

### Sin LVM — Contabo / VPS básico / Demo

**Cuándo usar:**
- VPS de Contabo (plan básico sin LVM)
- Instalaciones demo para clientes potenciales
- Clientes pequeños sin requerimientos de SLA estricto

**No requiere** preparación adicional de disco. Se instala directamente.

**Limitaciones:**
- Sin snapshots automáticos — backups solo via `pg_dump` (programados en cron)
- Resize de disco requiere downtime
- Mayor riesgo en actualizaciones (no hay rollback instantáneo)

---

## Proceso de instalación

### Paso 1 — Agregar repositorios de dependencias

SGE requiere PostgreSQL 18 y Node.js 24, que no están en los repos base de Debian 13. El siguiente script los agrega de forma segura:

```bash
curl -fsSL https://packages.humanbyte.net/setup.sh | sudo bash
```

Este script agrega:
- Repositorio PostgreSQL (pgdg) — firmado con clave oficial
- Repositorio Node.js 24 LTS (NodeSource) — firmado con clave oficial
- Repositorio Terracenter (SGE) — firmado con clave de Terracenter

### Paso 2 — Instalar SGE

```bash
sudo apt install sge
```

El paquete instala automáticamente:
- Binarios `sge` y `sgectl`
- Frontend Next.js
- Traefik reverse proxy
- golang-migrate
- Servicios systemd (deshabilitados hasta el setup)
- Plantillas de configuración

Al terminar mostrará el mensaje de post-instalación.

### Paso 3 — Configuración inicial

```bash
sudo sgectl setup
```

El asistente interactivo pedirá:
1. Aceptación de términos y condiciones
2. Dominio del servidor (ej: `sge.empresa.com`)
3. Email para certificado SSL

Y ejecutará automáticamente:
- Configuración de PostgreSQL, Redis, PgBouncer
- Generación de claves JWT RS4096
- Escritura de `/etc/sge/.env`
- Configuración de Traefik con el dominio
- Migraciones de base de datos
- Inicio de los 3 servicios

### Paso 4 — Guardar credenciales

Al finalizar `sgectl setup` se muestran las credenciales generadas. **Guardarlas inmediatamente en un gestor de contraseñas** antes de cerrar la sesión SSH.

También están en `/etc/sge/.env` (modo 600, solo accesibles como root o usuario `sge`).

### Paso 5 — Verificar que todo funciona

```bash
# Estado de servicios
sudo systemctl status sge sge-frontend sge-traefik

# Health check del backend
curl -sf https://sge.empresa.com/api/v1/health

# Logs en tiempo real
tail -f /var/log/sge/sge.log
```

### Paso 6 — Activar licencia

Acceder a `https://sge.empresa.com` e ingresar el serial de licencia en:
**Configuración → Licencias → Activar**

---

## Actualizaciones futuras

Las actualizaciones las gestiona el **personal autorizado del cliente** desde el panel de SGE (notificación de nueva versión → revisión del changelog → autorización → ejecución).

El comando técnico en el servidor es simplemente:

```bash
sudo apt upgrade sge
```

> **IMPORTANTE:** Nunca actualizar sin autorización del cliente y sin haber probado en entorno de prueba primero. Cada empresa tiene sus propias políticas de cambio.

---

## Operaciones comunes

```bash
# Estado de servicios
sudo systemctl status sge sge-frontend sge-traefik

# Reiniciar servicios
sudo systemctl restart sge
sudo systemctl restart sge-frontend
sudo systemctl restart sge-traefik

# Logs en tiempo real
tail -f /var/log/sge/sge.log
tail -f /var/log/sge/sge-error.log
tail -f /var/log/sge/traefik-access.log

# Conectar a la base de datos
sudo -u postgres psql -d sge_platform

# Ver configuración actual
sudo cat /etc/sge/.env
```

---

## Desinstalación

```bash
# Elimina binarios pero conserva datos y configuración
sudo apt remove sge

# Elimina TODO (excepto backups en /var/lib/sge/backups)
sudo apt purge sge
```

> Los backups en `/var/lib/sge/backups` **nunca se eliminan automáticamente**. El DBA del cliente debe revisarlos y eliminarlos manualmente.

---

## Soporte

Ante cualquier problema durante la instalación:
- Documentación: https://docs.humanbyte.net/deploy
- Soporte técnico: soporte@terracenter.com
