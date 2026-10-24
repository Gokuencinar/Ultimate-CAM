# Ultimate CAM

Primer prototipo de cámara propia para el iPhone 11 Pro con iOS 18.7.1. Nombre elegido por el usuario.

El objetivo es combinar captura nocturna por acumulación, como concepto de Lumi, con técnicas de fotografía computacional descritas por Google. Este proyecto contiene una primera pila de imágenes; no contiene Lumi, GCam ni sus modelos o bibliotecas.

## Candidato 0.6: HDR y controles de AGC

La [segunda etapa](docs/AGC-PORTABILIDAD-0.6.md) añade horquillado HDR experimental, HSL de ocho bandas, curvas RGB, gradación por zonas y efectos. Reorganiza los controles según los layouts del APK y su paleta Material3 de respaldo. Son implementaciones propias y la salida HDR sigue siendo un JPEG SDR. No se presenta como el motor HDR+ de Google ni como un port completo.

jb-p1lot quedó emparejado tras autorización expresa, con conexión TLS y UID 0 confirmados. No se ha abierto Ultimate CAM ni se han enviado capturas en el iPhone. Los informes de build51 que siguen corresponden al estado anterior y se conservan como historial; la instalación y validación de cada candidato 0.6 se registran aparte.

## Versión 0.5 / build51: instalada sin prueba funcional

La versión 0.5 adapta controles observados en el APK AGC 1.8.6 mediante código propio de Core Image/Vision. Añade cinco paneles, recetas por lente, perfiles JSON con LUT opcional, importación `.cube`, ruido cromático, detalle fino/contraste local, exposición y color del JPEG, calidad/P3/recorte, guías e histograma del resultado. Incluye alineación local y rechazo adaptativo experimentales, desactivados por defecto, y un punto de partida “Estático avanzado”. La revisión usa miniaturas limitadas a 1600 px, y el procesado ofrece progreso y cancelación cooperativa para conservar el original.

La [matriz de portabilidad](docs/AGC-PORTABILIDAD.md) identifica qué se adapta, qué ya existía y qué queda pendiente: no es un port completo ni el motor de Google. No se incorporan bibliotecas, shaders, modelos ni recursos del APK al producto. El APK original y los archivos descompilados permanecen como material de análisis local. Las pruebas funcionales del iPhone quedan aplazadas por petición del usuario. Se autoriza instalar 0.5 por SSH sin abrir ni probar la app; el informe de entrega separa instalación y funcionamiento. Los resultados de build43 que siguen son históricos.

Build51 (`0.5.0+build.51.git.e20394d`, código `e20394d08f002ded6b1dead69a24a006d4b04811`) está [compilada y comprobada con fixtures](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40055761390) e instalada por SSH. SHA-256 del DEB: `681b7db64d21d904c0452b97b92cab8a39440c47b0e9b8e64b316e294c38663f`. Hash del ejecutable y `dpkg --verify` correctos, sin abrir la app ni enviar capturas. El paquete añade un icono propio y conserva el identificador y contenedor anteriores.

Las [pruebas de interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40055520612), con los mismos fuentes Swift que build51 y diferencia solo en el catálogo del icono, completaron un caso compuesto con cero fallos en 48,971 s: visor, gestos, temporizador, Noche, panel Color y guardado/aplicación de perfiles. No son pruebas de óptica ni de cámara física. La revisión por SSH se limitó a archivos, registros existentes y estado del paquete; no hubo attach ni instrumentación de procesos. No se han medido mejoras de calidad, tiempo o memoria en el iPhone con 0.5.

## Noche estática experimental (0.4)

El selector **NOCHE** y el perfil **Noche estática** sustituyen al antiguo perfil Luz baja. El modo mide la exposición automática y distribuye el presupuesto entre 3 y 16 capturas consecutivas: hasta 1 segundo por exposición y un presupuesto de hasta 8 segundos de integración solicitada. El tiempo total incluye entrega del sensor, revelado y fusión y puede ser bastante mayor. Se necesita una escena inmóvil y el teléfono apoyado; no mide movimiento ni prolonga la exposición más allá de lo permitido por el formato.

