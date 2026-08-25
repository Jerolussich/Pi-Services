# Avisos, feed y métricas

Cómo la Pi te cuenta lo que le pasa, sin que tengas que acordarte de mirar.

---

## El problema que resuelve

El diagnóstico ya sabía todo. Corría cada hora y dejaba el resultado escrito en un archivo que **solo veías si entrabas por SSH**. Era una alarma de incendio que suena únicamente cuando ya estás en la habitación.

No hacía falta más inteligencia. Hacía falta alcance.

---

## Un motor, cuatro canillas

Cada hallazgo del diagnóstico sale por cuatro lados, desde un solo punto del código:

```
                 diagnostico.sh
        (el unico que sabe que es "estar bien")
                       │
     ┌─────────────┬───┴────────┬──────────────┐
     ▼             ▼            ▼              ▼
   pantalla       ntfy         feed        metrica
     │             │            │              │
   MOTD y      celular      eventos.pi     Grafana
   terminal   (si cambio)   (la memoria)  (el historial)
```

El punto es `bien` / `ojo` / `mal` en [`diagnostico.sh`](../diagnostico.sh), que son las tres funciones por donde pasa **todo**. Agregar un chequeo nuevo no obliga a acordarse de la métrica ni del aviso: salen solos.

Las funciones viven en [`lib/avisos.sh`](../lib/avisos.sh), aparte de `lib/comun.sh`, porque `respaldo.sh` también necesita avisar y no tiene por qué cargar 2600 líneas para mandar una notificación.

---

## Las tres superficies

Cada una contesta una pregunta distinta. Si dos contestaran la misma, sobraría una.

| | Contesta | Cuándo la mirás |
|---|---|---|
| **Celular** | ¿pasó algo ahora? | nunca, te busca él |
| **Homepage** | ¿está todo bien y qué abro? | siempre, es la entrada |
| **Grafana** | ¿desde cuándo, y esto empeora? | solo si el número está rojo |

Y el mensaje de bienvenida del SSH sigue donde estaba, de regalo: te muestra lo que está mal justo en el lugar por el que ya entrás.

---

## ntfy: cómo llega el aviso

Es un canal de radio. Elegís un nombre, la Pi transmite ahí, tu celular está sintonizado.

```
   Pi  ──transmite──▶  ntfy.sh  ──▶  tu celular (app)
```

Sin cuenta, sin registro, sin token. **El nombre del canal es la contraseña**: quien lo sabe, escucha. Por eso lo genera el instalador al azar y nunca te lo hace inventar, igual que hace con las claves de API de Radarr y Seerr.

```bash
./avisos.sh --canales     # a que suscribirte
./avisos.sh --probar      # manda uno de prueba a cada canal
```

Bajás la app **ntfy** (Google Play, App Store o F-Droid), tocás el `+`, escribís el nombre. Son treinta segundos y no lo tocás nunca más. También se ve en el navegador, sin instalar nada.

**Te llega estés donde estés**, porque el aviso no viaja por tu red: la Pi grita hacia internet y ntfy reparte. No necesitás Tailscale ni estar en casa. Y funciona incluso si la Pi ya se murió, siempre que haya alcanzado a mandarlo.

### Por qué no es un contenedor

> El que avisa que algo se rompió no puede romperse junto con eso.

Si el notificador fuera un contenedor, el día que se cae Docker o se llena el disco no te enterarías justamente de eso, que son los dos escenarios que pasaron el 20 de agosto de 2026. Es el mismo criterio por el que Pi-hole y Tailscale están fuera de Docker.

Acá el emisor es un `curl`, que ya viene instalado. No hay imagen, ni volumen, ni un servicio más que se pueda caer.

Y el servidor que reparte tampoco vive en casa. Autohospedar ntfy suena más prolijo y es exactamente lo que no hay que hacer: el servidor de avisos se caería con la Pi que tiene que reportar.

---

## Son dos canales

