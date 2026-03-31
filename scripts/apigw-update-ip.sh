#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# apigw-update-ip.sh — Actualiza la URL de backend en el API Gateway cuando
#                      el task ECS obtiene una nueva IP pública.
#
# Cuándo usarlo: después de cada "make scale-up", ya que Fargate asigna una
# nueva IP pública al task al reiniciarse.
#
# Uso directo:  bash scripts/apigw-update-ip.sh
# Uso via Make: make apigw-update-ip
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"
APP_PORT="${APP_PORT:-8000}"

APIGW_STATE_FILE=".apigw"

exists() { [[ -n "$1" && "$1" != "None" && "$1" != "null" ]]; }

# ─────────────────────────────────────────────────────────────────────────────
# 1. Leer IDs guardados por apigw-setup.sh
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$APIGW_STATE_FILE" ]]; then
    echo "✗ No se encontró ${APIGW_STATE_FILE}."
    echo "  Corré 'make apigw-setup' primero."
    exit 1
fi

# shellcheck source=/dev/null
source "$APIGW_STATE_FILE"

if ! exists "${API_ID:-}" || ! exists "${INTEGRATION_ID:-}"; then
    echo "✗ ${APIGW_STATE_FILE} está incompleto o corrupto."
    echo "  Corré 'make apigw-setup' para recrearlo."
    exit 1
fi

echo "=== Actualizar IP del backend en API Gateway ==="
echo "    API ID         : ${API_ID}"
echo "    Integration ID : ${INTEGRATION_ID}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 2. Esperar a que el task esté RUNNING y obtener su IP pública
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Esperando task RUNNING en ${ECS_CLUSTER}/${ECS_SERVICE}..."
MAX_ATTEMPTS=20
ATTEMPT=0

while [[ $ATTEMPT -lt $MAX_ATTEMPTS ]]; do
    TASK_ARN=$(aws ecs list-tasks \
        --cluster "$ECS_CLUSTER" \
        --service-name "$ECS_SERVICE" \
        --desired-status RUNNING \
        --region "$AWS_REGION" \
        --query 'taskArns[0]' \
        --output text 2>/dev/null || true)

    if exists "$TASK_ARN"; then
        ENI_ID=$(aws ecs describe-tasks \
            --cluster "$ECS_CLUSTER" \
            --tasks "$TASK_ARN" \
            --region "$AWS_REGION" \
            --query "tasks[0].attachments[0].details[?name=='networkInterfaceId'].value" \
            --output text 2>/dev/null || true)

        if exists "$ENI_ID"; then
            BACKEND_IP=$(aws ec2 describe-network-interfaces \
                --network-interface-ids "$ENI_ID" \
                --region "$AWS_REGION" \
                --query 'NetworkInterfaces[0].Association.PublicIp' \
                --output text 2>/dev/null || true)

            if exists "$BACKEND_IP"; then
                echo "  Task RUNNING — IP: ${BACKEND_IP}"
                break
            fi
        fi
    fi

    ATTEMPT=$((ATTEMPT + 1))
    echo "  Intento ${ATTEMPT}/${MAX_ATTEMPTS} — esperando 5s..."
    sleep 5
done

if [[ $ATTEMPT -ge $MAX_ATTEMPTS ]]; then
    echo "✗ El task no llegó a RUNNING luego de $((MAX_ATTEMPTS * 5))s."
    echo "  Revisá el estado con: make logs"
    exit 1
fi

BACKEND_URL="http://${BACKEND_IP}:${APP_PORT}"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Actualizar la integración con la nueva URL
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Actualizando integración hacia ${BACKEND_URL}..."
aws apigatewayv2 update-integration \
    --api-id "$API_ID" \
    --integration-id "$INTEGRATION_ID" \
    --integration-uri "$BACKEND_URL" \
    --region "$AWS_REGION" \
    --output text > /dev/null

APIGW_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

echo ""
echo "✓ Integración actualizada."
echo ""
echo "  Backend : ${BACKEND_URL}"
echo "  HTTPS   : ${APIGW_URL}"
echo ""
echo "  Verificar: curl ${APIGW_URL}/health"
echo ""
