# AGC 1.8.6: auditoría y adaptación para Ultimate CAM 0.5

Fecha: 24-10-2026. Petición: estudiar el APK y el Java descompilado, adaptar funciones y menús a iOS, sin pruebas ni instalación en el iPhone en esta fase.

## Material y alcance de la evidencia

- APK: `AGC_Camera-1.8.6_gcamapk.io.apk`, 56 108 836 bytes, SHA-256 `52fa474dd0b8bb75af452daa5d7a7f0d248f9760ae9156dbdaa80abe581d8970`.
- ZIP: 1159 entradas, un `classes.dex`; comprobación CRC sin errores. No se ha validado la firma del editor ni ejecutado el APK. La integridad ZIP no demuestra autenticidad.
- Los 126 archivos `assets/` y `lib/` del APK coinciden byte a byte con los de la carpeta descompilada. El manifiesto legible identifica `com.agc.gcam`, versión 1.8.6. Esto no acredita que sea el código fuente oficial de Google Camera.
- Carpeta: 5847 archivos, 2234 Java, 2236 smali, 894 XML, 63 archivos de shaders. Es una descompilación con métodos omitidos, no un proyecto fuente original con build reproducible.
- Se han inventariado 52 preferencias XML, incluyendo categorías y enlaces, y nueve campos `@Tunable`. Las referencias dinámicas `pref_*` se registran aparte: no representan necesariamente opciones visibles o funcionales.
- Se han revisado cuerpos de shaders y llamadas Java, no solo nombres. `defpackage/hw.java:b()` carga los shaders de alineación, pero su método principal `a()` está omitido por el descompilador. `defpackage/ng0.java` carga el merge incremental. `processing/LocalLaplacian.java` inicializa cuatro variantes y construye una pirámide. `PostProcessPipeline` enlaza etapas de color/HSL, pero cinco métodos principales están omitidos. Los smali conservan instrucciones DEX; reconstruirlos no proporciona automáticamente la misma captura y calibración en iOS.

Los archivos JSON vecinos conservan hashes, rutas de evidencia, preferencias y dependencias ELF. No se incorporan fuentes, bibliotecas, LUTs, iconos, modelos ni fotografías de terceros al producto.

## Matriz de portabilidad

“Adaptado” significa una implementación propia con intención similar. No significa mismos algoritmos, parámetros, rendimiento ni calidad.

| Familia observada en AGC | Evidencia de referencia | Estado en Ultimate CAM 0.5 |
|---|---|---|
| Foto, selección de lente, zoom, enfoque, AE/AF, exposición/WB manuales | `camera/b.java`, UI y Camera2 | Ya existentes mediante AVFoundation; límites reales de cada lente. |
| Noche / acumulación | Camera2, shaders `merge/`, modos UI | Noche estática existente: 3–16 capturas, hasta 8 s nominales. No es Night Sight. Se añade punto de partida avanzado experimental. |
| Alineación por bloques/pirámide y normalización por ruido | `alignment/`, `hw.java`, `wx.java` | Adaptación RGB opcional: registro global Vision y nueve estimaciones locales limitadas a 6 px con malla bilineal. No equivale al flujo Bayer de AGC. |
| Fusión temporal/Wiener/noise blend | `merge/incremental_merge.glsl`, `noise_blend.glsl`, `wiener_level.glsl` | Promedio lineal existente; nuevo rechazo suave opcional basado en mediana del residuo RGB. No incorpora Wiener multiescala ni modelo de ruido calibrado del sensor. |
| Rechazo de movimiento | shaders de diferencia/fusión | Existente fijo y nuevo adaptativo experimental. No garantiza escenas con personas ni evita todo ghosting; no hay detector de movimiento que adapte la exposición. |
| RAW10/16, Bayer/Quad Bayer y demosaico propio | `RawNative`, `demosaic/`, `merge/quadbayer_phase_split.glsl` | AVFoundation entrega DNG; CIRAWFilter revela. No se fuerza Quad Bayer al iPhone 11 Pro ni se reescribe el empaquetado de su sensor. DNG guardado sigue siendo referencia original. |
| Ruido cromático y luminancia | `denoise/`, opciones de ajustes | NR de luminancia existente; nueva adaptación cromática que conserva luminancia y suaviza crominancia. No es ESD3D de AGC. |
| Local Laplacian, claridad/textura | `LocalLaplacian.java`, `local_laplacian/`, `local_contrast.glsl` | Contraste local y detalle fino propios mediante dos escalas gaussianas y umbral suave. No se presenta como port exacto de Local Laplacian. |
| Nitidez, radio y detalle | `capturesharpening.glsl`, `sharpening/` | Nitidez existente, nuevo radio seleccionable y detalle fino; no se copian todos los parámetros de enmascarado de AGC. |
| Exposición posterior, luces, sombras, contraste, gamma | `initial.glsl`, `autoexposure.glsl`, `tonecurve.glsl`, `tonemap.glsl` | Ajustes propios de JPEG: EV, compresión de luces, sombras existentes, contraste y gamma. No recuperan altas luces ya recortadas. |
| Saturación, vibrance, viñeta | `effects.glsl`, controles de `AdjustmentsBottomSheet` | Adaptados, ajustables y serializados en perfiles. |
| LUT 3D e intensidad | parser `uu0.java`, `preview_lut.glsl` | Importación propia de `.cube` 3D, 2–64 puntos, dominio y mezcla. Solo resultado, no visor. No se importan Hald PNG ni LUTs de AGC. |
| Perfiles por lente y archivos personalizados | `LensSettingsFragment`, `CustomFilesFragment` | Recetas por lente y hasta 24 perfiles; importar/exportar JSON propio con LUT opcional. No acepta XML/config AGC ni promete calibración cruzada Android/iPhone. |
| JPEG quality / Display P3 | `preferences_advanced.xml` | Calidad 50–100 y salida JPEG SDR con perfil sRGB/Display P3. No inventa colores ausentes del JPEG de entrada. |
| Proporción/guías de composición | controles y `CompositionGuideView` | Recorte original/1:1/16:9, tercios, centro, diagonales y proporción áurea. Visor sigue a pantalla completa; no simula previsualización exacta del recorte. |
| Histograma | `preview_histogram.glsl` | Histograma del JPEG revisado y porcentajes de negros/luces extremos. No es histograma de sensor ni histograma en directo. |
| HDR+/HDR enhanced y bracketing | etiquetas UI y ruta de merge | Pendiente: requiere planificar exposiciones, metadatos por frame, compensación y fusión radiométrica. No se añade un botón engañoso. |
| Ultra HDR y gain map | `gainmap_ratio.glsl`, `pref_ultra_hdr_key` | Pendiente: un JPEG Display P3 SDR no es Ultra HDR. Necesita codificación HDR y validación en Fotos/pantallas. |
| AWB aprendido, noise models y matrices CCT | `awb_normalize.glsl`, importadores | Pendiente de datos/calibración por sensor y adaptación del formato. Se mantiene WB de cámara/DNG y control manual. |
| HSL selectivo, curvas RGB, gradación por zonas, dehaze y grano | `hsl.glsl`, `colorgrade.glsl`, `dehaze.glsl`, `effects.glsl` | Pendientes como controles individuales; una LUT permite ciertos looks, pero no equivale a implementar esos algoritmos y menús. |
| Face retouch, detección de sujetos/modelos | modelos `.tflite` y `.task`, MediaPipe | Pendientes de inferencia iOS y diseño/validación. No se copian modelos ni se afirma retrato/desenfoque equivalente. |
| Panorama y Photo Sphere | `libcyclops.so`, `liblightcycle.so`, clases JNI | Pendiente de reconstrucción de captura, movimiento, calibración y cosido en iOS. No reutilizables como binarios Mach-O. |
| Vídeo, estabilización y parámetros OIS | preferencias y Camera2 | Pendientes. La app actual captura fotos; el OIS y sus metadatos no se fuerzan copiando claves de Android. |
| Idioma/tema/icono alternativo, sonidos, volumen, espejo selfie, ubicación, carpeta/galería | `preferences.xml` | Sin port completo: UI española oscura y guardado explícito en Fotos. No se añaden permisos o preferencias sin implementación. |
| Developer panel, dump RAW, estadísticas | preferencias debug | Diagnóstico propio y trazas existentes; no se copia el panel de etapas Android. Sin envío automático de informes, red o actualizador propio. |