```
 alertas    lo que se rompe. Suena. Casi nunca habla.
 media      lo que esta listo. Silencioso y agrupado.
```

En la app se configuran por separado, así que podés silenciar el de media una semana sin quedarte ciego al de alertas.

Van separados para que el de alertas conserve su propiedad más importante: **que si no suena, está todo bien**.

Los dos nombres viven en el `.env` de la raíz, que nunca se versiona y que `respaldo.sh` ya levanta solo.

---

## La regla que hace que el canal sobreviva

> Se avisa cuando algo **cambia**, no cuando algo **está**.

| Situación | Qué pasa |
|---|---|
| Algo se rompió | te llega, con sonido si es grave |
| Eso mismo sigue roto la hora siguiente | **silencio** |
| Se arregló | te llega, con el tilde verde |
| Sigue roto desde hace 24 h | un recordatorio, uno solo |
| Es de madrugada y es un aviso menor | espera a la mañana |
| Está todo bien | nunca te llega nada |

Un canal que te repite lo mismo cada hora lo silenciás en una semana, y ahí volviste a no tener canal.

El aviso de **resuelto** no es un adorno: sin él nunca aprendés a confiar en que el silencio significa que está todo bien.

### La confirmación

Un contenedor que se reinicia treinta segundos durante una actualización no puede despertarte a las 3 de la mañana. Dos falsas alarmas alcanzan para que silencies el canal para siempre.

Por eso los chequeos de contenedores **no avisan la primera vez que ven el problema**: avisan si sigue ahí en la corrida siguiente. Se pierde una hora de aviso y se gana que el canal siga sirviendo.

Y si vuelve solo antes de confirmarse, tampoco se anuncia como resuelto: nunca se anunció como roto.

### La métrica de éxito

**Una semana normal son cero avisos.** Si empiezan a llegar dos o tres por día, el problema no está en la Pi: está en la calibración, y la respuesta es bajar cosas de rojo a ámbar en `ajustes.conf` o sacarlas.

---

## El feed

Las notificaciones son para lo que te tiene que interrumpir. El feed es para lo que vale la pena recordar, que es mucho más ancho: el respaldo que salió bien, el chequeo de discos que dio OK, las importaciones de anoche.

```bash
./avisos.sh              # las ultimas 30
./avisos.sh --todo       # todo
```

O en el navegador, en **`http://eventos.pi`**.

Ahí no hay ningún servicio nuevo: Caddy sirve una página estática y el archivo de texto que escribe el diagnóstico, y el navegador los junta. Por eso `eventos.pi` es un bloque más del Caddyfile y su registro DNS aparece solo.

Su mayor uso llega el día que algo se rompe: "se llenó el disco" es una cosa, y "se llenó el disco" con tres líneas más arriba diciendo "importadas 12 películas" es otra.

**Se corta solo y no usa logrotate**, a propósito: fue justamente logrotate el que se murió en silencio en marzo y dejó crecer un log hasta llenar la tarjeta. Un feed que depende de la pieza que ya falló no es buena idea.

---

## Las métricas

node-exporter tiene una puerta de atrás que casi nadie usa: **lee una carpeta con archivos de texto planos y publica lo que encuentre como métrica propia**. Con eso, el diagnóstico se convierte en exporter sin ser un contenedor.

Es una línea en el compose de node-exporter:

```
--collector.textfile.directory=/run/pi-services/metrics
```

Y con eso llegan a Grafana los 40 chequeos, SMART, la red, el espacio, los huérfanos y el score, **sin instalar un exporter por cada cosa**.

### Qué va y qué no

Solo lo que node-exporter **no puede saber solo**. El espacio del DAS, la CPU, la RAM y la temperatura ya los tiene: escribirlos de nuevo sería tener dos fuentes para el mismo hecho.

