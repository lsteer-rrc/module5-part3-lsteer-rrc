#!/usr/bin/env bash
# Yarrow-Mullein Bank Application idempotent Minikube deployment script
# Run with: ./apply_minikube_dockerenv.sh      Tear down with: ./apply_minikube_dockerenv.sh down
# Run minikube delete after tear down script to ensure minikube cluster is deleted.
# Works with git bash on windows, or any Linux terminal with docker, minikube and kubectl installed.

# Stop on first error
set -e

# 1. Configuration Variables
DEPLOY_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="docker-compose.yml"
K8S_DIR="k8s"
STUDENT_DIR="${STUDENT_DIR:-./studentportfolio}"
COMPOSE_SERVICES="backend transactions"
ALL_IMAGES="backend transactions studentportfolio"
OVERRIDE_FILE=".compose.minikube.override.yml"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

cd "$DEPLOY_DIR"

# Always remove the temporary compose override file when the script exits
trap 'rm -f "$OVERRIDE_FILE"' EXIT

# 2. Teardown
if [ "$1" = "down" ]; then
  kubectl delete -f "$K8S_DIR" --ignore-not-found
  kubectl delete pvc mongo-data-mongo-0 --ignore-not-found
  log "Everything is down (cluster left running; use 'minikube delete' to remove it)."
  exit 0
fi

# 3. Pre-deployment checks
log "Checking prerequisites..."
for tool in docker minikube kubectl; do
  command -v "$tool" >/dev/null || { log "$tool is not installed or not on PATH"; exit 1; }
done
docker info >/dev/null 2>&1 || { log "Docker is not running - start Docker Desktop"; exit 1; }
log "Prerequisites OK"

# 4. Validate deployment files
[ -f "$COMPOSE_FILE" ] || { log "$COMPOSE_FILE not found in $DEPLOY_DIR"; exit 1; }
[ -d "$K8S_DIR" ] || { log "$K8S_DIR folder not found in $DEPLOY_DIR"; exit 1; }
log "Found $COMPOSE_FILE and $K8S_DIR in $DEPLOY_DIR"

# 5. Start Minikube
# Idempotent deployment: if Minikube is already running, we don't start it again
if minikube status >/dev/null 2>&1; then
  log "Minikube already running"
else
  log "Starting Minikube (docker driver)..."
  minikube start --driver=docker --container-runtime=docker
fi

# On Windows, a containerd node fails with "SSH_AGENT_START" - so check first.
RUNTIME="$(kubectl get nodes -o wide | grep -o '[a-z]*://[0-9A-Za-z.+-]*' | head -n 1 || true)"
case "$RUNTIME" in
  docker://*) log "Container runtime: $RUNTIME" ;;
  *) log "Minikube is using '$RUNTIME' but docker-env needs the docker runtime."
     log "Run 'minikube delete' once, then re-run this script."
     exit 1 ;;
esac

minikube addons enable metrics-server >/dev/null

# 6. Point Docker at Minikube's Docker daemon
log "Switching to Minikube's Docker daemon..."
eval "$(minikube docker-env --shell bash)"
[ -n "$DOCKER_HOST" ] || { log "docker-env did not take effect"; exit 1; }
log "Docker daemon now: $DOCKER_HOST"

# Remember image IDs before building, so pods only restart if an image changed
image_ids() { for i in $ALL_IMAGES; do echo "$i=$(docker image inspect -f '{{.Id}}' "$i:latest" 2>/dev/null || true)"; done; }
BEFORE="$(image_ids)"

# 7. Build images inside Minikube
# The override file tags the compose images as backend:latest / transactions:latest,
# which are the names the Kubernetes manifests expect.
{
  echo "services:"
  for s in $COMPOSE_SERVICES; do
    echo "  $s:"
    echo "    image: $s:latest"
  done
} > "$OVERRIDE_FILE"

log "Building $COMPOSE_SERVICES with docker compose..."
docker compose -f "$COMPOSE_FILE" -f "$OVERRIDE_FILE" build $COMPOSE_SERVICES

[ -f "$STUDENT_DIR/Dockerfile" ] || { log "No Dockerfile in $STUDENT_DIR - set STUDENT_DIR=path and re-run"; exit 1; }
log "Building studentportfolio from $STUDENT_DIR..."
docker build -t studentportfolio:latest "$STUDENT_DIR"

# 8. Verify images inside the node's Docker
log "Verifying images inside the Minikube node..."
NODE_IMAGES="$(minikube ssh -- docker images --format '{{.Repository}}:{{.Tag}}' | tr -d '\r')"
for i in $ALL_IMAGES; do
  if echo "$NODE_IMAGES" | grep -qx "$i:latest"; then
    log "FOUND   $i:latest"
  else
    log "MISSING $i:latest inside the node"; exit 1
  fi
done

# 9. Apply Kubernetes manifests
log "Applying manifests from $K8S_DIR..."
kubectl apply -f "$K8S_DIR"

# 10. Restart deployments whose image was rebuilt
AFTER="$(image_ids)"
for i in $ALL_IMAGES; do
  b="$(echo "$BEFORE" | grep "^$i=" | cut -d= -f2)"
  a="$(echo "$AFTER"  | grep "^$i=" | cut -d= -f2)"
  if [ -n "$b" ] && [ "$a" != "$b" ]; then
    log "Image $i changed - restarting deployment/$i"
    kubectl rollout restart "deployment/$i"
  fi
done

# 11. Wait for workloads to be ready
log "Waiting for workloads..."
kubectl rollout status statefulset/mongo --timeout=180s
for d in backend transactions studentportfolio nginx; do
  kubectl rollout status "deployment/$d" --timeout=180s
done

# 12. Show cluster state
log "Cluster state:"
kubectl get pods,svc,hpa,pvc

log "Deployment finished successfully."
log "Open the app with: minikube service nginx --url   (keep that terminal open)"