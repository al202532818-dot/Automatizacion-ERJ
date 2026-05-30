#!/bin/bash

# Obtener lista de directorios en el nivel superior

directorio=$(ls ../)

# Obtener espacio disponible en disco (en GB)

peso=$(df -h / | awk 'NR==2 {print $4}' | sed 's/G//')

echo "Directorio: $directorio"
echo "Espacio disponible: $peso GB"

# Evaluar condiciones

if (( $(echo "$peso > 5" | bc -l) )); then
    mkdir -p primer_carpeta
    touch primer_carpeta/primer_archivo
    echo "$directorio" > primer_carpeta/primer_archivo
    echo "Se creó la carpeta y archivo porque hay suficiente espacio."
elif (( $(echo "$peso == 11" | bc -l) )); then
    echo "Se tiene espacio suficiente, pero queremos poner un elif en la condición."
else
    echo "Sin espacio suficiente."
fi

# Listar contenido y tamaño de cada directorio

cd ../
for i in $directorio; do
    echo "Contenido de $i:"
    ls -larth "$i"
    du -sh "$i"
done