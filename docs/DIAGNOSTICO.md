# El diagnóstico

`diagnostico.sh` responde una sola pregunta: **¿qué anda, qué no, y por qué?** Es la herramienta que sabe qué significa "estar bien" en esta máquina, y todo lo demás (los avisos al celular, el feed, Grafana, el mensaje de bienvenida del SSH, la verificación final del instalador) se alimenta de lo que ve acá.

<p align="center">
  <img src="img/diagnostico.png" alt="La salida de `pi estado`" width="60%">
  <br><sub>La salida de `pi estado`</sub>
</p>

```bash
pi estado                   # o ./diagnostico.sh: todo, con el detalle de lo que está bien
pi estado --breve           # solo lo que está mal
pi estado --arreglar        # y ofrece arreglar lo que sabe arreglar
pi estado radarr            # un contenedor suelto
```

Devuelve `0` si está todo bien y `1` si hay algo para mirar, así que sirve también para llamarlo desde una tarea programada.

---

## Cómo piensa

Cada cosa depende de una cadena de eslabones, y el diagnóstico **se corta en el primero que está roto**: lo que sigue es consecuencia. Si Pi-hole está caído fallan todos los nombres `.pi` de golpe, y reportar veinte errores esconde el único que importa. Por eso al final, cuando hay una causa de fondo clara, el resumen la nombra ("la causa de fondo parece ser: el disco está al 91%") y te avisa que arreglándola probablemente se vayan solos varios de los otros.

Tres reglas gobiernan lo que imprime:

- **Lo que está bien va en una línea y no se explica.** Si anda, no hay nada que decir.
- **Lo que está mal explica qué implica, en una línea** (`implica`), y a veces qué se comprobó para llegar ahí (`según`).
- **Cuando se le acaban los caminos, lo dice.** Un `freno` es algo que el script no puede hacer (necesita un navegador, tu cuenta, hardware o una decisión tuya), con el porqué y qué te toca a vos. Un diagnóstico que se calla justo donde no supo qué hacer te deja buscando en el lugar equivocado.

Cada hallazgo tiene tres estados: `●` bien, `◐` ojo (conviene mirarlo), `✗` mal.

---

## Las opciones

| | Qué hace |
|---|---|
| (sin nada) | Corre todo e imprime todo, también lo que está bien |
| `--breve` (`-b`) | Imprime solo `◐` y `✗`. Es lo que usa el timer y lo que corre el instalador al terminar |
| `--arreglar` (`-a`) | Al final lista lo que sabe arreglar y, si le decís que sí, lo aplica y **verifica** que haya quedado |
| `--avisar` | Además de imprimir: manda el aviso al celular si algo **cambió** de estado, anota en el feed y publica las métricas. Lo pasa el timer `pi-estado`, no vos |
| `<contenedor>` | Revisa solo ese contenedor (los cuatro eslabones de abajo), sin tocar métricas |
| `--ayuda` (`-h`) | La ayuda |

**Correrlo a mano nunca te manda nada al celular.** `--avisar` lo pasa solo el timer.

Una corrida de un contenedor suelto tampoco publica métricas ni el score: el archivo de métricas se reescribe entero, y una corrida parcial borraría las otras decenas de chequeos.

---

## Qué revisa, en orden

El orden es el de las capas: primero lo que, si falla, hace que lo de arriba no importe.

| Sección | Qué mira |
|---|---|
| **El equipo** | Espacio del disco del sistema (ámbar y rojo desde `DISCO_OJO` y `DISCO_MAL`), voltaje (`vcgencmd`, solo en una Pi), temperatura, errores del sistema de archivos y **si crecen** de una corrida a la otra, qué hace ext4 ante un error (`remount-ro`), chequeo periódico del disco cada 30 arranques, y log2ram (solo se reclama si arrancás de una microSD) |
| **La línea** | Internet, no las interfaces: latencia y pérdida contra `PING_DESTINO`, con diez paquetes. Se mide contra una IP y no un nombre, para no medir también al DNS |
| **DNS** | Pi-hole vivo, que **resuelva** de verdad (proceso vivo y servicio útil no son lo mismo), que estén todos los registros `.pi` del Caddyfile, y que escuche en `ALL` si hay Tailscale |
| **La puerta** | Caddy arriba, sin errores en su log, y que cada nombre del Caddyfile conteste algo distinto de 502 |
| **Los contenedores** | Los cuatro eslabones, ver abajo |
| **Multimedia** | Que el DAS esté montado, que qBittorrent siga aislado (red aparte, permisos, regla de UFW, reglas de iptables, solo la carpeta de descargas) y el estado del puerto de torrents, indexers de Prowlarr, que Radarr y Sonarr tengan carpeta raíz, cliente de descargas e indexers, perfil de idiomas de Bazarr, y biblioteca de Jellyfin |
| **Home Assistant** | Que el Bluetooth del equipo ande (`rev_ha_bluetooth`), solo si hay adaptador |
| **Monitoreo** | Que los objetivos de Prometheus respondan |
| **Datos personales** | Que los permisos de Fitbit y del correo del banco no hayan vencido: el contenedor corre pero no baja un solo dato |
| **Fuera de Docker** | UFW y fail2ban activos, y Tailscale conectado |
| **Los discos** | SMART de cada disco: falla declarada, sectores pendientes o no corregibles, reasignados que **crecen**, errores CRC (que acusan al cable y no al disco) y temperatura |
| **El espacio** | Cuánto queda en cada montaje del DAS, y cuántos GB hay en descargas que nunca llegaron a la biblioteca |
| **La biblioteca** | Películas que Radarr cree tener y no están en disco, y series con episodios y sin carpeta |
| **Los avisos** | Que los canales estén configurados (o apagados a propósito, que es un estado válido y no un reproche), que el feed no se desborde y que el gancho de importaciones siga puesto en Radarr y Sonarr |

