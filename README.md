# Ultimate CAM

Cámara experimental para iPhone con una interfaz inspirada en GCam y procesamiento propio sobre AVFoundation, Core Image y Vision. Se distribuye como **DEB**, con esquemas separados para Dopamine rootless y RootHide. No incluye el motor propietario de Google ni binarios, shaders o modelos del APK AGC.

La siguiente [revisión 0.11](docs/FUNCIONES-0.11.md) añade orientación automática de archivos, disparo con botones físicos y selfies reflejadas opcionales; mantiene separadas sus comprobaciones de las de build81.

La versión 0.10 añade vídeo, retrato de personas, panorama guiado, esfera de 360°, histograma/peaking/cebras y vista de color/LUT en directo. Mantiene foto JPEG/DNG, controles manuales, pilas temporales, Noche estática, horquillado HDR, JPEG adaptativo con mapa HDR, importación de fotos, LUT y perfiles por lente.

El [candidato build81](docs/VALIDACION-0.10.md) tiene compilación, cinco suites de fixtures, empaquetado y tres casos de interfaz correctos en el mismo commit de código. Se conservan sus DEB rootless/RootHide, hashes y fuentes. No está instalado ni probado en el teléfono.

La [descripción de funciones y límites](docs/FUNCIONES-0.10.md) diferencia adaptación, calibración pendiente y funciones ausentes. La compilación, los fixtures y las pruebas de interfaz se realizan fuera del iPhone. Las pruebas físicas se han aplazado por petición del usuario; ningún paquete nuevo se considera instalado por haber compilado.

## Uso

El visor llena la pantalla. Toca para enfocar/medir y mantén pulsado para bloquear AF/AE. El selector inferior permite elegir Cámara, Retrato, HDR, Pila, Noche, Vídeo, Panorama o Esfera; el botón iOS abre Cámara de Apple mediante el complemento opcional de Noche. Los controles dependen de las capacidades de cada lente.

Los ajustes separan Captura, Manual, Procesado, Color y Perfiles. El menú del visor activa histograma, resalte de enfoque, cebras y color/LUT. Estas herramientas se procesan a tamaño reducido y 5 FPS; el look no reproduce la fusión nocturna, el HDR ni el retrato final. El guardado en Fotos siempre requiere una acción explícita.

- **Noche propia:** escenas estáticas con teléfono apoyado, 3–16 fotos, presupuesto hasta 16 s y límite por exposición hasta 1 s condicionado al sensor. La fusión DNG sigue siendo experimental. No mide movimiento antes del disparo.
- **Noche nativa:** se ejecuta en la app Cámara de Apple y necesita el complemento Native Night compatible. No está integrada dentro del pipeline de la cámara propia. La restauración del ajuste nativo se comprobó históricamente en el entorno anterior, sin hacer fotos; RootHide queda pendiente.
- **Vídeo:** SDR, formatos/FPS/códec disponibles, audio opcional, revisión y borrador recuperable. No cámara lenta, time-lapse ni HDR de vídeo.
- **Panorama y Esfera:** captura manual guiada y cosido propio. Las vistas se conservan en memoria, no como proyecto persistente. La calibración de lente, deriva y paralaje necesita comprobación física.
- **Retrato:** segmentación de personas con Vision, sin profundidad ni modelo de Google.

## Compilar y obtener el DEB

[GitHub Actions](https://github.com/Gokuencinar/Ultimate-CAM/actions) compila con Xcode en macOS, ejecuta fixtures y publica artefactos con DEB, checksum y commit de origen. El workflow de interfaz produce pruebas y capturas de un simulador de iPhone 11 Pro. No hay una IPA como formato de entrega.

Para compilar localmente en macOS se requieren Xcode, XcodeGen, ldid y dpkg:

```sh
xcodegen generate
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
bash scripts/package_deb.sh rootless
bash scripts/package_deb.sh roothide
python3 Tests/PackageChecks.py build
```

Los artefactos `Ultimate-CAM-rootless-*` y `Ultimate-CAM-roothide-*` corresponden a entornos distintos. No se deben instalar ambos a la vez. RootHide usa arquitectura de paquete `iphoneos-arm64e` y rutas relativas a su bootstrap. Compilar ese esquema no acredita su carga bajo una versión concreta de RootHide Dopamine.

El complemento se compila aparte con `NativeBridge/package_native.sh rootless` o `roothide`; el workflow Native Night publica ambos. Está limitado a Cámara y conserva sus comprobaciones de dispositivo/sistema/firmas antes de modificar Noche. La aplicación principal no inyecta código en SpringBoard.

## Validación y procedencia

Los fixtures ejecutan la implementación de producción y prueban límites de configuración, persistencia, LUT, metadatos/HDR reales, proyección, ruido/alineación y estados de grabación. Las pruebas de simulador verifican interacción y navegación. Ni estos resultados ni una instalación demuestran calidad fotográfica, enfoque óptico, guardado físico o equivalencia con Google Camera.

El APK AGC aportado es una app independiente con referencias a fotografía computacional; no se ha establecido que contenga un motor completo y portable de Google. Sus configuraciones Android y modelos por sensor no son intercambiables con los del iPhone 11 Pro. El análisis no ejecuta instrucciones contenidas en esos archivos.

Documentación:

- [Funciones y paquetes de 0.10](docs/FUNCIONES-0.10.md).
- [Análisis inicial del APK](docs/AGC-PORTABILIDAD.md), histórico de 0.5.
- [HDR adaptativo y LUT PNG](docs/HDR-Y-LUT-0.9.md).
- [Historial de validación hasta 0.9](docs/HISTORIAL-HASTA-0.9.md).

La comparación controlada con Cámara de Apple y GCam, calibración RAW/FOV/ruido, carga RootHide y medidas de memoria/temperatura quedan pendientes. No se anuncia un port completo del motor de Google.