Por defecto fusiona JPEG de cámara para conservar el color del procesado de iOS. En las lentes con Bayer RAW se puede activar **Fusionar DNG** en Procesado: revela DNG mediante CIRAWFilter y los fusiona en RGB lineal, usando los JPEG para elegir la referencia. Esta ruta es experimental, más lenta y todavía necesita calibración de color y ruido en sombras profundas. Guarda el DNG original de la referencia, no un RAW fusionado. El mapeo tonal se aplica después de la acumulación: levanta sombras con ganancia limitada, conserva luces expuestas y comprime solo el extremo superior. No es horquillado HDR. En 0.4 hay rechazo conservador de movimiento y alineación por traslación, sin alineación local ni rotación. El candidato 0.5 añade la malla residual opcional descrita arriba.

La primera prueba física de build30 completó 8 exposiciones RAW de 0,5 s nominales a ISO400, fusionó 8/8 y generó un JPEG de 3008 × 3952. Tardó 28,45 s según el cliente de diagnóstico. La inspección visual detectó dominante magenta y ruido de color; también quedó alterada la cadencia del visor al volver a automático. Es evidencia de captura/fusión, no de calidad equivalente a Night Sight ni al modo Noche de Apple. Build37 confirmó la restauración de los límites de fotograma y de la exposición a 1/15 s; enfoque posterior, Foto y Pila 3 terminaron correctamente. La fusión DNG todavía tardó 27,73 s en total (21,02 s de procesado), con dominante de color. Se mantiene como opción experimental y no como ruta predeterminada.

El revelado DNG desactiva la curva global, la sustracción creativa de sombras (`shadowBias`) y el mapeo de gama antes de promediar; conserva el balance de blancos del DNG. No incluye AWB aprendido. Cada DNG se materializa una sola vez en un búfer lineal para reutilizarlo en alineación y fusión.

Noche exige exposición automática y flash desactivado. Los tiempos largos se seleccionan entre valores fijos y se ajusta el ISO para conservar la medición. Solo si el automático está cerca del ISO máximo, una falta de exposición medida por `exposureTargetOffset` puede compensarse hasta 2 EV. No se interpreta esa señal como detección de movimiento ni como protección completa contra luces recortadas. Conserva los bloqueos y modos anteriores para restaurarlos tras captura o error. Si el revelado falla, conserva la referencia y avisa que no hay fusión. No repite capturas automáticamente. La configuración nocturna y el procesamiento tienen límites de espera independientes.

## Auditoría física histórica: build43

`0.4.0+build.43.git.9aca748`, commit `9aca74887a3579c476fc74ee70a85104d4487f2e`, compilado en [Actions](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40012174142) e instalado por SSH. SHA-256: `6178d40ed72440fc2cebd3626119508f21149894d8728eaeaa84f32184f39907`. `dpkg --verify` sin diferencias; sin reinicio ni respring.

En la última escena, una pared con una fuente de luz directa, se completaron 14 pasos de diagnóstico: JPEG normal, Noche JPEG 16/16, enfoque posterior, Foto posterior, Pila 3/3, Noche DNG 16/16, exportaciones propias y consultas de restauración. Ambas pilas usaron 1/30 s nominal a ISO50, unos 0,53 s de integración total: la escena ya tenía bastante más luz que las pruebas iniciales. La inspección del JPEG procedente de DNG mostró color neutro sin la dominante magenta anterior en esta escena; no demuestra calibración en oscuridad profunda. El cliente midió 7,30 s totales para Noche JPEG (4,20 s de procesado) y 21,70 s para DNG (17,56 s de procesado). Esos tiempos no predicen una pila de ocho segundos de integración.

