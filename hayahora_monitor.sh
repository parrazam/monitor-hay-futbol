#!/usr/bin/env bash
# =============================================================================
# hayahora_monitor.sh - Monitor de bloqueos de LaLiga via hayahora.futbol
#
# Consulta la API de hayahora.futbol, determina si hay bloqueo activo
# (= hay fútbol y LaLiga está censurando) y notifica en Mattermost
# SOLO cuando el estado cambia (de bloqueado a libre o viceversa).
#
# Guarda un fichero mínimo (~/.hayahora_last_state) con el timestamp del
# último cambio procesado. Si el timestamp más reciente de la API coincide,
# no hay cambio → no se notifica. Así es seguro ejecutarlo con alta
# frecuencia sin spam en el canal.
#
# Uso con cron (cada 2-5 minutos):
#   */3 * * * * /ruta/a/hayahora_monitor.sh >> /var/log/hayahora.log 2>&1
#
# Requiere: curl, jq
# Configuración: fichero .env junto al script (ver .env.example)
# =============================================================================

set -euo pipefail

# ── Cargar .env ──────────────────────────────────────────────────────────────
# Ruta absoluta al directorio del script (necesario para cron)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: No se encontró ${ENV_FILE}" >&2
    exit 1
fi

# Cargar variables (compatible con cron, sin exportar basura)
# shellcheck source=/dev/null
set -a
source "$ENV_FILE"
set +a

# ── Validar variables requeridas ─────────────────────────────────────────────
: "${MATTERMOST_URL:?ERROR: MATTERMOST_URL no definida en .env}"
: "${MATTERMOST_TOKEN:?ERROR: MATTERMOST_TOKEN no definida en .env}"
: "${MATTERMOST_CHANNEL_ID:?ERROR: MATTERMOST_CHANNEL_ID no definida en .env}"

# Opcionales con defaults
API_URL="${API_URL:-https://hayahora.futbol/estado/data.json}"
CURL_TIMEOUT="${CURL_TIMEOUT:-15}"
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/.hayahora_last_state}"
# Porcentaje mínimo de IPs bloqueadas en un ISP para considerar bloqueo real.
# Cuando LaLiga bloquea, >90% de las IPs de cada ISP pasan a true simultáneamente.
# Un umbral de 50% filtra el ruido residual (IPs sueltas que quedan en true).
BLOCK_THRESHOLD_PCT="${BLOCK_THRESHOLD_PCT:-50}"
# (Opcional) URL de push de Uptime Kuma. Si está definida, se enviará un
# GET al finalizar la ejecución con éxito como heartbeat.
UPTIME_KUMA_PUSH_URL="${UPTIME_KUMA_PUSH_URL:-}"
# (Opcional) URL de Ntfy para notificar fallos del script. Si está definida,
# se enviará una alerta cuando el script falle indicando el paso y motivo.
NTFY_URL="${NTFY_URL:-}"
NTFY_TOKEN="${NTFY_TOKEN:-}"

# ── Funciones ────────────────────────────────────────────────────────────────

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

CURRENT_STEP="inicialización"

send_ntfy() {
    [[ -z "$NTFY_URL" ]] && return 0
    local title="$1" body="$2"
    local auth_args=()
    [[ -n "$NTFY_TOKEN" ]] && auth_args=(-H "Authorization: Bearer ${NTFY_TOKEN}")
    curl -fsS -o /dev/null --max-time "$CURL_TIMEOUT" \
        -H "Title: ${title}" \
        -H "Priority: high" \
        -H "Tags: rotating_light" \
        "${auth_args[@]}" \
        -d "$body" \
        "$NTFY_URL" \
        || log "WARN: no se pudo enviar notificación a Ntfy" >&2
}

die() {
    local msg="$1"
    log "ERROR: $msg" >&2
    send_ntfy "hayahora_monitor: fallo en '${CURRENT_STEP}'" \
        "Paso: ${CURRENT_STEP}
Motivo: ${msg}"
    exit 1
}

