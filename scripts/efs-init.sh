#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# efs-init.sh — Pre-descarga los modelos de HuggingFace al volumen EFS.
#
# Lanza un task Fargate de vida corta que descarga Whisper y LED a /mnt/efs
# y luego termina. Las próximas ejecuciones del servicio usarán esa cache
# sin necesidad de descargar los modelos (~2 GB) en cada cold start.
#
# Uso: make efs-init  (solo la primera vez, o al cambiar de modelo)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-blablatotext}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
APP_PORT="${APP_PORT:-8000}"

TASK_FAMILY="blablatotext-task"
LOG_GROUP="/ecs/${ECR_REPO}"

echo "=== EFS Init: descargando modelos a EFS ==="
echo "    Cluster : ${ECS_CLUSTER}"
echo "    Región  : ${AWS_REGION}"
echo ""
echo "    Esto puede tardar 5-10 minutos según la velocidad de descarga."
echo ""

# Obtener VPC/subnets/SG para la network config del task
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Vpcs[0].VpcId' \
    --output text)

SUBNET_ID=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Subnets[0].SubnetId' \
    --output text)

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=blablatotext-sg" "Name=vpc-id,Values=${VPC_ID}" \
    --region "${AWS_REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text)

# Obtener la task definition más reciente
TASK_DEF_ARN=$(aws ecs describe-task-definition \
    --task-definition "${TASK_FAMILY}" \
    --region "${AWS_REGION}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo "→ Lanzando task de inicialización..."

# Override del CMD: descarga los modelos y sale
OVERRIDES=$(cat <<EOF
{
  "containerOverrides": [{
    "name": "${ECR_REPO}",
    "command": [
      "python", "-c",
      "import os; os.environ['HF_HOME']='/mnt/efs'; from transformers import pipeline; from blablatotext.config import settings; print('Descargando modelo ASR...'); pipeline('automatic-speech-recognition', model=settings.asr_model); print('Descargando modelo de resumen...'); pipeline('summarization', model=settings.summarizer_model); print('Modelos descargados correctamente.')"
    ]
  }]
}
EOF
)

TASK_ARN=$(aws ecs run-task \
    --cluster "${ECS_CLUSTER}" \
    --task-definition "${TASK_DEF_ARN}" \
    --launch-type FARGATE \
    --platform-version LATEST \
    --network-configuration "awsvpcConfiguration={
        subnets=[${SUBNET_ID}],
        securityGroups=[${SG_ID}],
        assignPublicIp=ENABLED
    }" \
    --overrides "${OVERRIDES}" \
    --region "${AWS_REGION}" \
    --query 'tasks[0].taskArn' \
    --output text)

echo "    Task ARN: ${TASK_ARN}"
echo ""
echo "→ Esperando que el task termine (puede tardar varios minutos)..."

aws ecs wait tasks-stopped \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --region "${AWS_REGION}"

# Verificar exit code
EXIT_CODE=$(aws ecs describe-tasks \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --region "${AWS_REGION}" \
    --query 'tasks[0].containers[0].exitCode' \
    --output text)

if [[ "${EXIT_CODE}" == "0" ]]; then
    echo ""
    echo "✓ Modelos descargados correctamente en EFS."
    echo "  Los próximos arranques del servicio no necesitarán descargarlos."
    echo ""
    echo "  Para encender el servicio:"
    echo "  make scale-up"
else
    echo ""
    echo "ERROR: El task terminó con exit code ${EXIT_CODE}."
    echo "  Ver logs con: make logs"
    exit 1
fi