El máximo de 1 s por foto/8 s de integración y la compensación de falta de exposición de hasta 2 EV están comprobados en el planificador con datos sintéticos; no se han validado físicamente en build43 con una escena suficientemente oscura. En versiones anteriores sí se recibieron DNG de 0,5 s; build41 rechazó una duración fraccionaria cuyo EXIF declaró 1 s, por lo que ahora se eligen tiempos fijos.

El guardado de una nueva imagen nocturna se confirmó mediante PhotoKit en build38; no se repitió en build43 y no implica revisión visual del álbum. La vuelta de obturación manual de 0,5 s a automática se comprobó en build40. Las [pruebas de interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40009305004), con el mismo archivo CameraView que build43, completaron un caso compuesto sin fallos: visor completo, gestos AF/AE, selección del temporizador y perfil Noche. Son pruebas de simulador, sin calidad óptica.

La valoración del usuario sigue siendo que el modo Noche nativo funciona mucho mejor. No se ha hecho una comparación controlada con ese modo ni con GCam. La alineación global, el rechazo de movimiento y el ruido del revelado todavía necesitan trabajo; el número de fotos fusionadas no demuestra equivalencia de calidad.

## Auditoría anterior: 0.3 / build26

La versión `0.3.0+build.26.git.1b4f237` está [compilada](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/39996357339) e instalada por SSH en el iPhone 11 Pro con iOS 18.7.1. Se verificaron SHA-256, manifiesto y `dpkg --verify`, sin diferencias ni respring.

Se completaron 63 casos funcionales por SSH, más una captura frontal con flash y cuatro comprobaciones de protección/restauración, con 34 solicitudes al sensor: RAW y guardado en Fotos, protección contra duplicados, flash JPEG, zoom, EV, WB con matiz, enfoque manual/automático, bloqueo AF/AE, exposición manual, las cuatro cámaras y pilas 3/5/7/9. Se crearon 3 elementos nuevos en Fotos y no se borró ninguno. El callback de PhotoKit no sustituye una revisión visual del álbum.

El flash ON devolvió `flashEnabled=true` en principal y frontal; AUTO decidió no activarlo en esta escena. La frontal expone soporte de flash en este dispositivo. Se ofrece solo en Foto JPEG y lentes con flash soportado/preparado, con OFF por defecto; RAW y pilas no usan flash. Se consulta el soporte de la salida y la disponibilidad antes de enviar la petición. No se ha medido la iluminación resultante.

A 5000 K, los matices -35/+35 produjeron ganancias distintas, verificadas por consulta del sensor; no es calibración de color. El bloqueo de enfoque con exposición manual conservó `exposureMode=3`, y se diferencia de un bloqueo AF/AE automático. El zoom mostrado procede del valor aplicado por AVFoundation.

Las pilas fusionaron 3/3, 5/5, 7/7, 9/9 fotogramas en esta sesión y terminaron sin timeout. Estas cifras no se extrapolan a otras escenas. [XCTest](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/39997982041) comprueba que el visor ocupa el ancho y alto de pantalla y recibe toque/pulsación larga, además de selección del temporizador y ajustes/perfil Luz baja. El visor recorta para llenar la pantalla; las fotos conservan formato y resolución originales.

Pasaron las pruebas sintéticas del procesador. Quedan pendientes la revisión visual de nitidez, encuadre, orientación y Fotos, la interacción física con el botón de liberación y temporizador, la comparación de calidad con Cámara de Apple/GCam y medidas sostenidas de memoria/temperatura. No es una implementación completa de HDR+ ni Night Sight.

