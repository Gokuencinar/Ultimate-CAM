# Noche, procesado iOS y estado del port · 0.7

## Uso del procesado de Apple

La revisión detectó que todas las peticiones usaban `.speed`, incluidas fotos individuales automáticas. Desde 0.7, **Calidad iOS** es el valor inicial para una foto JPEG automática. Se puede seleccionar Rapidez o Equilibrado. El preset «Foto con procesado de iOS» restablece controles automáticos y selecciona Calidad.

Se conserva `.speed` para RAW, pilas, HDR, Noche propia y exposición personalizada o bloqueada. Esas rutas requieren una exposición controlada por petición. La sesión ya prepara recursos hasta `.quality`; no se cambia ese máximo en mitad de una captura.

Según [Apple, WWDC21](https://developer.apple.com/videos/play/wwdc2021/10247/), la prioridad es una indicación: AVFoundation decide qué algoritmo usar según escena, dispositivo y formato. La petición `.quality` no selecciona ni garantiza Deep Fusion, Smart HDR o el modo Noche de la app Cámara. En la documentación pública revisada no se ha encontrado un selector para integrar ese modo Noche completo en una app independiente. No se han inventado selectores privados ni hooks sin firmas verificadas.

## Fotografías del modo Noche de Cámara

El botón de galería permite importar una imagen elegida con el selector de Fotos, sin solicitar acceso de lectura a toda la fototeca. El panel Procesado explica cómo tomar una foto en Cámara de Apple e importarla para aplicar las recetas de Ultimate CAM. Es interoperabilidad con una foto ya tomada; no captura nativa integrada.

- Entrada hasta 24 MP y 48 MB, validación de formato, dimensiones y estado completo.
- JPEG sin ajustes: se conserva byte a byte. No se han validado sus recursos HDR incorporados.
- HEIF/PNG y demás imágenes renderizadas: referencia convertida a JPEG; edición con orientación aplicada y resolución conservada dentro del límite de entrada.
- Edición: utiliza los controles JPEG existentes. No activa captura, fusión nocturna, bracketing ni RAW por importar con un perfil Noche/HDR seleccionado.
- RAW importado: rechazado con explicación; no se presenta un revelado genérico como calibración iPhone/Google.
- Al editar o convertir se produce JPEG SDR, sin gain map HDR. El original de Fotos no se modifica. El guardado de una nueva versión sigue siendo explícito.
- Progreso, cancelación cooperativa, límite de espera y errores visibles. Solo se sustituye el resultado anterior tras una importación satisfactoria.

## Fusión nocturna ponderada

La ruta anterior sustituía muestras rechazadas por la referencia y después promediaba todos los fotogramas. Cada rechazo podía volver a introducir la misma muestra ruidosa de referencia. La nueva ruta acumula un peso por píxel:

`media_nueva = (media × peso_acumulado + muestra × peso_nuevo) / (peso_acumulado + peso_nuevo)`.

El rechazo se calcula sobre diferencias RGB suavizadas y una estimación robusta del residuo. Una muestra rechazada añade peso cero. Se materializan media y pesos después de cada paso; no se conserva un grafo de todos los fotogramas revelados. Son dos búferes acumulados y más trabajo que la media anterior: consumo y tiempo reales todavía deben medirse.

La opción se aplica a Noche JPEG o DNG revelado y se puede desactivar. La cifra de fotogramas alineados no implica que todos los píxeles reciban contribución de todos ellos. Esta técnica propia no es el filtro Wiener de Google, fusión Bayer ni un modelo de ruido calibrado.

Noche permite elegir hasta 2/4/8/16 segundos de integración solicitada y un límite por foto entre 1/30 y 1 segundo, con un máximo de 16 fotogramas y los límites de la lente. La medición puede producir una duración total menor; entrega y procesado aumentan el tiempo transcurrido. Acortar la exposición puede dejar la imagen oscura si el ISO llega a su máximo. No se ha añadido detección de movimiento de sujetos.

## Condiciones para acreditar el port completo

La [explicación de Night Sight de Google](https://research.google/blog/night-sight-seeing-in-the-dark-on-pixel-phones/) describe medición de movimiento, selección de exposiciones, fusión robusta y balance de blancos aprendido. Compartir nombres o número de imágenes no demuestra esas cualidades.

| Familia | Estado real tras esta etapa |
|---|---|
| Captura, manuales, JPEG/RAW y guardado | Código existente; los resultados históricos del iPhone no validan las nuevas versiones. |
| Controles y apariencia AGC | Adaptación de XML, paleta, HSL/curvas/ruedas y perfiles. Falta comparación con Android ejecutándose y estados completos. |
| Calidad de iOS | Ruta de prioridad real añadida; algoritmo elegido por el sistema y calidad física pendientes. |
| Noche de Apple | Importación de su imagen renderizada, sin integración directa del motor privado. |
| Noche propia | Planificación estática, alineación, fusión ponderada y tono. Sin medición óptica de movimiento ni AWB aprendido. |
| RAW/Bayer, HDR+ y HDRnet | No portados. El APK usa JNI/ELF y código decompilado con métodos omitidos; hace falta reconstrucción y calibración del sensor, no solo traducción de nombres. |
| Ultra HDR y modelos | Pendientes de implementación, formatos y validación. No se redistribuyen bibliotecas ni modelos del APK. |
| Vídeo, panoramas, Photo Sphere y retrato | No implementados. No se muestran botones que simulen esas funciones. |
| Misma calidad que GCam | Sin acreditar: requiere fotografías comparables, referencias, medición de detalle/ruido/color/movimiento y valoración visual. |

Las pruebas funcionales del iPhone siguen aplazadas por el usuario. jb-p1lot permite consultar estado, transferir e instalar paquetes sin abrir Ultimate CAM; estar conectado con UID 0 no elimina la necesidad de calibración y pruebas físicas. No se declara completado el objetivo global.
