# Fusión espectral de investigación

Esta etapa adapta las funciones `rcwindow` y `hdrplus_merge` de [google/burst-denoising](https://github.com/google/burst-denoising), revisión `7ff07e009568778ff337c259e192d1d81aedbea6`. Ese repositorio acompaña una investigación sobre reducción de ruido y redes de predicción de kernels; su referencia de fusión no es el motor comercial completo de Google Camera.

La adaptación utiliza Swift y Accelerate. Cada tesela de 32 × 32 recibe una ventana coseno; se calcula una FFT 2D de referencia y muestra. La diferencia compleja por frecuencia determina cuánto aceptar de la muestra. Si cambia mucho, se conserva la frecuencia de referencia. El promedio de la referencia y las muestras regularizadas reproduce algebraicamente la fórmula temporal de la referencia. Las teselas se solapan a media anchura y se normalizan por su cobertura.

La aplicación procesa RGB lineal ya revelado. No accede a un mosaico Bayer para esta fusión ni sustituye el demosaico de CIRAWFilter. La desviación de ruido se estima de diferencias espaciales entre fotogramas RGB y supone una escena mayoritariamente estática. No se utilizan sin transformar los coeficientes `NoiseProfile` de un DNG. La alineación global y la malla residual opcional siguen siendo las de Ultimate CAM.

Para limitar memoria se conserva un único búfer de referencia, un fotograma de entrada y un resultado, sin espectros de toda la ráfaga. El lado largo se limita a 2048 px. Los bordes se extienden localmente; se ha sustituido el enrollado periódico de la referencia para no mezclar lados opuestos de la foto. La cancelación se comprueba entre filas de teselas. El tiempo y la memoria reales necesitan medición en el iPhone.

La opción está desactivada por defecto y se ofrece dentro de Noche. Al activarla utiliza el rechazo espectral y no aplica de nuevo el rechazo espacial del promedio ponderado. El control de mezcla mayor acepta más contribución de otros fotogramas; uno menor conserva más la referencia. Los controles sin efecto para el método elegido se deshabilitan. El DNG original sigue siendo una referencia sin fusionar.

## Validación numérica

`Tests/Research/make_wiener_fixture.py` genera cinco vectores con las funciones numéricas de la revisión de Google indicada, ejecutadas con NumPy y sin importar TensorFlow ni sus scripts de entrenamiento. Se conservan revisión y hash del archivo de origen. Los casos incluyen identidad, ruido estático, detalle que cambia de fase, cambio de exposición y una mezcla menor.

`SpectralChecks` contrasta el resultado Swift/Accelerate con esos vectores, prueba bordes y cancelación, y compara una textura fina móvil con la máscara espacial anterior. También comprueba reducción de ruido de una región sintética estática y la integración completa con el procesador nocturno. En el candidato build86, el error máximo de los cinco casos es de `8,940697e-8`. La región estática sintética pasa de RMSE `0,0197670` a `0,0152956`. El detalle fino móvil conserva un contraste de `0,501886`, frente a `0,00122155` del rechazo espacial grueso en ese caso concreto. La integración del procesador fusiona las dos imágenes de prueba por FFT. Estos resultados no representan una escena fotografiada ni una comparación óptica con GCam. Las seis suites pasan en la [ejecución de compilación](https://github.com/Gokuencinar/Ultimate-CAM/actions/runs/40190915296), commit `f1eafea6059ff9dc526b83d40f201bd535330edf`.

La finalidad es disponer de otra fusión verificable, no garantizar una mejora en cualquier escena. Puede conservar ruido de la referencia, perder resolución por el límite de trabajo o comportarse de otra manera con ruido correlacionado, movimiento complejo y RAW oscuro. No se considera calibrada ni equivalente a Night Sight o Noche de Apple antes de las pruebas físicas aplazadas.

## Procedencia

La adaptación y sus cambios están identificados en `Sources/ResearchWiener.swift`. La licencia Apache 2.0 y el aviso de procedencia se distribuyen en `Legal/` dentro de la app y en los fuentes. Los paquetes verifican su presencia. No se incorpora código, shaders, modelos ni bibliotecas del APK AGC.

También se revisó [google/hdrnet](https://github.com/google/hdrnet), revisión `e9a5bf59a232ee7562d02a6cf4dc5cef6191b6c6`. Es código de investigación con TensorFlow antiguo y un operador de slicing específico. El modelo HDR+ documentado espera una representación lineal especialmente preparada; su propio README advierte de colores incorrectos al usar sRGB. No se ha añadido un modelo cualquiera sobre JPEG ni un botón que afirme ejecutar HDRnet sin pesos y dominio de entrada validados.

El archivo público de modelos HDRnet se ha localizado en el servidor del proyecto MIT y se han leído su directorio ZIP y tamaños mediante peticiones HTTP por rangos. Contiene checkpoints TensorFlow, incluido `hdrp`; su existencia está confirmada. No se han descargado ni ejecutado los pesos, convertido el modelo ni incorporado esos archivos al producto. La disponibilidad de un checkpoint no acredita que sea el motor actual de Google Camera ni resuelve su dominio de entrada y calibración.
