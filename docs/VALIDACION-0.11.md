# Candidato 0.11 · compilación 84

Código `c1843ebe573296fb000724f0f5ef9d9ae35ca650`. La aplicación y los DEB siguen **sin instalar ni probar en el iPhone**. Se conserva 0.10 build81 como punto de recuperación independiente.

[La compilación](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40187397417) completó Xcode, las cinco suites de procesamiento y la construcción/validación de los DEB rootless y RootHide. El inspector comprobó rutas, arquitectura, manifiestos, Mach-O, versión mínima y firma ad hoc; las dos variantes contienen el mismo ejecutable.

[La interfaz](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40187399255), sobre el mismo commit de código, completó tres casos compuestos con cero fallos en 142,201 s. Además de visor, ajustes, perfiles y navegación entre modos, verifica que las preferencias de espejo y botones físicos pasen de Foto a Vídeo y permite restaurarlas desde allí. El simulador no generó capturas ni eventos de botones físicos.

Los nuevos fixtures comprueban un MOV real con transformación de giro y la edición de imágenes con las cuatro orientaciones EXIF reflejadas. No prueban la orientación real del sensor, un botón de volumen ni una selfie JPEG/DNG en el dispositivo.

| Esquema | Versión | SHA-256 |
| --- | --- | --- |
| App rootless | `0.11.0+build.84.git.c1843eb` | `e62d0485e60db01c399b891c789daa734a13bf242ed89aa1b1024f1ecb6451ee` |
| App RootHide | `0.11.0+build.84.git.c1843eb` | `ca6f28387133be6aa76a5deae32ba4c6be7bce7f7aa74a8286ce4031d692c986` |

Native Night permanece sin cambios desde `8ac1c15`, compilación 3, con sus [variantes e inspección documentadas en 0.10](VALIDACION-0.10.md). No se ha instalado ni cargado la variante RootHide; la confirmación histórica del controlador de Noche nativa no acredita una captura nueva ni su calidad.

Las [funciones de 0.11](FUNCIONES-0.11.md) y las [pruebas físicas preparadas](PRUEBAS-FISICAS-0.10.md) describen lo que debe comprobarse después: orientación en las cuatro posiciones y al girar durante una pila/clip, espejo frontal, botones de volumen/temporizador, permisos, interrupciones y los pendientes de calidad y rendimiento anteriores. No se acredita un port completo del motor propietario de GCam.
