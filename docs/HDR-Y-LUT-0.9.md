# HDR adaptativo y LUT PNG

Esta etapa añade dos familias de formato identificadas en la referencia Android. El procesamiento sigue siendo propio: no incorpora bibliotecas ni modelos del APK y no acredita el motor de Google Camera.

## Archivo HDR con base SDR

La opción **Color → Salida JPEG → Conservar HDR cuando esté disponible** utiliza dos representaciones y el codificador público de Core Image (`CIImageRepresentationOption.hdrImage`). La base conserva los ajustes artísticos SDR; una segunda representación recupera la relación de luminancia de la fuente HDR, limitada a ocho veces el blanco SDR. Core Image calcula el mapa auxiliar. Tras codificar se exige que ImageIO pueda leer un mapa ISO o Apple; si no aparece, se devuelve error y se conserva la referencia.

Está disponible en el horquillado de tres JPEG y al editar una foto que ya contenga un mapa HDR. La radiancia obtenida del horquillado JPEG es aproximada, porque sus entradas ya tienen el procesado tonal de la cámara. No equivale a fusión Bayer HDR+ ni a HDRnet. Foto sin mapa, fusión temporal y Noche propia siguen produciendo SDR. Display P3 por sí solo tampoco significa HDR.

Las fotos importadas sin ajustes conservan el JPEG byte a byte, incluso con esta opción activada. Las entradas HEIF con mapa se convierten a JPEG adaptativo al activar la opción. Los recortes se aplican a ambas representaciones; el visor y las miniaturas continúan mostrando SDR. PhotoKit recibe los bytes originales del archivo de salida, sin convertirlos a UIImage para guardar. Su presentación HDR real en Fotos sigue pendiente.

La estrategia de dos representaciones sigue [la explicación de Apple sobre HDR](https://developer.apple.com/videos/play/wwdc2024/10177/) y la API pública [hdrImage](https://developer.apple.com/documentation/coreimage/ciimagerepresentationoption/hdrimage). No se usa `hdrGainMapAsRGB`, que no está presente en el SDK iOS 18.5 de compilación.

## LUT PNG

La auditoría de `sources/defpackage/uu0.java:q()` identifica mosaicos cuadrados de porciones azules y tiras horizontales. La implementación propia admite ese mosaico AGC y, además, Hald estándar. **Son distribuciones distintas:** el usuario elige cuál corresponde a un PNG cuadrado. Las tiras se reconocen por sus dimensiones.

Se admiten PNG RGB de 8 bits sin transparencia ni giro, de hasta 16 MB y 16 MP. Los cuadrados deben tener lado L³, con L entre 2 y 16; las tiras tienen ancho N² y alto N, entre 2 y 256. El cubo resultante se limita a 64 puntos con interpolación trilineal. No se redimensiona la imagen PNG, porque mezclaría porciones azules distintas. Tampoco se aplica su perfil ICC como si fuera una foto: los canales contienen datos numéricos. PNG indexado o de 16 bits se rechaza con un mensaje explícito.

La lectura, conversión y almacenamiento de LUT se ejecutan fuera del hilo de interfaz con un indicador de progreso. Las recetas JSON y la intensidad existente siguen usando la representación CubeLUT validada. No se distribuye ninguna LUT del APK. Referencias: [Hald CLUT en ImageMagick](https://imagemagick.org/command-line-options/#hald-clut) y [dimensiones en GraphicsMagick](https://graphicsmagick.sourceforge.io/api/hclut.html).

## Verificación y trabajo pendiente

Los fixtures comprueban que el archivo contiene datos auxiliares HDR y que, al decodificar, una región conserva razón 1 y otra recupera aproximadamente 4; no basta con guardar una etiqueta. También verifican recorte, importación, edición, persistencia y rechazo de geometría incompatible. Las LUT se contrastan con identidad, intercambio rojo/azul, ambos cuadrados, tira y remuestreo 81→64. El informe de entrega registra el commit y los resultados finales; que exista una prueba no implica que haya pasado en cualquier commit.

Build68, fuente `fd607923eb4b9c9dbace7c37cc803d747e8167f7`, pasó [compilación y fixtures](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40130600584) y está instalada. La razón HDR decodificada fue 1,0 en la región tenue y 3,9981055 en las luces; pasaron también el límite con edición de +2 EV y la importación EXIF vertical. DEB SHA-256: `1c25927d01d4cb0bb94fa04cbe5cd16dfb9b26cc143721e043251b974182a244`.

La [prueba final de interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40130901718), fuente `4f2e1a1428a628e365229ecbf7da05fd4a2f3a04`, pasó un caso compuesto sin fallos en 64,589 segundos. Todos los archivos `Sources/` coinciden con el paquete instalado. Comprueba el interruptor HDR, controles de color, perfiles, selección de modos, acceso a galería, visor completo y gestos. No importa una imagen mediante el proveedor de Fotos o Archivos ni solicita capturas. El intento anterior del test pulsaba el centro de la etiqueta de SwiftUI; el vídeo permitió corregir el punto al interruptor visible, conservando la comprobación de su valor real.

La activación/restauración nativa de Noche se documenta aparte en [0.8](NOCHE-NATIVA-0.8.md). Quedan pendientes capturas y calidad física, salto completo entre apps, presentación HDR y guardado en Fotos, memoria/temperatura, calibración Bayer/ruido/AWB, HDRnet, vídeo, retrato, panorama/Photo Sphere y comparación de la UI con Android ejecutándose. No se declara terminado el port completo.
