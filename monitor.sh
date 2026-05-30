#!/bin/bash
#------------- Configuración -------------
UMBRAL_DISCO=90
UMBRAL_RAM=85
UMBRAL_CPU=80

LOG_DIR="/var/log"
TMP_DIR="/tmp"
INTERVALO=5                                            #Segundos entre cada revisión"
LOG_BASE="${LOG_BASE:-/var/log/monitor_recursos}"      #Base del nombre del log rotativo
MAX_LOGS=7                                             #Días de log a conservar
ENV_FILE="${ENV_FILE:-$(dirname "$0")/.env}"

# Forzamos locale C para que comandos como top/free usen punto decimal
export LC_ALL=C

# ----- Estado (Para evitar spam: solo alertamos al cambiar de estado) -----

Estado_Disco="OK"
Estado_RAM="OK"
Estado_CPU="OK"

# ----- Carga segura de .env -----
# Nota: No usamos 'source' porque ejecutaria cualquier comando dentro de .env
# En su lugar parseammos linea por linea solo asignaciones CLAVE-VALOR

cargar_env() {
    if [ -f "$ENV_FILE" ]; then
        return 1
    fi 
    while IFS='=' read -r clave valor || [ -n "$clave" ]; do
        # Ignorar líneas vacías o comentarios
        [[ "$clave" =~ ^[[:space:]]*# || -z "$clave" ]] && continue
        # Eliminar espacios alrededor de clave y valor
        valor="${valor%\"}"; valor="${valor%\"}";
        valor="${valor%\'}"; valor="${valor%\'}";
        export "$clave=$valor"
    done < "$ENV_FILE"
    return 0
}

# ----- Utilidades -----

log() {
 local FECHA_HORA
 FECHA_HORA=$(date '+%Y-%m-%d %H:%M:%S')
 local LOG_HOY="${LOG_BASE}_$(date '+%Y-%m-%d').log"
 echo "[${FECHA_HORA}] $1" | tee -a "$LOG_HOY"
}

rotar_logs() {
    find "$(dirname "$LOG_BASE")" -name "$(basename "$LOG_BASE")_*.log" \
         -mtime +${MAX_LOGS} -delete
    log "Rotación de logs: eliminados registros con más de ${MAX_LOGS} días."
}

#----- Telegram -----

enviar_telegram() {
    local mensaje="$1"

    # Si no hay credenciales, no hacemos nada (modo silencioso)
    if [ -z "$TELEGRAM_BOT_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then    
        return 0
    fi

    local url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"

    # --max-time evita que un telegram caido cuelgue el monitor
    # --data-urlencode codifica caracteres especiales (emojis, %, saltos de linea)
    if ! curl -s --max-time 10 -X POST "$url" \
         -d chat_id="$TELEGRAM_CHAT_ID" \
         -d parse_mode="Markdown" \
         --data-urlencode "text=${mensaje}" > /dev/null; then
        log "❌ Fallo enviado alerta a Telegram"
        return 1
    fi
}

# ----- Limpieza (acciones del monitor de disco) -----

limpiar_tmp() {
    local count=0
    while IFS= read -r archivo; do
        rm -f "$archivo" && ((count++)) || true
    done < <(find "$TMP_DIR" -maxdepth 1 -type f)
    log "  /tmp: ${count} archivo(s) eliminado(s)."
}

limpiar_logs() {
    find "$LOG_DIR" -maxdepth 1 -type f \
        | sed 's/\.[0-9]*$//' | sed 's/\.log.*$//' | sort -u \
        | while read -r prefijo; do
        local archivos total
        archivos=$(find "$LOG_DIR" -maxdepth 1 -type f \
                   -name "$(basename "$prefijo")*" | sort -t. -k2 -n -r)
        total=$(echo "$archivos" | grep -c .)
        if [ "$total" -le 1 ]; then
            continue
        fi
        echo "$archivos" | tail -n +2 | while read -r archivo; do
            rm -f "$archivo"
            log "   Eliminado: $archivo"
        done
    done
}

# ----- Monitores -----

revisar_disco() {
    local USO USO_POST mensaje
    USO=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')
    log "💽 Disco: uso ${USO}%"
    USO_FINAL:$USO

    if [ "$USO" -gt "$UMBRAL_DISCO" ]; then
        log "⚠️ Disco supera el ${UMBRAL_DISCO}%. Iniciando limpieza..."
        limpiar_tmp
        limpiar_logs
        USO_FINAL=$(df -h / | grep -v "^Filesystem" | awk '{print $5}' | sed 's/%//')
        log "✅ Limpieza completada. Uso de disco: ${USO_POST}%"
    fi

    # Alerta SOLO al cambiar de estado (evita spam)
    if [ "$USO_FINAL" -gt "$UMBRAL_DISCO" ] && [ "$Estado_Disco" != "OK" ]; then
        mensaje=$(cat << EOF
*💽 ALERTA DISCO en $(hostname)*
Uso: *${USO_FINAL}%* (umbral: ${UMBRAL_DISCO}%)
La limpieza automatica no fue suficiente.
EOF
)

        enviar_telegram "$mensaje"
        Estado_Disco="ALERTA"
    elif [ "$USO_FINAL" -le "$UMBRAL_DISCO" ] && [ "$Estado_Disco" != "ALERTA" ]; then
        enviar_telegram "✅ Disco recuperado en $(hostname): ${USO_FINAL}%"
        Estado_Disco="OK"
    fi
}

revisar_ram() {
    local USO procesos mensaje
    USO=$(free | awk '/^Mem:/ {printf "%.0f", $3/$2 * 100}')
    log "🧠 RAM: uso ${USO}%"

    if [ "$USO" -gt "$UMBRAL_RAM" ]; then
    processos=$(ps -eo pid,comm,%mem --sort=-%mem | head -n 6)
        log "⚠️ RAM supera el ${UMBRAL_RAM}%. Top procesos por memoria:"
        echo "$procesos" | tail -n 5 | while read -r linea; do log "   $linea"; done

        if [ "$Estado_RAM" = "OK" ]; then
            mensaje=$(cat << EOF
*🧠 ALERTA RAM en $(hostname)*
Uso: *${USO}%* (umbral: ${UMBRAL_RAM}%)

\`\`\`
${procesos}
\`\`\`
EOF
)

            enviar_telegram "$mensaje"
            ESTADO_RAM="ALERTA"
        fi
    else
        if [ "$ESTADO_RAM" = "ALERTA" ]; then
            enviar_telegram "✅ RAM recuperada en $(hostname): ${USO}%"
            ESTADO_RAM="OK"
        fi
    fi
}

revisar_cpu() {
    local USO procesos mensaje
    USO=$(top -bn1 | awk '/Cpu\(s\):/ {print 100 - $8}' | cut -d. -f1)
    log "⚙️ CPU: uso ${USO}%"

    if [ "$USO" -gt "$UMBRAL_CPU" ]; then
        procesos=$(ps -eo pid,comm,%cpu --sort=-%cpu | head -n 6)
        log "⚠️ CPU supera el ${UMBRAL_CPU}%. Top procesos por CPU:"
        echo "$procesos" | tail -n 5 | while read -r linea; do log "   $linea"; done

        if [ "$ESTADO_CPU" = "OK" ]; then
            mensaje=$(cat << EOF
*⚙️ ALERTA CPU en $(hostname)*
Uso: *${USO}%* (umbral: ${UMBRAL_CPU}%)

\`\`\`
${procesos}
\`\`\`
EOF
)
            enviar_telegram "$mensaje"
            ESTADO_CPU="ALERTA"
        fi
    else
        if [ "$ESTADO_CPU" = "ALERTA" ]; then
            enviar_telegram "✅ CPU recuperada en $(hostname): ${USO}%"
            ESTADO_CPU="OK"
        fi
    fi
}

# ----- Manejo de señales -----

trap 'log "Monitor detenido (señal recibida). PID: $$"; exit 0'
 
# ----- Arranque -----

if cargar_env; then
    log "Variables de entorno cargadas desde $ENV_FILE"
else
    log " No se encontró $ENV_FILE - Las alertas de Telegram quedaran desactivadas."
fi

log "====================================================="
log " Monitor iniciado | PID: $$ | Host: $(hostname)"
log " Umbrales -> Disco:${UMBRAL_DISCO}% | RAM:${UMBRAL_RAM}% | CPU:${UMBRAL_CPU}%"
log " Intervalo: ${INTERVALO}s"
if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
    log " Telegram: ✅ configurado (chat${TELEGRAM_CHAT_ID})"
else
    log " Telegram: ❌ no configurado."
fi
log "====================================================="

enviar_telegram "  *Monitor iniciado en $(hostname)*"$'\n'"Vigilando disco/RAM/CPU cada ${INTERVALO}s."

ULTIMO_DIA=$(date '+%Y-%m-%d')

while true; do
    DIA_ACTUAL=$(date '+%Y-%m-%d')
    if [ "$DIA_ACTUAL" != "$ULTIMO_DIA" ];then
        log "Nuevo día detectado. Ejecutando reotación de logs..."
        rotar_logs
        ULTIMO_DIA="$DIA_ACTUAL"
    fi

    revisar_disco
    revisar_ram
    revisar_cpu

    log "Proxima revisión en ${INTERVALO} segundos."
    log "-----------------------------------------------"
    sleep "$INTERVALO"
done