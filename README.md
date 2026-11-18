# Víbora Pádel — Despliegue con actualización automática

## Estructura
```
vibora-padel/
├── index.html          ← se genera automáticamente, no tocar
├── build.py            ← script de construcción
├── template.html       ← plantilla de la app
├── descargar.sh        ← script de descarga (corre en GitHub Actions)
└── .github/
    └── workflows/
        └── update.yml  ← automatización diaria
```

## Setup inicial (5 minutos)

1. Crea un repositorio en GitHub: github.com/new
2. Sube estos archivos
3. Ve a Settings → Secrets → Actions → New repository secret
   - Nombre: `PADEL_API_TOKEN`
   - Valor: tu token de Padel API
4. Ve a Settings → Pages → Source: "GitHub Actions"
5. Haz un push vacío para disparar el primer build:
   `git commit --allow-empty -m "trigger" && git push`

La URL será: https://TU_USUARIO.github.io/vibora-padel/

## Actualizaciones
- **Completa**, cada noche (01:30 UTC): descarga toda la temporada (`descargar.sh`).
- **Rápida**, cada 30 minutos (a y cuarto y a menos cuarto): si hoy hay un torneo en juego, vuelve a bajar solo su calendario y sus partidos (`directo.sh`) partiendo de los datos guardados en la caché de GitHub, y publica. Si no hay torneo, termina sin gastar peticiones ni publicar.

Para lanzarla a mano: Actions → "Actualizar datos Víbora Pádel" → Run workflow, y elige `completa` o `rapida`.

Solo se publica la app (carpeta `_site`); los datos en bruto de la API no salen a la web.

## App instalable
`manifest.webmanifest`, `sw.js` y los iconos (`icon-*.png`, `apple-touch-icon.png`, generados desde `icon.svg`) permiten instalar Víbora en el móvil y abrirla sin conexión con los últimos datos descargados. En Inicio aparece una tarjeta «Instala Víbora» (Android/Chrome: botón Instalar; iPhone: instrucciones de Safari).

## Pala de cada jugador
La ficha de cada jugador muestra «Juega con …» si está en la lista `const PALAS` de `template.html` (fuente: PadelAddict, temporada 2026). Para añadir o corregir un jugador, edita una línea de `PALAS`: `['men' o 'women', [nombres de pila], 'apellido', 'Marca y modelo']`.

### Fotos
Las fotos de los jugadores vienen de Padel API (`photo_url`). La de la pala es opcional: sube `fotos/palas/<nombre>.jpg` (mejor con fondo blanco) con uno de estos nombres:
- `arturo-coello.jpg`
- `agustin-tapia.jpg`
- `alejandro-galan.jpg`
- `federico-chingotto.jpg`
- `juan-lebron.jpg`
- `franco-stupaczuk.jpg`
- `francisco-navarro.jpg`
- `miguel-yanguas.jpg`
- `jorge-nieto.jpg`
- `leandro-augsburger.jpg`
- `jon-sanz.jpg`
- `martin-di-nenno.jpg`
- `francisco-guerrero.jpg`
- `lucas-bergamini.jpg`
- `jeronimo-gonzalez.jpg`
- `javier-leal.jpg`
- `gemma-triay.jpg`
- `delfina-brea.jpg`
- `paula-josemaria.jpg`
- `beatriz-gonzalez.jpg`

## Estadísticas de visitas
GoatCounter (anónimo, sin cookies): https://viborapadel.goatcounter.com
- Cada pantalla cuenta como una vista (`/inicio`, `/ranking`, `/torneos`, `/jugador/<nombre>`, `/torneo/<nombre>`…).
- Eventos: `app-instalada`, `quiniela` (una vez por visita) y `favorito/<jugador>`.
- No cuenta las visitas desde `localhost`.

## Avisos en el móvil (OneSignal)
En la ficha de cada jugador hay un botón 🔔: quien lo pulsa recibe avisos cuando ese jugador **va a empezar un partido** (unos 30–45 min antes) y con **su resultado** al terminar. Los envía `avisos.py` en cada actualización (la rápida, cada 30 min durante los torneos).

