# Cambios posteriores al candidato 0.10

La versión 0.10 build81 y sus informes se conservan como punto de recuperación. Estos cambios pertenecen a 0.11 y necesitan su propia compilación y registro de pruebas; no heredan automáticamente los resultados de la entrega anterior.

## Orientación de los archivos

Foto y Vídeo consultan el coordinador de rotación de AVFoundation para la cámara activa, sin intercambiar manualmente las orientaciones de la cámara frontal. Se elige el eje cardinal próximo y se fija al comenzar la transacción: todas las fotos de una pila/horquillado y todo un clip comparten la misma geometría. El visor y los controles continúan en disposición vertical. Panorama/Esfera conservan su captura vertical guiada y la convención de pose del cosido.

No se cambia la orientación mientras llega una pila ni se vuelve a capturar para corregirla. Si la conexión rechaza el ángulo, se muestra la causa antes de enviar la petición. El coordinador se libera al abandonar el modo; se vuelve a preparar cuando la cámara regresa al primer plano. Las dimensiones mostradas del vídeo incluyen su `preferredTransform`, en lugar de confundir el tamaño del sensor codificado con el de reproducción.

## Botones de volumen y selfies

La preferencia **Disparar con botones de volumen** utiliza `onCameraCaptureEvent` de AVKit/SwiftUI. Una pulsación terminada activa el mismo camino que el botón visible: Foto/temporizador, iniciar/detener Vídeo o añadir una vista guiada si está lista. Los eventos de inicio/cancelación no disparan. Se deshabilita al procesar, guardar, revisar, mostrar ajustes/diálogos o perder el primer plano. Deshabilitar la interacción devuelve el comportamiento normal del sistema; no se vigila el volumen mediante KVO ni se simulan pulsaciones.

La preferencia **Guardar selfies reflejadas**, desactivada por defecto, afecta solo a la captura frontal y se fija al iniciar la foto o clip. En las cámaras traseras no refleja la imagen. Un temporizador conserva la opción elegida cuando empezó. Los controles aparecen en Captura y en los ajustes de Vídeo; se comparten mediante una preferencia propia, separada de los perfiles de color.

Panorama y Esfera permiten enfocar/medir antes de su primera vista. Después mantienen los bloqueos necesarios para la unión; sus visores ya no muestran gestos de zoom o de bloqueo manual que no implementan. La revisión de la esfera sigue teniendo su propio gesto de zoom, independiente de la cámara.

## Verificación

`MovieChecks` genera un MOV con transformación de giro y utiliza el inspector real de producción para comprobar el tamaño de reproducción. `PortChecks` edita imágenes con las cuatro orientaciones EXIF reflejadas y comprueba geometría, contenido y orientación final 1, evitando reflejar/rotar dos veces al guardar metadatos. El informe de cada candidato debe identificar el commit exacto y las pruebas que pasaron.

El simulador no valida botones físicos, sensores de orientación, espejo real JPEG/DNG ni cambios de orientación del dispositivo. Estas comprobaciones se mantienen aplazadas, sin conectar con el iPhone ni instalar esta versión.

Referencias: [rotación de captura](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator), [eventos de botones físicos](https://developer.apple.com/documentation/avkit/avcaptureeventinteraction) y [su integración SwiftUI](https://developer.apple.com/documentation/swiftui/view/oncameracaptureevent(isenabled:action:)).
