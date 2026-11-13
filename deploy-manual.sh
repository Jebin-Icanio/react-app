#!/usr/bin/env bash
set -Eeuo pipefail

AWS_REGION="${AWS_REGION:-ap-south-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-sample-dev-eks}"
ECR_REPOSITORY_NAME="${ECR_REPOSITORY_NAME:-sample/dev/react-app}"
DEPLOYMENT_MANIFEST="${DEPLOYMENT_MANIFEST:-kubernetes/deployment.yaml.tmpl}"
SERVICE_MANIFEST="${SERVICE_MANIFEST:-kubernetes/service.yaml}"

command -v aws >/dev/null 2>&1 || { echo "aws CLI is required" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "Docker is required" >&2; exit 1; }
command -v envsubst >/dev/null 2>&1 || { echo "envsubst is required (gettext package)" >&2; exit 1; }
test -f Dockerfile || { echo "Run this script from the React repository root (Dockerfile not found)" >&2; exit 1; }
test -f "$DEPLOYMENT_MANIFEST" || { echo "Kubernetes deployment manifest not found: $DEPLOYMENT_MANIFEST" >&2; exit 1; }
test -f "$SERVICE_MANIFEST" || { echo "Kubernetes service manifest not found: $SERVICE_MANIFEST" >&2; exit 1; }

DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
  if sudo -n docker info >/dev/null 2>&1; then
    DOCKER=(sudo docker)
  else
    echo "Cannot access the Docker daemon. Reconnect to refresh docker group membership or check that Docker is running." >&2
    exit 1
  fi
fi

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
ECR_REPOSITORY="${ECR_REGISTRY}/${ECR_REPOSITORY_NAME}"
IMAGE_TAG="$(git rev-parse --short HEAD 2>/dev/null || date -u +%Y%m%d%H%M%S)"
export REACT_IMAGE_URI="${ECR_REPOSITORY}:${IMAGE_TAG}"

CLUSTER_STATUS="$(aws eks describe-cluster \
  --name "$EKS_CLUSTER_NAME" \
  --region "$AWS_REGION" \
  --query 'cluster.status' \
  --output text)"
if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
  echo "EKS cluster $EKS_CLUSTER_NAME is $CLUSTER_STATUS; wait until it is ACTIVE" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  KUBERNETES_VERSION="$(aws eks describe-cluster \
    --name "$EKS_CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query 'cluster.version' \
    --output text)"
  KUBECTL_VERSION="v${KUBERNETES_VERSION}.0"
  curl --fail --silent --show-error --location \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    --output /tmp/kubectl
  curl --fail --silent --show-error --location \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256" \
    --output /tmp/kubectl.sha256
  echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

aws ecr get-login-password --region "$AWS_REGION" |
  "${DOCKER[@]}" login --username AWS --password-stdin "$ECR_REGISTRY"

"${DOCKER[@]}" build --pull --platform linux/amd64 --tag "$REACT_IMAGE_URI" .
"${DOCKER[@]}" push "$REACT_IMAGE_URI"

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
envsubst '${REACT_IMAGE_URI}' < "$DEPLOYMENT_MANIFEST" | kubectl apply -f -
kubectl apply -f "$SERVICE_MANIFEST"
kubectl rollout status deployment/react-app --timeout=180s
kubectl get service react-app
