#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONITOR_SCRIPT="${SCRIPT_DIR}/hayahora_monitor.sh"
WORK_DIR=$(mktemp -d)
PASSED=0
FAILED=0
PORT_BASE=19870

cleanup() {
    jobs -p | xargs -r kill 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

echo "========================================"
echo " Test suite: hayahora_monitor.sh"
echo "========================================"
echo ""

# ── Datos simulados ──────────────────────────────────────────────────────────

cat > "${WORK_DIR}/api_blocked.json" <<'JSON'
{"lastUpdate":"2026-04-10 20:01:00","data":[{"ip":"104.16.93.114","isp":"Movistar","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T15:00:00Z","state":false},{"timestamp":"2026-04-10T20:00:00Z","state":true}]},{"ip":"104.16.93.114","isp":"Vodafone","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T15:00:00Z","state":false},{"timestamp":"2026-04-10T19:58:00Z","state":true}]},{"ip":"104.16.94.114","isp":"DIGI","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T15:00:00Z","state":false},{"timestamp":"2026-04-10T19:55:00Z","state":true}]}]}
JSON

cat > "${WORK_DIR}/api_free.json" <<'JSON'
{"lastUpdate":"2026-04-10 23:30:00","data":[{"ip":"104.16.93.114","isp":"Movistar","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T20:00:00Z","state":true},{"timestamp":"2026-04-10T22:30:00Z","state":false}]},{"ip":"104.16.93.114","isp":"Vodafone","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T19:58:00Z","state":true},{"timestamp":"2026-04-10T22:28:00Z","state":false}]},{"ip":"104.16.94.114","isp":"DIGI","description":"Cloudflare","stateChanges":[{"timestamp":"2026-04-10T19:55:00Z","state":true},{"timestamp":"2026-04-10T22:25:00Z","state":false}]}]}
JSON

# ── Helper: montar entorno de integración ────────────────────────────────────

# start_mock PORT JSON_FILE BODY_OUTPUT_FILE
start_mock_api() {
    python3 -c "
import http.server,threading,os,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(open(sys.argv[1],'rb').read())
        threading.Timer(0.1,os._exit,[0]).start()
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[2])),H).serve_forever()
" "$1" "$2" &
}

start_mock_mm() {
    python3 -c "
import http.server,threading,os,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        open(sys.argv[1],'ab').write(body + b'\n')
        self.send_response(201); self.send_header('Content-Type','application/json'); self.end_headers()
        self.wfile.write(b'{\"id\":\"ok\"}')
        threading.Timer(0.1,os._exit,[0]).start()
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[2])),H).serve_forever()
" "$1" "$2" &
}

start_mock_kuma() {
    python3 -c "
import http.server,threading,os,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        open(sys.argv[1],'ab').write(b'ping ' + self.path.encode() + b'\n')
        self.send_response(200); self.end_headers(); self.wfile.write(b'OK')
        threading.Timer(0.1,os._exit,[0]).start()
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[2])),H).serve_forever()
" "$1" "$2" &
}

start_mock_ntfy() {
    python3 -c "
import http.server,threading,os,sys
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0)))
        title=self.headers.get('Title','')
        auth=self.headers.get('Authorization','')
        with open(sys.argv[1],'ab') as f:
            f.write(b'TITLE=' + title.encode() + b'\n')
            f.write(b'AUTH=' + auth.encode() + b'\n')
            f.write(b'BODY=' + body + b'\n---\n')
        self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        threading.Timer(0.1,os._exit,[0]).start()
    def log_message(self,*a): pass
http.server.HTTPServer(('127.0.0.1',int(sys.argv[2])),H).serve_forever()
" "$1" "$2" &
}