| Va | No va |
|---|---|
| `pi_check` de cada chequeo | espacio de disco |
| `pi_salud`, `pi_problemas` | CPU, RAM |
| `pi_voltaje_ok`, `pi_fs_errores` | temperatura de la Pi |
| `pi_smart_*` | tráfico de red por interfaz |
| `pi_red_latencia_ms`, `pi_red_perdida_pct` | uptime |
| `pi_huerfanos_bytes`, `pi_biblioteca_bytes` | |

### Tres detalles que se pagan caro

**Se reescribe entero, nunca se agrega.** Si solo se agregara, un chequeo que desaparece (un contenedor que borraste) dejaría su métrica congelada en verde para siempre.

**Se escribe de forma atómica.** Prometheus lee seguido y tarde o temprano leería el archivo a medio escribir. Se escribe en un `.tmp` y se hace `mv`: o está el viejo entero, o el nuevo entero, nunca la mitad. Es el error clásico de este collector.

**Nunca va algo que cambia adentro de una etiqueta.** Ni el texto de un error ni una fecha. Cada valor distinto crea una serie nueva que Prometheus guarda para siempre: es la forma más común de llenar el disco con el sistema que vigila que no se llene el disco.

### Las que se miden cada dos días

SMART, el espacio del DAS y los huérfanos van a un archivo aparte, `pi-lentas.prom`, que se guarda en disco y se copia a RAM en cada corrida.

Si fueran por el mismo archivo que el resto desaparecerían de Grafana durante 47 horas de cada 48, porque ese archivo se reescribe entero cada vez.

### Quién vigila al vigilante

Si el diagnóstico se muere, sus métricas **no desaparecen: se quedan pegadas** en el último valor bueno. Un tablero todo en verde porque ya nadie está mirando.

node-exporter publica solo la fecha de modificación de cada archivo, así que el tablero tiene un panel de "hace cuánto se midió". En rojo significa que todo lo demás de esa pantalla es viejo. Es el chequeo que le faltó a logrotate.

---

## El score

Un solo número que dice si hace falta abrir algo. **Verde significa no abras nada**, y esa es toda su función.

No es un promedio de categorías, y eso es lo único que importa del diseño. Se arranca en 100 y se resta lo que cuesta cada cosa:

| Qué se rompió | Castigo (`mal`) | (`ojo`) |
|---|---|---|
| Podés perder datos: voltaje, disco lleno, SMART, respaldo, DAS | **40** | 10 |
| Se cayó algo que usás: Pi-hole, Caddy, Jellyfin, internet | **15** | 5 |
| Algo degradado: token vencido, un 502, reinicios en bucle | **8** | 4 |
| Configuración floja: log2ram, fsck, firewall, feed, ganchos | **3** | 3 |

Verde de 90 para arriba, ámbar hasta 70, rojo abajo.

La propiedad que importa: **un solo problema de la primera fila deja el número en 60**, o sea en rojo, sin que haga falta que se acumule nada más. Con un promedio de cinco categorías, ese mismo disco muriéndose mostraría 96 y no lo mirarías.

Y al revés: diez configuraciones flojas dejan 70, incómodo pero no urgente. Que es exactamente lo correcto.

### Lo que el score no hace

**Solo ve lo que está chequeado.** En marzo, cuando logrotate se murió, este número habría marcado 100 durante cinco meses porque nadie le preguntaba a logrotate.

Así que la lección no es "poné un score", es **cada vez que algo te sorprenda, agregá el chequeo**.

---

## Los avisos de media

Radarr y Sonarr no avisan al importar: **escriben una línea en un archivo**. Un timer revisa cada pocos minutos si la tanda terminó y manda un solo mensaje.

```
 Radarr importa  ─┐
                  ├─▶  una linea en un archivo  ─▶  timer  ─▶  ntfy media
 Sonarr importa  ─┘        (dentro del contenedor)   (en el host)
```

Tres cosas caen solas de armarlo así:

