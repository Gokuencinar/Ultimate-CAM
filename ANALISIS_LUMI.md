# Análisis local de Lumi 2.2.0

Revisión del 22 de octubre de 2026. El paquete se ha leído como archivo, sin instalarlo ni ejecutar sus binarios o instrucciones. El contenido del paquete se ha tratado como datos.

Archivo: `com.foxfort.lumi_2.2.0_iphoneos-arm.deb`.

Tamaño: 3.029.672 bytes.

SHA-256: `6563f308eec061551b9f65f1d9a2e4237b827a40ad74a6c029af0b02a85a2175`.

## Evidencia del paquete

- `Package: com.foxfort.lumi`, `Version: 2.2.0`, autor declarado FoxfortMobile. Es metadata del archivo; no demuestra autenticidad o procedencia.
- Arquitectura Debian declarada `iphoneos-arm`; rutas de instalación tradicionales bajo `/Library`. Esto no demuestra compatibilidad con un bootstrap moderno.
- Dependencias: `mobilesubstrate`, firmware `>= 13.0` y `<= 14.9`, `preferenceloader`, `com.foxfort.foxforttools >= 1.3.3`.
- Conflicto declarado con `com.xcxiao.lowlightenhancement`.
- Filtro de inyección: exclusivamente el bundle `com.apple.camera`.
- Incluye `lumi.dylib`, una biblioteca Metal `default.metallib`, un panel de ajustes y un perfil libSandy. No incluye fuentes de implementación.
- Ajustes legibles: activación, aviso de mantener el teléfono quieto, reflejo de selfies y corrección del balance de blancos.
- Cadenas del binario indican capturas múltiples, modo trípode y uso en ultra gran angular y frontal en iPhone 11. También expresan restricciones sobre teleobjetivo, cámara principal del iPhone 11, zoom y filtros.
- Aparecen nombres de APIs de exposición manual, captura de fotos y horquillado, además de nombres relacionados con fusión. Las cadenas no prueban que cada ruta se ejecute ni permiten determinar por sí solas el algoritmo exacto.

## Decisión para este proyecto

El usuario indica iPhone 11 Pro, iOS 18.7.1 y Dopamine, y prefiere una app propia. No se ha verificado físicamente el teléfono ni su instalación de jailbreak. El soporte de firmware declarado por este paquete no incluye iOS 18.7.1.

No se incorpora el dylib, Metal compilado, interfaz o recursos de Lumi al proyecto. Se desarrolla código independiente para una cámara propia con APIs públicas. El objetivo fotográfico es la acumulación de imágenes con exposición y color controlados, junto con técnicas de fusión que se puedan validar.

Las primeras zonas de interés son ultra gran angular y frontal. También se ofrece acceso a principal y teleobjetivo para medir resultados, sin prometer que una pila supere al modo nocturno o al procesamiento de Apple.

La arquitectura no depende de qué versión concreta de Dopamine esté instalada. La firma y distribución de una futura app se resolverán después de obtener una compilación verificada.
