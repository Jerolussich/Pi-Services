# Plugins de Jellyfin

Lo que pediste no es todo del mismo tipo, y eso cambia cómo se instala cada cosa. Están agrupados por tipo para que no pierdas tiempo buscando en el catálogo algo que no está ahí.

---

## Resumen

| Qué | Tipo real | Dónde se instala |
|---|---|---|
| Trickplay | **Nativo**, ya viene en Jellyfin | Dashboard, no es plugin |
| Intro Skipper | Plugin, repositorio externo | Catálogo, agregando el repo |
| MergeVersions | Plugin, repositorio externo | Catálogo, agregando el repo |
| Cinema Mode | Plugin | Catálogo |
| jellyfin_ratings | **Userscript**, no es plugin | Inyector de JavaScript |
| jellyfin-rewind | **App web aparte** | Fuera de Jellyfin |
| jellyfin-watch-updater | **Servicio externo** | Fuera de Jellyfin |

---

## Trickplay: no lo busques, ya lo tenés

Trickplay es la previsualización en miniatura al arrastrar la barra de tiempo. **Dejó de ser un plugin: es nativo desde Jellyfin 10.9.** Si buscás el plugin en el catálogo no lo vas a encontrar, y el repositorio viejo está discontinuado.

Se activa en `Dashboard → Playback → Trickplay`.

Una advertencia concreta para tu caso: generar las miniaturas es **trabajo de CPU sostenido**, y en un Pi 5 sobre una biblioteca grande puede tardar horas y calentar bastante. Conviene activarlo cuando la biblioteca ya esté cargada, dejarlo procesar de noche, y usar la opción de generar durante el escaneo en vez de todo de golpe.

---

## Plugins de repositorio externo

Intro Skipper y MergeVersions no están en el catálogo oficial: hay que agregar primero el repositorio de cada uno en `Dashboard → Plugins → Repositories → +`, y recién ahí aparecen en el catálogo para instalar.

**No dejo las URLs escritas acá a propósito.** Estos proyectos cambian de URL entre versiones, y una URL vieja falla de forma silenciosa o te instala una versión incompatible. Sacalas del README del proyecto en el momento de instalar:

- Intro Skipper: `github.com/intro-skipper/intro-skipper`
- MergeVersions: `github.com/danieladov/jellyfin-plugin-MergeVersions`

**Intro Skipper es muy sensible a la versión de Jellyfin.** Cada release apunta a una versión específica del servidor y con otra no carga. Verificá la compatibilidad antes de instalar, y tenelo en cuenta cuando actualices Jellyfin.

Igual que Trickplay, Intro Skipper analiza los archivos para detectar las intros, y ese análisis es intensivo en CPU. En un Pi 5 conviene dejarlo corriendo de noche.

**Cinema Mode** (trailers y cortinilla antes de la película) sí suele estar en el catálogo oficial. Buscalo ahí primero.

---

## jellyfin_ratings: es un userscript

`github.com/Druidblack/jellyfin_ratings` reemplaza las puntuaciones nativas por las de IMDb, Trakt, Letterboxd y otras. **No es un plugin instalable desde el catálogo.** Es JavaScript que se inyecta en la interfaz web.

Necesitás dos cosas antes de empezar:

1. Una **API key de mdblist.com**, que es de donde saca las puntuaciones.
2. Un plugin inyector: **JavaScript Injector Plugin** para la v2 del script.

El método recomendado por el propio proyecto es instalar el inyector y pegar el contenido del script en su ventana de configuración. Hay una alternativa como userscript de navegador (Tampermonkey), pero solo funciona en ese navegador y no en las apps de TV ni celular.

Ojo con una implicancia: al ser inyección en la web, **una actualización de Jellyfin puede romperlo**, y si editás `index.html` a mano la actualización te pisa el cambio. El inyector es más resistente que la edición manual.

---

## jellyfin-rewind y jellyfin-watch-updater: van fuera de Jellyfin

**jellyfin-rewind** (`github.com/Chaphasilor/jellyfin-rewind`) es un resumen anual estilo Spotify Wrapped para tu música. Es una **aplicación web independiente** que se conecta a la API de Jellyfin. No se instala adentro: se abre aparte y se le da la URL de tu servidor. Si querés servirla desde el Pi, entra como un contenedor más con su entrada en Caddy, igual que el resto del repo.

**jellyfin-watch-updater** (`github.com/Simon-Eklundh/jellyfin-watch-updater`) corrige la fecha de última reproducción cuando los clientes no la escriben, algo que necesitan las herramientas de limpieza automática de biblioteca para saber qué ya viste. Es un **servicio externo** que habla con la API, no un plugin. Se ejecuta periódicamente, así que el lugar natural en tu repo es una tarea de `ofelia`, que ya usás para programar trabajos.

Verificá los requisitos de cada uno en su README antes de armarles el contenedor, porque son proyectos chicos y cambian seguido.

---

## Orden sugerido

1. Levantá Jellyfin y cargá la biblioteca completa.
2. Activá Trickplay y dejalo procesar de noche.
3. Instalá Cinema Mode desde el catálogo oficial.
4. Agregá los repos de Intro Skipper y MergeVersions, verificando compatibilidad de versión.
5. Recién al final el inyector y jellyfin_ratings, que es lo más frágil ante actualizaciones.

Dejar lo frágil para el final tiene una razón práctica: si algo se rompe, sabés que fue lo último que tocaste.
