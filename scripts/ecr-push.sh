#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ecr-push.sh — Build, tag y push de la imagen Docker a Amazon ECR.
#
# Uso directo:  AWS_REGION=us-east-1 ECR_REPO=blablatotext bash scripts/ecr-push.sh
# Uso via Make: make push
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Variables (sobreescribibles desde el entorno) ───────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-blablatotext}"

# ─── Derivadas ───────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO}:latest"

echo "=== ECR Push: ${ECR_REPO} ==="
echo "    Cuenta : ${AWS_ACCOUNT_ID}"
echo "    Región : ${AWS_REGION}"
echo "    Imagen : ${IMAGE_URI}"
echo ""

# ─── 1. Crear repositorio ECR si no existe ───────────────────────────────────
if aws ecr describe-repositories \
    --repository-names "${ECR_REPO}" \
    --region "${AWS_REGION}" \
    --output text &>/dev/null; then
    echo "→ [1/5] Repositorio ECR ya existe — OK"
else
    echo "→ [1/5] Creando repositorio ECR: ${ECR_REPO}..."
    aws ecr create-repository \
        --repository-name "${ECR_REPO}" \
        --region "${AWS_REGION}" \
        --image-scanning-configuration scanOnPush=true \
        --query 'repository.repositoryUri' \
        --output text
fi

# ─── 2. Login a ECR ──────────────────────────────────────────────────────────
echo "→ [2/5] Autenticando con ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ─── 3. Build ────────────────────────────────────────────────────────────────
echo "→ [3/5] Building imagen Docker (--no-cache para garantizar imagen limpia)..."
docker build \
    --platform linux/amd64 \
    --no-cache \
    --tag "${ECR_REPO}:latest" \
    .

# ─── 4. Tag ──────────────────────────────────────────────────────────────────
echo "→ [4/5] Tagging imagen..."
docker tag "${ECR_REPO}:latest" "${IMAGE_URI}"

# ─── 5. Push ─────────────────────────────────────────────────────────────────
echo "→ [5/5] Push a ECR..."
docker push "${IMAGE_URI}"

echo ""
echo "✓ Imagen publicada: ${IMAGE_URI}"
