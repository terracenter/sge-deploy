# Fase 3 — Systemd Services y Configuración Traefik

## Estructura FHS adoptada

```
/etc/sge/              → configuración (config.yaml, keys/, traefik/, .env)
/opt/sge/              → binarios (bin/) y frontend
/var/log/sge/          → logs de todos los servicios SGE
/var/lib/sge/          → datos persistentes (backups/, data/)
```

---

## PASO 1 — En el VPS: crear estructura FHS

```bash
sudo mkdir -p /etc/sge/{keys,traefik/dynamic} && sudo mkdir -p /opt/sge/{bin,frontend} && sudo mkdir -p /var/log/sge && sudo mkdir -p /var/lib/sge/{backups,data/redis} && sudo touch /etc/sge/traefik/acme.json && sudo chmod 600 /etc/sge/traefik/acme.json && sudo chmod 700 /etc/sge/keys && sudo chown -R sge:sge /etc/sge /opt/sge /var/log/sge /var/lib/sge && echo "FHS OK"
```

**Mover .env a su ubicación FHS:**
```bash
sudo mv /opt/sge/.env /etc/sge/.env && sudo chmod 600 /etc/sge/.env && sudo chown sge:sge /etc/sge/.env && echo ".env movido OK"
```

---

## PASO 2 — Desde MÁQUINA LOCAL: subir todo con rsync

```bash
rsync -av deploy/sge.service deploy/sge-frontend.service deploy/sge-traefik.service traefik/traefik.yml traefik/dynamic/routes.yml freddy@sge.humanbyte.net:/tmp/
```

---

## PASO 3 — En el VPS: instalar todo

**Instalar systemd services:**
```bash
sudo mv /tmp/sge.service /tmp/sge-frontend.service /tmp/sge-traefik.service /etc/systemd/system/ && sudo systemctl daemon-reload && sudo systemctl enable sge sge-frontend sge-traefik && echo "Services OK"
```

**Instalar configs Traefik:**
```bash
sudo mv /tmp/traefik.yml /etc/sge/traefik/traefik.yml && sudo mv /tmp/routes.yml /etc/sge/traefik/dynamic/routes.yml && sudo chown -R sge:sge /etc/sge/traefik/ && echo "Traefik OK"
```

**Agregar ACME_EMAIL al .env (reemplazar con email real):**
```bash
echo "ACME_EMAIL=tu@email.com" | sudo tee -a /etc/sge/.env
```

---

## PASO 4 — Verificar en el VPS

```bash
sudo systemctl status sge sge-frontend sge-traefik --no-pager
```

> Los services mostrarán `inactive (dead)` — es correcto, aún no hay binarios desplegados.

```bash
sudo ls -la /etc/sge/ && sudo ls -la /etc/sge/traefik/ && sudo ls -la /var/log/sge/
```
