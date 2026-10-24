# Ultimate CAM 0.6 — segunda etapa del port de AGC 1.8.6

Fecha: 24-10-2026. Se conserva el APK auditado en 0.5 (SHA-256 `52fa474dd0b8bb75af452daa5d7a7f0d248f9760ae9156dbdaa80abe581d8970`). Las bibliotecas Android, Camera2 y EGL/JNI no son binarios iOS. La entrega sigue siendo una adaptación propia; un APK descompilado con métodos omitidos no permite acreditar el mismo motor ni la misma calidad que Google Camera.

## Funciones añadidas

| Familia | Implementación y límites |
|---|---|
| Horquillado HDR | Plan de tres exposiciones: referencia medida, corta y larga; separación solicitada ±1/2/3 EV, limitada por lente/ISO y 0,5 s por toma. Cambios de ISO/obturación confirmados antes de cada petición. No usa el motor HDR+ de Google. |
| Fusión HDR | Normaliza mediante ISO × tiempo del EXIF realmente recibido, registra imágenes con Vision, descarta alineaciones malas y pondera zonas sin recortar. Tiene rechazo conservador de diferencias y mapeo tonal a SDR. JPEG ya contiene tono/ISP, por lo que solo aproxima la radiancia del sensor. |
| Referencia y restauración | La primera exposición es la referencia medida. Se conserva en fallos; no se repite la captura. Se restauran exposición, cadencia, WB y enfoque. RAW y flash se excluyen del horquillado. Los temporizadores de ajuste se vinculan al índice de fotograma para no cancelar una exposición posterior. |
| HSL | Ocho bandas con matiz, saturación y luminosidad; interpolación circular y protección de píxeles acromáticos. Receta serializada, validada y transformada en una tabla 33³. |
| Curvas | Cinco puntos editables por canal RGB global, rojo, verde y azul; gráfico táctil y deslizadores accesibles. Interpolación lineal propia. |
| Gradación | Ruedas de sombras, medios tonos y luces, intensidad, balance y transición de zonas. Desplazamiento cromático con luminancia compensada, sin emular la inferencia de Google. |
| Efectos | Borrar neblina aproximado, grano determinista y tamaño de grano. Se aplican al JPEG; no al DNG ni al visor en directo. |
| Perfiles | Las nuevas opciones se guardan por lente y en JSON. La ausencia de la nueva receta en perfiles antiguos conserva valores neutros. Se rechaza la combinación simultánea Noche/HDR y las curvas o bandas mal formadas. |

Se comparte el acabado JPEG entre foto individual, pila y HDR. Las comprobaciones anteriores de resolución, P3, alineación, rechazo de movimiento y referencia siguen ejecutándose para detectar regresiones.

## Recreación de interfaz

Se revisaron `activity_main.xml`, `dialog_settings.xml`, `panel_adjustments.xml`, los selectores y la resolución de colores Material3. La evidencia estructural extraída se conserva en `AGC-layout-reference.json`.

- Disparador de 72 puntos, miniatura circular a la izquierda y cambio de cámara a la derecha.
- Selector de lentes sobre el disparador; accesos laterales a perfiles y LUT.
- Barra inferior con ajustes a la izquierda, modos y controles de imagen a la derecha.
- Menú rápido plegable y controles de composición en el visor. Se conserva la preferencia previa del usuario de visor a pantalla completa.
- Paleta de respaldo resuelta del APK: primario `#d0bcff`, superficie base `#141218` y contenedor `#211f26`. Android puede sustituirla por colores dinámicos.
- Herramientas de Color con pestañas Color/Curvas/HSL/Ruedas/Efectos.

Es una recreación de los controles operativos y de la estructura observable. No se afirma coincidencia píxel a píxel: no hay captura de referencia del APK ejecutándose en Android, los componentes siguen siendo SwiftUI y no se muestran modos que aún no tienen implementación.

## jb-p1lot y cerberus-re

El usuario autorizó expresamente configurar certificados, emparejar este ordenador y activar el servicio. Se compiló el cliente jb-p1lot 0.1.6 desde el repositorio original, commit `9bedf513a56786771c83f6e58c0ddc499033aaf4`. La inspección previa encontró el paquete instalado, pero sin daemon registrado ni certificados en las rutas previstas. Se añadieron únicamente identidad de servidor y CA pública con permisos limitados, se retiraron los archivos temporales y se registró el LaunchDaemon. No se reinstaló el paquete ni se hizo respring.

La consulta del puente TLS confirmó UID 0. Una lectura acotada confirmó iPhone12,3 / 22H31 y Ultimate CAM build51, sin proceso de Ultimate CAM activo en ese momento. El resultado `paired:true` de una dirección explícita, por sí solo, no se tomó como evidencia de emparejamiento: se exigió comunicación autenticada real.

Las claves privadas del cliente/CA permanecen fuera del repositorio y no se incluyen en artefactos de cámara. Se aplica la disciplina de cerberus-re para separar análisis estático, conexión y comportamiento observado. No se han hecho attach de Frida/LLDB ni pruebas funcionales de cámara. La instalación de la nueva app, cuando se realice, debe constar aparte del estado del puente.

## Pendiente para completar el objetivo

| Familia pendiente | Trabajo real que falta |
|---|---|
| Motor RAW/Bayer de AGC | Desempaquetado/demosaico/fusión antes del ISP, calibración por sensor/lente, flujo de alineación piramidal, ruido y comparación con DNG reales. CIRAWFilter más fusión RGB no acredita este port. |
| HDR+ completo y HDRnet | Agenda de captura dependiente de movimiento, exposiciones subexpuestas de referencia, respuesta del sensor y tono adaptativo. El nuevo horquillado JPEG no los reproduce. |
| Ultra HDR | Gain map y codificación compatible, PhotoKit y validación en pantallas/editores; P3 SDR no lo sustituye. |
| Modelos Google/MediaPipe | Conversión/ejecución iOS y validación de entradas, salidas, calibración y condiciones de uso; no se cargan bibliotecas JNI Android. |
| Vídeo y estabilización | Sesión/salida de vídeo, audio/permisos, códecs, orientación, guardado y estabilización comprobados. |
| Panorama/Photo Sphere | Captura guiada, movimiento/calibración y cosido iOS; `libcyclops.so`/`liblightcycle.so` no pueden enlazarse como Mach-O. |
| AWB/modelos de ruido | Datos del sensor del iPhone y validación óptica; no se reutilizan calibraciones de teléfonos Android como si fueran las del iPhone. |
| Interfaz idéntica | Referencia visual real de Android para comparar geometría, estados y transiciones. La extracción de XML demuestra estructura, no todos los estados visibles. |

## Verificación

Se han añadido fixtures de planificación HDR, exposiciones inválidas, recuperación de radiancia no recortada, negros, pipeline completo de un bracket sintético, HSL selectivo/achromático, curvas, gradación, grano y persistencia. La interfaz en simulador comprueba nuevos menús y la selección del modo HDR sin pulsar el disparador. Consultar el informe de entrega para el commit y resultados exactos; esta lista describe pruebas implementadas, no resultados por anticipado.

Siguen aplazadas las capturas físicas, el guardado real de esta versión, calidad nocturna/HDR, memoria, temperatura y tiempos en el iPhone. No se declara port completo ni calidad equivalente antes de esas comprobaciones.
