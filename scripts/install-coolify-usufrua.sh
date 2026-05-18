#!/usr/bin/env bash
# ============================================================
# Instalación de Coolify v4 en el server Usufrua (raicube@47.184.25.55)
# Puertos no-estándar para no chocar con el nginx en :80 (otro huésped).
#
# USO: copiá-pegá ESTE archivo entero en tu sesión SSH, NO lo subas al
# server primero. Es self-contained. Va a pedir sudo password 1-2 veces.
# Tiempo: ~10-15 min (la mayoría es docker pull de imágenes).
# ============================================================

set -euo pipefail

# ---- Puertos custom (no chocan con el nginx en :80) ----
APP_PORT_CUSTOM=8000
PROXY_HTTP_PORT=8080
PROXY_HTTPS_PORT=8443

log() { printf '\n\033[1;36m[install-coolify] %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31m[install-coolify ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

# ============================================================
# 0. Pre-flight
# ============================================================

log "0/6 — Pre-flight: verificando precondiciones del server"

command -v sudo >/dev/null || fail "sudo no está disponible"
command -v docker >/dev/null || fail "docker no está instalado"
command -v curl >/dev/null || fail "curl no está instalado"

sudo -v || fail "necesitás sudo activo. corré 'sudo -v' antes."

docker_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "")
[[ -n "$docker_version" ]] || fail "el daemon de Docker no responde. asegurate que esté arriba."
log "Docker OK: v$docker_version"

# Verificar puertos libres
for port in "$APP_PORT_CUSTOM" "$PROXY_HTTP_PORT" "$PROXY_HTTPS_PORT"; do
  if ss -tlnp 2>/dev/null | grep -qE ":$port\s"; then
    fail "puerto $port ya está en uso. cambiá las vars del script o liberá el puerto."
  fi
done
log "Puertos libres: $APP_PORT_CUSTOM, $PROXY_HTTP_PORT, $PROXY_HTTPS_PORT"

# Verificar espacio en disco
disk_free_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
[[ "$disk_free_gb" -ge 30 ]] || fail "necesitás al menos 30 GB libres en /. tenés ${disk_free_gb} GB."
log "Disco OK: ${disk_free_gb} GB libres"

# Verificar RAM
ram_total_mb=$(free -m | awk '/^Mem:/{print $2}')
[[ "$ram_total_mb" -ge 2000 ]] || fail "necesitás al menos 2 GB de RAM. tenés ${ram_total_mb} MB."
log "RAM OK: ${ram_total_mb} MB total"

# Verificar GPU (info, no bloqueante)
if command -v nvidia-smi >/dev/null; then
  gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader,nounits 2>/dev/null | head -1)
  log "GPU detectada: ${gpu_name:-desconocida} (lista para passthrough en Fase 5)"
fi

# ============================================================
# 1. Instalación oficial de Coolify
# ============================================================

log "1/6 — Instalando Coolify v4 (script oficial)"

if [[ -d /data/coolify ]]; then
  log "/data/coolify ya existe. saltando install para no pisar config existente."
  log "si querés reinstalar desde cero: 'sudo rm -rf /data/coolify' y volvé a correr esto."
else
  # El install script oficial pide sudo internamente; lo corremos directo.
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash
fi

[[ -d /data/coolify/source ]] || fail "instalación incompleta. /data/coolify/source no existe."
log "Coolify instalado en /data/coolify"

# ============================================================
# 2. Ajustar puertos custom (no chocar con :80 del nginx ajeno)
# ============================================================

log "2/6 — Configurando puertos custom + workaround Soketi IPv6"

COOLIFY_ENV=/data/coolify/source/.env

[[ -f "$COOLIFY_ENV" ]] || fail "$COOLIFY_ENV no existe."

# Backup del .env antes de modificar
sudo cp "$COOLIFY_ENV" "${COOLIFY_ENV}.bak-$(date +%s)"