Para activarlos:
1. Crea una app en onesignal.com de tipo **Web**, con la URL del sitio `https://<usuario>.github.io` y la ruta `/vibora-padel/`.
2. En GitHub → Settings → Secrets and variables → Actions:
   - pestaña **Variables**: `ONESIGNAL_APP_ID` = el App ID de OneSignal.
   - pestaña **Secrets**: `ONESIGNAL_REST_KEY` = la REST API Key de OneSignal.
3. Lanza una actualización completa.

Sin esas dos claves no aparece la campana ni se envía nada. En iPhone los avisos solo funcionan con la app instalada en la pantalla de inicio (iOS 16.4 o posterior).

## Botón de YouTube en cada partido
En los partidos sin jugar **hasta cuartos** de un torneo en juego aparece «▶ Ver en YouTube · <pista>», que lleva a la emisión de esa pista en el canal oficial. Lo prepara `youtube.py` en cada actualización: mira los directos y los programados del canal (unas 3 unidades de cuota de las 10.000 diarias gratis) y `build.py` los empareja con la pista de cada partido por el título («Center Court», «Pista Central», «Court 2», «Pista 2»…) y el nombre del torneo. Si no encuentra la emisión, el botón lleva a la lista de directos del canal.

Para activarlo, crea una clave de la **YouTube Data API v3** en Google Cloud y guárdala en GitHub → Settings → Secrets and variables → Actions → **Secrets** como `YT_API_KEY`. Mira dos canales: Premier Padel (`@PremierPadelOfficial`, variable `YT_CHANNEL` para cambiarlo) y la FIP (`@padelfip`, variable `YT_CHANNEL_FIP`). Cada torneo solo se empareja con emisiones de su circuito y, si hay versión [ESP] y [ENG], se elige la española.

## Torneos FIP
Además de la temporada de Premier Padel entran los **FIP Platinum y Gold** de la temporada FIP activa que estén en juego, por jugar o que empezaran hace como mucho 45 días (`fip.py`; los Silver se dejan fuera porque son decenas). Sus partidos salen en el calendario, el mapa, los cuadros, los horarios y con botón de YouTube, pero **el Elo, los rankings, las rachas y los récords solo cuentan Premier Padel**.

## Fantasy (Supabase) · modo mánager
Pestaña **Fantasy**: ligas con amigos de hasta 10 mánagers (solo chicos, solo chicas o mixtas, con o sin clausulazos), sobre inicial de 4 jugadores, plantilla de 6, alineación de 2 revés + 2 drive con Pala de Oro (×2), mercado diario de 8 jugadores con pujas ciegas, ventas y cláusulas.
- `supabase/fantasy.sql`: perfiles de mánager (ya instalado). `supabase/manager.sql`: todo el modo mánager (tablas, reglas en `m_cfg`, funciones y seguridad). Se pegan en Supabase → SQL Editor → Run; se pueden volver a ejecutar.
- `manager.py` (después de `build.py`): valor de cada jugador (según ranking y racha, ±10 % al día, de 3 a 90 M), bloqueo de alineaciones al empezar un torneo Premier, pago de 0,2 M por punto al acabar, puntos de cada jugador y cierre de mercados pendientes.
- Puntos por partido: victoria hasta octavos +3, cuartos +5, semis +8, final +12; campeón +5; +1 por set ganado; +1 si gana sin ceder set; +2 por 6-0; sorpresa (gana a mejor Elo) +2 o +4; −2 si cae en su primer partido; −1 por 0-6; abandono propio 0. Las mismas reglas en `manager.py` y en la app (`mxPartido`).
- En GitHub → Settings → Secrets and variables → Actions: **variables** `SUPABASE_URL` y `SUPABASE_ANON_KEY`; **secreto** `SUPABASE_SERVICE_KEY`. Sin ellas no aparece la pestaña.
