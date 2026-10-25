# Ultimate CAM

Cámara para iPhone inspirada en GCam, distribuida como **DEB** para Dopamine rootless y RootHide.

## Funciones

- Foto JPEG y RAW, enfoque por toque, bloqueo AF/AE y controles manuales.
- Noche, pilas de imágenes, HDR y fusión espectral opcional.
- Retrato, vídeo, panorama y esfera de 360°.
- Color, curvas, LUT, perfiles por lente e importación de fotos.
- Visor a pantalla completa, histograma, resalte de enfoque y cebras.
- Temporizador, botones de volumen y selfies reflejadas.

Toca el visor para enfocar y mantén pulsado para bloquear AF/AE. Elige el modo en la barra inferior y ajusta captura, procesado y color desde Ajustes. Las fotos se guardan desde la revisión.

La fusión espectral está desactivada por defecto y limita el lado largo a 2048 px. Noche está pensado para escenas estáticas con el teléfono apoyado. El complemento Native Night funciona en Cámara de Apple, por separado.

## Instalación

Descarga el DEB de [GitHub Actions](https://github.com/Gokuencinar/Ultimate-CAM/actions) e instálalo con tu gestor de paquetes. Elige **rootless** para Dopamine rootless o **RootHide** para su bootstrap. No instales ambas variantes a la vez. Native Night se distribuye como complemento independiente.

## Compilación

Requiere macOS, Xcode, XcodeGen, ldid y dpkg.

```sh
xcodegen generate
xcodebuild -project UltimateCAM.xcodeproj -scheme UltimateCAM -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
bash scripts/package_deb.sh rootless
bash scripts/package_deb.sh roothide
```

El procesamiento es una adaptación para iOS; no incorpora el motor propietario completo de GCam. Las licencias de terceros están en `Legal/`.
