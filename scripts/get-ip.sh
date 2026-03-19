#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# get-ip.sh — Obtiene la IP pública del task ECS en ejecución.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"
APP_PORT="${APP_PORT:-8000}"

# 1. Obtener el ARN del task en ejecución
TASK_ARN=$(aws ecs list-tasks \
    --cluster "${ECS_CLUSTER}" \
    --service-name "${ECS_SERVICE}" \
    --desired-status RUNNING \
    --region "${AWS_REGION}" \
    --query 'taskArns[0]' \
    --output text)

if [[ -z "${TASK_ARN}" || "${TASK_ARN}" == "None" ]]; then
    echo "No hay tasks RUNNING en ${ECS_CLUSTER}/${ECS_SERVICE}."
    echo "Revisá el estado con:"
    echo "  aws ecs describe-services --cluster ${ECS_CLUSTER} --services ${ECS_SERVICE} --region ${AWS_REGION}"
    exit 1
fi

# 2. Obtener el ENI (Elastic Network Interface) del task
ENI_ID=$(aws ecs describe-tasks \
    --cluster "${ECS_CLUSTER}" \
    --tasks "${TASK_ARN}" \
    --region "${AWS_REGION}" \
    --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
    --output text)

# 3. Obtener la IP pública del ENI
PUBLIC_IP=$(aws ec2 describe-network-interfaces \
    --network-interface-ids "${ENI_ID}" \
    --region "${AWS_REGION}" \
    --query 'NetworkInterfaces[0].Association.PublicIp' \
    --output text)

if [[ -z "${PUBLIC_IP}" || "${PUBLIC_IP}" == "None" ]]; then
    echo "El task no tiene IP pública asignada todavía. Esperá unos segundos e intentá de nuevo."
    exit 1
fi

echo "${PUBLIC_IP}"
echo ""
echo "API disponible en: http://${PUBLIC_IP}:${APP_PORT}"
echo "Healthcheck:       http://${PUBLIC_IP}:${APP_PORT}/health"
echo "Docs interactivos: http://${PUBLIC_IP}:${APP_PORT}/docs"
