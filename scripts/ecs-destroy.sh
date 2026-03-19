#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ecs-destroy.sh — Elimina toda la infraestructura ECS + EFS de blablatotext.
#
# Elimina (en orden seguro):
#   1. Application Auto Scaling (scheduled actions + scalable target)
#   2. Escala el servicio a 0 y lo elimina
#   3. Deregistra todas las revisiones de la task definition
#   4. Elimina el cluster ECS
#   5. Elimina mount targets EFS (hay que esperarlos antes de borrar el FS)
#   6. Elimina el EFS filesystem
#   7. Elimina el security group
#   8. Elimina el repositorio ECR y sus imágenes
#   9. Detacha políticas y elimina el IAM role
#  10. Elimina el CloudWatch Log Group
#
# Uso: make destroy   (pide confirmación antes de proceder)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-blablatotext}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"

TASK_FAMILY="blablatotext-task"
ROLE_NAME="blablatotext-task-exec-role"
LOG_GROUP="/ecs/${ECR_REPO}"
SG_NAME="blablatotext-sg"
EFS_NAME="blablatotext-efs"

# ─── Confirmación explícita ──────────────────────────────────────────────────
echo ""
echo "⚠️  DESTROY: Esto eliminará TODOS los recursos de blablatotext en AWS:"
echo "   - Auto Scaling schedules"
echo "   - ECS Service: ${ECS_SERVICE}"
echo "   - ECS Cluster: ${ECS_CLUSTER}"
echo "   - EFS:         ${EFS_NAME}  (incluye los modelos cacheados)"
echo "   - ECR Repo:    ${ECR_REPO}  (incluye todas las imágenes)"
echo "   - IAM Role:    ${ROLE_NAME}"
echo "   - Log Group:   ${LOG_GROUP}"
echo "   - Security Group: ${SG_NAME}"
echo ""
read -r -p "¿Continuar? (escribe 'destroy' para confirmar): " CONFIRM
if [[ "${CONFIRM}" != "destroy" ]]; then
    echo "Cancelado."
    exit 0
fi
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Application Auto Scaling
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [1/10] Eliminando Application Auto Scaling..."

RESOURCE_ID="service/${ECS_CLUSTER}/${ECS_SERVICE}"

for ACTION in "scale-up-business-hours" "scale-down-business-hours"; do
    aws application-autoscaling delete-scheduled-action \
        --service-namespace ecs \
        --resource-id "${RESOURCE_ID}" \
        --scalable-dimension ecs:service:DesiredCount \
        --scheduled-action-name "${ACTION}" \
        --region "${AWS_REGION}" 2>/dev/null && echo "       Scheduled action '${ACTION}' eliminada" || echo "       '${ACTION}' no existe — OK"
done

aws application-autoscaling deregister-scalable-target \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --region "${AWS_REGION}" 2>/dev/null && echo "       Scalable target deregistrado" || echo "       Scalable target no existe — OK"

# ─────────────────────────────────────────────────────────────────────────────
# 2. Servicio ECS
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [2/10] Eliminando servicio ECS: ${ECS_SERVICE}..."

SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "${ECS_SERVICE}" \
    --region "${AWS_REGION}" \
    --query "services[0].status" \
    --output text 2>/dev/null || echo "")

if [[ "${SERVICE_STATUS}" == "ACTIVE" ]]; then
    # Primero escalar a 0 para no generar cargos mientras se elimina
    aws ecs update-service \
        --cluster "${ECS_CLUSTER}" \
        --service "${ECS_SERVICE}" \
        --desired-count 0 \
        --region "${AWS_REGION}" \
        --output text > /dev/null

    echo "       Esperando que los tasks se detengan..."
    aws ecs wait services-stable \
        --cluster "${ECS_CLUSTER}" \
        --services "${ECS_SERVICE}" \
        --region "${AWS_REGION}"

    aws ecs delete-service \
        --cluster "${ECS_CLUSTER}" \
        --service "${ECS_SERVICE}" \
        --force \
        --region "${AWS_REGION}" \
        --output text > /dev/null

    echo "       Eliminado"
else
    echo "       No existe o ya está eliminado — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Task Definitions
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [3/10] Deregistrando task definitions: ${TASK_FAMILY}..."

TASK_ARNS=$(aws ecs list-task-definitions \
    --family-prefix "${TASK_FAMILY}" \
    --region "${AWS_REGION}" \
    --query 'taskDefinitionArns[*]' \
    --output text 2>/dev/null || echo "")

if [[ -n "${TASK_ARNS}" && "${TASK_ARNS}" != "None" ]]; then
    COUNT=0
    for ARN in ${TASK_ARNS}; do
        aws ecs deregister-task-definition \
            --task-definition "${ARN}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null
        COUNT=$((COUNT + 1))
    done
    echo "       ${COUNT} revisión(es) deregistrada(s)"
