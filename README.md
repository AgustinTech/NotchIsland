# NotchIsland 0.4

Una "isla dinámica" para el notch de tu MacBook. Pasa el ratón por el notch (o haz clic, o desliza dos dedos hacia abajo) y se abre.

## Qué hace

**Notch cerrado (actividad en vivo)**
- Con música sonando se ensancha: carátula a la izquierda y visualizador animado a la derecha.
- Canción nueva: el notch se despliega un momento con el título y el artista.
- Al enchufar el cargador aparece un rayo verde con el porcentaje.
- Aviso de batería baja (20 % y 10 %).
- Al conectar AirPods u otros auriculares Bluetooth: icono, nombre y batería.
- Al pasar el ratón crece un poco, y se funde con la barra de menús como la Dynamic Island.

**Pestaña Música**
- Fondo con el color de la carátula; la carátula "respira" al pausar. Clic en ella abre Música/Spotify.
- Letra sincronizada de tres líneas (lrclib.net). Toca una línea para saltar a ese punto.
- Barra de progreso que crece al acercarte; arrástrala para saltar.
- Anterior / play-pausa / siguiente y volumen del sistema.

**Pestaña Bandeja**
- Arrastra archivos hacia el notch (se abre solo), o pulsa **Añadir** para elegirlos.
- Miniaturas reales de los archivos. Arrástralos fuera, doble clic para abrir, clic derecho para más.
- **AirDrop**, **Compartir** y **Vaciar**. Se recuerda al reiniciar.

**Pestaña Portapapeles**
- Historial con tarjetas de texto, enlaces, imágenes y archivos; permite fijar, copiar, pegar o borrar.
- Guarda hasta 40 elementos sin fijar en `~/Library/Application Support/NotchIsland/`. Se puede pausar desde el menú.
- Omite contenido marcado como privado o transitorio y el de gestores de contraseñas conocidos.

**Pestaña Hoy**
- Próximo evento con cuenta atrás, tiempo actual y batería de AirPods y otros dispositivos.

**Pestaña Herramientas**
- Temporizador, Pomodoro y cronómetro, con el tiempo visible también en el notch cerrado.
- Acciones rápidas para mantener la pantalla despierta, modo oscuro, Dock, captura y Papelera.

**Pestaña Espejo**
- La cámara del Mac como espejo. Solo se enciende mientras esa pestaña está abierta.

**Siempre**
- Batería del Mac arriba a la derecha.
- Botón "…" del notch (o icono de la barra de menús) para activar o desactivar cada función y abrir al iniciar sesión.
- **Ajustes visuales…** para elegir tamaño, velocidad, movimiento y pestañas visibles.
- Respuesta háptica al abrir (si tu trackpad la soporta).

## Novedades (0.4)

- **Herramientas y ajustes visuales**: temporizador y acciones rápidas, más tamaño, velocidad y pestañas configurables.

- **Pestaña Hoy** con agenda (varios eventos), recordatorios que se marcan con un clic, tiempo y dispositivos.
- **Pestaña Portapapeles**: historial con tarjetas (texto, enlaces, imágenes, archivos, colores), fijar, borrar y pegar con un clic. No guarda lo que marcan como privado ni lo que copian los gestores de contraseñas; se puede pausar o desactivar en el menú.
- **Avisos en el notch cerrado**: descargas con progreso, AirDrop recibido y **volumen / brillo** (al abrirlo aparecen como una pastilla abajo).
- **Firma estable**: `./build.sh` firma con tu cuenta de desarrollador de Apple si la encuentra (Xcode > Ajustes > Cuentas). Así macOS recuerda los permisos (Spotify/Música, Accesibilidad, calendario, recordatorios, ubicación, cámara, Bluetooth) entre compilaciones. Sin cuenta se firma "ad hoc" y se piden de nuevo cada vez.
- **Permiso de Automatización**: si macOS bloquea el control de Spotify/Música, la pestaña de música lo explica y abre Ajustes con un botón.
- **Cuenta de Spotify**: menú de la isla › "Vincular cuenta de Spotify…" (o el botón en la pestaña de música). Inicio de sesión oficial (OAuth con PKCE); necesitas tu propio *Client ID* de developer.spotify.com/dashboard con la Redirect URI `http://127.0.0.1:53682/callback`. Con la cuenta vinculada la isla lee lo que suena en cualquier dispositivo y lo controla por la API web (los controles necesitan Spotify Premium; si no, usa AppleScript). La sesión se guarda en el Llavero.
- **HUD de volumen y brillo**: para que el HUD del sistema no salga a la vez, NotchIsland intercepta esas teclas y aplica el cambio él mismo. Necesita **Accesibilidad** (Ajustes > Privacidad y seguridad > Accesibilidad). Sin el permiso, el sistema muestra el suyo. Se desactiva en el menú ("Ocultar el HUD del sistema").

## Cómo compilarla

Necesitas Xcode o las Command Line Tools (`xcode-select --install`) y macOS 14 o superior.

```bash
cd NotchIsland
chmod +x build.sh
./build.sh
open build/NotchIsland.app
```

Para comprobar el lector de letras sincronizadas: `swift test`.

## Permisos (se piden solo cuando hacen falta)

| Permiso | Cuándo | Para qué |
|---|---|---|
| Automatización (Música / Spotify) | al sonar música o pulsar un botón | botones, posición y carátula |
| Calendario | al abrir la pestaña Hoy | próximo evento |
| Ubicación | al abrir la pestaña Hoy | tiempo |
| Cámara | al abrir la pestaña Espejo | espejo |
| Bluetooth | al arrancar | aviso al conectar AirPods |

Si rechazas alguno por error: Ajustes del Sistema → Privacidad y seguridad.

## Privacidad

- Sin analítica ni telemetría.
- El historial del portapapeles se guarda localmente si está activado; puedes pausarlo o desactivarlo desde el menú.
- Las letras envían a lrclib.net el título, artista, álbum y duración de la canción (se puede desactivar en el menú).
- Al abrir **Hoy**, el tiempo envía tu ubicación aproximada a open-meteo.com; deja de actualizarse al salir de la pestaña.
- Todo lo demás se queda en tu Mac.

## Límites conocidos

- La carátula de Música solo funciona con canciones de tu biblioteca; si falla se ve un icono de nota.
- Las letras dependen de que lrclib.net tenga la canción.
- La bandeja guarda referencias a los archivos, no copias.
- Solo Música y Spotify. Para YouTube, Safari, etc. haría falta un componente extra (macOS 15.4+ bloqueó la API que usaban esas apps).
- Si tienes muchos iconos en la barra de menús, el de NotchIsland puede quedar oculto detrás del notch.
- No hay detector universal de llamadas: macOS no ofrece a esta app una API pública fiable para las llamadas de FaceTime, iPhone y otras aplicaciones.
- La lógica de pantallas externas tiene pruebas con pantallas simuladas, pero falta comprobar físicamente conectar y desconectar un monitor.
- La compilación local usa un certificado de desarrollo si está disponible. Para distribuir una app notarizada hace falta un certificado Developer ID Application y completar la notarización de Apple.
