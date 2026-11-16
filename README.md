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
