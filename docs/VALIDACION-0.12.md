# Candidato 0.12 · compilación 86

Código `f1eafea6059ff9dc526b83d40f201bd535330edf`. La aplicación sigue **sin instalar ni probar en el iPhone**. Los puntos anteriores 0.10 build81 y 0.11 build84 se conservan por separado.

[La compilación](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40190915296) completó Xcode, las seis suites de procesamiento y los DEB rootless y RootHide. Se inspeccionaron los archivos reales del paquete: control, rutas, manifiestos, Mach-O, versión mínima, firma ad hoc, permisos y licencia/avisos de la adaptación de Google. Las dos variantes contienen el mismo ejecutable.

[La interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40190916873) usa el mismo commit de código y completó tres casos compuestos con cero fallos en 137,961 s. Incluye activar la nueva fusión espectral, controles/perfiles/color, herramientas del visor, entrada/salida de modos guiados y preferencias compartidas con Vídeo. No generó fotos, grabaciones ni eventos de botones físicos.

## Fusión espectral

Cinco casos se comparan con las funciones numéricas de `google/burst-denoising` fijadas en `7ff07e009568778ff337c259e192d1d81aedbea6`, ejecutadas con NumPy. El fixture puede regenerarse de forma idéntica byte a byte. No importa scripts de entrenamiento ni modelos. Los resultados de Swift/Accelerate tienen un error máximo de `8,940697e-8` respecto a esa referencia.

En el fixture sintético de dos imágenes, la región estática pasa de RMSE `0,0197670443` a `0,0152956085`. El patrón fino que cambia entre imágenes conserva un contraste de `0,5018861`, frente a `0,0012215509` con la máscara espacial gruesa anterior. La prueba completa del procesador fusiona `2/2` imágenes mediante FFT; también pasan identidad/bordes, cancelación, límites y serialización de opciones.

Estos números describen fixtures, no escenas del teléfono. No prueban mejor calidad en todas las situaciones. La adaptación sigue desactivada por defecto, trabaja con RGB lineal revelado y limita el lado largo a 2048 px. No es una fusión Bayer calibrada ni el motor propietario de Google Camera. Véase [algoritmo y procedencia](FUSION-ESPECTRAL-0.12.md).

## Paquetes

| Esquema | Versión | SHA-256 |
| --- | --- | --- |
| App rootless | `0.12.0+build.86.git.f1eafea` | `8dfd82a5b91bafcc7810bb073803d9017370f88a8b17d094e2b3137c77ed78ce` |
| App RootHide | `0.12.0+build.86.git.f1eafea` | `7b1f96e385310e5938d7a5814278300ffc252ac3d3c511225deb97fa6951a1dd` |

Native Night no ha cambiado desde `8ac1c15`, compilación 3. Se conservan las variantes comprobadas en [0.10](VALIDACION-0.10.md); esta etapa no las instala ni confirma su carga bajo RootHide. No se ha forzado Noche ni enviado señales/solicitudes de captura al dispositivo.

## Pendientes

Las seis suites pasan: `PortChecks`, `ProcessorChecks`, `MovieChecks`, `PanoramaChecks`, `SphereChecks` y `SpectralChecks`. La primera ejecución de 0.12 no pasó la aserción de integración, aunque sí la paridad FFT; no se cuenta como válida. El candidato final mantiene la aserción de dos imágenes fusionadas y usa una textura sintética no periódica para evitar un registro ambiguo.

La [matriz del port](ESTADO-DEL-PORT-0.12.md) distingue funciones implementadas y ausentes. Siguen pendientes la carga RootHide, sesiones/permisos, RAW y Fotos, enfoque/exposición, orientación/espejo/botones, vídeo, segmentación real, panorama/esfera y la comparación nocturna controlada con Cámara de Apple. La nueva FFT necesita medir tiempo, memoria, temperatura y efecto sobre ruido, color y detalle en el iPhone. Compilar y empaquetar no acredita esa calidad.