on_unexpected_error() {
    local code=$?
    local line="$1"
    local cmd="$2"
    send_ntfy "hayahora_monitor: fallo inesperado en '${CURRENT_STEP}'" \
        "Paso: ${CURRENT_STEP}
Línea: ${line}
Comando: ${cmd}
Exit code: ${code}"
    exit "$code"
}
trap 'on_unexpected_error "$LINENO" "$BASH_COMMAND"' ERR

send_heartbeat() {
    [[ -z "$UPTIME_KUMA_PUSH_URL" ]] && return 0
    if curl -fsS -o /dev/null --max-time "$CURL_TIMEOUT" "$UPTIME_KUMA_PUSH_URL"; then
        log "Uptime Kuma: push enviado"
    else
        log "WARN: Uptime Kuma push falló"
    fi
}

send_mattermost() {
    local message="$1"
    local payload

    payload=$(jq -n --arg ch "$MATTERMOST_CHANNEL_ID" --arg msg "$message" \
        '{channel_id: $ch, message: $msg}')

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        --max-time "$CURL_TIMEOUT" \
        -X POST \
        -H "Authorization: Bearer ${MATTERMOST_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${MATTERMOST_URL}/api/v4/posts")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        log "Mattermost: mensaje enviado (HTTP ${http_code})"
    else
        log "ERROR: Mattermost respondió HTTP ${http_code}" >&2
        return 1
    fi
}

# ── Obtener datos de la API ──────────────────────────────────────────────────

CURRENT_STEP="consulta a la API de hayahora.futbol"
log "Consultando API: ${API_URL}"

API_RESPONSE=$(curl -s --max-time "$CURL_TIMEOUT" -f "$API_URL") || {
    send_mattermost ":warning: **hayahora_monitor**: No se pudo contactar con la API de hayahora.futbol. ¿Estará bloqueada también?" || true
    die "No se pudo contactar con la API (${API_URL})"
}

# ── Analizar JSON ────────────────────────────────────────────────────────────
# Estrategia por proporción:
#   1. Para cada ISP, calcular qué porcentaje de sus IPs tienen state=true
#      en su último stateChange.
#   2. Si ALGÚN ISP supera BLOCK_THRESHOLD_PCT → bloqueo activo (hay fútbol).
#   3. Si ninguno lo supera → son IPs residuales/ruido → no hay bloqueo.
#
# Esto funciona porque cuando LaLiga activa el bloqueo, >90% de las IPs de
# cada ISP pasan a true simultáneamente. Las IPs sueltas que quedan en true
# después son artefactos que no representan un bloqueo real.

CURRENT_STEP="análisis del JSON de la API"
JQ_STDERR=$(mktemp)
trap 'rm -f "$JQ_STDERR"' EXIT

