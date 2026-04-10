# monitor-hay-futbol

Monitor de bloqueos de LaLiga que consulta la API de [hayahora.futbol](https://hayahora.futbol) y notifica en Mattermost cuando el estado cambia (bloqueo activo / Internet libre).

## Cómo funciona

1. Consulta `https://hayahora.futbol/estado/data.json`
2. Para cada ISP, calcula el porcentaje de IPs bloqueadas
3. Si algún ISP supera el umbral (por defecto 50%), se considera bloqueo activo
4. Solo notifica cuando el estado **cambia** (de bloqueado a libre o viceversa)

Cuando LaLiga bloquea, >90% de las IPs se bloquean simultáneamente. Las IPs sueltas que quedan en `true` tras un partido son ruido residual que el umbral filtra.

## Requisitos

- `bash`, `curl`, `jq`

## Configuración

```bash
cp env.example .env
# Editar .env con los datos de tu instancia de Mattermost
```

Variables requeridas:

| Variable | Descripción |
|---|---|
| `MATTERMOST_URL` | URL base de Mattermost (sin `/` final) |
| `MATTERMOST_TOKEN` | Token de bot o token personal |
| `MATTERMOST_CHANNEL_ID` | ID del canal donde publicar |

Variables opcionales:

| Variable | Default | Descripción |
|---|---|---|
| `API_URL` | `https://hayahora.futbol/estado/data.json` | URL de la API |
| `CURL_TIMEOUT` | `15` | Timeout de curl en segundos |
| `BLOCK_THRESHOLD_PCT` | `50` | % mínimo de IPs bloqueadas en un ISP para considerar bloqueo real |

## Uso

```bash
# Ejecución manual
./hayahora_monitor.sh

# Con cron (cada 3 minutos)
*/3 * * * * /ruta/a/hayahora_monitor.sh >> /var/log/hayahora.log 2>&1
```

## Tests

```bash
bash test_hayahora_monitor.sh
```
