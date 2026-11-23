# Yarrow-Mullein Bank Application idempotent deployment script
# Run with: ./script.sh      Tear down with: ./script.sh down
# Works with git bash on windows, or any Linux terminal with docker and docker-compose installed.

# Stop on first error
set -e

# Configuration Variables
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"   # folder containing this script
COMPOSE_FILE="docker-compose.yml"
URL="http://localhost"
PORTS="80 3000 5000"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cd "$DEPLOY_DIR"

# Optional teardown
if [ "$1" = "down" ]; then
  docker compose down -v
  log "Everything is down."
  exit 0
fi

# Pre-deployment checks
log "Checking prerequisites..."
command -v docker >/dev/null || { log "Docker is not installed"; exit 1; }
docker compose version >/dev/null || { log "Docker Compose is not installed"; exit 1; }

# Ports must be free, unless our own stack is already using them (re-run)
# Idempotent deployment: if the containers are already running, we don't need to check ports
port_in_use() { (echo > /dev/tcp/127.0.0.1/"$1") 2>/dev/null; }
 
if [ -z "$(docker compose ps -q 2>/dev/null)" ]; then
  for p in $PORTS; do
    if port_in_use "$p"; then
      log "Port $p is already in use"; exit 1
    fi
  done
fi

log "Prerequisites OK"

# Validate docker compose file
[ -f "$COMPOSE_FILE" ] || { log "$COMPOSE_FILE not found in $DEPLOY_DIR"; exit 1; }
log "Found $COMPOSE_FILE in $DEPLOY_DIR"

# Build and Deploy
log "Building and starting containers..."
docker compose up -d --build

# Health Checks
log "Running health checks..."
for u in "$URL" http://localhost:3000 http://localhost:5000; do
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$u" || true)
    [ "$code" != "000" ] && break
    sleep 2
  done
  log "$u -> HTTP $code"
done

# # List Images and Containers
log "Images:"
docker images
log "Containers:"
docker ps

NGINX_ID=$(docker ps -q --filter "ancestor=nginx:alpine" | head -n 1)
log "NGINX container ID: $NGINX_ID"

# Page Render Validations
log "Page at $URL:"
curl -s "$URL" | grep -i "Yarrow-Mullein" && log "Page renders with branding" || log "Branding not found on page"

# Jq intsalled
if ! command -v jq >/dev/null; then
  log "jq not found - installing..."
  if command -v apt-get >/dev/null; then
    sudo apt-get update -y
    sudo apt-get install -y jq
  else
    # Git Bash on Windows: download jq.exe into ~/bin
    mkdir -p "$HOME/bin"
    curl -L -o "$HOME/bin/jq.exe" https://github.com/jqlang/jq/releases/latest/download/jq-windows-amd64.exe
    export PATH="$HOME/bin:$PATH"
  fi
fi
log "jq version: $(jq --version)"

# Inspect and save to logs
docker inspect nginx:alpine > nginx-logs
log "Saved inspect output to nginx-logs"

# Extract Keys
log "Extracted values:"
jq -r '.[0] |
  "RepoTags:     \(.RepoTags | tojson)",
  "Created:      \(.Created)",
  "Os:           \(.Os)",
  "Config:       \(.Config | tojson)",
  "ExposedPorts: \(.Config.ExposedPorts | tojson)"' nginx-logs

log "Deployment finished successfully."