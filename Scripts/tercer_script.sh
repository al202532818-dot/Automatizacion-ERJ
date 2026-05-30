#!/bin/bash

UMBRAL_Disco=90
LOG_DIR="/var/log"
TMP_DIR="/tmp"
INTERVALO=50
LOG_BASE="/var/log/monitor_disco"
MAX_LOGS=7

log() {
    local FECHA_HORA
    FECHA_HORA=$(date +'%Y-%m-%d %H:%M:%S')
    local LOG_HOY="${LOG_BASE}_$(date +%Y-%m-%d).log"
    echo "[${FECHA_HORA}] $1" | tee -a "$LOG_HOY"
}

rotar_logs() {
    find "$(dirname "$LOG_BASE")" -name "monitor_disco_*.log" -mtime +${MAX_LOGS} -delete
    log "Rotación de logs: eliminados registros con más de ${MAX_LOGS} días."
}

limpiar_tmp() {
    local count=0
    while IFS= read -r archivo; do
        rm -f "$archivo" && ((count++))
    done < <(find "$TMP_DIR" -maxdepth 1 -type f)
    log "Limpieza /tmp: ${count} archivo(s) eliminado(s)."
}

limpiar_logs() {
    find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" | \
    sed 's/\.[0-9]*$//' | sed 's/\.log.*$//' | sort -u | while read -r prefijo; do

        local archivos total
        archivos=$(find "$LOG_DIR" -maxdepth 1 -type f -name "$(basename "$prefijo")*" | sort -t. -k2 -n -r)
        total=$(echo "$archivos" | grep -c '^')

        if [ "$total" -le 1 ]; then
            continue
        fi

        echo "$archivos" | tail -n +2 | while read -r archivo; do
            rm -f "$archivo"
            log "Eliminando: $archivo"
        done
    done
}

# Inicio del script

log "================================================="
log "Monitor iniciado | PID: $$ | Umbral: ${UMBRAL_Disco}%"
log "================================================="

ULTIMO_DIA=$(date '+%Y-%m-%d')

while true; do
    DIA_ACTUAL=$(date '+%Y-%m-%d')
    
    if [ "$DIA_ACTUAL" != "$ULTIMO_DIA" ]; then
        log "Nuevo día detectado. Ejecutando rotación de logs..."
        rotar_logs
        ULTIMO_DIA="$DIA_ACTUAL"
    fi

    # Uso del disco en porcentaje (sin el símbolo %)
    USO=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')

    log "Revisión del disco: uso actual ${USO}%"

    if [ "$USO" -gt "$UMBRAL_Disco" ]; then
        log "Alerta: uso supera el ${UMBRAL_Disco}%. Iniciando limpieza..."
        
        limpiar_tmp
        limpiar_logs

        USO_POST=$(df -h / | awk 'NR==2 {print $5}' | sed 's/%//')
        log "Limpieza completada. Uso después: ${USO_POST}%"
    else
        log "Uso dentro del límite, sin acción requerida."
    fi

    log "Próxima revisión en ${INTERVALO} segundos."
    log "----------------------------------------------"

    sleep "$INTERVALO"
done