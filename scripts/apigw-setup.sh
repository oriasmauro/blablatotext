#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# apigw-setup.sh — Crea un API Gateway HTTP (v2) con HTTPS que forwardea
#                  al task ECS Fargate en ejecución.
#
# Arquitectura:
#   Internet → HTTPS API Gateway ($default stage) → HTTP → ECS task (IP pública)
#
# Nota MVP: la IP del task cambia al reiniciarse. Correr "make apigw-update-ip"
#           después de cada "make scale-up" para sincronizar la URL de backend.
#
# Uso directo:  bash scripts/apigw-setup.sh
# Uso via Make: make apigw-setup
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"
ECS_CLUSTER="${ECS_CLUSTER:-blablatotext-cluster}"
ECS_SERVICE="${ECS_SERVICE:-blablatotext-service}"
APP_PORT="${APP_PORT:-8000}"

APIGW_NAME="blablatotext-apigw"
APIGW_STATE_FILE=".apigw"

exists() { [[ -n "$1" && "$1" != "None" && "$1" != "null" ]]; }

echo "=== API Gateway HTTPS Setup ==="
echo "    Región  : ${AWS_REGION}"
echo "    Nombre  : ${APIGW_NAME}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Obtener IP pública del task en ejecución
# ─────────────────────────────────────────────────────────────────────────────
echo "→ Obteniendo IP pública del task ECS..."
BACKEND_IP=$(AWS_REGION="$AWS_REGION" ECS_CLUSTER="$ECS_CLUSTER" \
    ECS_SERVICE="$ECS_SERVICE" APP_PORT="$APP_PORT" \
    bash scripts/get-ip.sh | head -1)

if ! exists "$BACKEND_IP"; then
    echo "✗ No hay task RUNNING. Corré 'make scale-up' primero."
    exit 1
fi
BACKEND_URL="http://${BACKEND_IP}:${APP_PORT}"
echo "  Backend: ${BACKEND_URL}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 2. Crear (o reusar) la HTTP API
# ─────────────────────────────────────────────────────────────────────────────
EXISTING_API_ID=$(aws apigatewayv2 get-apis \
    --region "$AWS_REGION" \
    --query "Items[?Name=='${APIGW_NAME}'].ApiId | [0]" \
    --output text 2>/dev/null || true)

if exists "$EXISTING_API_ID"; then
    echo "→ HTTP API ya existe (${EXISTING_API_ID}) — reutilizando."
    API_ID="$EXISTING_API_ID"

    # Leer o descubrir el Integration ID
    EXISTING_INTEGRATION_ID=$(grep '^INTEGRATION_ID=' "$APIGW_STATE_FILE" 2>/dev/null \
        | cut -d= -f2 || true)

    if ! exists "$EXISTING_INTEGRATION_ID"; then
        # Intentar descubrirlo desde la API (caso: .apigw borrado o run parcial)
        EXISTING_INTEGRATION_ID=$(aws apigatewayv2 get-integrations \
            --api-id "$API_ID" \
            --region "$AWS_REGION" \
            --query 'Items[0].IntegrationId' \
            --output text 2>/dev/null || true)
    fi

    if exists "$EXISTING_INTEGRATION_ID"; then
        INTEGRATION_ID="$EXISTING_INTEGRATION_ID"
        echo "→ Actualizando integración ${INTEGRATION_ID} con nueva IP..."
        aws apigatewayv2 update-integration \
            --api-id "$API_ID" \
            --integration-id "$INTEGRATION_ID" \
            --integration-uri "$BACKEND_URL" \
            --region "$AWS_REGION" \
            --output text > /dev/null
        echo "  Integración actualizada."
    else
        echo "✗ No se encontró ninguna integración. Corré 'make apigw-destroy' y volvé a ejecutar."
        exit 1
    fi

    # Crear ruta $default si no existe
    EXISTING_ROUTE=$(aws apigatewayv2 get-routes \
        --api-id "$API_ID" \
        --region "$AWS_REGION" \
        --query "Items[?RouteKey=='\$default'].RouteId | [0]" \
        --output text 2>/dev/null || true)

    if ! exists "$EXISTING_ROUTE"; then
        echo "→ Creando ruta catch-all \$default (faltaba)..."
        aws apigatewayv2 create-route \
            --api-id "$API_ID" \
            --route-key '$default' \
            --target "integrations/${INTEGRATION_ID}" \
            --region "$AWS_REGION" \
            --output text > /dev/null
        echo "  Ruta \$default creada."
    fi

    # Crear stage $default si no existe
    EXISTING_STAGE=$(aws apigatewayv2 get-stages \
        --api-id "$API_ID" \
        --region "$AWS_REGION" \
        --query "Items[?StageName=='\$default'].StageName | [0]" \
        --output text 2>/dev/null || true)

    if ! exists "$EXISTING_STAGE"; then
        echo "→ Creando stage \$default (faltaba)..."
        aws apigatewayv2 create-stage \
            --api-id "$API_ID" \
            --stage-name '$default' \
            --auto-deploy \
            --region "$AWS_REGION" \
            --output text > /dev/null
        echo "  Stage \$default creado."
    fi

    # Actualizar .apigw con los IDs correctos
    cat > "$APIGW_STATE_FILE" <<EOF