# setup_test TEST_DIR API_JSON_FILE STATE_FILE_CONTENT(optional)
# Sets globals: T, API_PORT, MM_PORT, MM_BODY_FILE, T_STATE_FILE
setup_test() {
    local test_dir="$1" api_json="$2" prev_state="${3:-}"
    PORT_BASE=$((PORT_BASE + 2))
    API_PORT=$PORT_BASE
    MM_PORT=$((PORT_BASE + 1))

    T="${WORK_DIR}/${test_dir}"
    MM_BODY_FILE="${T}/mm_body.txt"
    T_STATE_FILE="${T}/.hayahora_last_state"
    mkdir -p "$T"
    cp "$MONITOR_SCRIPT" "$T/hayahora_monitor.sh"
    chmod +x "$T/hayahora_monitor.sh"

    cat > "$T/.env" <<ENV
MATTERMOST_URL=http://127.0.0.1:${MM_PORT}
MATTERMOST_TOKEN=test-tok
MATTERMOST_CHANNEL_ID=ch-test
API_URL=http://127.0.0.1:${API_PORT}
CURL_TIMEOUT=5
STATE_FILE=${T_STATE_FILE}
ENV

    if [[ -n "$prev_state" ]]; then
        echo "$prev_state" > "$T_STATE_FILE"
    fi

    start_mock_api "$api_json" "$API_PORT"
    start_mock_mm "$MM_BODY_FILE" "$MM_PORT"
    sleep 0.4
}

assert_msg_contains() {
    local file="$1" pattern="$2" label="$3"
    if [[ -f "$file" ]] && jq -r '.message' "$file" 2>/dev/null | grep -q "$pattern"; then
        echo "  ✓ ${label}"; PASSED=$((PASSED+1))
    else
        echo "  ✗ ${label} (patrón '${pattern}' no encontrado)"; FAILED=$((FAILED+1))
    fi
}

assert_no_file() {
    local file="$1" label="$2"
    if [[ ! -f "$file" ]]; then
        echo "  ✓ ${label}"; PASSED=$((PASSED+1))
    else
        echo "  ✗ ${label} (fichero existe pero no debería)"; FAILED=$((FAILED+1))
    fi
}

assert_state_file() {
    local file="$1" expected="$2" label="$3"
    if [[ -f "$file" ]] && [[ "$(cat "$file")" == "$expected" ]]; then
        echo "  ✓ ${label}"; PASSED=$((PASSED+1))
    else
        echo "  ✗ ${label} (esperado '${expected}', obtenido '$(cat "$file" 2>/dev/null || echo "<no existe>")')"; FAILED=$((FAILED+1))
    fi
}

assert_file_contains() {
    local file="$1" pattern="$2" label="$3"
    if [[ -f "$file" ]] && grep -q "$pattern" "$file"; then
        echo "  ✓ ${label}"; PASSED=$((PASSED+1))
    else
        echo "  ✗ ${label} (patrón '${pattern}' no encontrado en ${file})"; FAILED=$((FAILED+1))
    fi
}

# ── Test 1: Primera ejecución — bloqueo activo → NOTIFICA ───────────────────
echo "── Test 1: Primera ejecución con bloqueo → notifica ──"
setup_test "t1" "${WORK_DIR}/api_blocked.json"
"$T/hayahora_monitor.sh" 2>&1 | grep -E "(Cambio|BLOQUEO|Finalizado)" || true
sleep 0.3

assert_msg_contains "$MM_BODY_FILE" "LaLiga" "Alerta de bloqueo enviada"
assert_state_file "$T_STATE_FILE" "true" "Estado guardado correctamente"
echo ""

# ── Test 2: Segunda ejecución sin cambios → NO notifica ─────────────────────
echo "── Test 2: Misma ejecución sin cambios → no notifica ──"
setup_test "t2" "${WORK_DIR}/api_blocked.json" "true"
OUTPUT=$("$T/hayahora_monitor.sh" 2>&1) || true
echo "$OUTPUT" | grep -E "(Sin cambios)" || true
sleep 0.3

assert_no_file "$MM_BODY_FILE" "No se envió mensaje (correcto)"
echo ""

# ── Test 3: Transición bloqueado→libre → NOTIFICA ───────────────────────────
echo "── Test 3: Transición bloqueado → libre → notifica ──"
setup_test "t3" "${WORK_DIR}/api_free.json" "true"
"$T/hayahora_monitor.sh" 2>&1 | grep -E "(Cambio|FINALIZADO|Finalizado)" || true
sleep 0.3

