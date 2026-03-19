#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ecs-setup.sh — Crea toda la infraestructura ECS Fargate + EFS + Auto Scaling.
#
# Crea (en orden):
#   1. IAM Task Execution Role (con permisos EFS)
#   2. CloudWatch Log Group
#   3. ECS Cluster
#   4. EFS Filesystem + Mount Targets
#   5. Security Group (TCP 8000 + NFS 2049 self)
#   6. Task Definition (2 vCPU / 4 GiB, monta EFS en /mnt/efs)
#   7. ECS Service (desired=0 inicial)
#   8. Application Auto Scaling (scale-to-0 con schedule horario laboral)
#
# Uso directo:  bash scripts/ecs-setup.sh
# Uso via Make: make setup
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Variables ───────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPO="${ECR_REPO:-blablatotext}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"
APP_PORT="${APP_PORT:-8000}"

# Horario laboral en UTC — ajustar según zona horaria del equipo
# Ejemplos: ART (UTC-3): 8am=11:00 UTC, 8pm=23:00 UTC
#           EST (UTC-5): 8am=13:00 UTC, 8pm=01:00 UTC
SCALE_UP_UTC="${SCALE_UP_UTC:-11}"    # hora UTC para encender (8am ART)
SCALE_DOWN_UTC="${SCALE_DOWN_UTC:-23}" # hora UTC para apagar  (8pm ART)

TASK_FAMILY="blablatotext-task"
ROLE_NAME="blablatotext-task-exec-role"
LOG_GROUP="/ecs/${ECR_REPO}"
SG_NAME="blablatotext-sg"
EFS_NAME="blablatotext-efs"

# 2 vCPU / 4 GiB — mínimo para correr Whisper + LED simultáneamente
CPU="2048"
MEMORY="4096"

# ─── Derivadas ───────────────────────────────────────────────────────────────
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE_URI="${ECR_REGISTRY}/${ECR_REPO}:latest"

echo "=== ECS Fargate + EFS + Auto Scaling Setup ==="
echo "    Cuenta  : ${AWS_ACCOUNT_ID}"
echo "    Región  : ${AWS_REGION}"
echo "    Imagen  : ${IMAGE_URI}"
echo "    CPU/Mem : ${CPU} units / ${MEMORY} MiB"
echo "    Horario : encendido ${SCALE_UP_UTC}:00 UTC / apagado ${SCALE_DOWN_UTC}:00 UTC (L-V)"
echo ""

exists() { [[ -n "$1" && "$1" != "None" && "$1" != "null" ]]; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. IAM Task Execution Role
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [1/8] IAM Task Execution Role: ${ROLE_NAME}"

ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" \
    --query 'Role.Arn' --output text 2>/dev/null || echo "")

if exists "${ROLE_ARN}"; then
    echo "       Ya existe — OK (${ROLE_ARN})"
else
    TRUST_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ecs-tasks.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF
)
    ROLE_ARN=$(aws iam create-role \
        --role-name "${ROLE_NAME}" \
        --assume-role-policy-document "${TRUST_POLICY}" \
        --description "ECS task execution role para blablatotext" \
        --query 'Role.Arn' \
        --output text)

    aws iam attach-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

    # Política inline para EFS — permite montar el filesystem desde Fargate
    EFS_POLICY=$(cat <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "elasticfilesystem:ClientMount",
      "elasticfilesystem:ClientWrite",
      "elasticfilesystem:DescribeMountTargets"
    ],
    "Resource": "*"
  }]
}
EOF
)
    aws iam put-role-policy \
        --role-name "${ROLE_NAME}" \
        --policy-name "blablatotext-efs-access" \
        --policy-document "${EFS_POLICY}"

    echo "       Creado: ${ROLE_ARN}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. CloudWatch Log Group
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [2/8] CloudWatch Log Group: ${LOG_GROUP}"

