# Git y GitHub — Referencia para el equipo de desarrollo

Este documento explica los conceptos clave de Git y GitHub usados en el proyecto SGE. Está pensado para desarrolladores que se integran al equipo.

---

## 1. Git vs GitHub

| | Git | GitHub |
|---|---|---|
| **Qué es** | Herramienta de control de versiones (corre en tu PC) | Plataforma web que aloja repositorios Git |
| **Dónde vive** | Local (tu máquina) | En la nube (github.com) |
| **Para qué sirve** | Registrar cambios en el código | Colaborar, revisar código, automatizar tareas |

Git es la herramienta. GitHub es el servidor donde se guarda y comparte el trabajo.

---

## 2. Repositorios: privados y públicos

Un **repositorio** (repo) es la carpeta del proyecto con todo su historial de cambios.

| | Privado | Público |
|---|---|---|
| **Quién puede verlo** | Solo miembros con acceso | Cualquier persona en internet |
| **Quién puede descargarlo** | Solo con autenticación | Sin necesidad de cuenta ni contraseña |
| **Cuándo usarlo** | Código fuente, secretos, lógica de negocio | Instaladores, documentación, releases |

**En SGE:**
- `terracenter/sge` → **privado** — contiene todo el código fuente
- `terracenter/sge-deploy` → **público** — contiene el instalador y los paquetes `.deb` para descargar

---

## 3. GitHub Actions (CI/CD)

**CI/CD** significa *Continuous Integration / Continuous Delivery* — automatización del proceso de construir, probar y publicar software.

**GitHub Actions** es el sistema de automatización de GitHub. Se configura con archivos `.yml` dentro de `.github/workflows/`.

### Cómo funciona

```
Desarrollador hace push/tag
        ↓
GitHub detecta el evento
        ↓
Lanza un "runner" (servidor temporal en la nube)
        ↓
Ejecuta los pasos definidos en el workflow
        ↓
Resultado: binarios compilados, paquetes creados, releases publicados
```

### Ejemplo en SGE

Cuando se hace `git tag v1.0.0 && git push --tags` en el repo `sge`:

1. GitHub Actions arranca automáticamente
2. Compila los binarios de Go (backend)
3. Compila el frontend (Next.js)
4. Construye el paquete `.deb`
5. Publica el release en `sge-deploy` (público)

Todo esto sin intervención manual.

---

## 4. Secrets (secretos)

Los workflows de GitHub Actions a veces necesitan credenciales: contraseñas, tokens, claves. Estas **no se guardan en el código** — se guardan como *secrets* en la configuración del repo.

**Dónde se configuran:**
`Repo → Settings → Secrets and variables → Actions`

**Cómo se usan en el workflow:**
```yaml
- name: Publicar release
  env:
    TOKEN: ${{ secrets.SGE_DEPLOY_PAT }}
  run: gh release create ...
```

El valor real del secret nunca aparece en los logs ni en el código.

---

## 5. Personal Access Tokens (PAT)

Un **PAT** es una credencial que representa a un usuario de GitHub. Funciona como una contraseña, pero:

- Tiene permisos específicos (no acceso total)
- Tiene fecha de expiración
- Se puede revocar en cualquier momento
- Se puede limitar a repositorios específicos

### Tipos de PAT

| Tipo | Alcance | Recomendado |
|---|---|---|
| Classic | Acceso amplio, difícil de limitar | No |
| Fine-grained | Por repo, por permiso, con expiración | ✅ Sí |

---

## 6. Cross-repo workflows (flujo entre repositorios)

Es el caso donde un workflow en un repo necesita hacer algo en **otro repo diferente**.

**Problema:** Por defecto, el CI de `sge` solo tiene permiso para actuar dentro de `sge`. Para publicar algo en `sge-deploy` necesita autorización explícita.

**Solución:** Fine-grained PAT con permiso de escritura en `sge-deploy`, guardado como secret en `sge`.

```
CI de sge (privado)
  usa secret SGE_DEPLOY_PAT
        ↓
  se autentica en GitHub como Terracenter
        ↓
  crea release en sge-deploy (público)
        ↓
  sube el .deb como asset del release
```

**Resultado:** cualquier persona puede descargar el `.deb` desde `sge-deploy` sin tener cuenta de GitHub ni token.

---

## 7. Releases y assets

Un **release** en GitHub es una versión publicada del software. Se asocia a un tag de Git (ej: `v1.0.0`).

Un release puede tener **assets**: archivos adjuntos para descargar (binarios, paquetes `.deb`, `.tar.gz`, etc.).

```
github.com/terracenter/sge-deploy/releases/tag/v1.0.0
  ├── sge_1.0.0_amd64.deb       ← paquete Debian
  ├── sge-linux-amd64-v3        ← binario Go
  └── sge-frontend.tar.gz       ← frontend compilado
```

En repos públicos, estos archivos son descargables por cualquier persona sin autenticación.

---

## Resumen del flujo completo en SGE

```
1. Desarrollador: git tag v1.0.0 && git push --tags
                        (en repo sge, privado)
2. GitHub Actions:
   - compila Go + Next.js
   - construye sge_1.0.0_amd64.deb
   - usa SGE_DEPLOY_PAT para publicar en sge-deploy
3. Release público en sge-deploy con el .deb
4. Implementador (en el VPS del cliente):
   curl .../setup.sh | sudo bash
   sudo apt install sge
   sudo sgectl setup
```
