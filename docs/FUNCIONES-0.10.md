# Ultimate CAM 0.10: implementación y límites

Esta versión amplía la cámara propia y añade paquetes separados para Dopamine rootless y RootHide. La compilación y los fixtures se verifican fuera del iPhone. La instalación, carga del complemento bajo RootHide, captura y calidad fotográfica quedan para la fase física solicitada por el usuario.

## Modos y procesamiento

| Familia de la referencia Android | Implementación iOS | Qué falta para equipararla |
| --- | --- | --- |
| Foto y RAW | AVFoundation; prioridad de calidad seleccionable, JPEG y DNG original, enfoque/medición por toque, bloqueo AF/AE, ISO/obturación/WB/zoom manuales según lente | Caracterización de cada sensor y comparación óptica |
| HDR | Tres exposiciones ±1/2/3 EV, registro, rechazo y mezcla de radiancia aproximada; JPEG adaptativo con mapa HDR opcional | Fusión Bayer, exposición y respuesta radiométrica calibradas; no es HDR+ ni HDRnet |
| Noche | Planificador de 3–16 fotos, presupuesto de 2/4/8/16 s, límite por foto hasta 1 s condicionado al formato; revelado DNG opcional, media lineal con pesos por píxel, alineación global/local y rechazo adaptativo | Medición de movimiento antes de disparar, calibración RAW/ruido/color en oscuridad y evaluación de sujetos móviles |
| Noche de Apple | Complemento separado en Cámara de Apple; solicitud expirable de Noche máximo, comprobación del soporte y restauración del ajuste anterior | Nuevo jailbreak y ruta completa de ida/vuelta pendientes. No se ha integrado el pipeline privado de Apple dentro del visor propio |
| Color | HSL, curvas RGB, ruedas por zonas, exposición/gamma/luces/sombras, ruido cromático, contraste local, textura, enfoque, vibrance, dehaze, grano y viñeta | Los operadores son propios; los controles no demuestran reproducción idéntica de los shaders Android |
| LUT y perfiles | `.cube` y PNG AGC/Hald/tira con validación; recetas JSON propias y ajustes por lente | No importa configuraciones XML, calibraciones ni modelos de otros sensores |
| Retrato | Segmentación de personas con Vision y desenfoque del fondo normalizado para reducir contaminación de bordes; intensidad ajustable | Profundidad, mascotas/objetos, retocado facial y calibración de bordes reales. No usa el modelo de Google |
| Herramientas en directo | Histograma de luminancia, peaking, cebras y acabado color/LUT; salida pequeña, 5 FPS, sin cola de fotogramas acumulados | Comparación visual y coste térmico en el dispositivo. El look no simula la fusión ni el retrato final |
| Vídeo | 720p/1080p/4K, 24/30/60 FPS si el formato lo admite, HEVC/H.264, audio opcional, estabilización disponible, antorcha, enfoque y zoom; revisión, compartir y guardado explícito | No HDR de vídeo, cámara lenta, time-lapse ni estabilización de Google. Los formatos no admitidos se rechazan y conservan la configuración anterior |
| Panorama | Captura manual guiada de 2–10 fotos, exposición/WB/AF bloqueados, registro traslacional y homográfico sobre solapamiento, mezcla y recorte por cobertura | Corrección de paralaje, optimización conjunta de poses y calibración de lente; no es el binario Cyclops |
| Photo Sphere | 62 objetivos guiados por Core Motion; pose asociada a la foto, proyección equirectangular, rechazo de cobertura incompleta, JPEG 2:1 y metadatos GPano; visor 360° con arrastre/zoom y vista plana | Calibración FOV, deriva del sensor y paralaje. La referencia es relativa, sin rumbo GPS. No es Lightcycle |
| Menús y galería | Visor completo, selector horizontal, lentes, ajustes rápidos y paneles por función; miniaturas, revisión, histograma, importación elegida por el usuario, guardado PhotoKit | No réplica píxel a píxel ni comparación Android en ejecución; sin editor de vídeo, ubicación, volúmenes de disparo ni iconos alternativos |
| AWB/noise models/IA | WB de iOS o DNG y controles manuales; ruido estimado de diferencias RGB para el rechazo | No se dispone de un motor Google portable, AWB aprendido, modelos HDRnet ni calibraciones por sensor verificadas |

No hay botones que anuncien estas familias ausentes como si estuvieran implementadas. El APK AGC se conserva como referencia local; no se distribuyen sus binarios Android, shaders, modelos, marcas ni recursos. Las cadenas y símbolos de una librería no acreditan un algoritmo disponible ni su equivalencia.

## Captura, interrupciones y revisión

Cada modo posee su sesión de cámara. El modo Foto la libera antes de abrir Vídeo/Panorama/Esfera y vuelve a configurar la lente al regresar: los formatos, FPS y bloqueos de los dispositivos AVFoundation pueden persistir entre sesiones. Solo el botón explícito del usuario inicia una foto o grabación. Los timeouts no repiten capturas.

