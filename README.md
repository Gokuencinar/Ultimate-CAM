# Ultimate CAM

Primer prototipo de cámara propia para el iPhone 11 Pro con iOS 18.7.1. Nombre elegido por el usuario.

El objetivo es combinar captura nocturna por acumulación, como concepto de Lumi, con técnicas de fotografía computacional descritas por Google. Este proyecto contiene una primera pila de imágenes; no contiene Lumi, GCam ni sus modelos o bibliotecas.

## Estado real

El primer prototipo ha compilado en GitHub Actions con Xcode 16.4 y SDK iOS 18.5, con un IPA arm64 sin firmar. La interfaz y las comprobaciones añadidas después deben verificarse en su propia ejecución de Actions. Sin instalación ni prueba en el iPhone. La calidad fotográfica no está verificada. No es todavía un modo Night Sight ni un HDR+ completo.

Repositorio: [Gokuencinar/Ultimate-CAM](https://github.com/Gokuencinar/Ultimate-CAM).

## Interfaz

Implementación propia inspirada en la captura y descripción públicas de [26CAM de ngkhoi](https://www.reddit.com/r/jailbreak/comments/1vd9zwl/upcoming_26cam_a_tweak_that_bring_ios_26_camera/): visor a pantalla completa, controles flotantes, selector inferior en cápsula, anillo del disparador y botones de lentes. En iOS 18 utiliza materiales translúcidos de SwiftUI; no depende del tweak Liquid (Gl)ass ni incorpora sus binarios. No es una copia de su implementación ni el efecto Liquid Glass nativo de iOS 26.

Los controles muestran únicamente los modos implementados: Foto y Pila 3. La captura de vídeo no está implementada. Exposición, temperatura de color y cuadrícula se despliegan con el botón superior. El visor puede recortar la imagen para llenar la pantalla; la revisión enseña la foto guardable completa.

## Lo que implementa el código

- Vista previa y selección de cámaras físicas: ultra gran angular, principal, teleobjetivo y frontal, según disponibilidad.
- Foto individual JPEG con prioridad de calidad del sistema.
- Compensación de exposición entre −2 y +2 EV, limitada a lo que admita cada cámara.
- Balance de blancos automático o manual entre 2500 y 8000 K, con límites de ganancias del dispositivo.
- Pila experimental de tres fotos consecutivas con exposición y balance de blancos bloqueados. Bloquea también el enfoque cuando la cámara lo permite.
- Alineación global por traslación con Vision y promedio en RGB lineal mediante Core Image. Rechaza alineaciones fallidas, de poca confianza o con desplazamientos grandes.
- Recorte del área común. Procesamiento limitado a 2560 píxeles en el lado largo para acotar memoria. Puede reducirse más por el recorte.
- Revisión y guardado explícito en Fotos del resultado y del primer fotograma original. Si solo hay una foto válida, conserva esa foto sin fingir una fusión.
- Sesión fuera del hilo principal, protección contra capturas simultáneas, manejo de permisos e interrupciones y límite de 30 segundos por foto sin reintento automático.

## Límites de esta primera versión

La pila usa JPEG ya procesados por iOS, no RAW. Son capturas consecutivas, no una ráfaga de alta velocidad. Promediar tres fotos no reproduce el procesamiento de Google. Solo se corrige traslación: no rotación, paralaje ni movimiento local. Personas, mascotas, hojas y vehículos pueden dejar dobles contornos. Se necesita una escena inmóvil y preferiblemente trípode.

No fuerza exposiciones largas ni añade luz que el sensor no haya registrado. No incluye horquillado HDR, reducción avanzada de ruido, superresolución, astrofotografía, retrato, RAW/DNG o Live Photos. Detecta si una lente ofrece RAW, pero no lo captura todavía. El resultado fusionado no copia los metadatos EXIF de exposición del primer fotograma porque describirían solo una parte de la pila; la referencia original se conserva sin recodificar.

La app usa APIs públicas y no necesita jailbreak para esta versión. Tener Dopamine no sustituye compilar y firmar la app. No usa hooks, permisos especiales de jailbreak, acceso a toda la fototeca ni servicios externos. El código no realiza solicitudes de red.

## Abrir y compilar

Se necesita macOS, Xcode con SDK de iOS 18 o posterior y XcodeGen. El proyecto utiliza Swift 5 y destino mínimo iOS 18.0.

Desde esta carpeta en un Mac con XcodeGen instalado:

```sh
xcodegen generate
open UltimateCAM.xcodeproj
```

En Xcode, selecciona el target UltimateCAM, elige tu equipo de firma en Signing & Capabilities y cambia `local.ultimatecam.camera` por un identificador propio si corresponde. Selecciona el iPhone y ejecuta Run. Los permisos se solicitan desde la app.

## Compilar desde GitHub

Cada push a `main` o ejecución manual de **iOS · Ultimate CAM** compila la app para iPhone, ejecuta comprobaciones sintéticas del procesador y publica un artefacto `Ultimate-CAM-unsigned-N` con IPA, SHA-256 y commit. Los artefactos se conservan 14 días. La app necesita firma o un método de instalación compatible con el dispositivo antes de ejecutarse. El workflow no contiene certificados ni credenciales de Apple y no instala nada en el teléfono.

Las comprobaciones del procesador ejecutan el código real de Core Image y Vision en macOS con imágenes de ruido y desplazamientos conocidos. No sustituyen pruebas de captura, calidad, rendimiento o estabilidad en el iPhone. El log se conserva junto al log de compilación.

Para verificar compilación sin firma y sin instalar:

```sh
xcodegen generate
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
```

El simulador sirve para comprobar compilación e interfaz, no para validar las cámaras.

## Primera comprobación en el iPhone

1. Probar permisos concedidos y denegados, abrir y cerrar la app, pasar a segundo plano y cambiar entre las cuatro cámaras.
2. En una escena inmóvil con trípode, tomar una foto individual y otra con pila de tres. Comprobar enfoque, orientación y colores. Probar especialmente 0,5× y frontal.
3. Revisar el número de fotogramas fusionados. Comparar detalle, ruido y contornos a igual escala: el resultado fusionado puede tener menos resolución que la referencia.
4. Guardar y comprobar en Fotos el resultado y la referencia. Denegar el permiso de guardado y verificar que se puede volver a intentar sin otra captura.
5. Comparar por separado con Cámara de Apple, manteniendo escena, lente y encuadre. La referencia de UltimateCAM no es una captura independiente del procesamiento de Apple.
6. Probar una persona moviéndose para documentar los límites. No considerar esa prueba superada si aparecen dobles contornos.
7. Medir duración, memoria, temperatura y estabilidad durante varias capturas. No hay medidas reales todavía.

## Siguientes etapas

Primero comprobar el build y las pruebas sintéticas de la versión exacta que se vaya a instalar. Después validar permisos, captura, cambio de lentes y calidad en el iPhone.

Con esa base medida: añadir control ISO/obturación y exposición larga dentro de los límites de cada lente; captura RAW en las cámaras que realmente la expongan; selección de fotograma de referencia, alineación local, rechazo de zonas móviles y fusión sensible al ruido. Después, horquillado y mapeo tonal para un modo HDR propio. La astrofotografía y la superresolución deben ser módulos posteriores, con pruebas separadas.

## Referencias

- [Lumi, descripción del autor de la versión 1.4.4](https://foxfort.yourepo.com/pack/lumi1). Es documentación histórica; el análisis local de 2.2.0 está en ANALISIS_LUMI.md.
- [Night Sight: Seeing in the Dark on Pixel Phones](https://research.google/blog/night-sight-seeing-in-the-dark-on-pixel-phones/).
- [HDR+ with Bracketing on Pixel Phones](https://research.google/blog/hdr-with-bracketing-on-pixel-phones/).
- [Apple: captura por horquillado](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings).
- [Apple: alineación por traslación](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest).

Las publicaciones describen técnicas y no convierten el código de este prototipo en una implementación equivalente ni autorizan a redistribuir binarios de terceros.
