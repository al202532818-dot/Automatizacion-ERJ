#!/bin/bash

path="carpeta2"
file="archivo2.log"
ruta="$path/$file"

# Verificar si la carpeta existe, si no, crearla

if [[ ! -d "$path" ]]; then
    mkdir "$path"
fi

# Verificar si el archivo existe, si no, crearlo

if [[ ! -f "$ruta" ]]; then
    touch "$ruta"
fi

# Bucle infinito que escribe la fecha cada 5 segundos

while true; do
    fecha=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$fecha" >> "$ruta"
    sleep 5
done