assert_msg_contains "$MM_BODY_FILE" "Internet libre" "Mensaje de desbloqueo enviado"
assert_state_file "$T_STATE_FILE" "false" "Estado actualizado a false"
echo ""

# ── Test 4: Transición libre→bloqueado → NOTIFICA ───────────────────────────
echo "── Test 4: Transición libre → bloqueado → notifica ──"
setup_test "t4" "${WORK_DIR}/api_blocked.json" "false"
"$T/hayahora_monitor.sh" 2>&1 | grep -E "(Cambio|BLOQUEO|Finalizado)" || true
sleep 0.3

assert_msg_contains "$MM_BODY_FILE" "LaLiga" "Alerta de bloqueo enviada"
assert_state_file "$T_STATE_FILE" "true" "Estado actualizado a true"
echo ""

# ── Test 5: Sin cambios en estado libre → NO notifica ───────────────────────
echo "── Test 5: Sin cambios en estado libre → no notifica ──"
setup_test "t5" "${WORK_DIR}/api_free.json" "false"
OUTPUT=$("$T/hayahora_monitor.sh" 2>&1) || true
echo "$OUTPUT" | grep -E "(Sin cambios)" || true
sleep 0.3

assert_no_file "$MM_BODY_FILE" "No se envió mensaje (correcto)"
echo ""

# ── Test 6: Sin .env falla correctamente ─────────────────────────────────────
echo "── Test 6: Sin .env debe fallar ──"
T="${WORK_DIR}/t6"; mkdir -p "$T"
cp "$MONITOR_SCRIPT" "$T/hayahora_monitor.sh"; chmod +x "$T/hayahora_monitor.sh"
if OUTPUT=$("$T/hayahora_monitor.sh" 2>&1); then
    echo "  ✗ No debería funcionar sin .env"; FAILED=$((FAILED+1))
else
    echo "$OUTPUT" | grep -q "No se encontró" && { echo "  ✓ Falla correctamente"; PASSED=$((PASSED+1)); } || { echo "  ✗ Error inesperado"; FAILED=$((FAILED+1)); }
fi

echo ""

# ── Test 7: Uptime Kuma — push al haber cambio de estado ────────────────────
echo "── Test 7: Uptime Kuma push tras cambio de estado ──"
setup_test "t7" "${WORK_DIR}/api_blocked.json"
KUMA_PORT=$((PORT_BASE + 2))
KUMA_BODY_FILE="${T}/kuma_body.txt"
start_mock_kuma "$KUMA_BODY_FILE" "$KUMA_PORT"
echo "UPTIME_KUMA_PUSH_URL=http://127.0.0.1:${KUMA_PORT}/api/push/abc?status=up" >> "$T/.env"
sleep 0.3
"$T/hayahora_monitor.sh" 2>&1 | grep -E "(Uptime Kuma|Finalizado)" || true
sleep 0.3

assert_file_contains "$KUMA_BODY_FILE" "ping " "Uptime Kuma recibió el push"
echo ""

# ── Test 8: Uptime Kuma — push también sin cambios de estado ────────────────
echo "── Test 8: Uptime Kuma push aunque no haya cambios ──"
setup_test "t8" "${WORK_DIR}/api_blocked.json" "true"
KUMA_PORT=$((PORT_BASE + 2))
KUMA_BODY_FILE="${T}/kuma_body.txt"
start_mock_kuma "$KUMA_BODY_FILE" "$KUMA_PORT"
echo "UPTIME_KUMA_PUSH_URL=http://127.0.0.1:${KUMA_PORT}/api/push/abc?status=up" >> "$T/.env"
sleep 0.3
"$T/hayahora_monitor.sh" 2>&1 | grep -E "(Sin cambios|Uptime Kuma)" || true
sleep 0.3