# Función helper para setear/reemplazar una variable en el .env
set_env_var() {
  local key="$1" value="$2"
  if sudo grep -qE "^${key}=" "$COOLIFY_ENV"; then
    sudo sed -i "s|^${key}=.*|${key}=${value}|" "$COOLIFY_ENV"
  else
    echo "${key}=${value}" | sudo tee -a "$COOLIFY_ENV" >/dev/null
  fi
}

set_env_var "APP_PORT" "$APP_PORT_CUSTOM"
set_env_var "APP_PROXY_HTTP_PORT" "$PROXY_HTTP_PORT"
set_env_var "APP_PROXY_HTTPS_PORT" "$PROXY_HTTPS_PORT"
# Workaround conocido v4.1.0: Soketi bindea localhost (IPv4) y rompe realtime
# si el resolver del container favorece IPv6. Bindeamos a "::".
set_env_var "SOKETI_HOST" '"::"'

log "Variables actualizadas en $COOLIFY_ENV"

# ============================================================
# 3. Restart Coolify para aplicar la config
# ============================================================

log "3/6 — Restarting Coolify con la config nueva"

cd /data/coolify/source
sudo docker compose down
sudo docker compose up -d

# ============================================================
# 4. Esperar que todos los containers estén healthy
# ============================================================

log "4/6 — Esperando que Coolify esté listo (hasta 120s)..."

deadline=$(( $(date +%s) + 120 ))
while [[ $(date +%s) -lt $deadline ]]; do
  status=$(sudo docker inspect coolify --format '{{.State.Health.Status}}' 2>/dev/null || echo "starting")
  if [[ "$status" == "healthy" ]]; then
    log "Coolify container healthy"
    break
  fi
  sleep 3
done

# ============================================================
# 5. Verificación
# ============================================================

log "5/6 — Verificación final"

# Containers up
echo "Containers de Coolify:"
sudo docker ps --filter "label=coolify.managed" --format "  {{.Names}}: {{.Status}}" || \
  sudo docker ps --filter "name=coolify" --format "  {{.Names}}: {{.Status}}"

# Endpoint del dashboard
if curl -sf -o /dev/null -m 5 "http://127.0.0.1:${APP_PORT_CUSTOM}/"; then
  log "Dashboard responde en http://127.0.0.1:${APP_PORT_CUSTOM}/"
else
  log "WARN: dashboard aún no responde — puede tardar 30-60s más después del primer boot."
fi

# ============================================================
# 6. Info final
# ============================================================

PUBLIC_IP=$(curl -sS --max-time 4 https://api.ipify.org 2>/dev/null || echo "47.184.25.55")

log "6/6 — Listo. Resumen:"
cat <<EOF

  ┌─────────────────────────────────────────────────────────┐
  │  Coolify instalado en Usufrua                            │
  ├─────────────────────────────────────────────────────────┤
  │  Dashboard:    http://${PUBLIC_IP}:${APP_PORT_CUSTOM}/registration
  │  Proxy HTTP:   :${PROXY_HTTP_PORT}  (redirect → HTTPS)
  │  Proxy HTTPS:  :${PROXY_HTTPS_PORT}  (TLS via Let's Encrypt)
  │  Config dir:   /data/coolify/
  │  Logs:         sudo docker logs -f coolify
  │
  │  Próximos pasos:
  │  1) Abrí el dashboard en tu browser local
  │  2) Crear cuenta admin (primera vez te lleva a /registration)
  │  3) Settings → Sources → New GitHub App
  │     → Authorize repo: kenshin1986/axon-workspace
  │  4) New Project: "admin-data-platform"
  │  5) Add Resource → Database → Postgres 16
  │  6) Add Resource → Application → Dockerfile (apps/web/Dockerfile)
  │     → Port: 3000  |  Health Path: /api/health
  │     → Domain: admin.${PUBLIC_IP//./-}.sslip.io:${PROXY_HTTPS_PORT}
  │     → Pegar env vars de apps/web/.env.production.example
  │  7) Deploy
  └─────────────────────────────────────────────────────────┘

EOF
