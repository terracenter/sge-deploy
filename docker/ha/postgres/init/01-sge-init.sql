-- ─────────────────────────────────────────────────────────────────────────────
-- Inicialización PostgreSQL — Entorno HA Humanbyte
-- Se ejecuta automáticamente en el primer arranque del primario
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Bases de datos ────────────────────────────────────────────────────────────

-- Base de datos principal de SGE (ya existe si POSTGRES_DB=sge_platform)
-- Solo crear sge_panel que no se crea automáticamente
CREATE DATABASE sge_panel
    OWNER postgres
    ENCODING 'UTF8'
    LC_COLLATE 'en_US.UTF-8'
    LC_CTYPE 'en_US.UTF-8'
    TEMPLATE template0;

-- ── Usuarios de aplicación ────────────────────────────────────────────────────

-- Usuario SGE (se crea con POSTGRES_USER, pero asignamos permisos explícitos)
GRANT ALL PRIVILEGES ON DATABASE sge_platform TO sge;

-- Usuario sge_panel
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'sge_panel') THEN
        -- La contraseña se pasa por variable de entorno en el script de replicación
        -- Aquí solo creamos el rol sin contraseña; el script la asigna
        CREATE ROLE sge_panel LOGIN;
    END IF;
END $$;

GRANT ALL PRIVILEGES ON DATABASE sge_panel TO sge_panel;

-- ── Tablespace SGE ────────────────────────────────────────────────────────────
-- Se crea en un paso posterior (sección 9 del manual) después de montar el LV
-- El directorio /srv/sge_data debe existir y tener permisos antes de ejecutar:
-- CREATE TABLESPACE sge_data OWNER sge LOCATION '/srv/sge_data';

-- ── Extensiones en sge_platform ───────────────────────────────────────────────
\connect sge_platform

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- ── Extensiones en sge_panel ──────────────────────────────────────────────────
\connect sge_panel

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
