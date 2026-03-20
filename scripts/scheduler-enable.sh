#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scheduler-enable.sh — Activa el encendido/apagado automático del servicio ECS.
#
# Crea (o recrea) los dos scheduled actions de Application Auto Scaling:
#   - scale-up-business-hours:   L-V SCALE_UP_UTC:00   UTC → desired=1
#   - scale-down-business-hours: L-V SCALE_DOWN_UTC:00 UTC → desired=0
#
# Uso directo:  bash scripts/scheduler-enable.sh
# Uso via Make: make scheduler-enable
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"
SCALE_UP_UTC="${SCALE_UP_UTC:-11}"
SCALE_DOWN_UTC="${SCALE_DOWN_UTC:-23}"

RESOURCE_ID="service/${ECS_CLUSTER}/${ECS_SERVICE}"

echo "=== Activar Auto Scaling scheduler ==="
echo "    Cluster : ${ECS_CLUSTER}"
echo "    Servicio: ${ECS_SERVICE}"
echo "    Encendido : L-V ${SCALE_UP_UTC}:00 UTC → desired=1"
echo "    Apagado   : L-V ${SCALE_DOWN_UTC}:00 UTC → desired=0"
echo ""

# Asegurar que el scalable target existe (idempotente)
aws application-autoscaling register-scalable-target \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --min-capacity 0 \
    --max-capacity 2 \
    --region "${AWS_REGION}" > /dev/null

# Schedule encendido
aws application-autoscaling put-scheduled-action \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --scheduled-action-name "scale-up-business-hours" \
    --schedule "cron(0 ${SCALE_UP_UTC} ? * MON-FRI *)" \
    --scalable-target-action MinCapacity=1,MaxCapacity=2 \
    --region "${AWS_REGION}" > /dev/null

echo "→ Schedule encendido creado: L-V ${SCALE_UP_UTC}:00 UTC → desired=1"

# Schedule apagado
aws application-autoscaling put-scheduled-action \
    --service-namespace ecs \
    --resource-id "${RESOURCE_ID}" \
    --scalable-dimension ecs:service:DesiredCount \
    --scheduled-action-name "scale-down-business-hours" \
    --schedule "cron(0 ${SCALE_DOWN_UTC} ? * MON-FRI *)" \
    --scalable-target-action MinCapacity=0,MaxCapacity=0 \
    --region "${AWS_REGION}" > /dev/null

echo "→ Schedule apagado creado:   L-V ${SCALE_DOWN_UTC}:00 UTC → desired=0"
echo ""
echo "✓ Scheduler activado. El servicio se encenderá y apagará automáticamente."
