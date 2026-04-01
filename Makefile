# ─── Variables configurables ──────────────────────────────────────────────────
# Sobreescribir desde CLI: make push AWS_REGION=sa-east-1
AWS_REGION  ?= us-east-1
ECR_REPO    ?= blablatotext
ECS_CLUSTER ?= blablatotext-cluster
ECS_SERVICE ?= blablatotext-service
APP_PORT    ?= 8000
SCALE_UP_UTC   ?= 11
SCALE_DOWN_UTC ?= 23
APIGW_NAME     ?= blablatotext-apigw

# HOST para make health — usa localhost por defecto, IP del task para remoto
# Ejemplo: make health HOST=3.91.12.34
HOST ?= localhost

# Derivadas — solo se evalúan en targets que las usen (requieren AWS CLI)
AWS_ACCOUNT_ID = $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR_REGISTRY   = $(AWS_ACCOUNT_ID).dkr.ecr.$(AWS_REGION).amazonaws.com
IMAGE_URI      = $(ECR_REGISTRY)/$(ECR_REPO):latest

# ─── Config interna ───────────────────────────────────────────────────────────
.DEFAULT_GOAL := help
.PHONY: help dev test lint build run push setup efs-init deploy scale-up scale-down scheduler-enable scheduler-disable destroy health logs apigw-setup apigw-update-ip apigw-url apigw-destroy

# ─── Targets ──────────────────────────────────────────────────────────────────

help: ## Lista todos los comandos disponibles
	@echo ""
	@echo "  blablatotext — comandos disponibles"
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Variables: AWS_REGION=$(AWS_REGION)  ECR_REPO=$(ECR_REPO)"
	@echo "             ECS_CLUSTER=$(ECS_CLUSTER)  APP_PORT=$(APP_PORT)"
	@echo ""

# ─── Desarrollo local ─────────────────────────────────────────────────────────

dev: ## Levanta la API local con uvicorn --reload
	uv run uvicorn blablatotext.api:app --reload --host 0.0.0.0 --port $(APP_PORT)

test: ## Corre pytest con cobertura
	uv run pytest

lint: ## ruff check + ruff format --check
	uv run ruff check src tests
	uv run ruff format --check src tests

# ─── Docker ───────────────────────────────────────────────────────────────────

build: ## Docker build de la imagen local
	docker build -t $(ECR_REPO):latest .

run: build ## Docker run local en APP_PORT (verifica antes de deployar)
	docker run --rm \
		-p $(APP_PORT):$(APP_PORT) \
		-e BLABLATOTEXT_DEVICE=cpu \
		$(ECR_REPO):latest

# ─── AWS ──────────────────────────────────────────────────────────────────────

push: ## Build + push a ECR (--no-cache, tag versionado, actualiza task definition)
	@AWS_REGION=$(AWS_REGION) \
	ECR_REPO=$(ECR_REPO) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	bash scripts/ecr-push.sh

setup: ## Crea toda la infraestructura en AWS (ECS + EFS + Auto Scaling)
	@AWS_REGION=$(AWS_REGION) \
	ECR_REPO=$(ECR_REPO) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	APP_PORT=$(APP_PORT) \
	bash scripts/ecs-setup.sh

efs-init: ## Pre-descarga los modelos al volumen EFS (solo la primera vez)
	@AWS_REGION=$(AWS_REGION) \
	ECR_REPO=$(ECR_REPO) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	APP_PORT=$(APP_PORT) \
	bash scripts/efs-init.sh

scale-up: ## Enciende el servicio (desired=1) — para uso fuera del horario laboral
	@echo "→ Encendiendo servicio $(ECS_CLUSTER)/$(ECS_SERVICE)..."
	@aws ecs update-service \
		--cluster $(ECS_CLUSTER) \
		--service $(ECS_SERVICE) \
		--desired-count 1 \
		--region $(AWS_REGION) \
		--query 'service.{desired:desiredCount,running:runningCount}' \
		--output table
	@echo ""
	@echo "El task tarda ~30s en estar RUNNING. Seguí con: make logs"

