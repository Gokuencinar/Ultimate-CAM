# Ultimate CAM

Primer prototipo de cámara propia para el iPhone 11 Pro con iOS 18.7.1. Nombre elegido por el usuario.

El objetivo es combinar captura nocturna por acumulación, como concepto de Lumi, con técnicas de fotografía computacional descritas por Google. Este proyecto contiene una primera pila de imágenes; no contiene Lumi, GCam ni sus modelos o bibliotecas.

## Estado real

La versión `0.3.0+build.21.git.215e733` está compilada e instalada por SSH en un iPhone 11 Pro con iOS 18.7.1. `dpkg --verify com.gokuencinar.ultimatecam` termina sin diferencias. [Build y pruebas](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/39957311334): arm64, firma, paquete rootless y pruebas sintéticas correctos.

Esta revisión responde a dos fallos notificados: RAW no se guardaba en Fotos y tocar el visor no enfocaba. Se ha reimplementado la importación de RAW, separado los controles del visor, añadido retícula y confirmación de AF/AE y rediseñado la interfaz. El guardado usa DNG primario desde archivo y JPEG de cámara alternativo, siguiendo el [ejemplo actual de Apple](https://developer.apple.com/documentation/avfoundation/capturing-photos-in-raw-and-apple-proraw-formats). Incluye guardar solo JPEG y protección contra duplicados. Es una corrección implementada; todavía no está validada físicamente porque el teléfono estaba bloqueado.

[XCTest de interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/39957526080) pasó con un toque y una pulsación larga sobre el UIView real del visor, selección OFF/3s/10s/OFF del temporizador, apertura de ajustes y selección del perfil Luz baja. El registro confirma ambos gestos. Eso comprueba la ruta de entrada en el simulador, no el movimiento óptico del enfoque ni el guardado en la fototeca del teléfono.

Las pruebas físicas históricas pertenecen a la compilación 18: Foto, pilas 3/5/7/9, RAW+JPEG y ajustes, con 27 solicitudes sin timeout. Se fusionaron 3/3, 4/5, 6/7 y 5/9 imágenes; RAW devolvió 9.699.857 bytes. La 19 confirmó ajustes a 3024 × 4032. No se trasladan esos resultados automáticamente al nuevo código de configuración/captura de 0.3.

Pasaron las pruebas sintéticas de ruido, traslación, referencia nítida, rechazo de movimiento y resolución completa. La comparación visual con Cámara de Apple o GCam, el nuevo guardado y el enfoque óptico siguen pendientes. No es un HDR+ ni un Night Sight completo.

Repositorio: [Gokuencinar/Ultimate-CAM](https://github.com/Gokuencinar/Ultimate-CAM).

## Interfaz

Interfaz propia con visor 4:3 separado de los controles, botones grandes sobre fondo oscuro, retícula AF/AE, bloqueo por pulsación larga, formato/temporizador/cuadrícula rápidos y exposición visible. El zoom admite pellizco. Los ajustes se dividen en Captura, Manual y Procesado; la revisión mantiene Guardar siempre accesible y ofrece JPEG como alternativa al RAW. Conserva la referencia visual inicial de 26CAM sin incorporar su código o binarios.

Los perfiles Natural, Detalle y Luz baja ajustan los controles de procesado existentes. Luz baja selecciona una pila de siete y ajustes moderados; no reproduce el algoritmo de Google. Los atajos Cerca/Lejos cambian posiciones normalizadas de la lente, sin prometer distancias calibradas. Los controles se limitan a las capacidades de cada cámara.

## Lo que implementa el código

- Vista previa y selección de cámaras físicas: ultra gran angular, principal, teleobjetivo y frontal, según disponibilidad.
- Foto individual JPEG. Cada petición usa prioridad `.speed` para no exigir una fusión adicional al sistema y respetar ISO y obturación bloqueados; la fusión múltiple se hace en la app.
- Compensación de exposición entre −2 y +2 EV, limitada a lo que admita cada cámara.
- Balance de blancos automático o manual entre 2500 y 8000 K, con límites de ganancias del dispositivo.
- Pila de 3, 5, 7 o 9 fotos con exposición y balance de blancos bloqueados. Bloquea también el enfoque cuando se admite. Conserva el modo de exposición manual si ya estaba activo.
- Alineación por traslación con Vision y promedio en RGB lineal mediante Core Image. Rechaza alineaciones fallidas o con desplazamientos grandes. Opcionalmente elige la referencia por nitidez y la conserva en las zonas con diferencias grandes para reducir dobles contornos.
- Límite de resolución de pila seleccionable: 2048, 2560 o hasta 4096 píxeles en el lado largo. La resolución final depende de las capturas y del recorte; ampliar el límite no inventa detalle.
- Reducción de ruido, nitidez y elevación de sombras regulables, con esos ajustes adicionales desactivados por defecto.
- ISO y obturación manuales dentro de los límites del formato activo de cada lente.
- Enfoque al tocar el visor, enfoque manual donde exista soporte y zoom digital limitado por el dispositivo (hasta 8× sobre la lente elegida). El zoom digital no es superresolución.
- RAW/DNG + JPEG en Foto cuando la salida de la lente expone Bayer RAW. No fuerza ProRAW ni genera un RAW fusionado a partir de JPEG. Al guardar, el DNG es el recurso principal y el JPEG de cámara es su alternativo. Si existe un JPEG ajustado distinto, se añade como otra foto.
- Temporizador de 3 o 10 segundos, cancelado al pasar a segundo plano. Mantiene la pantalla despierta mientras la cámara está en primer plano; no impide el bloqueo manual.
- Revisión y guardado explícito en Fotos del resultado, con referencia opcional sin recodificar y alternativa JPEG en capturas RAW. Si solo hay una foto válida y no se han pedido ajustes, conserva esa foto sin fingir una fusión.
- Sesión fuera del hilo principal, protección contra capturas simultáneas y manejo de permisos e interrupciones. Tras 30 segundos sin finalización se bloquean nuevas peticiones y se pide cerrar y reabrir la app para no acumular capturas pendientes. No hay reintentos automáticos.

## Límites de esta primera versión

La pila usa JPEG ya procesados por iOS, no RAW. Son capturas consecutivas, no una ráfaga de alta velocidad. Promediar imágenes no reproduce el procesamiento de Google. Solo se alinea por traslación: no rotación, paralaje ni flujo óptico. El rechazo por diferencias puede confundir ruido, iluminación y movimiento; todavía pueden aparecer artefactos. Se recomienda una escena inmóvil y trípode.

No excede las exposiciones admitidas por la lente ni añade luz que el sensor no haya registrado. No incluye horquillado HDR, modelos neuronales de Google, superresolución, astrofotografía, retrato o Live Photos. La entrega de RAW+JPEG se comprobó en la cámara principal; otras lentes, decodificación del DNG y guardado en Fotos siguen pendientes. El resultado fusionado no copia los metadatos EXIF de exposición de la referencia porque describirían solo una parte de la pila.

El motor usa APIs públicas. La distribución actual es un `.deb` para jailbreak rootless convencional con arquitectura Debian `iphoneos-arm64` y raíz `/var/jb`. Instala una app independiente; no inyecta hooks ni modifica Cámara de Apple. No solicita acceso a toda la fototeca. La firma añade únicamente `com.apple.private.security.container-required` con el identificador de esta app para vincular su propio contenedor; no desactiva el sandbox ni omite los permisos de Cámara o Fotos. La forma de esta vinculación se contrasta con el [código de TrollStore](https://github.com/opa334/TrollStore/blob/main/RootHelper/main.m). El código no realiza solicitudes de red. Este paquete no es una variante específica para RootHide.

## Abrir y compilar

Se necesita macOS, Xcode con SDK de iOS 18 o posterior, XcodeGen, ldid y dpkg. El proyecto utiliza Swift 5 y destino mínimo iOS 18.0. El workflow contiene los comandos exactos para compilar y empaquetar.

Desde esta carpeta en un Mac con XcodeGen instalado:

```sh
xcodegen generate
open UltimateCAM.xcodeproj
```

El identificador de app y paquete es `com.gokuencinar.ultimatecam`. Para la distribución con jailbreak, el workflow compila sin certificado Apple, firma el ejecutable con ldid y crea el `.deb` con `scripts/package_deb.sh`. Los permisos de Cámara y de añadir fotos se solicitan desde la app.

## Compilar desde GitHub

Cada push a `main` o ejecución manual de **iOS · Ultimate CAM** compila la app para iPhone, ejecuta comprobaciones sintéticas del procesador y publica un artefacto `Ultimate-CAM-rootless-N` con `.deb`, SHA-256 y commit. Los artefactos se conservan 14 días. El workflow no contiene certificados, contraseñas SSH ni credenciales de Apple y no instala nada en el teléfono. La generación de capturas del simulador es opcional mediante la entrada manual `ui_preview`.

Las comprobaciones del procesador ejecutan el código real de Core Image y Vision en macOS con imágenes de ruido y desplazamientos conocidos. No sustituyen pruebas de captura, calidad, rendimiento o estabilidad en el iPhone. El log se conserva junto al log de compilación.

Para verificar compilación sin firma y sin instalar:

```sh
xcodegen generate
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

El simulador sirve para comprobar compilación e interfaz, no para validar las cámaras.

## Instalación y desinstalación

En Sileo u otro gestor compatible, abre el `.deb` y confirma su instalación. También puede instalarse desde una terminal con privilegios mediante `dpkg -i` y la ruta exacta del archivo. El script de instalación registra solo esta app con `uicache`; no hace respring ni reinicia el teléfono.

La ruta es `/var/jb/Applications/UltimateCAM.app`. Para quitarla usa el gestor de paquetes o `sudo dpkg -r com.gokuencinar.ultimatecam`. El script de retirada desregistra únicamente Ultimate CAM. La desinstalación no borra las fotografías guardadas en Fotos.

## Diagnóstico por SSH

La app guarda un registro rotativo de hasta unos 128 KiB en su directorio de caché, `UltimateCAM-capture.jsonl`. Registra estado de sesión, identificadores de solicitud, callbacks, errores y número de bytes recibidos; no incluye imágenes ni EXIF. El guardado registra únicamente el resultado de PhotoKit, errores e identificadores de los elementos recién creados. Es local y no se transmite por red.

El artefacto independiente `Ultimate-CAM-diagnostics-N` contiene `UltimateCAM-device-state`, una utilidad de solo lectura que consulta estados de notificación y busca únicamente el proceso UltimateCAM. También lee versión, PID, último evento, ruta del registro y error de escritura publicados por la app mediante estados locales. No acepta órdenes por ese canal ni envía notificaciones a SpringBoard ni modifica el bloqueo. Los nombres de estado son señales de diagnóstico del sistema, no una garantía de compatibilidad futura.

Para una prueba de captura sin tocar los controles de la app, esta debe estar abierta en primer plano y con permiso de Cámara. En su caché se puede escribir `UltimateCAM-request.json` con `{"action":"capture","mode":"normal"}` o `{"action":"capture","mode":"stack"}` y enviar `SIGUSR1` al PID exacto de UltimateCAM. El segundo modo prueba la pila de tres por defecto. En la compilación 18 se admiten además campos de texto `"count":"5"` (también 3, 7 o 9), `"raw":"true"` solo en Foto y `"adjustments":"true"` para una combinación acotada de ajustes. Son controles de diagnóstico; no cambian las selecciones visibles de la interfaz. Una señal sin solicitud local válida no toma fotos. La app consume la solicitud y comprueba su estado de primer plano antes de ejecutarla; si no está activa la ignora. No guarda automáticamente el resultado en Fotos.

## Primera comprobación en el iPhone

1. Probar permisos concedidos y denegados, abrir y cerrar la app, pasar a segundo plano y cambiar entre las cuatro cámaras.
2. En una escena inmóvil con trípode, tomar una foto individual y otra con pila de tres. Comprobar enfoque, orientación y colores. Probar especialmente 0,5× y frontal.
3. Revisar el número de fotogramas fusionados. Comparar detalle, ruido y contornos a igual escala: el resultado fusionado puede tener menos resolución que la referencia.
4. Guardar y comprobar en Fotos el resultado y la referencia. Denegar el permiso de guardado y verificar que se puede volver a intentar sin otra captura.
5. Comparar por separado con Cámara de Apple, manteniendo escena, lente y encuadre. La referencia de UltimateCAM no es una captura independiente del procesamiento de Apple.
6. Probar una persona moviéndose para documentar los límites. No considerar esa prueba superada si aparecen dobles contornos.
7. Medir duración, memoria, temperatura y estabilidad durante varias capturas. No hay medidas reales todavía.
8. Validar por lente RAW/DNG, controles manuales y pilas largas. Su compilación o disponibilidad anunciada por la API no demuestra que esos escenarios funcionen en el dispositivo.

## Siguientes etapas

Primero comprobar el build y las pruebas sintéticas de la versión exacta que se vaya a instalar. Después validar permisos, captura, cambio de lentes y calidad en el iPhone.

Con esa base medida: pasar de exportar RAW a una fusión RAW real, añadir alineación local y un modelo de ruido por sensor. Después, horquillado y mapeo tonal para un modo HDR propio. La astrofotografía y la superresolución deben ser módulos posteriores, con pruebas separadas. No llamar Night Sight o HDR+ a los controles de sombras o al promedio JPEG.

## Referencias

- [Lumi, descripción del autor de la versión 1.4.4](https://foxfort.yourepo.com/pack/lumi1). Es documentación histórica; el análisis local de 2.2.0 está en ANALISIS_LUMI.md.
- [Night Sight: Seeing in the Dark on Pixel Phones](https://research.google/blog/night-sight-seeing-in-the-dark-on-pixel-phones/).
- [HDR+ with Bracketing on Pixel Phones](https://research.google/blog/hdr-with-bracketing-on-pixel-phones/).
- [Apple: captura por horquillado](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings).
- [Apple: alineación por traslación](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest).
- [Apple: exposición manual y prioridad de captura](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)).

Las publicaciones describen técnicas y no convierten el código de este prototipo en una implementación equivalente ni autorizan a redistribuir binarios de terceros.

### Auditoría de 0.3

El canal local de diagnóstico conserva el requisito de primer plano y solicitud JSON + SIGUSR1. Además de captura, admite órdenes acotadas `focus`, `lens`, `control`, `inspect` y `save`. La última realiza un guardado explícito del resultado actual, con `format` igual a `all` o `jpeg` y `reference` opcional. Estas pruebas escriben en Fotos y solo deben usarse dentro de una sesión de pruebas autorizada. No hay órdenes de borrado ni ejecución arbitraria. La confirmación del callback de PhotoKit se distingue de una revisión visual del álbum.