else
    echo "       No existen — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. ECS Cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [4/10] Eliminando cluster: ${ECS_CLUSTER}..."

CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "${ECS_CLUSTER}" \
    --region "${AWS_REGION}" \
    --query "clusters[0].status" \
    --output text 2>/dev/null || echo "")

if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
    aws ecs delete-cluster \
        --cluster "${ECS_CLUSTER}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null
    echo "       Eliminado"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Security Group
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# 5. EFS Mount Targets + Filesystem
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [5/10] Eliminando EFS: ${EFS_NAME}..."

EFS_ID=$(aws efs describe-file-systems \
    --region "${AWS_REGION}" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId" \
    --output text 2>/dev/null || echo "")

if [[ -n "${EFS_ID}" && "${EFS_ID}" != "None" ]]; then
    # Primero eliminar mount targets (EFS no se puede borrar con mount targets activos)
    MT_IDS=$(aws efs describe-mount-targets \
        --file-system-id "${EFS_ID}" \
        --region "${AWS_REGION}" \
        --query 'MountTargets[*].MountTargetId' \
        --output text 2>/dev/null || echo "")

    for MT_ID in ${MT_IDS}; do
        aws efs delete-mount-target \
            --mount-target-id "${MT_ID}" \
            --region "${AWS_REGION}"
        echo "       Mount target ${MT_ID} eliminado"
    done

    if [[ -n "${MT_IDS}" && "${MT_IDS}" != "None" ]]; then
        echo "       Esperando que los mount targets terminen..."
        sleep 15
    fi

    aws efs delete-file-system \
        --file-system-id "${EFS_ID}" \
        --region "${AWS_REGION}"
    echo "       EFS ${EFS_ID} eliminado"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. Security Group
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [6/10] Eliminando security group: ${SG_NAME}..."

VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Vpcs[0].VpcId' \
    --output text 2>/dev/null || echo "")

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --region "${AWS_REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

if [[ -n "${SG_ID}" && "${SG_ID}" != "None" ]]; then
    aws ec2 delete-security-group \
        --group-id "${SG_ID}" \
        --region "${AWS_REGION}"
    echo "       Eliminado (${SG_ID})"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. ECR Repositorio
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [7/10] Eliminando repositorio ECR: ${ECR_REPO} (incluye todas las imágenes)..."

ECR_EXISTS=$(aws ecr describe-repositories \
    --repository-names "${ECR_REPO}" \
    --region "${AWS_REGION}" \
    --query 'repositories[0].repositoryName' \
    --output text 2>/dev/null || echo "")

if [[ "${ECR_EXISTS}" == "${ECR_REPO}" ]]; then
    aws ecr delete-repository \
        --repository-name "${ECR_REPO}" \
        --force \
        --region "${AWS_REGION}" \
        --output text > /dev/null
    echo "       Eliminado"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. IAM Role
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [8/10] Eliminando IAM role: ${ROLE_NAME}..."

ROLE_EXISTS=$(aws iam get-role \
    --role-name "${ROLE_NAME}" \
    --query 'Role.RoleName' \
    --output text 2>/dev/null || echo "")

if [[ "${ROLE_EXISTS}" == "${ROLE_NAME}" ]]; then
    # Hay que desadjuntar políticas antes de eliminar el rol
    ATTACHED=$(aws iam list-attached-role-policies \
        --role-name "${ROLE_NAME}" \
        --query 'AttachedPolicies[*].PolicyArn' \
        --output text)

    for POLICY_ARN in ${ATTACHED}; do
        aws iam detach-role-policy \
            --role-name "${ROLE_NAME}" \
            --policy-arn "${POLICY_ARN}"
    done

    # Eliminar política inline de EFS si existe
    aws iam delete-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-name "blablatotext-efs-access" 2>/dev/null || true

    aws iam delete-role --role-name "${ROLE_NAME}"
    echo "       Eliminado"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 7. CloudWatch Log Group
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [9/10] Eliminando log group: ${LOG_GROUP}..."

LOG_EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "${LOG_GROUP}" \
    --region "${AWS_REGION}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text 2>/dev/null || echo "")

if [[ -n "${LOG_EXISTS}" && "${LOG_EXISTS}" != "None" ]]; then
    aws logs delete-log-group \
        --log-group-name "${LOG_GROUP}" \
        --region "${AWS_REGION}"
    echo "       Eliminado"
else
    echo "       No existe — OK"
fi

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Todos los recursos de blablatotext han sido eliminados."
echo "  Verificá en la consola AWS que no queden recursos activos."
