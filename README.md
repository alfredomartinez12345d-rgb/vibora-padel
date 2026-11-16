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

## Para actualizar manualmente
Ve a Actions → "Actualizar datos Víbora Pádel" → Run workflow

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
