#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scheduler-disable.sh — Desactiva el encendido/apagado automático del servicio ECS.
#
# Elimina los dos scheduled actions de Application Auto Scaling:
#   - scale-up-business-hours
#   - scale-down-business-hours
#
# El servicio queda en el estado actual (desired sin cambiar).
# Para controlarlo manualmente: make scale-up / make scale-down
#
# Uso directo:  bash scripts/scheduler-disable.sh
# Uso via Make: make scheduler-disable
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"

RESOURCE_ID="service/${ECS_CLUSTER}/${ECS_SERVICE}"

echo "=== Desactivar Auto Scaling scheduler ==="
echo "    Cluster : ${ECS_CLUSTER}"
echo "    Servicio: ${ECS_SERVICE}"
echo ""

delete_action() {
    local name="$1"
    aws application-autoscaling delete-scheduled-action \
        --service-namespace ecs \
        --resource-id "${RESOURCE_ID}" \
        --scalable-dimension ecs:service:DesiredCount \
        --scheduled-action-name "${name}" \
        --region "${AWS_REGION}" 2>/dev/null \
        && echo "→ Eliminado: ${name}" \
        || echo "→ No existía (ya eliminado): ${name}"
}

delete_action "scale-up-business-hours"
delete_action "scale-down-business-hours"

echo ""
echo "✓ Scheduler desactivado. El servicio no se encenderá ni apagará automáticamente."
echo ""
echo "  Control manual:"
echo "    make scale-up    — encender (desired=1)"
echo "    make scale-down  — apagar   (desired=0)"
echo ""
echo "  Para reactivar el scheduler:"
echo "    make scheduler-enable"
