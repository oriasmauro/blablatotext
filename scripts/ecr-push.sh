#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ecr-push.sh — Build, tag y push de la imagen Docker a Amazon ECR.
#
# Genera un tag versionado (vYYYYMMDD-HHMM) además de :latest para evitar
# que Fargate reutilice capas cacheadas de imágenes anteriores.
# Siempre build con --no-cache para garantizar una imagen limpia.
# Actualiza la Task Definition de ECS para apuntar al nuevo tag versionado.
#
# Uso directo:  AWS_REGION=us-east-1 ECR_REPO=blablatotext bash scripts/ecr-push.sh
# Uso via Make: make push
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-blablatotext}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
VERSION_TAG="v$(date +%Y%m%d-%H%M)"
IMAGE_VERSIONED="${ECR_REGISTRY}/${ECR_REPO}:${VERSION_TAG}"
IMAGE_LATEST="${ECR_REGISTRY}/${ECR_REPO}:latest"
TASK_FAMILY="${ECR_REPO}-task"

echo "=== ECR Push: ${ECR_REPO} ==="
echo "    Cuenta  : ${AWS_ACCOUNT_ID}"
echo "    Región  : ${AWS_REGION}"
echo "    Tag     : ${VERSION_TAG}"
echo ""

# ─── 1. Crear repositorio ECR si no existe ───────────────────────────────────
if aws ecr describe-repositories \
    --repository-names "${ECR_REPO}" \
    --region "${AWS_REGION}" \
    --output text &>/dev/null; then
    echo "→ [1/6] Repositorio ECR ya existe — OK"
else
    echo "→ [1/6] Creando repositorio ECR: ${ECR_REPO}..."
    aws ecr create-repository \
        --repository-name "${ECR_REPO}" \
        --region "${AWS_REGION}" \
        --image-scanning-configuration scanOnPush=true \
        --query 'repository.repositoryUri' \
        --output text
fi

# ─── 2. Login a ECR ──────────────────────────────────────────────────────────
echo "→ [2/6] Autenticando con ECR..."
aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ─── 3. Build (--no-cache para evitar capas corruptas cacheadas) ─────────────
echo "→ [3/6] Building imagen Docker (--no-cache, --platform linux/amd64)..."
docker build \
    --platform linux/amd64 \
    --no-cache \
    --tag "${ECR_REPO}:${VERSION_TAG}" \
    .

# ─── 4. Verificar que la imagen arranca correctamente ────────────────────────
echo "→ [4/6] Verificando imports críticos..."
docker run --rm --platform linux/amd64 "${ECR_REPO}:${VERSION_TAG}" \
    python -c "
from blablatotext.summarizer import Summarizer
from blablatotext.transcriber import Transcriber
import torch
print(f'  torch {torch.__version__} — OK')
print(f'  imports OK')
"
echo "  Imagen verificada."

# ─── 5. Tag + Push ───────────────────────────────────────────────────────────
echo "→ [5/6] Tagging y push a ECR..."
docker tag "${ECR_REPO}:${VERSION_TAG}" "${IMAGE_VERSIONED}"
docker tag "${ECR_REPO}:${VERSION_TAG}" "${IMAGE_LATEST}"
docker push "${IMAGE_VERSIONED}"
docker push "${IMAGE_LATEST}"
echo "  Pusheado: ${IMAGE_VERSIONED}"

# ─── 6. Actualizar Task Definition para apuntar al tag versionado ────────────
echo "→ [6/6] Actualizando Task Definition (${TASK_FAMILY}) con nuevo tag..."
TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "${TASK_FAMILY}" \
    --region "${AWS_REGION}" \
    --query 'taskDefinition' \
    --output json)

NEW_TASK_DEF=$(echo "$TASK_DEF" | python3 -c "
import json, sys
td = json.load(sys.stdin)
td['containerDefinitions'][0]['image'] = '${IMAGE_VERSIONED}'
for key in ['taskDefinitionArn','revision','status','requiresAttributes',
            'compatibilities','registeredAt','registeredBy']:
    td.pop(key, None)
print(json.dumps(td))
")

NEW_ARN=$(aws ecs register-task-definition \
    --region "${AWS_REGION}" \
    --cli-input-json "$NEW_TASK_DEF" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

# Guardar el tag para referencia
echo "${VERSION_TAG}" > .last-deploy-tag

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Push completado                                     ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  Tag       : %-39s║\n" "${VERSION_TAG}"
printf "║  Task Def  : %-39s║\n" "$(echo "$NEW_ARN" | grep -o 'task-definition/.*')"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Próximos pasos:                                     ║"
echo "║    make scale-up                                     ║"
echo "║    make apigw-update-ip                              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