API_ID=${API_ID}
INTEGRATION_ID=${INTEGRATION_ID}
EOF
else
    # ─────────────────────────────────────────────────────────────────────────
    # 3. Crear HTTP API
    # ─────────────────────────────────────────────────────────────────────────
    echo "→ Creando HTTP API..."
    API_ID=$(aws apigatewayv2 create-api \
        --name "$APIGW_NAME" \
        --protocol-type HTTP \
        --cors-configuration \
            AllowOrigins='["*"]',AllowMethods='["GET","POST","PUT","DELETE","OPTIONS"]',AllowHeaders='["*"]' \
        --region "$AWS_REGION" \
        --query 'ApiId' \
        --output text)
    echo "  API ID: ${API_ID}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # 4. Crear integración HTTP_PROXY con path forwarding
    # ─────────────────────────────────────────────────────────────────────────
    echo "→ Creando integración HTTP_PROXY → ${BACKEND_URL}..."
    INTEGRATION_ID=$(aws apigatewayv2 create-integration \
        --api-id "$API_ID" \
        --integration-type HTTP_PROXY \
        --integration-method ANY \
        --integration-uri "$BACKEND_URL" \
        --payload-format-version 1.0 \
        --request-parameters '{"overwrite:path": "$request.path"}' \
        --region "$AWS_REGION" \
        --query 'IntegrationId' \
        --output text)
    echo "  Integration ID: ${INTEGRATION_ID}"
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # 5. Crear ruta catch-all $default
    # ─────────────────────────────────────────────────────────────────────────
    echo "→ Creando ruta catch-all \$default..."
    aws apigatewayv2 create-route \
        --api-id "$API_ID" \
        --route-key '$default' \
        --target "integrations/${INTEGRATION_ID}" \
        --region "$AWS_REGION" \
        --output text > /dev/null
    echo "  Ruta \$default creada."
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # 6. Crear stage $default con auto-deploy
    # ─────────────────────────────────────────────────────────────────────────
    echo "→ Creando stage \$default con auto-deploy..."
    aws apigatewayv2 create-stage \
        --api-id "$API_ID" \
        --stage-name '$default' \
        --auto-deploy \
        --region "$AWS_REGION" \
        --output text > /dev/null
    echo "  Stage \$default creado."
    echo ""

    # ─────────────────────────────────────────────────────────────────────────
    # 7. Persistir IDs para uso posterior (update-ip, destroy)
    # ─────────────────────────────────────────────────────────────────────────
    cat > "$APIGW_STATE_FILE" <<EOF
API_ID=${API_ID}
INTEGRATION_ID=${INTEGRATION_ID}
EOF
    echo "  IDs guardados en ${APIGW_STATE_FILE}"
fi

APIGW_URL="https://${API_ID}.execute-api.${AWS_REGION}.amazonaws.com"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  API Gateway HTTPS listo                             ║"
echo "╠══════════════════════════════════════════════════════╣"
printf "║  URL base: %-42s║\n" "${APIGW_URL}"
echo "╠══════════════════════════════════════════════════════╣"
echo "║  Endpoints:                                          ║"
printf "║    GET  %-45s║\n" "${APIGW_URL}/health"
printf "║    POST %-45s║\n" "${APIGW_URL}/transcribe"
printf "║    POST %-45s║\n" "${APIGW_URL}/summarize"
printf "║    POST %-45s║\n" "${APIGW_URL}/process"
printf "║    GET  %-45s║\n" "${APIGW_URL}/docs"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  ⚠ La URL cambia si borrás y recreás el API."
echo "  ⚠ Después de cada 'make scale-up', corré: make apigw-update-ip"
echo ""