LOG_EXISTS=$(aws logs describe-log-groups \
    --log-group-name-prefix "${LOG_GROUP}" \
    --region "${AWS_REGION}" \
    --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName" \
    --output text)

if exists "${LOG_EXISTS}"; then
    echo "       Ya existe — OK"
else
    aws logs create-log-group \
        --log-group-name "${LOG_GROUP}" \
        --region "${AWS_REGION}"

    aws logs put-retention-policy \
        --log-group-name "${LOG_GROUP}" \
        --retention-in-days 7 \
        --region "${AWS_REGION}"

    echo "       Creado (retención: 7 días)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. ECS Cluster
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [3/8] ECS Cluster: ${ECS_CLUSTER}"

CLUSTER_STATUS=$(aws ecs describe-clusters \
    --clusters "${ECS_CLUSTER}" \
    --region "${AWS_REGION}" \
    --query "clusters[0].status" \
    --output text 2>/dev/null || echo "")

if [[ "${CLUSTER_STATUS}" == "ACTIVE" ]]; then
    echo "       Ya existe — OK"
else
    aws ecs create-cluster \
        --cluster-name "${ECS_CLUSTER}" \
        --region "${AWS_REGION}" \
        --output text > /dev/null
    echo "       Creado"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. EFS Filesystem + Mount Targets
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [4/8] EFS Filesystem: ${EFS_NAME}"

# Obtener VPC default y sus subnets
VPC_ID=$(aws ec2 describe-vpcs \
    --filters "Name=isDefault,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Vpcs[0].VpcId' \
    --output text)

if ! exists "${VPC_ID}"; then
    echo "ERROR: No se encontró VPC default en ${AWS_REGION}."
    exit 1
fi

SUBNET_IDS_RAW=$(aws ec2 describe-subnets \
    --filters "Name=vpc-id,Values=${VPC_ID}" "Name=default-for-az,Values=true" \
    --region "${AWS_REGION}" \
    --query 'Subnets[*].SubnetId' \
    --output text)

# Buscar EFS existente por tag Name
EFS_ID=$(aws efs describe-file-systems \
    --region "${AWS_REGION}" \
    --query "FileSystems[?Tags[?Key=='Name' && Value=='${EFS_NAME}']].FileSystemId" \
    --output text 2>/dev/null || echo "")

if exists "${EFS_ID}"; then
    echo "       EFS ya existe — OK (${EFS_ID})"
else
    EFS_ID=$(aws efs create-file-system \
        --region "${AWS_REGION}" \
        --encrypted \
        --tags "Key=Name,Value=${EFS_NAME}" \
        --query 'FileSystemId' \
        --output text)

    echo "       EFS creado: ${EFS_ID} — esperando que esté disponible..."

    # Esperar a que el EFS esté en estado available
    while true; do
        STATUS=$(aws efs describe-file-systems \
            --file-system-id "${EFS_ID}" \
            --region "${AWS_REGION}" \
            --query 'FileSystems[0].LifeCycleState' \
            --output text)
        [[ "${STATUS}" == "available" ]] && break
        sleep 3
    done
    echo "       EFS disponible"
fi

# Crear mount targets (uno por subnet / AZ) si no existen
echo "       Verificando mount targets..."
for SUBNET_ID in ${SUBNET_IDS_RAW}; do
    MT_EXISTS=$(aws efs describe-mount-targets \
        --file-system-id "${EFS_ID}" \
        --region "${AWS_REGION}" \
        --query "MountTargets[?SubnetId=='${SUBNET_ID}'].MountTargetId" \
        --output text 2>/dev/null || echo "")

    if exists "${MT_EXISTS}"; then
        echo "       Mount target en ${SUBNET_ID} ya existe — OK"
    else
        aws efs create-mount-target \
            --file-system-id "${EFS_ID}" \
            --subnet-id "${SUBNET_ID}" \
            --region "${AWS_REGION}" \
            --output text > /dev/null
        echo "       Mount target creado en ${SUBNET_ID}"
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 5. Security Group
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [5/8] Security Group: ${SG_NAME}"

SG_ID=$(aws ec2 describe-security-groups \
    --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
    --region "${AWS_REGION}" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

if exists "${SG_ID}"; then
    echo "       Ya existe — OK (${SG_ID})"
else
    SG_ID=$(aws ec2 create-security-group \
        --group-name "${SG_NAME}" \
        --description "blablatotext API + EFS NFS" \
        --vpc-id "${VPC_ID}" \
        --region "${AWS_REGION}" \
        --query 'GroupId' \
        --output text)

    # TCP 8000 — API pública
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port "${APP_PORT}" \
        --cidr 0.0.0.0/0 \
        --region "${AWS_REGION}" > /dev/null

    # TCP 2049 self-referential — EFS NFS (ECS task → EFS mount target, mismo SG)
    aws ec2 authorize-security-group-ingress \
        --group-id "${SG_ID}" \
        --protocol tcp \
        --port 2049 \
        --source-group "${SG_ID}" \
        --region "${AWS_REGION}" > /dev/null

    echo "       Creado: ${SG_ID} (TCP 8000 público + TCP 2049 self)"
fi

# Asociar el SG a los mount targets de EFS (si no están ya asociados)
for SUBNET_ID in ${SUBNET_IDS_RAW}; do
    MT_ID=$(aws efs describe-mount-targets \
        --file-system-id "${EFS_ID}" \
        --region "${AWS_REGION}" \
        --query "MountTargets[?SubnetId=='${SUBNET_ID}'].MountTargetId" \
        --output text 2>/dev/null || echo "")

    if exists "${MT_ID}"; then
        CURRENT_SGS=$(aws efs describe-mount-target-security-groups \
            --mount-target-id "${MT_ID}" \
            --region "${AWS_REGION}" \
            --query 'SecurityGroups' \
            --output text 2>/dev/null || echo "")

        if [[ "${CURRENT_SGS}" != *"${SG_ID}"* ]]; then
            aws efs modify-mount-target-security-groups \
                --mount-target-id "${MT_ID}" \
                --security-groups "${SG_ID}" \
                --region "${AWS_REGION}"
            echo "       SG asociado al mount target ${MT_ID}"
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
# 6. Task Definition
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [6/8] Task Definition: ${TASK_FAMILY}"

SUBNET_IDS_CSV=$(echo "${SUBNET_IDS_RAW}" | tr '\t' ',')

TASK_DEF=$(cat <<EOF
{
  "family": "${TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "${CPU}",
  "memory": "${MEMORY}",
  "executionRoleArn": "${ROLE_ARN}",
  "taskRoleArn": "${ROLE_ARN}",
  "volumes": [
    {
      "name": "efs-models",
      "efsVolumeConfiguration": {
        "fileSystemId": "${EFS_ID}",
        "rootDirectory": "/",
        "transitEncryption": "ENABLED"
      }
    }
  ],
  "containerDefinitions": [
    {
      "name": "${ECR_REPO}",
      "image": "${IMAGE_URI}",
      "portMappings": [
        { "containerPort": ${APP_PORT}, "protocol": "tcp" }
      ],
      "mountPoints": [
        {
          "sourceVolume": "efs-models",
          "containerPath": "/mnt/efs",
          "readOnly": false
        }
      ],
      "essential": true,
      "environment": [
        { "name": "BLABLATOTEXT_DEVICE", "value": "cpu" },
        { "name": "HF_HOME",             "value": "/mnt/efs" }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "${LOG_GROUP}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "ecs"
        }
      },
      "healthCheck": {
        "command": ["CMD-SHELL", "curl -f http://localhost:${APP_PORT}/health || exit 1"],
        "interval": 30,
        "timeout": 10,
        "retries": 3,
        "startPeriod": 60
      }
    }
  ]
}
EOF
)

TASK_DEF_ARN=$(aws ecs register-task-definition \
    --cli-input-json "${TASK_DEF}" \
    --region "${AWS_REGION}" \
    --query 'taskDefinition.taskDefinitionArn' \
    --output text)

echo "       Registrada: ${TASK_DEF_ARN}"

# ─────────────────────────────────────────────────────────────────────────────
# 7. ECS Service (desired=0 — Auto Scaling controla el ciclo de vida)
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [7/8] ECS Service: ${ECS_SERVICE}"

SERVICE_STATUS=$(aws ecs describe-services \
    --cluster "${ECS_CLUSTER}" \
    --services "${ECS_SERVICE}" \
    --region "${AWS_REGION}" \
    --query "services[0].status" \
    --output text 2>/dev/null || echo "")

if [[ "${SERVICE_STATUS}" == "ACTIVE" ]]; then
    echo "       Ya existe — actualizando task definition..."
    aws ecs update-service \
        --cluster "${ECS_CLUSTER}" \
        --service "${ECS_SERVICE}" \
        --task-definition "${TASK_FAMILY}" \
        --region "${AWS_REGION}" \
        --force-new-deployment \
        --output text > /dev/null
else
    aws ecs create-service \
        --cluster "${ECS_CLUSTER}" \
        --service-name "${ECS_SERVICE}" \
        --task-definition "${TASK_FAMILY}" \
        --desired-count 0 \
        --launch-type FARGATE \
        --platform-version LATEST \
        --network-configuration "awsvpcConfiguration={
            subnets=[${SUBNET_IDS_CSV}],
            securityGroups=[${SG_ID}],
            assignPublicIp=ENABLED
        }" \
        --region "${AWS_REGION}" \
        --query 'service.serviceArn' \
        --output text > /dev/null

    echo "       Creado con desired=0 (Auto Scaling lo controla)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 8. Application Auto Scaling — scale-to-0 con schedule horario laboral
# ─────────────────────────────────────────────────────────────────────────────
echo "→ [8/8] Application Auto Scaling (schedule L-V)"

RESOURCE_ID="service/${ECS_CLUSTER}/${ECS_SERVICE}"

# Registrar el servicio ECS como scalable target
aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 0 \
    --max-capacity 2 \
    --region "${AWS_REGION}" > /dev/null

echo "       Scalable target registrado (min=0, max=2)"

# Schedule encendido: lunes a viernes a las ${SCALE_UP_UTC}:00 UTC → desired=1
aws application-autoscaling put-scheduled-action \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --scheduled-action-name "scale-up-business-hours" \
    --schedule "cron(0 ${SCALE_UP_UTC} ? * MON-FRI *)" \
    --scalable-target-action MinCapacity=1,MaxCapacity=2 \
    --region "${AWS_REGION}" > /dev/null

echo "       Schedule encendido: L-V ${SCALE_UP_UTC}:00 UTC → desired=1"

# Schedule apagado: lunes a viernes a las ${SCALE_DOWN_UTC}:00 UTC → desired=0
aws application-autoscaling put-scheduled-action \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --scheduled-action-name "scale-down-business-hours" \
    --schedule "cron(0 ${SCALE_DOWN_UTC} ? * MON-FRI *)" \
    --scalable-target-action MinCapacity=0,MaxCapacity=0 \
    --region "${AWS_REGION}" > /dev/null

echo "       Schedule apagado: L-V ${SCALE_DOWN_UTC}:00 UTC → desired=0"

# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Setup completo."
echo ""
echo "  Próximo paso — pre-cargar modelos en EFS (solo la primera vez):"
echo "  make efs-init"
echo ""
echo "  Encender la API ahora (fuera del horario laboral):"
echo "  make scale-up"
echo ""
echo "  Ver logs:"
echo "  make logs"