## Flujo añadido y decisiones

`Captura → registro global → malla local opcional → rechazo fijo/adaptativo → promedio RGB lineal → tono nocturno → NR/nitidez/sombras → textura/color/LUT → recorte/espacio de salida → JPEG → revisión/histograma → guardado explícito`.

La malla y el rechazo adaptativo están desactivados por defecto. “Estático avanzado” los activa junto a ruido cromático y detalle moderados; necesita validación con escenas reales. No se cambian los límites del sensor ni se añade captura automática en segundo plano. Los fallos del procesado conservan el JPEG de referencia y el DNG original disponible, muestran la causa y no repiten la captura.

Las recetas validan límites y números finitos, identificadores UUID y tamaño de archivo. Las LUTs validan dimensiones, número exacto de muestras, dominio, canales y alfa. Las importaciones no ejecutan instrucciones del archivo ni acceden a rutas indicadas por perfiles. Los archivos de perfiles ilegibles se conservan sin sobrescribir. Los ajustes manuales de captura no forman parte del perfil de procesado. El DNG no recibe los ajustes del JPEG.

La persistencia de perfiles es propia de esta app. Las calibraciones y configuraciones de otros teléfonos no son intercambiables por compartir el nombre de una opción.

## Pruebas y límites de entrega

La compilación iOS y las pruebas de Core Image/Vision se ejecutan en GitHub Actions. `Tests/PortChecks.swift` comprueba valores inválidos, LUT identidad y dominio, kernels, malla residual, máscara adaptativa, recorte y perfil P3, histograma, persistencia y passthrough. `Tests/ProcessorChecks.swift` conserva las regresiones de alineación, ruido y planificación nocturna. XCTest comprueba interacción de menús en simulador. Consultar el informe de candidato para el commit y resultados finales: no confundir que exista una prueba con que haya pasado.

No se han instalado estos cambios ni se han hecho capturas por SSH durante esta fase. Build43/0.4 sigue siendo el último estado instalado documentado. Quedan pendientes calidad nocturna, tiempo/memoria/temperatura, alineación en escenas reales, importación mediante Archivos en iPhone y revisión en Fotos. Nada de esta auditoría demuestra calidad comparable a Google Camera o al modo Noche de Apple.

## Referencias de implementación

- [CIColorCube: estructura RGBA y orden de muestras](https://developer.apple.com/documentation/coreimage/cicolorcube/cubedata).
- [CIColorCubeWithColorSpace](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace).
- [CIWarpKernel y región de interés](https://developer.apple.com/documentation/coreimage/ciwarpkernel/apply(extent:roicallback:image:arguments:)).
- [Registro traslacional de Vision](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest).