if ! ISP_STATS=$(echo "$API_RESPONSE" | jq --argjson threshold "$BLOCK_THRESHOLD_PCT" '
    if (.data | type) != "array" then
        error("payload inesperado: .data no es un array (type=\(.data | type))")
    else . end
    | [.data[] | {isp, blocked: (.stateChanges[-1].state // false)}]
    | group_by(.isp)
    | map({
        isp: .[0].isp,
        total: length,
        blocked: ([.[] | select(.blocked == true)] | length),
        pct: (([.[] | select(.blocked == true)] | length) * 100.0 / length)
      })
    | {
        isps: .,
        any_over_threshold: (any(.[]; .pct >= $threshold)),
        blocked_isps_over: [.[] | select(.pct >= $threshold) | .isp]
      }
' 2>"$JQ_STDERR"); then
    JQ_ERR=$(<"$JQ_STDERR")
    SAMPLE=$(printf '%s' "$API_RESPONSE" | head -c 300)
    die "jq falló analizando el JSON de la API. Error: ${JQ_ERR}. Muestra (300B): ${SAMPLE}"
fi

if [[ -z "$ISP_STATS" || "$ISP_STATS" == "null" ]]; then
    die "No se pudieron extraer datos del JSON de la API"
fi

BLOCK_ACTIVE=$(echo "$ISP_STATS" | jq -r '.any_over_threshold')
LAST_UPDATE=$(echo "$API_RESPONSE" | jq -r '.lastUpdate')
TOTAL_ENTRIES=$(echo "$API_RESPONSE" | jq '.data | length')
BLOCKED_COUNT=$(echo "$API_RESPONSE" | jq '[.data[] | select(.stateChanges[-1].state == true)] | length')
BLOCKED_ISPS=$(echo "$ISP_STATS" | jq -r '[.isps[] | select(.blocked > 0) | "  - \(.isp): \(.blocked)/\(.total) (\(.pct | round)%)"] | join("\n")')
BLOCKED_ISPS_OVER=$(echo "$ISP_STATS" | jq -r '.blocked_isps_over | join(", ")')

# El estado efectivo: true solo si algún ISP supera el umbral
if [[ "$BLOCK_ACTIVE" == "true" ]]; then
    LATEST_STATE="true"
else
    LATEST_STATE="false"
fi

log "Umbral: ${BLOCK_THRESHOLD_PCT}% | Bloqueo activo: ${BLOCK_ACTIVE}"
log "Bloqueados: ${BLOCKED_COUNT}/${TOTAL_ENTRIES} entradas | Detalle ISPs: ${BLOCKED_ISPS}"

# ── Detectar cambio de estado ────────────────────────────────────────────────
# Fichero de estado: una línea con "TIMESTAMP|STATE" del último cambio notificado.
# Si el timestamp+state actual coincide con el guardado → sin cambios → no notificar.

CURRENT_STEP="detección de cambio de estado"
PREV_RECORD=""
if [[ -f "$STATE_FILE" ]]; then
    PREV_RECORD=$(cat "$STATE_FILE" 2>/dev/null || echo "")
fi

CURRENT_RECORD="${LATEST_STATE}"

if [[ "$CURRENT_RECORD" == "$PREV_RECORD" ]]; then
    log "Sin cambios desde la última ejecución (${CURRENT_RECORD}). No se notifica."
    CURRENT_STEP="push de heartbeat a Uptime Kuma"
    send_heartbeat
    exit 0
fi

log "¡Cambio detectado! Anterior: '${PREV_RECORD:-<primera ejecución>}' → Actual: '${CURRENT_RECORD}'"

# ── Construir y enviar mensaje ───────────────────────────────────────────────

if [[ "$LATEST_STATE" == "true" ]]; then
    MSG=$(cat <<EOF
:rotating_light: **¡HAY FÚTBOL! LaLiga está censurando Internet** :rotating_light:

Se han detectado **bloqueos activos** en las IPs monitorizadas por [hayahora.futbol](https://hayahora.futbol).

| Dato | Valor |
|:--|:--|
| Entradas bloqueadas | **${BLOCKED_COUNT}** de ${TOTAL_ENTRIES} |
| ISPs afectados (>${BLOCK_THRESHOLD_PCT}%) | ${BLOCKED_ISPS_OVER} |
| Última actualización API | ${LAST_UPDATE} |

**IPs bloqueadas por ISP:**
${BLOCKED_ISPS}

:point_right: Si no puedes acceder a alguna web, prueba con una VPN.
EOF
    )
    log "BLOQUEO ACTIVO → enviando alerta a Mattermost"
else
    MSG=$(cat <<EOF
:white_check_mark: **Se acabó el fútbol — Internet libre de nuevo**

Los bloqueos de LaLiga han cesado según [hayahora.futbol](https://hayahora.futbol).

| Dato | Valor |
|:--|:--|
| Última actualización API | ${LAST_UPDATE} |

**IPs bloqueadas por ISP:**
${BLOCKED_ISPS:-  - Ninguna}

:tada: Puedes navegar tranquilamente.
EOF
    )
    log "BLOQUEO FINALIZADO → enviando aviso a Mattermost"
fi

CURRENT_STEP="envío de notificación a Mattermost"
if send_mattermost "$MSG"; then
    # Solo guardar estado si el envío fue exitoso (así reintenta en la próxima)
    echo "$CURRENT_RECORD" > "$STATE_FILE"
    log "Estado guardado en ${STATE_FILE}"
else
    die "No se pudo enviar mensaje a Mattermost; no se guarda estado (reintentará en la próxima ejecución)"
fi

CURRENT_STEP="push de heartbeat a Uptime Kuma"
send_heartbeat

log "Finalizado correctamente."