Vídeo valida el archivo MOV real antes de revisarlo. Una grabación detenida al pasar a segundo plano se conserva en `Documents/VideoDrafts`; el inicio de Vídeo recupera el borrador más reciente. El guardado usa marcas persistentes para evitar repetir una transacción cuyo resultado quedó sin confirmar. Descartar elimina únicamente el borrador propio elegido. Los límites son 10 min/2 GB y se exige espacio libre antes de empezar.

Panorama y Esfera conservan las fotos en memoria hasta cerrar o descartar el proyecto. No son proyectos persistentes: terminar el proceso pierde esas vistas. Pasar a segundo plano detiene la captura. Una esfera interrumpida no acepta nuevas poses de otra sesión de orientación; permite revisar/unir lo ya capturado o empezar de nuevo. Una esfera con cobertura inferior al 99,5 % no se exporta como completa.

El visor 360° usa la misma convención de coordenadas que el proyector y verifica polos, giros y costura con imágenes sintéticas. El render se ejecuta fuera del hilo de interfaz con una petición pendiente como máximo; un arrastre sustituye la petición anterior. No inicia sensores ni solicita acceso a Fotos. El JPEG exportado conserva la proyección completa, no el recorte mostrado por el visor.

Los JPEG reprocesados conservan una selección acotada de fecha, cámara, lente y exposición de referencia. Se actualiza la orientación a la geometría renderizada; no se copian miniaturas ni tamaños antiguos, MakerNotes o mapas HDR de otra foto. Una pila se identifica como composición y sus etiquetas de exposición describen la referencia. El mapa HDR válido del resultado se conserva al añadir metadatos. El JPEG sin editar y el DNG original mantienen sus bytes.

## Paquetes

| Entorno | Arquitectura del DEB | Aplicación | Complemento |
| --- | --- | --- | --- |
| Dopamine rootless | `iphoneos-arm64` | `/var/jb/Applications/UltimateCAM.app` | `/var/jb/usr/lib/TweakInject` |
| RootHide | `iphoneos-arm64e` | `/Applications/UltimateCAM.app`, reubicada por el bootstrap | `/Library/MobileSubstrate/DynamicLibraries` |

La arquitectura de control del paquete RootHide no cambia la aplicación Mach-O arm64 ni prueba compatibilidad del sistema. La app usa frameworks Apple y no enlaza un bootstrap fijo. El complemento encuentra primero `MSHookMessageEx` cargado; en RootHide puede resolver el backend respecto a su propia imagen y `.jbroot`. El filtro continúa limitado a Cámara. Conserva sus comprobaciones de modelo, versión del sistema y firmas antes de cambiar el controlador; no inventa soporte de Noche.

No se deben instalar ambos esquemas a la vez. Tras migrar el jailbreak se seleccionará el paquete correspondiente cuando se verifique el entorno real; esta etapa no modifica el teléfono.

## Comprobaciones reproducibles

`ios.yml` compila con Xcode, ejecuta `PortChecks`, `ProcessorChecks`, `MovieChecks`, `PanoramaChecks` y `SphereChecks`, construye ambos esquemas y valida los DEB reales. Las pruebas cubren LUT/HDR/metadata, persistencia de recetas, kernels, ruido y alineación, estados de grabación/MOV, registro de solapamientos, recorte, poses, cobertura, proyección y GPano. Los archivos y hashes producidos permiten identificar exactamente cada candidato.

`interface.yml` ejecuta XCTest en un simulador de iPhone 11 Pro: visor y gestos, ajustes/perfiles, opciones de vídeo, herramientas de previsualización y entrada/salida de los modos guiados. No dispara la cámara ni valida sensores. El informe del candidato registra el commit y el resultado de cada ejecución; la existencia de una prueba por sí sola no indica que haya pasado.

No queda demostrada calidad equiparable a Night Sight o a Cámara de Apple. La comparación en escenas oscuras, enfoque y guardado físico, HDR en Fotos, carga RootHide, memoria, temperatura y tiempos reales se harán después. No puede considerarse terminado un port exacto del motor propietario con esta evidencia.

## Referencias técnicas

- [AVFoundation: grabación de vídeo](https://developer.apple.com/documentation/avfoundation/avcapturemoviefileoutput).
- [Vision: segmentación de personas](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest).
- [Vision: alineación homográfica](https://developer.apple.com/documentation/vision/vnimagehomographicalignmentobservation).
- [Core Motion: actitud del dispositivo](https://developer.apple.com/documentation/coremotion/cmdevicemotion/attitude).
- [GPano: metadatos de panoramas esféricos](https://developers.google.com/streetview/spherical-metadata).
- [ImageIO: copia y mezcla de metadatos](https://developer.apple.com/documentation/imageio/kcgimagedestinationmergemetadata).
- [RootHide: desarrollo y distribución](https://github.com/roothide/Developer/blob/main/roothide.md).
