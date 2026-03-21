# SGE — Sistema de Gestión Empresarial

Repositorio público de distribución de SGE. Contiene el instalador, el script de repositorios y la estructura del paquete `.deb`.

> El código fuente de SGE es privado. Este repositorio solo contiene las herramientas de instalación y los releases del paquete.

---

## Instalación rápida

### Requisitos previos

| Requisito | Valor |
|-----------|-------|
| Sistema operativo | Debian 13 (trixie) — amd64 |
| CPU | mínimo 2 vCPU |
| RAM | mínimo 4 GB |
| Disco | mínimo 40 GB SSD |
| DNS | el dominio ya debe apuntar al servidor (registro A) |

### Paso 1 — Configurar repositorios

```bash
curl -fsSL https://packages.humanbyte.net/setup.sh | sudo bash
```

Agrega los repositorios de PostgreSQL 18, Node.js 24 LTS y SGE.

### Paso 2 — Instalar SGE

```bash
sudo apt install sge
```

### Paso 3 — Configuración inicial

```bash
sudo sgectl setup
```

El asistente interactivo pedirá el dominio y el email para SSL, luego configurará PostgreSQL, Redis, PgBouncer, Traefik, generará las claves JWT y ejecutará las migraciones.

Al finalizar SGE estará corriendo en `https://<dominio>`.

---

## Documentación completa

- [Guía del implementador](docs/deploy/implementador.md) — proceso completo, decisión LVM, operaciones comunes
- Documentación pública: https://docs.humanbyte.net/deploy

---

## Estructura del repositorio

```
packaging/
  install.sh              script de instalación (descarga .deb desde GitHub Releases)
  setup-repos.sh          configura repositorios APT de dependencias
  debian/                 archivos de control del paquete .deb
  usr/share/sge/          plantillas de configuración incluidas en el paquete
docs/
  deploy/
    implementador.md      guía para implementadores
traefik/                  configuración de referencia de Traefik
```

---

## Soporte

- Documentación: https://docs.humanbyte.net
- Soporte técnico: soporte@terracenter.com