Repositorio: [Gokuencinar/Ultimate-CAM](https://github.com/Gokuencinar/Ultimate-CAM).

## Interfaz

Interfaz propia con visor a pantalla completa, controles superpuestos y botones grandes sobre degradados oscuros, retícula AF/AE, bloqueo por pulsación larga, formato/temporizador/cuadrícula rápidos y exposición visible. El zoom admite pellizco. Los ajustes del candidato se dividen en Captura, Manual, Procesado, Color y Perfiles; la revisión mantiene Guardar siempre accesible y ofrece JPEG como alternativa al RAW. Conserva la referencia visual inicial de 26CAM sin incorporar su código o binarios.

Los perfiles Natural y Detalle ajustan los controles de procesado existentes. Noche estática activa el modo nocturno descrito arriba; el antiguo perfil Luz baja, basado en siete JPEG y sombras, se ha retirado. Los atajos Cerca/Lejos cambian posiciones normalizadas de la lente, sin prometer distancias calibradas. Los controles se limitan a las capacidades de cada cámara.

## Lo que implementa el código

- Vista previa y selección de cámaras físicas: ultra gran angular, principal, teleobjetivo y frontal, según disponibilidad.
- Flash OFF/AUTO/ON en Foto JPEG, condicionado al soporte y disponibilidad de la lente. Desactivado para RAW y pilas.
- Foto individual JPEG. Cada petición usa prioridad `.speed` para no exigir una fusión adicional al sistema y respetar ISO y obturación bloqueados; la fusión múltiple se hace en la app.
- Compensación de exposición entre −2 y +2 EV, limitada a lo que admita cada cámara.
- Balance de blancos automático o manual entre 2500 y 8000 K y matiz verde/magenta de -100 a +100, con límites de ganancias del dispositivo. No es una calibración de color.
- Pila de 3, 5, 7 o 9 fotos con exposición y balance de blancos bloqueados. Bloquea también el enfoque cuando se admite. Conserva el modo de exposición manual si ya estaba activo.
- Alineación por traslación con Vision y promedio en RGB lineal mediante Core Image. Rechaza alineaciones fallidas o con desplazamientos grandes. Opcionalmente elige la referencia por nitidez y la conserva en las zonas con diferencias grandes para reducir dobles contornos.
- Límite de resolución de pila seleccionable: 2048, 2560 o hasta 4096 píxeles en el lado largo. La resolución final depende de las capturas y del recorte; ampliar el límite no inventa detalle.
- Reducción de ruido, nitidez y elevación de sombras regulables, con esos ajustes adicionales desactivados por defecto.
- ISO y obturación manuales dentro de los límites del formato activo de cada lente.
- Enfoque al tocar el visor, enfoque manual donde exista soporte y zoom digital limitado por el dispositivo (hasta 8× sobre la lente elegida). El zoom digital no es superresolución.
- RAW/DNG + JPEG en Foto cuando la salida de la lente expone Bayer RAW. No fuerza ProRAW ni genera un RAW fusionado a partir de JPEG. Al guardar, el JPEG de cámara es el recurso principal y el DNG desde archivo es su alternativo. Si existe un JPEG ajustado distinto, se añade como otra foto.
- Temporizador de 3 o 10 segundos, cancelado al pasar a segundo plano. Mantiene la pantalla despierta mientras la cámara está en primer plano; no impide el bloqueo manual.
- Revisión y guardado explícito en Fotos del resultado, con referencia opcional sin recodificar y alternativa JPEG en capturas RAW. Si solo hay una foto válida y no se han pedido ajustes, conserva esa foto sin fingir una fusión.
- Sesión fuera del hilo principal, protección contra capturas simultáneas y manejo de permisos e interrupciones. Tras 30 segundos sin finalización se bloquean nuevas peticiones y se pide cerrar y reabrir la app para no acumular capturas pendientes. No hay reintentos automáticos.

## Límites de esta primera versión

PILA y NOCHE usan JPEG de cámara por defecto; NOCHE permite activar la ruta DNG experimental cuando la cámara la expone. Son capturas consecutivas, no una ráfaga de alta velocidad. Promediar imágenes no reproduce el procesamiento de Google. La ruta predeterminada alinea por traslación. La malla local opcional de 0.5 no es flujo óptico denso ni garantiza corregir rotación/paralaje. El rechazo por diferencias puede confundir ruido, iluminación y movimiento; todavía pueden aparecer artefactos. Se recomienda una escena inmóvil y trípode.

No excede las exposiciones admitidas por la lente ni añade luz que el sensor no haya registrado. No incluye horquillado HDR, modelos neuronales de Google, superresolución, astrofotografía, retrato o Live Photos. La entrega de RAW+JPEG y su guardado por PhotoKit se comprobaron en la cámara principal; RAW en teleobjetivo y revisión visual del DNG siguen pendientes. Ultra gran angular y frontal no exponen RAW en este dispositivo. El resultado fusionado no copia los metadatos EXIF de exposición de la referencia porque describirían solo una parte de la pila.

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

La app guarda un registro rotativo de unos 128 KiB, más una copia anterior acotada, en su directorio de caché, `UltimateCAM-capture.jsonl`. Registra estado de sesión, identificadores de solicitud, callbacks, errores y número de bytes recibidos; no incluye imágenes ni ubicación. Noche registra únicamente exposición, ISO y marcas de tiempo de captura para comprobar la cadencia. El guardado registra únicamente el resultado de PhotoKit, errores e identificadores de los elementos recién creados. Es local y no se transmite por red.

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

Con esa base medida: calibrar el revelado y ruido por ISO, añadir alineación local y corrección de pequeñas rotaciones, medir movimiento y revisar el detalle conservado frente a la referencia. La prueba del usuario sigue situando el modo Noche nativo por delante; los conteos de fotogramas no refutan esa observación. Después, horquillado y mapeo tonal para un modo HDR propio. La astrofotografía y la superresolución deben ser módulos posteriores, con pruebas separadas. No llamar Night Sight o HDR+ a los controles de sombras o al promedio JPEG.

## Referencias

- [Lumi, descripción del autor de la versión 1.4.4](https://foxfort.yourepo.com/pack/lumi1). Es documentación histórica; el análisis local de 2.2.0 está en ANALISIS_LUMI.md.
- [Night Sight: Seeing in the Dark on Pixel Phones](https://research.google/blog/night-sight-seeing-in-the-dark-on-pixel-phones/).
- [HDR+ with Bracketing on Pixel Phones](https://research.google/blog/hdr-with-bracketing-on-pixel-phones/).
- [Apple: captura por horquillado](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings).
- [Apple: alineación por traslación](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest).
- [Apple: desfase medido de exposición](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposuretargetoffset).
- [Apple: sustracción de sombras del revelador RAW](https://developer.apple.com/documentation/coreimage/cirawfilter/shadowbias).
- [Apple: exposición manual y prioridad de captura](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:)).

Las publicaciones describen técnicas y no convierten el código de este prototipo en una implementación equivalente ni autorizan a redistribuir binarios de terceros.

### Auditoría de 0.3

El canal local de diagnóstico conserva el requisito de primer plano y solicitud JSON + SIGUSR1. Además de captura, admite órdenes acotadas `focus`, `lens`, `control`, `inspect` y `save`. La última realiza un guardado explícito del resultado actual, con `format` igual a `all` o `jpeg` y `reference` opcional. Estas pruebas escriben en Fotos y solo deben usarse dentro de una sesión de pruebas autorizada. No hay órdenes de borrado ni ejecución arbitraria. La confirmación del callback de PhotoKit se distingue de una revisión visual del álbum.


En build26, la solicitud local de captura admite `"flash":"off"`, `"auto"` u `"on"`, solo en Foto JPEG. Una solicitud RAW o Pila con flash se rechaza antes de enviarla al sensor. El control de balance de blancos admite `"tint":"-35"` (rango -100 a +100) junto a `"value":"5000"`; el registro permite consultar las ganancias aplicadas. Estos controles conservan la validación de primer plano.

El flash se configura en cada [solicitud fotográfica](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/flashmode), comprobando los [modos soportados por la salida](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/supportedflashmodes-1n6nm). Se registra el indicador resuelto de la captura; este no es una medición de iluminación ni de calidad de imagen.
