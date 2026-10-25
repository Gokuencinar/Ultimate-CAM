# Estado del port en 0.12

Esta matriz describe implementaciones disponibles en los fuentes; la calidad y el comportamiento físico siguen pendientes. La referencia AGC descompilada no es un proyecto fuente completo de Google Camera. Los paquetes Android, bibliotecas ELF y configuraciones de sensores no se pueden convertir en un motor iOS cambiando nombres o menús.

| Familia | Implementación de Ultimate CAM | Límite pendiente |
| --- | --- | --- |
| Captura y controles | AVFoundation, lentes disponibles, zoom, punto AF/AE, bloqueo, ISO/obturación/WB, flash, temporizador y botones físicos | Comprobar cada capacidad con el dispositivo y el nuevo jailbreak |
| Foto RAW | DNG original con su JPEG de cámara; JPEG editado o fusionado separado | El DNG no contiene una fusión Bayer propia |
| Noche propia | Plan de exposición estática, 3–16 tomas, selección de referencia, registro global, malla residual opcional y fusión lineal | Sin medición de movimiento antes del disparo ni calibración completa por sensor |
| Fusión temporal | Media, pesos por píxel y nueva FFT opcional con referencia numérica pública de Google | La FFT trabaja sobre RGB revelado, a un máximo de 2048 px por lado; no es Night Sight |
| Noche de Apple | Complemento Native Night limitado a Cámara, con comprobaciones y restauración del control | Backend independiente; carga y captura en RootHide pendientes. No está dentro del procesador de la app |
| HDR fotográfico | Horquillado de tres exposiciones, fusión radiométrica aproximada, JPEG adaptativo con mapa HDR | No incorpora el motor HDR+ comercial ni demuestra el mismo rango o calidad |
| HDRnet | Código y requisitos públicos revisados; el archivo público de modelos ha sido localizado e inventariado por rangos HTTP | Sin pesos cargados ni inferencia integrada. Hace falta validar dominio de entrada, conversión y salida antes de ofrecerlo |
| Ruido y detalle | Reducción cromática, luminancia, rechazo de movimiento, nitidez y detalle a dos escalas | No son modelos ESD3D ni una calibración de ruido Bayer del iPhone |
| Color | HSL, curvas RGB, gradación por zonas, exposición, contraste, sombras/luces, gamma, vibrance, dehaze, grano y viñeta | AWB aprendido y matrices de calibración Google ausentes |
| LUT y perfiles | Cube y PNG con disposición explícita; intensidad, recetas por lente y JSON propio | No interpreta configuraciones XML ni calibraciones de otro sensor como equivalentes |
| Retrato | Segmentación de personas con Vision y desenfoque del fondo | Sin profundidad ni modelo de retrato/retocado de Google |
| Panorama | Captura manual guiada, registro y cosido con recorte de cobertura | Sin barrido automático ni proyecto recuperable; paralaje/calibración pendientes |
| Esfera | Guía de orientación, 62 vistas, proyección equirectangular, cobertura, GPano y visor interactivo | Sin modelo de lente calibrado ni recuperación de proyecto; deriva y costuras pendientes |
| Vídeo | SDR, resolución/FPS/códec disponibles, audio opcional, estabilización disponible, orientación, espejo y borrador recuperable | HDR de vídeo, cámara lenta, time-lapse y estabilización propietaria Google ausentes |
| Visor y revisión | Pantalla completa, carrusel de modos, ajustes rápidos, herramientas a 5 FPS, histogramas, referencia/resultado y guardado explícito | La similitud visual no acredita identidad con todos los menús/versiones de GCam |

El análisis original del APK se conserva como histórico en [AGC-PORTABILIDAD.md](AGC-PORTABILIDAD.md). Las implementaciones posteriores están descritas en [0.10](FUNCIONES-0.10.md), [0.11](FUNCIONES-0.11.md) y [fusión espectral 0.12](FUSION-ESPECTRAL-0.12.md). No se han añadido preferencias para anunciar funciones ausentes como si estuvieran terminadas.

## Qué puede cerrarse sin el teléfono

Compilación, formatos y rutas de los DEB, licencias incluidas, valores/persistencia de las recetas, fixtures numéricos, generación de archivos sintéticos y navegación en simulador. Los informes identifican cada commit y ejecución; una prueba fallida no se convierte en válida por existir una compilación posterior.

## Qué requiere la siguiente fase

Carga RootHide, permisos y sesiones reales, AF/AE, RAW y guardado en Fotos, giro/espejo/botones físicos, formatos de vídeo, segmentación real, calibración de lente/ruido y comparaciones nocturnas controladas con Apple Camera. También tiempo, memoria y temperatura con pilas largas. Estas pruebas siguen aplazadas por petición del usuario.

No hay evidencia que permita declarar un port completo del procesamiento propietario de GCam o una calidad equivalente. La nueva FFT es una adaptación concreta de investigación abierta, con procedencia y contraste numérico, y se mantiene experimental hasta medirla en el teléfono.
