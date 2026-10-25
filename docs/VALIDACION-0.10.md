# Candidato 0.10 · compilación 81

Código: `b9e1dcb1d810e1cea8798311c151ed4b9882ac59`. Los cambios posteriores de documentación no modifican los fuentes de aplicación, pruebas ni empaquetado de este candidato. Fecha: 25 de octubre de 2026.

**No instalado ni probado en el iPhone.** No se ha contactado con el dispositivo durante esta etapa. Los informes de instalación de 0.9 y de pruebas físicas anteriores se conservan como históricos y no se aplican a 0.10 ni al nuevo jailbreak.

## Resultados fuera del dispositivo

- [Compilación y fixtures](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40157695659): Xcode, `PortChecks`, `ProcessorChecks`, `MovieChecks`, `PanoramaChecks` y `SphereChecks` correctos; ambos DEB construidos y comprobados.
- [Interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40157697279): mismo commit de aplicación y pruebas, tres casos compuestos, cero fallos en 109,043 s. Comprueban visor completo y gestos, ajustes/perfiles, vídeo sin grabar, herramientas del visor, entrada/salida de Panorama/Esfera, centrado de sus disparadores y visibilidad completa del modo HDR seleccionado. Las capturas se revisaron visualmente.
- [Native Night](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40153606223): matriz rootless/RootHide correcta, código `8ac1c1541744053d2cfce6f004c6306efbcd822c`. Sus fuentes permanecen idénticos en el candidato principal. No se han instalado ni cargado estas variantes.

Los fixtures de retrato usan una máscara sintética; no prueban la identificación de una persona real. Panorama comprueba registro de imágenes con solapamiento conocido y recorte por cobertura. Esfera verifica poses sintéticas, proyección, cobertura, metadatos GPano leídos del JPEG y orientación/costura del visor 360°. Vídeo genera y valida un MOV H.264 real con imágenes sintéticas y comprueba sus estados; no utiliza la cámara del iPhone.

La prueba HDR comprueba datos auxiliares reales y su reexpansión: la razón entre HDR y SDR es 1 en una región y aproximadamente 4 en otra. Comprueba también que añadir fecha, lente y exposición conserve el mapa y la geometría. Los valores racionales de exposición/apertura/focal se mantienen en su representación XMP para evitar escribir 0 en EXIF. Esto no demuestra que Fotos presente HDR correctamente en el dispositivo.

La prueba sintética nocturna reduce RMSE de 10,2703 a 6,2389 en su fixture; es una regresión del algoritmo, no una medida de mejora óptica ni una comparación con Night Sight. No hay nueva evidencia fotográfica del modo Noche en esta entrega.

## Paquetes y hashes

| Paquete | Versión | SHA-256 |
| --- | --- | --- |
| App rootless | `0.10.0+build.81.git.b9e1dcb` | `9ad21f4f9240c1ef3b1455ae58b581ebd95411673632bdfa51d03c277c12629f` |
| App RootHide | `0.10.0+build.81.git.b9e1dcb` | `e9cbb0e2f0c8bfb45c08abc93ac9a1f4e853cda80506f316adb60f2ef3c00021` |
| Native Night rootless | `0.1.0+build.3.git.8ac1c15` | `7e0c9a1e487b06666cb1c2eb80e91c09d212d20e0ec2897becfae8294e347463` |
| Native Night RootHide | `0.1.0+build.3.git.8ac1c15` | `8b9660ba0c2ae2e354179e3fcfca6d3d4a265a9b9a6895261fa2f93bfef021d2` |

Se verificaron los hashes de los ZIP de Actions y de cada DEB, control/arquitectura, rutas, manifiestos MD5, Mach-O, versión mínima y firma ad hoc. La app contiene el mismo ejecutable arm64 en ambos esquemas, con el permiso de contenedor propio. El complemento conserva su filtro de Cámara y sus dos slices arm64/arm64e. Los scripts no lanzan cámara, capturas ni respring. La arquitectura de paquete RootHide no acredita por sí sola su carga.

Los artefactos de Actions tienen retención limitada; se ha guardado una copia local verificada de los paquetes, logs, capturas, fuentes y manifiesto del candidato. La versión instalada históricamente no se sustituye en los informes por este candidato.

## Pendientes

[Funciones y límites](FUNCIONES-0.10.md) y [pruebas físicas preparadas](PRUEBAS-FISICAS-0.10.md) detallan el siguiente paso. Faltan carga RootHide real, captura/enfoque/guardado, inferencia de retrato real, FOV/deriva/paralaje, formatos/audio/estabilización de vídeo, coste térmico/memoria y comparación nocturna controlada.

El motor propietario HDR+/HDRnet, AWB aprendido, modelos de ruido y fusión Bayer calibrada no están implementados como el motor de Google. La interfaz es una adaptación propia y no una réplica Android verificada píxel a píxel. Este candidato no acredita un port completo de GCam ni calidad equivalente al modo Noche de Apple; calibrar esa parte requiere las pruebas aplazadas en el iPhone.