**El contenedor no necesita nada.** No curl, no internet, no la URL de ntfy. El script adentro de Radarr es literalmente un `echo` a un archivo, así que **el nombre del canal nunca entra a un contenedor**.

**Es el mismo mecanismo para los dos.** Una película sola y un pack de ocho capítulos pasan por el mismo camino y salen bien los dos.

**Agrupa donde hace falta.** Un capítulo suelto es un aviso; un pack de temporada también es uno solo, no ocho.

| Caso | Qué llega |
|---|---|
| Una película | `Dune: Part Two (2024)` · `1080p, ya la podes ver` |
| Tres películas juntas | `3 peliculas nuevas` · `A, B, C` |
| Un capítulo | `Fallout · temporada 2` · `S02E03, ya lo podes ver` |
| Un pack de 8 | `Fallout · temporada 2` · `8 episodios nuevos` |
| Una mejora de calidad | nada, se descarta |

Lo último importa: que te reemplacen un 720p por un 1080p de algo que ya tenías no es una novedad, es ruido, y el perfil de calidad que mejora solo lo dispara seguido. Se cambia con `MEDIA_AVISAR_MEJORAS` en `ajustes.conf`.

Para que el aviso no mienta, el instalador también le pide a Jellyfin que reescanee al importar. Sin eso te diría "ya la podés ver" antes de que Jellyfin la haya indexado.

---

## Dónde se cambia todo

En [`ajustes.conf`](../ajustes.conf), un solo archivo, y sin tocar código:

```
 discos          cada 48 h, preferentemente a las 04
 espacio         cada 48 h
 respaldo        todos los dias a las 04
 silencio        de 00 a 08 (solo pasa lo grave)
 agrupar media   5 min
 umbrales        disco, temperatura, latencia, perdida, huerfanos
```

Los horarios de los timers de systemd **salen de ahí**: el instalador los escribe con esos valores en vez de que estén escritos a mano en dos lugares. Es el mismo principio que los registros DNS del Caddyfile.

Si cambiás un horario, volvé a correr `./instalador.sh`. Si cambiás un umbral o una cadencia de las de adentro del diagnóstico, vale en la corrida siguiente sin hacer nada.

---

## La cadencia

El diagnóstico corre cada hora y **esa es la pulsación de todo**. Lo pesado no tiene su propio temporizador: declara cada cuánto quiere correr y se saltea el resto de las corridas.

Los discos van cada 48 horas por un motivo que no es obvio: **preguntarle a un disco cómo está lo despierta**. Un chequeo horario tendría los dos discos del DAS girando las 24 horas, o sea que la herramienta que los cuida sería la que los gasta.

Si por lo que sea se pasa la hora preferida, corre igual pasado un día más. Una tarea que se saltea en silencio porque nadie estaba a las 4 no sirve de nada.

---

## Comandos

```bash
./avisos.sh                     # el feed
./avisos.sh --canales           # a que suscribirte
./avisos.sh --probar            # una prueba a cada canal
./diagnostico.sh                # todo, sin avisar a nadie
./diagnostico.sh --avisar       # ademas notifica, anota y publica metricas
systemctl list-timers 'pi-*'    # cuando corre cada cosa
```

Correr el diagnóstico a mano **nunca te manda nada al celular**: `--avisar` lo pasa el timer, no vos.

---

## Cuando algo no llega

| Síntoma | Dónde mirar |
|---|---|
| No llega ningún aviso | `./avisos.sh --canales`, y que estés suscrito a ese nombre exacto |
| Llegan las alertas pero no las de media | el gancho: `./diagnostico.sh --arreglar` lo vuelve a poner |
| Los paneles de Grafana están vacíos | que exista `/run/pi-services/metrics/pi.prom` y que node-exporter lo monte |
| Un panel muestra un número viejo | el panel "hace cuánto se midió": si está rojo, el diagnóstico no está corriendo |
| El aviso de una película llega y en Jellyfin no está | falta la conexión de reescaneo, la pone el instalador |
