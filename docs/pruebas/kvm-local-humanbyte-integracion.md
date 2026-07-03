# Pruebas de integración SGE ↔ SGE-PANEL — Entorno KVM local Humanbyte

**Entorno:** Docker HA en VM KVM local (IP Tailscale: 100.69.62.114)
**Fecha inicio:** 2026-04-23
**Objetivo:** Verificar que SGE-PANEL gestiona correctamente instalaciones SGE en escenarios normales y de error.

---

## Credenciales del entorno de pruebas

| Servicio | Usuario | Contraseña |
|----------|---------|------------|
| SGE admin | admin@sge.local | admin123 |
| SGE-PANEL admin | admin | Admin1234567! |

**JWT SGE:** expira en 15 min — obtener con `POST /sge/api/v1/auth/login`
**CSRF Panel:** obtener en respuesta de `POST /sge-panel/api/auth/login`

---

## Ed25519 — Clave activa en VM (desde commit 3d81aee)

- Public key (en `sge-panel/keys/` y embebida en binario SGE de la VM):
  `MCowBQYDK2VwAyEAzNr/y+V5xWfNPQnmlKBFg8nENzN1iwo8AdylSw4gVa4=`

- Clave vieja (en `Sge-Go/internal/core/licensing/public.pem` en rama local main):
  `MCowBQYDK2VwAyEAE85jydwuR5YV/2ScP/hdtGm9T4nPahs0tEJ6aQMTkF0=`
  → **PENDIENTE sync** a la rama local

---

## Combinaciones válidas de tipo de licencia × tipo de instalación

| Instalación | Licencias permitidas |
|-------------|---------------------|
| `personal` | `trial-pf`, `basic` |
| `empresa` | `trial-enterprise`, `enterprise` |

---

## Resultados de los tests

### T-01 — Registro demo exitoso
**Objetivo:** Llamar `POST /sge-panel/api/register` con datos válidos y obtener serial demo.
**Resultado:** ✅ PASÓ
- `installation_id` generado
- Serial demo devuelto en respuesta
- Tipo de serial: `trial-enterprise` (empresa) / `trial-pf` (personal)

---

### T-02 — Registro con email inválido
**Objetivo:** Verificar validación de email en el endpoint de registro.
**Resultado:** ✅ PASÓ — error 400 retornado correctamente.

---

### T-03 — Registro con fingerprint vacío
**Objetivo:** Verificar que el fingerprint es obligatorio.
**Resultado:** ✅ PASÓ — error 400 retornado.

---

### T-04 — Ver instalación en SGE-PANEL admin
**Objetivo:** Confirmar que la instalación registrada aparece en la lista del admin.
**Resultado:** ✅ PASÓ — instalación visible en `GET /api/installations`.

---

### T-05 — Activación exitosa con serial válido
**Objetivo:** Activar SGE con serial enterprise generado desde admin panel.
**Serial:** fingerprint real de la VM (`2481f64a...`)
**Resultado:** ✅ PASÓ
- Respuesta: `{"license_type":"enterprise","message":"Licencia activada exitosamente.",...}`
- Módulos activos: accounting, company-setup, core, inventory, invoicing, partners, personal-finance, treasury

---

### T-06 — Verificar estado de licencia post-activación
**Objetivo:** Confirmar que `GET /api/v1/licenses/installation-status` refleja la activación.
**Resultado:** ✅ PASÓ — status activo, tipo enterprise.

---

### T-07 — Revocación detectada por phone-home
**Objetivo:** Revocar licencia en panel y verificar que SGE la detecta.
**Resultado:** ✅ PASÓ (2026-04-24)
**Evidencia (log sge-ha-backend-1):**
```
{"level":"info","timestamp":"2026-04-24T18:28:07.928Z","message":"phone-home: validación exitosa","action":"status=revoked next_check=7d"}
```
SGE detectó correctamente la revocación via phone-home.

---

### T-08 — Expiración detectada por phone-home
**Objetivo:** Serial con 1 día de vigencia → SGE lo detecta al expirar.
**Resultado:** ✅ PASÓ (2026-04-24)
**Evidencia (log sge-ha-backend-1):**
```
{"level":"info","timestamp":"2026-04-24T18:29:08.719Z","message":"phone-home: validación exitosa","action":"status=expired next_check=7d"}
```
SGE detectó correctamente la expiración via phone-home.

---

### T-09 — Serial con firma Ed25519 de clave antigua (rotación de claves)
**Objetivo:** Serial firmado con clave privada anterior al commit 3d81aee (rotación).
**Serial usado:** `9d38097d...` (firmado con clave vieja)
**Resultado:** ✅ PASÓ (comportamiento correcto)
- SGE rechazó el serial con `{"error":"invalid token"}`
- Clave vieja ya no es válida tras rotación.

---

### T-10 — Serial con firma tampered (byte modificado)
**Objetivo:** Verificar que SGE detecta firmas adulteradas.
**Resultado:** ✅ PASÓ (comportamiento correcto)
- Serial con último byte de firma modificado → `{"error":"invalid token"}`
- Ed25519 signature verification funciona correctamente.