assert_no_file "$MM_BODY_FILE" "No se notificó a Mattermost (sin cambios)"
assert_file_contains "$KUMA_BODY_FILE" "ping " "Uptime Kuma recibió el push aunque no hubiera cambios"
echo ""

# ── Test 9: Ntfy — notifica cuando la API falla ─────────────────────────────
echo "── Test 9: Ntfy notifica fallo al contactar con la API ──"
PORT_BASE=$((PORT_BASE + 2))
API_PORT=$PORT_BASE                    # sin mock → connection refused
MM_PORT=$((PORT_BASE + 1))
NTFY_PORT=$((PORT_BASE + 2))

T="${WORK_DIR}/t9"; mkdir -p "$T"
cp "$MONITOR_SCRIPT" "$T/hayahora_monitor.sh"; chmod +x "$T/hayahora_monitor.sh"
MM_BODY_FILE="${T}/mm_body.txt"
NTFY_BODY_FILE="${T}/ntfy_body.txt"
T_STATE_FILE="${T}/.hayahora_last_state"

cat > "$T/.env" <<ENV
MATTERMOST_URL=http://127.0.0.1:${MM_PORT}
MATTERMOST_TOKEN=test-tok
MATTERMOST_CHANNEL_ID=ch-test
API_URL=http://127.0.0.1:${API_PORT}
CURL_TIMEOUT=3
STATE_FILE=${T_STATE_FILE}
NTFY_URL=http://127.0.0.1:${NTFY_PORT}/mi-topic
NTFY_TOKEN=secreto123
ENV

start_mock_mm "$MM_BODY_FILE" "$MM_PORT"
start_mock_ntfy "$NTFY_BODY_FILE" "$NTFY_PORT"
sleep 0.4

"$T/hayahora_monitor.sh" 2>&1 | grep -E "(ERROR|API)" || true
sleep 0.3

assert_file_contains "$NTFY_BODY_FILE" "TITLE=hayahora_monitor" "Ntfy recibió notificación con título"
assert_file_contains "$NTFY_BODY_FILE" "consulta a la API" "Ntfy incluye el paso que falló"
assert_file_contains "$NTFY_BODY_FILE" "AUTH=Bearer secreto123" "Ntfy recibe token Bearer"
echo ""

# ── Test 10: Ntfy — sin NTFY_URL no se envía nada ──────────────────────────
echo "── Test 10: Sin NTFY_URL no se envía notificación de fallo ──"
PORT_BASE=$((PORT_BASE + 2))
API_PORT=$PORT_BASE                    # sin mock → connection refused
MM_PORT=$((PORT_BASE + 1))

T="${WORK_DIR}/t10"; mkdir -p "$T"
cp "$MONITOR_SCRIPT" "$T/hayahora_monitor.sh"; chmod +x "$T/hayahora_monitor.sh"
MM_BODY_FILE="${T}/mm_body.txt"
T_STATE_FILE="${T}/.hayahora_last_state"

cat > "$T/.env" <<ENV
MATTERMOST_URL=http://127.0.0.1:${MM_PORT}
MATTERMOST_TOKEN=test-tok
MATTERMOST_CHANNEL_ID=ch-test
API_URL=http://127.0.0.1:${API_PORT}
CURL_TIMEOUT=3
STATE_FILE=${T_STATE_FILE}
ENV

start_mock_mm "$MM_BODY_FILE" "$MM_PORT"
sleep 0.4

if OUTPUT=$("$T/hayahora_monitor.sh" 2>&1); then
    echo "  ✗ Debería haber fallado"; FAILED=$((FAILED+1))
else
    echo "$OUTPUT" | grep -q "ERROR" && { echo "  ✓ El script falló como se esperaba"; PASSED=$((PASSED+1)); } || { echo "  ✗ No loguea ERROR"; FAILED=$((FAILED+1)); }
fi
echo ""

echo "========================================"
printf " Resultados: %d pasados, %d fallidos\n" "$PASSED" "$FAILED"
echo "========================================"
[[ $FAILED -eq 0 ]] && exit 0 || exit 1
