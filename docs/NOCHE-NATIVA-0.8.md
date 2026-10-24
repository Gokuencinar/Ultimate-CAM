# Noche nativa: activación y restauración

El complemento `com.gokuencinar.ultimatecam.native-night` se inyecta únicamente en Cámara de Apple. Su activación exige iPhone12,3, iOS build 22H31 y las firmas Objective-C verificadas en `NATIVE-NIGHT-ABI-22H31.json`. Solicita el valor nativo 2 mediante el controlador real de Cámara y conserva las comprobaciones originales de lente, modo, ráfaga y grabación. No sustituye duraciones ni anuncia capacidades inexistentes.

Ultimate CAM 0.8 libera su sesión y abre `camera://` con una solicitud temporal de 120 segundos. El usuario opera el disparador de Apple y puede importar después el resultado. La elección manual del usuario, el paso a segundo plano y la caducidad cancelan la solicitud. Esta integración usa la interfaz de Apple; no ejecuta su motor dentro del visor de Ultimate CAM.

## Evidencia del 24 de octubre de 2026

- App 0.8.0+build.61.git.95cc1c0, fuente `95cc1c08e9872c1f46f8f6ec3bbedbc338d10488`: [compilación y fixtures](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40128367339) correctos. DEB SHA-256 `a371188a099efef237bc690e029d42dc28bdb0310aee7599d6474bbd228b8bdf`; instalado mediante jb-p1lot, con hash del ejecutable y `dpkg --verify` correctos. La nueva app no se abrió al instalar.
- Complemento 0.1.0+build.2.git.95cc1c0: [compilación y protocolo C](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40128368924) correctos. DEB SHA-256 `1813f8083e6a68dd91ec3bbf54af505eafb84bab1d16ca1702336521a228d976`; instalación y tres hashes de archivos verificados.
- El usuario reinició Cámara manualmente, PID nuevo 65899; estado del complemento 1 (preparado). La solicitud `117497737486865` produjo control nativo 2, modo resuelto 2, confirmación coincidente y estado 4. Al desarmar, solicitud 0, estado 6 y control/modo 1, iguales al control previo 1. Se observaron activación y restauración reales. Se enviaron **cero solicitudes de captura**.
- [Interfaz en simulador](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40127344135), fuente `ac11cdfec1614e211d35106dd764469db28c69da`: un caso compuesto, cero fallos, 61,734 segundos. CameraView coincide con build61; después cambió el seguimiento de confirmación del coordinador. No prueba el salto real entre apps ni el proveedor de Fotos.

No se acredita todavía una foto nocturna, su tiempo de exposición, detalle, ruido, guardado o equivalencia con Night Sight. Tampoco se ha verificado físicamente la caducidad ni la cancelación por elección manual; solo la desactivación explícita y restauración. Los intentos de apertura desde un proceso de diagnóstico root devolvieron errores reales de LaunchServices; el ACK de `uiopen` no se usó como prueba de apertura. No se intentó desbloquear el dispositivo.

Las familias pendientes de `NOCHE-Y-PORT-0.7.md` siguen pendientes salvo esta activación nativa y la ruta de acceso añadida. No se declara un port completo del procesamiento de Google.
