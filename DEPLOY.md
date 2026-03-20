# Deploy en AWS ECS Fargate + EFS + Auto Scaling

Guía para deployar blablatotext como API REST en AWS ECS Fargate con modelos cacheados en EFS y scale-to-0 automático en horario no laboral.

## Índice

- [Prerequisitos](#prerequisitos)
- [Arquitectura](#arquitectura)
- [Deploy desde cero](#deploy-desde-cero)
- [Ciclo de vida del servicio](#ciclo-de-vida-del-servicio)
- [Gestionar el scheduler](#gestionar-el-scheduler)
- [Actualizar después de un cambio](#actualizar-después-de-un-cambio)
- [Costos estimados](#costos-estimados)
- [Cómo bajar todo](#cómo-bajar-todo)
- [Troubleshooting](#troubleshooting)

---

## Prerequisitos

### Software local

| Herramienta | Versión mínima | Verificar |
|---|---|---|
| AWS CLI | v2.x | `aws --version` |
| Docker | 24.x | `docker --version` |
| uv | 0.5+ | `uv --version` |
| make | cualquiera | `make --version` |

### AWS

- Cuenta AWS activa con credenciales configuradas
- Permisos IAM para: ECR, ECS, EFS, EC2, IAM, CloudWatch Logs, Application Auto Scaling, STS

```bash
aws sts get-caller-identity   # debe mostrar tu Account ID
```

### Variables del Makefile

```makefile
AWS_REGION  ?= us-east-1
ECR_REPO    ?= blablatotext
ECS_CLUSTER ?= blablatotext-cluster
ECS_SERVICE ?= blablatotext-service
APP_PORT    ?= 8000
SCALE_UP_UTC   ?= 11   # 8am ART (UTC-3) — hora de encendido L-V
SCALE_DOWN_UTC ?= 23   # 8pm ART (UTC-3) — hora de apagado L-V
```

Ajustá `SCALE_UP_UTC` y `SCALE_DOWN_UTC` según tu zona horaria.

---

## Arquitectura

```
Internet
   │
   ▼  TCP 8000
Security Group (blablatotext-sg)
   │                          │ TCP 2049 (NFS, self)
   ▼                          ▼
ECS Service (Fargate)      EFS Filesystem (blablatotext-efs)
   │  2 vCPU / 4 GiB          │  modelos cacheados en /mnt/efs
   │  monta EFS ──────────────┘  (~1.7 GB, cifrado en reposo)
   │
   ▼
ECR Repository (blablatotext:latest)
   │  logs a
   ▼
CloudWatch Logs (/ecs/blablatotext)

Application Auto Scaling
   ├── L-V 11:00 UTC → desired=1  (encendido automático)
   └── L-V 23:00 UTC → desired=0  (apagado automático)
```

### Recursos creados

| Recurso | Nombre | Notas |
|---|---|---|
| ECR Repository | `blablatotext` | Imagen Docker |
| ECS Cluster | `blablatotext-cluster` | Fargate serverless |
| ECS Service | `blablatotext-service` | min=0 / max=2 tasks |
| Task Definition | `blablatotext-task` | 2048 CPU / 4096 MiB |
| EFS Filesystem | `blablatotext-efs` | Modelos HuggingFace (~1.7 GB) |
| IAM Role | `blablatotext-task-exec-role` | ECR + CW Logs + EFS |
| Security Group | `blablatotext-sg` | TCP 8000 público + TCP 2049 self |
| Log Group | `/ecs/blablatotext` | Retención 7 días |
| Auto Scaling | scheduled actions | Scale-to-0 horario laboral |

### Por qué EFS

Los modelos de Whisper + mT5 pesan ~1.7 GB y tardan varios minutos en descargarse. Sin EFS, cada cold start de un nuevo task descargaría los modelos desde HuggingFace. Con EFS:

- La descarga se hace **una sola vez** (`make efs-init`)
- El task monta `/mnt/efs` al arrancar y los modelos ya están ahí
- El cold start pasa de ~5 minutos a ~30 segundos

---

## Deploy desde cero

### Paso 1 — Tests y lint

```bash
make test
make lint
```

### Paso 2 — Push de la imagen a ECR

```bash
make push
```

Primera ejecución: build + push tarda ~5-10 min (PyTorch es grande). Los siguientes usan cache de capas.

### Paso 3 — Crear la infraestructura

```bash
make setup
```

Crea en orden: IAM Role → Log Group → ECS Cluster → EFS → Security Group → Task Definition → ECS Service (desired=0) → Auto Scaling schedules.

El script es **idempotente**: si algún recurso ya existe, lo saltea.

### Paso 4 — Pre-cargar modelos en EFS (solo la primera vez)

```bash
make efs-init
```

Lanza un task Fargate de vida corta que descarga Whisper y mT5 al volumen EFS y luego termina. Tarda ~5-10 minutos según la velocidad de la red.

Solo es necesario repetirlo si cambiás los modelos (`BLABLATOTEXT_ASR_MODEL`, `BLABLATOTEXT_SUMMARIZER_MODEL`).

### Paso 5 — Encender el servicio

```bash
make scale-up
```

El Auto Scaling lo apaga y enciende automáticamente en el horario configurado. `scale-up` es para encenderlo manualmente fuera de ese horario.

### Paso 6 — Obtener la IP pública

```bash
bash scripts/get-ip.sh
```

El task tarda ~30 segundos en estar `RUNNING`. Ver el progreso con:

```bash
make logs
```

---

## Ciclo de vida del servicio

### Control automático (horario laboral)

El Auto Scaling maneja el ciclo de vida sin intervención manual:

```
L-V 11:00 UTC → desired=1  → ECS levanta 1 task → API disponible en ~30s
L-V 23:00 UTC → desired=0  → ECS detiene el task → $0 de compute
```

### Control manual

```bash
make scale-up    # encender (desired=1)
make scale-down  # apagar   (desired=0)
```

---

## Gestionar el scheduler

El scheduler controla el encendido y apagado automático del servicio en horario laboral. Se puede activar y desactivar sin tocar el resto de la infraestructura.

### Desactivar el scheduler

```bash
make scheduler-disable
```

Elimina los scheduled actions de Auto Scaling. El servicio **queda en el estado actual** (si está encendido, sigue encendido). A partir de ese momento el control es completamente manual con `make scale-up` / `make scale-down`.

### Reactivar el scheduler

```bash
make scheduler-enable
```

Recrea los scheduled actions con el horario configurado en el Makefile (`SCALE_UP_UTC` / `SCALE_DOWN_UTC`). Es idempotente: si ya existen, los sobreescribe.

### Cambiar el horario

```bash
make scheduler-enable SCALE_UP_UTC=13 SCALE_DOWN_UTC=01
```

O bien modificar los valores por defecto en el Makefile y volver a correr `make scheduler-enable`.

### Healthcheck

```bash
make health HOST=<ip-publica>
# o
curl http://<ip-publica>:8000/health
```

### Probar los endpoints

```bash
export API="http://<ip-publica>:8000"

curl -X POST "${API}/transcribe" -F "audio=@audios/mi_audio.mp4"
curl -X POST "${API}/summarize" -H "Content-Type: application/json" \
     -d '{"text": "Texto a resumir..."}'
curl -X POST "${API}/process" -F "audio=@audios/mi_audio.mp4"
```

Documentación interactiva: `http://<ip-publica>:8000/docs`

---

## Actualizar después de un cambio

```bash
make test          # verificar que no rompiste nada
make push          # nueva imagen a ECR
make deploy        # fuerza redeployment (ECS usa la imagen nueva, zero-downtime)
```

Si cambiaste los modelos en `config.py`:

```bash
make push
make efs-init      # re-descargar los nuevos modelos a EFS
make deploy
```

---

## Costos estimados

### Con scale-to-0 (horario laboral, L-V 12hs/día)

| Recurso | Cálculo | Costo/mes |
|---|---|---|
| Fargate vCPU (2 vCPU × 12h × 22 días) | 528h × $0.04048/vCPU-h × 2 | ~$42.80 |
| Fargate memoria (4 GiB × 12h × 22 días) | 528h × $0.004445/GiB-h × 4 | ~$9.39 |
| EFS almacenamiento (~2 GB) | 2 × $0.30/GB-mes | ~$0.60 |
| ECR almacenamiento (~4 GB) | 4 × $0.10/GB | ~$0.40 |
| CloudWatch Logs | < 5 GB (tier gratis) | $0 |
| **Total estimado** | | **~$53/mes** |

### Comparación vs 24/7

| Modo | Costo/mes |
|---|---|
| 24/7 sin scale-to-0 | ~$210 |
| Horario laboral (L-V 12hs) con scale-to-0 | ~$53 |
| Solo cuando hay requests (`make scale-up/down` manual) | ~$5-10 |

### Para minimizar al máximo

Usar `make scale-down` al terminar de usar la API y `make scale-up` cuando se necesite. El EFS persiste los modelos, así que el cold start siempre es rápido (~30s).

---

## Cómo bajar todo

```bash
make destroy
```

Elimina en orden: Auto Scaling → ECS Service → Task Definitions → ECS Cluster → EFS (mount targets + filesystem) → Security Group → ECR → IAM Role → CloudWatch Log Group.

Pedirá confirmación (hay que escribir `destroy`). **Atención:** elimina también los modelos cacheados en EFS — habrá que correr `make efs-init` nuevamente si se vuelve a hacer setup.

---

## Troubleshooting

### El task no arranca

```bash
aws ecs describe-services \
  --cluster blablatotext-cluster \
  --services blablatotext-service \
  --region us-east-1 \
  --query 'services[0].events[0:5]'
```

Causas comunes:
- **EFS no montable:** verificar que los mount targets están en estado `available` y que el SG tiene la regla NFS self-referential
- **Imagen no encontrada en ECR:** correr `make push` primero
- **IAM role incompleto:** verificar que tiene la política inline `blablatotext-efs-access`

### El task arranca pero falla el healthcheck

El `startPeriod` es de 60s. Si el task tiene los modelos en EFS debería arrancar en ~30s. Si falla:

```bash
make logs
```

Causa más común: los modelos no están en EFS → correr `make efs-init`.

### El service tiene desired=0 y no arranca solo

El Auto Scaling usa schedules. Si estás fuera del horario:

```bash
make scale-up
```

### Error de plataforma en Mac Apple Silicon

```bash
# make push ya incluye --platform linux/amd64
# Si buildeas manualmente:
docker build --platform linux/amd64 -t blablatotext .
```

### Ver todos los comandos disponibles

```bash
make help
```
