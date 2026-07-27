#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="${PROJECT_DIR:-/opt/proxmox-cloud-portal}"
COMPOSE_BASE="docker-compose.yml"
COMPOSE_LAB="docker-compose.lab.yml"

log(){ printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn(){ printf '\n\033[1;33mWARNING: %s\033[0m\n' "$*"; }
die(){ printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"
cd "$PROJECT_DIR"
[[ -f "$COMPOSE_BASE" ]] || die "$PROJECT_DIR/$COMPOSE_BASE not found"
[[ -f .env.example ]] || die "$PROJECT_DIR/.env.example not found"
command -v docker >/dev/null || die "Docker is not installed"
docker compose version >/dev/null || die "Docker Compose plugin is not installed"

log "Installing small required utilities"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl jq openssl ca-certificates >/dev/null
systemctl enable --now docker >/dev/null 2>&1 || true

DEFAULT_PORTAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
read -rp "Portal VM IP [$DEFAULT_PORTAL_IP]: " PORTAL_IP
PORTAL_IP="${PORTAL_IP:-$DEFAULT_PORTAL_IP}"
[[ -n "$PORTAL_IP" ]] || die "Portal IP is required"

read -rp "Proxmox API IP or hostname [10.150.100.31]: " PVE_HOST
PVE_HOST="${PVE_HOST:-10.150.100.31}"
read -rp "Proxmox token ID [portal@pve!cloudportal]: " PVE_TOKEN_ID
PVE_TOKEN_ID="${PVE_TOKEN_ID:-portal@pve!cloudportal}"
read -rsp "Proxmox token secret: " PVE_TOKEN_SECRET; echo
[[ -n "$PVE_TOKEN_SECRET" ]] || die "Token secret is required"
read -rp "Proxmox node containing the template [node1]: " PVE_NODE
PVE_NODE="${PVE_NODE:-node1}"
read -rp "Proxmox storage [local-lvm]: " PVE_STORAGE
PVE_STORAGE="${PVE_STORAGE:-local-lvm}"
read -rp "Proxmox bridge [vmbr0]: " PVE_BRIDGE
PVE_BRIDGE="${PVE_BRIDGE:-vmbr0}"
read -rp "Approved template VMID [9000]: " TEMPLATE_VMID
TEMPLATE_VMID="${TEMPLATE_VMID:-9000}"
[[ "$TEMPLATE_VMID" =~ ^[0-9]+$ ]] || die "Template VMID must be numeric"

log "Testing Proxmox API token"
PVE_RESPONSE="$(curl -ksS --connect-timeout 8 --max-time 20 \
  -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}" \
  "https://${PVE_HOST}:8006/api2/json/version")" || die "Cannot reach Proxmox API"
echo "$PVE_RESPONSE" | jq -e '.data.version' >/dev/null || die "Proxmox authentication failed: $PVE_RESPONSE"
echo "$PVE_RESPONSE" | jq '.data'

log "Backing up current configuration"
STAMP="$(date +%Y%m%d-%H%M%S)"
mkdir -p backups
[[ -f .env ]] && cp -a .env "backups/.env.$STAMP"
[[ -f "$COMPOSE_LAB" ]] && cp -a "$COMPOSE_LAB" "backups/$COMPOSE_LAB.$STAMP"
[[ -f keycloak-realm.json ]] && cp -a keycloak-realm.json "backups/keycloak-realm.json.$STAMP"

[[ -f .env ]] || cp .env.example .env

set_env(){
  local key="$1" value="$2"
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

# Generate passwords only when placeholders/missing.
current_or_random(){
  local key="$1" current
  current="$(grep -E "^${key}=" .env | cut -d= -f2- || true)"
  if [[ -z "$current" || "$current" == CHANGE_ME* ]]; then
    openssl rand -hex 24
  else
    printf '%s' "$current"
  fi
}

POSTGRES_PASSWORD="$(current_or_random POSTGRES_PASSWORD)"
KEYCLOAK_ADMIN_PASSWORD="$(current_or_random KEYCLOAK_ADMIN_PASSWORD)"

log "Writing lab configuration"
set_env POSTGRES_DB cloudportal
set_env POSTGRES_USER cloudportal
set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
set_env KEYCLOAK_ADMIN admin
set_env KEYCLOAK_ADMIN_PASSWORD "$KEYCLOAK_ADMIN_PASSWORD"
set_env KEYCLOAK_REALM cloud
set_env KEYCLOAK_CLIENT_ID cloud-portal-api
set_env KEYCLOAK_ISSUER_INTERNAL http://keycloak:8080/auth/realms/cloud
set_env KEYCLOAK_ISSUER_PUBLIC "https://${PORTAL_IP}/auth/realms/cloud"
set_env PROXMOX_API_URL "https://${PVE_HOST}:8006/api2/json"
set_env PROXMOX_TOKEN_ID "$PVE_TOKEN_ID"
set_env PROXMOX_TOKEN_SECRET "$PVE_TOKEN_SECRET"
set_env PROXMOX_VERIFY_TLS false
set_env PROXMOX_CA_CERT /run/secrets/proxmox_ca.pem
set_env PROXMOX_DEFAULT_NODE "$PVE_NODE"
set_env PROXMOX_DEFAULT_STORAGE "$PVE_STORAGE"
set_env PROXMOX_DEFAULT_BRIDGE "$PVE_BRIDGE"
set_env PROXMOX_TEMPLATE_VMID "$TEMPLATE_VMID"
set_env NEXT_PUBLIC_API_BASE_URL "https://${PORTAL_IP}/api/v1"
set_env NEXT_PUBLIC_KEYCLOAK_URL "https://${PORTAL_IP}/auth"
set_env NEXT_PUBLIC_KEYCLOAK_REALM cloud
set_env NEXT_PUBLIC_KEYCLOAK_CLIENT_ID cloud-portal-web
chmod 600 .env

mkdir -p secrets nginx/certs
[[ -s secrets/proxmox_ca.pem ]] || printf 'lab-placeholder\n' > secrets/proxmox_ca.pem

log "Creating self-signed HTTPS certificate for ${PORTAL_IP}"
openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout nginx/certs/cloudportal.key \
  -out nginx/certs/cloudportal.crt \
  -days 825 \
  -subj "/CN=${PORTAL_IP}" \
  -addext "subjectAltName=IP:${PORTAL_IP}" >/dev/null 2>&1
chmod 600 nginx/certs/cloudportal.key

cat > nginx/default.conf <<'NGINX'
server {
    listen 80;
    return 301 https://$host$request_uri;
}
server {
    listen 443 ssl;
    ssl_certificate /etc/nginx/certs/cloudportal.crt;
    ssl_certificate_key /etc/nginx/certs/cloudportal.key;
    client_max_body_size 20m;

    location /auth/ {
        proxy_pass http://keycloak:8080/auth/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
    }
    location /api/ {
        proxy_pass http://backend:8000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location / {
        proxy_pass http://frontend:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

cat > "$COMPOSE_LAB" <<EOF
services:
  keycloak:
    environment:
      KC_HTTP_RELATIVE_PATH: /auth
      KC_PROXY_HEADERS: xforwarded
      KC_HOSTNAME: https://${PORTAL_IP}/auth
      KC_HOSTNAME_STRICT: "false"
  nginx:
    image: nginx:1.27-alpine
    restart: unless-stopped
    depends_on:
      - frontend
      - backend
      - keycloak
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
EOF

# Ensure PKCE is enabled in the source.
if [[ -f frontend/app/vms/page.tsx ]]; then
  sed -i "s/pkceMethod: false/pkceMethod: 'S256'/g; s/pkceMethod: \"S256\"/pkceMethod: 'S256'/g" frontend/app/vms/page.tsx
fi

# Update initial realm import for fresh deployments.
python3 - "$PORTAL_IP" <<'PY'
import json, sys
from pathlib import Path
p = Path('keycloak-realm.json')
if not p.exists():
    raise SystemExit(0)
ip = sys.argv[1]
data = json.loads(p.read_text())
for c in data.get('clients', []):
    if c.get('clientId') == 'cloud-portal-web':
        c['redirectUris'] = [f'https://{ip}/*']
        c['webOrigins'] = [f'https://{ip}']
p.write_text(json.dumps(data, indent=2) + '\n')
PY

log "Validating Docker Compose"
docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAB" config --quiet

log "Building and starting all services"
docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAB" up -d --build

log "Waiting for backend health"
for i in $(seq 1 60); do
  if curl -fsS http://127.0.0.1:8000/api/v1/health >/dev/null 2>&1; then break; fi
  sleep 3
  [[ $i -lt 60 ]] || { docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAB" logs --tail=100; die "Backend did not become healthy"; }
done

log "Waiting for Keycloak"
for i in $(seq 1 80); do
  if curl -fsS http://127.0.0.1:8080/auth/realms/master >/dev/null 2>&1; then break; fi
  sleep 3
  [[ $i -lt 80 ]] || { docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAB" logs --tail=100 keycloak; die "Keycloak did not become ready"; }
done

log "Configuring Keycloak client and demo user"
KC="docker compose -f $COMPOSE_BASE -f $COMPOSE_LAB exec -T keycloak /opt/keycloak/bin/kcadm.sh"
$KC config credentials --server http://localhost:8080/auth --realm master --user admin --password "$KEYCLOAK_ADMIN_PASSWORD" >/dev/null

CLIENT_UUID="$($KC get clients -r cloud -q clientId=cloud-portal-web --fields id --format csv --noquotes 2>/dev/null | head -1 || true)"
if [[ -n "$CLIENT_UUID" ]]; then
  $KC update "clients/${CLIENT_UUID}" -r cloud \
    -s 'publicClient=true' \
    -s 'standardFlowEnabled=true' \
    -s 'redirectUris=["https://'"${PORTAL_IP}"'/*"]' \
    -s 'webOrigins=["https://'"${PORTAL_IP}"'"]' >/dev/null
fi

USER_ID="$($KC get users -r cloud -q username=demo-admin --fields id --format csv --noquotes 2>/dev/null | head -1 || true)"
if [[ -z "$USER_ID" ]]; then
  $KC create users -r cloud -s username=demo-admin -s enabled=true -s emailVerified=true >/dev/null
fi
$KC set-password -r cloud --username demo-admin --new-password 'CloudPortal-Lab-2026!' --temporary=false >/dev/null
$KC add-roles -r cloud --uusername demo-admin --rolename platform-admin >/dev/null 2>&1 || true

log "Final checks"
curl -ksS "https://${PORTAL_IP}/api/v1/health" | jq .
docker compose -f "$COMPOSE_BASE" -f "$COMPOSE_LAB" ps

cat <<EOF

======================================================================
LAB CLOUD PORTAL IS READY
======================================================================
Portal URL:           https://${PORTAL_IP}/vms
Keycloak Admin URL:  https://${PORTAL_IP}/auth/admin/
Portal username:     demo-admin
Portal password:     CloudPortal-Lab-2026!
Keycloak admin user: admin
Keycloak admin pass: ${KEYCLOAK_ADMIN_PASSWORD}

Browser note:
  The certificate is self-signed. Click Advanced -> Proceed once.

Useful commands:
  cd ${PROJECT_DIR}
  docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_LAB} ps
  docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_LAB} logs -f backend
  docker compose -f ${COMPOSE_BASE} -f ${COMPOSE_LAB} logs -f frontend

The Proxmox token is stored in ${PROJECT_DIR}/.env (mode 600).
Do not share that file or screenshots containing the token.
======================================================================
EOF
