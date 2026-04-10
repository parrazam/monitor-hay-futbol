# CLAUDE.md

Script bash que monitoriza bloqueos de LaLiga via la API de hayahora.futbol y notifica en Mattermost.

## Estructura

- `hayahora_monitor.sh` — Script principal. Consulta la API, evalúa el estado por proporción de IPs bloqueadas por ISP y notifica en Mattermost solo cuando hay cambio de estado.
- `test_hayahora_monitor.sh` — Tests de integración. Levanta servidores HTTP mock (API + Mattermost) y verifica transiciones de estado.
- `env.example` — Plantilla de configuración.
- `.env` — Configuración real (no en git).
- `.hayahora_last_state` — Fichero de estado con `true` o `false` (no en git).

## Lógica de detección

El bloqueo se determina por **proporción**: para cada ISP se calcula el % de IPs con `stateChanges[-1].state == true`. Si algún ISP supera `BLOCK_THRESHOLD_PCT` (default 50%), hay bloqueo. Las IPs sueltas residuales no disparan alertas.

## Tests

```bash
bash test_hayahora_monitor.sh
```

Los tests usan servidores Python mock y no necesitan credenciales reales.