---

### T-11 — Serial con fingerprint de otra máquina (firma válida)
**Objetivo:** Verificar si SGE valida que el fingerprint del serial coincide con el hardware real.
**Serial:** fingerprint `aabbccdd00112233aabbccdd00112233aabbccdd00112233aabbccdd00112233` (falso)
**Firma:** válida con clave activa.
**Resultado:** ✅ PASÓ tras fix de BUG-03 (2026-04-24)

BUG-03 original: SGE aceptaba serial con fingerprint falso.
**Fix aplicado (commits `19be96a` + `cfb65d2`):** `ActivateInstallation` verifica que `SGE_FINGERPRINT` (env var del contenedor/sistema) coincida con `payload.Fingerprint` del serial. Si no coincide → `{"error":"fingerprint mismatch"}`.

Post-fix: serial con fingerprint `aabbccdd...` es rechazado correctamente en máquina con fingerprint diferente.

---

### T-12 — SGE-PANEL offline durante registro
**Objetivo:** Detener el panel backend y verificar manejo de error.
**Prueba:** `docker stop sge-ha-panel-backend`, luego llamar endpoints del panel.
**Resultado:** ⚠️ PARCIALMENTE PASÓ — bug de infraestructura encontrado

**Hallazgos:**
1. `POST /sge-panel/api/register` con panel offline → **404** (devuelve HTML de Next.js, no 502 de Traefik)
   - Causa: cuando el contenedor para, Traefik elimina el router del backend y el frontend Next.js captura todo `/sge-panel/`
   - Esperado: 502/503 de Traefik para que SGE detecte el panel offline
   - **BUG-04:** configuración Traefik — usar `healthcheck` para marcar servicio no disponible con 503, no enrutar al frontend

2. `POST /sge-panel/api/validate` → mismo resultado: 404 HTML

3. **Phone-home worker de SGE**: código revisado en `phonehome.go`
   - Si panel responde != 200 → llama `handleOffline()`
   - Si no hay state file previo: crea estado de emergencia con 30 días, 7 días readonly, 14 días grace → SGE sigue funcionando
   - Si hay state file previo: respeta el estado guardado
   - **Comportamiento correcto** — SGE no bloquea usuarios inmediatamente cuando el panel cae

**Conclusión T-12:** La lógica de SGE es resiliente al panel offline. El problema es a nivel de Traefik: debería devolver 502/503, no redirigir al frontend.

---

## Bugs encontrados

| ID | Severidad | Descripción | Estado |
|----|-----------|-------------|--------|
| BUG-01 | Media | `AdminSerialRequest` sin JSON tags → request con snake_case falla | ✅ Ya tenía tags (verificado 2026-04-24) |
| BUG-02 | Media | `SGE_INSTALLATION_ID` y `SGE_FINGERPRINT` faltantes en docker-compose → phone-home deshabilitado | ✅ Corregido commit `14f50d9` |
| BUG-03 | **Alta** | SGE no verifica que el fingerprint del serial coincida con el hardware real | ✅ Corregido commits `19be96a` + `fix: usar SGE_FINGERPRINT env var en Docker` |
| BUG-04 | Baja | Traefik enruta a frontend Next.js cuando panel backend está offline (debería 502/503) | ✅ Corregido: healthcheck Traefik + regla panel-web excluye /api |
| BUG-05 | Media | phone-home no encontraba license.key — `ActivateInstallation` no escribía el archivo | ✅ Corregido: service.go ahora escribe `/etc/sge/license.key`; volumen `sge-ha-etc` en compose |

---

## Comandos de referencia para los tests

```bash
# Login SGE (renovar JWT cada 15 min)
curl -s -X POST http://100.69.62.114/sge/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@sge.local","password":"admin123"}'

# Login SGE-PANEL admin (renovar CSRF cuando expire)
curl -sv -X POST http://100.69.62.114/sge-panel/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"admin","password":"Admin1234567!"}'

# Generar serial desde admin panel
curl -s -X POST http://100.69.62.114/sge-panel/api/serials \
  -H 'Content-Type: application/json' \
  -H 'X-CSRF-Token: <TOKEN>' \
  -b 'sge_admin_session=<SESSION>' \
  -d '{"ContactName":"...","ContactEmail":"...","ContactPhone":"...","Fingerprint":"...","InstallationType":"empresa","LicenseType":"enterprise","ExpiryDays":0}'

# Activar serial en SGE
curl -s -X POST http://100.69.62.114/sge/api/v1/licenses/activate-installation \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer <JWT>" \
  -H 'X-Company-ID: 1' \
  -d '{"serial":"<SERIAL>"}'

# Estado de licencia
curl -s http://100.69.62.114/sge/api/v1/licenses/installation-status \
  -H "Authorization: Bearer <JWT>" \
  -H 'X-Company-ID: 1'
```