Tres revisiones pesadas (discos, espacio y biblioteca) tienen cadencia propia y se saltean el resto de las corridas: discos y espacio cada `CADA_CUANTO_DISCOS` horas, biblioteca cada `CADA_CUANTO_BIBLIOTECA`. Los discos no se consultan cada hora porque **preguntarle a un disco cómo está lo despierta**: el chequeo que los cuida sería el que los gasta. Todo está en [`../ajustes.conf`](../ajustes.conf), y eso explica que el instalador avise que "hay revisiones que corren cada varias horas y pueden no entrar en esta pasada".

### Los cuatro eslabones de un contenedor

Para cada contenedor, en este orden, cortando en el primero que falla:

1. **Existe.** Si no está creado pero sí en algún compose, "nunca se levantó"; si no está en ninguno, es un `freno`.
2. **Corre.** Si salió, muestra el código: el 137 es el sistema matándolo por falta de memoria, y subirlo de nuevo no cambia nada.
3. **No está en bucle.** Un bucle son *dos* cosas, no una: que el contador de reinicios **crezca** de una corrida a la otra, o que lleve segundos de vida con muchos reinicios encima. `RestartCount` es un contador de por vida, y hay servicios que se reinician solos como parte de su funcionamiento normal (la homepage cada vez que editás su configuración): mirar solo el número daba falsas alarmas.
4. **Contesta.** Se le pregunta por HTTP *desde el host* a la IP del contenedor, y el puerto sale del Caddyfile. Si recién arrancó (menos de dos o tres minutos), un 5xx o un silencio es `◐` (todavía arranca); pasada la ventana, `✗`.

---

## Lo que arregla (`--arreglar`)

Para estar en esta lista un arreglo tiene que cumplir tres cosas: ser **reversible**, **no borrar datos** y poder **verificarse después**. Uno que dice haber andado sin comprobarlo es peor que no tenerlo.

| Qué | Función |
|---|---|
| Borrar imágenes y capas que no usa nadie | `rep_liberar_docker` |
| Que ext4 pase a solo lectura ante un error | `rep_errores_remount_ro` |
| Chequeo del disco cada 30 arranques | `rep_activar_fsck` |
| Reiniciar log2ram, Pi-hole o fail2ban | `rep_reiniciar_servicio` |
| Cargar los registros `.pi` que faltan | `rep_dns_faltantes` |
| Pi-hole en modo `ALL` | `rep_pihole_escucha` |
| Levantar o recrear un contenedor | `rep_levantar`, `rep_recrear` |
| Validar y recargar Caddy | `rep_recargar_caddy` |
| Pausar las descargas hasta conectar el disco | `rep_pausar_descargas` |
| Volver a aislar a qBittorrent | `rep_aislar_torrents` |
| Configurar Radarr o Sonarr (pide la contraseña) | `rep_configurar_arr` |
| Instalar y prender bluez | `rep_bluetooth` |
| Instalar `smartmontools` | `rep_instalar_smartmontools` |
| Volver a poner el gancho de importaciones | `rep_ganchos_media` |

Lo que no está acá no es un olvido: es lo que no se puede arreglar sin vos, y sale como `freno` (reparar el sistema de archivos con la raíz montada, cambiar una fuente de alimentación, cargar indexers, autorizar Fitbit).

---

## El score

Al final de una corrida completa sale un número de 0 a 100: **verde significa que no hace falta abrir nada**. Se arranca en 100 y se resta lo que cuesta cada hallazgo, según a qué clase pertenece (`clase_de` en el script):

| Clase | Qué incluye | `mal` | `ojo` |
|---|---|---|---|
| Podés perder datos | voltaje, disco, sistema de archivos, respaldo, SMART | 40 | 10 |
| Se cayó algo que usás | Pi-hole, Caddy, Jellyfin, homepage, internet | 15 | 5 |
| Configuración floja | log2ram, chequeo del disco, firewall, Tailscale, canales, feed, gancho de media | 3 | 3 |
| Todo lo demás (degradado) | un 502, reinicios en bucle, un permiso vencido, etc. | 8 | 4 |

Verde desde 90, ámbar hasta 70, rojo abajo. Un solo problema de la primera fila te deja en 60, rojo, sin que se acumule nada más. Más detalle del diseño y de por qué no es un promedio, en [AVISOS.md](AVISOS.md#el-score).

**Solo ve lo que está chequeado.** Cuando logrotate se murió en marzo, este número habría marcado 100 durante cinco meses porque nadie le preguntaba a logrotate. La lección es que cada vez que algo te sorprenda, hay que agregar el chequeo.

---

## Adónde va lo que encuentra

Cada hallazgo pasa por tres funciones (`bien`, `ojo` y `mal`) y de ahí sale por cuatro lados: la pantalla, el celular (`--avisar`, solo si cambia), el feed de `eventos.pi` y las métricas de Grafana. Agregar un chequeo nuevo no obliga a acordarse de ninguna de las otras tres. Los archivos que deja:

| Archivo | Para qué |
|---|---|
| `/run/pi-services/estado` | La última salida breve. La leen `pi` a secas y el mensaje de bienvenida del SSH. Vive en RAM para no desgastar la tarjeta |
| `/run/pi-services/metrics/pi.prom` y `pi-lentas.prom` | Las métricas que levanta node-exporter |
| `datos/estado.json` | El score, que sirve Caddy en `/estado.json` para el recuadro de la homepage |
| `datos/eventos.log` | El feed |

Todo el detalle de los avisos, el feed y las métricas, en [AVISOS.md](AVISOS.md).