scheduler-enable: ## Activa el encendido/apagado automático L-V (scheduled actions)
	@AWS_REGION=$(AWS_REGION) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	SCALE_UP_UTC=$(SCALE_UP_UTC) \
	SCALE_DOWN_UTC=$(SCALE_DOWN_UTC) \
	bash scripts/scheduler-enable.sh

scheduler-disable: ## Desactiva el encendido/apagado automático (elimina scheduled actions)
	@AWS_REGION=$(AWS_REGION) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	bash scripts/scheduler-disable.sh

scale-down: ## Apaga el servicio (desired=0) — para parar costos
	@echo "→ Apagando servicio $(ECS_CLUSTER)/$(ECS_SERVICE)..."
	@aws ecs update-service \
		--cluster $(ECS_CLUSTER) \
		--service $(ECS_SERVICE) \
		--desired-count 0 \
		--region $(AWS_REGION) \
		--query 'service.{desired:desiredCount,running:runningCount}' \
		--output table

deploy: ## Fuerza redeployment del servicio ECS con la imagen más reciente
	@echo "→ Forzando nuevo deployment en $(ECS_CLUSTER)/$(ECS_SERVICE)..."
	@aws ecs update-service \
		--region $(AWS_REGION) \
		--cluster $(ECS_CLUSTER) \
		--service $(ECS_SERVICE) \
		--force-new-deployment \
		--query 'service.deployments[0].{status:status,desired:desiredCount,running:runningCount}' \
		--output table
	@echo ""
	@echo "Seguí el progreso con: make logs"

destroy: ## Baja todo de AWS (servicio ECS, cluster, ECR, IAM role, log group)
	@AWS_REGION=$(AWS_REGION) \
	ECR_REPO=$(ECR_REPO) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	bash scripts/ecs-destroy.sh

# ─── API Gateway HTTPS ────────────────────────────────────────────────────────

apigw-setup: ## Crea API Gateway HTTPS → ECS (correr después de scale-up)
	@AWS_REGION=$(AWS_REGION) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	APP_PORT=$(APP_PORT) \
	bash scripts/apigw-setup.sh

apigw-update-ip: ## Actualiza la IP del backend tras un scale-up (nueva tarea Fargate)
	@AWS_REGION=$(AWS_REGION) \
	ECS_CLUSTER=$(ECS_CLUSTER) \
	ECS_SERVICE=$(ECS_SERVICE) \
	APP_PORT=$(APP_PORT) \
	bash scripts/apigw-update-ip.sh

apigw-url: ## Muestra la URL HTTPS del API Gateway
	@API_ID=$$(grep '^API_ID=' .apigw 2>/dev/null | cut -d= -f2); \
	if [[ -z "$$API_ID" || "$$API_ID" == "None" ]]; then \
		echo "API Gateway no configurado. Corré: make apigw-setup"; \
	else \
		echo "https://$$API_ID.execute-api.$(AWS_REGION).amazonaws.com"; \
	fi

apigw-destroy: ## Elimina el API Gateway (no toca ECS ni EFS)
	@if [[ ! -f .apigw ]]; then echo "No hay .apigw — nada que eliminar."; exit 0; fi; \
	API_ID=$$(grep '^API_ID=' .apigw | cut -d= -f2); \
	echo "→ Eliminando API Gateway $$API_ID..."; \
	aws apigatewayv2 delete-api \
		--api-id "$$API_ID" \
		--region $(AWS_REGION); \
	rm -f .apigw; \
	echo "✓ API Gateway eliminado."

# ─── Observabilidad ───────────────────────────────────────────────────────────

health: ## Curl al /health (HOST=localhost por defecto, o make health HOST=<ip>)
	@curl -sf http://$(HOST):$(APP_PORT)/health | python3 -m json.tool \
		|| (echo "Error: API no responde en http://$(HOST):$(APP_PORT)/health" && exit 1)

logs: ## Tail de logs del servicio en CloudWatch (Ctrl+C para salir)
	aws logs tail /ecs/$(ECR_REPO) \
		--region $(AWS_REGION) \
		--follow \
		--format short
