# Comprobación física de 0.10 · pendiente

Este documento prepara la siguiente fase. No registra pruebas realizadas ni autoriza ejecutar capturas ahora. El usuario ha solicitado terminar primero el trabajo fuera del dispositivo. Los paquetes, fuentes y logs exactos del candidato deben conservarse antes de empezar.

## Arranque y cambio de modo

Verificar el jailbreak real tras la migración y seleccionar el esquema correspondiente. Separar instalación del DEB, carga de la app y carga del complemento en Cámara: cada una requiere su propia evidencia. Confirmar versión/hash y abrir la app con el teléfono desbloqueado cuando se inicie la fase física.

Recorrer Foto → Vídeo → Foto, Foto → Panorama → Foto y Foto → Esfera → Foto. Repetir tras usar ISO/obturación/WB manuales. Observar que no quede zoom, exposición o WB retenido por otra sesión y que Foto vuelva a medir. No deducir funcionamiento del sensor de una animación o un callback del controlador.

## Foto, guardado y retrato

Una captura identificada por caso, sin reintentos automáticos. JPEG y JPEG+DNG en cada lente que anuncie RAW; revisar orientación y foco real y conservar metadatos. Guardar un resultado RAW y uno editado: verificar el elemento creado, el recurso DNG alternativo y el JPEG ajustado en Fotos. Confirmar que una segunda pulsación no duplique una transacción confirmada.

Retrato necesita una persona real, bordes finos y fondo con textura. Comparar intensidad cero/media/alta. Revisar pelo, huecos entre brazos, contorno y color del fondo cerca del sujeto. Un fixture con una máscara sintética no sustituye esta evaluación ni demuestra que el modelo identifique correctamente a la persona.

## Noche y HDR

Usar trípode o apoyo y una escena inmóvil con detalles a más de un metro, zonas oscuras y una luz pequeña. Conservar encuadre, iluminación y lente 1× durante las comparaciones. Fotografiar con Noche propia JPEG, Noche DNG y Noche nativa; guardar los originales y los registros de exposición real por foto, duración total y fotogramas aceptados. No igualar el presupuesto solicitado con el tiempo de exposición que realmente devuelve el sensor.

Evaluar detalle, ruido cromático, dominantes, luces, fantasmas y aspecto general a un tamaño de salida comparable. Las medidas de diferencias entre fotos con procesados distintos no son por sí solas una medida de ruido ni de calidad. La valoración del usuario y los archivos originales siguen siendo necesarios. La calibración RAW requiere más de una lente/ISO y un único DNG histórico no basta.

Para HDR, comprobar las tres exposiciones y leer el mapa auxiliar del archivo exportado; después revisar su presentación en Fotos y una exportación del recurso original. Distinguir disponibilidad del mapa, guardado y presentación HDR real. Comprobar también que los datos de lente, fecha, exposición de referencia, tamaño y orientación del JPEG editado sean coherentes.

El complemento Noche debe confirmar solo la solicitud vigente, respetar soporte/lente/modo y devolver el ajuste anterior al cancelar/caducar/regresar. La confirmación del ajuste del controlador no equivale a que una foto se haya disparado ni a su calidad.

## Vídeo y modos guiados

Vídeo: empezar por 1080p30 y un clip corto. Comprobar resolución, FPS medios/temporización, códec, orientación y pista de audio del MOV real; reproducir y guardar en Fotos. Probar 4K/60 solo si el formato lo anuncia, antorcha y enfoque. Una combinación incompatible debe conservar el estado anterior y mostrar la causa. Interrumpir una grabación pasando a segundo plano; verificar archivo conservado y recuperación, sin una grabación nueva automática. Revisar consumo antes de alargar clips.

Panorama: escena lejana con textura, sin primer plano cercano, 40–60 % de solapamiento; comenzar con dos fotos. Revisar alineación real, bordes, geometría y recorte. Probar después giro más largo y error de falta de solapamiento sin perder las fotos conservadas en memoria.

Esfera: teléfono girando alrededor del centro óptico, primeras vistas al horizonte, luego filas y polos. Medir campo de visión del formato, orientación y deriva; comprobar los 62 objetivos y que las vistas asociadas correspondan al instante del disparo. Revisar cobertura, costura y polos en el visor 360° y en un lector GPano. Una esfera interrumpida no debe mezclar orientaciones de una sesión nueva; las vistas no sobreviven a terminar el proceso.

## Coste y registro

Comprobar alineación de las superposiciones del visor y activar las herramientas una a una. Medir uso de memoria, temperatura y tiempo con el mismo caso base y con color/LUT. Registrar errores e interrupciones concretos antes de repetir el caso. Cerrar la fase con un informe que distinga resultado observado, reparación propuesta y lo que sigue sin comprobar.
