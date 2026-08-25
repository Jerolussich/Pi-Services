# Arquitectura

Qué hay adentro del Pi, cómo se conecta, y por qué está armado así.

---

## El mapa

```
                    Internet
                       │
                  ┌────┴────┐
                  │ Router  │  192.168.68.1
                  └────┬────┘
                       │
              ┌────────┴────────┐
              │   Raspberry Pi 5 │  192.168.68.66
              └────────┬─────────┘
                       │
   ┌───────────────────┼───────────────────┐
   │                   │                   │
┌──┴───────┐    ┌──────┴──────┐    ┌───────┴────────┐
│ Pi-hole  │    │    Caddy    │    │   Tailscale    │
│ DNS :53  │    │  HTTP :80   │    │  acceso remoto │
│          │    │             │    │                │
│ resuelve │───▶│  proxy a    │    │  entra sin     │
│  *.pi    │    │  todo       │    │  abrir puertos │
└──────────┘    └──────┬──────┘    └────────────────┘
                       │
     ┌───────────┼──────────────┬──────────────┬────────────┐
     │           │              │              │            │
┌────┴────┐ ┌────┴──────┐  ┌────┴─────┐  ┌─────┴──────┐ ┌───┴────┐
│ Panel y │ │  Lectura  │  │  Datos   │  │ Multimedia │ │  Casa  │
│ métricas│ │           │  │personales│  │            │ │        │
└─────────┘ └───────────┘  └──────────┘  └─────┬──────┘ └───┬────┘
                                               │            │
                                          ┌────┴────┐  ┌────┴─────┐
                                          │   DAS   │  │ red del  │
                                          │ 2 discos│  │   host   │
                                          └─────────┘  └──────────┘
```

---

## Las tres decisiones que explican todo

### 1. Nada se expone directamente

Ningún contenedor publica puertos al host. **Todo el tráfico HTTP entra por Caddy en el puerto 80** y de ahí se reparte según el nombre que pediste.

La única excepción es el puerto de torrenting de qBittorrent, que necesita recibir conexiones entrantes de otros pares y no puede ir por proxy.

La ventaja práctica: hay un solo lugar donde mirar quién entra, un solo lugar donde poner autenticación, y agregar un servicio nuevo no abre nada nuevo hacia afuera.

**Ojo con cómo se enuncia esta regla.** No es "todo va en la red del puente de Docker", es **"nada se expone a tu red salvo por Caddy en el 80"**. La diferencia importa porque hay dos cosas que no están en el puente y no lo violan: el panel de Pi-hole, que corre en el host en el 8181, y Home Assistant, que corre en la red del host en el 8123. Los dos tienen su puerto cerrado por UFW y solo Caddy llega.

Home Assistant está ahí porque descubre los dispositivos de la casa por mDNS, SSDP y DHCP, que son protocolos de difusión y no atraviesan el puente. En el puente arrancaría igual y parecería sano, pero habría que cargar cada dispositivo a mano por IP. El detalle está en [../home/README.md](../home/README.md).

### 2. Los nombres los resuelve Pi-hole

Cada servicio tiene un nombre `*.pi` que Pi-hole resuelve a la IP del Pi. Caddy después mira ese nombre y te manda al contenedor correcto.

Por eso Pi-hole no es solo un bloqueador de publicidad: es la pieza de la que depende que funcionen los nombres de toda tu infraestructura. Si Pi-hole se cae, los servicios siguen andando pero no llegás a ellos por nombre.

Los registros se cargan en Pi-hole, en `Local DNS → DNS Records`, todos apuntando a `192.168.68.66`. **No hace falta cargarlos a mano**: el instalador los deriva del Caddyfile, uno por nombre, cada vez que corre. Hoy son 19.

### 3. Un solo compose levanta todo

El `docker-compose.yml` de la raíz no define servicios: los **incluye** desde cada carpeta. Eso permite dos cosas a la vez:

```bash
docker compose up -d          # desde la raiz: levanta los 23 servicios
```

```bash
cd media && docker compose up -d    # desde una carpeta: levanta solo eso
```

Todos comparten la red `pi-services`, así que se ven entre ellos por nombre de contenedor. Por eso en el Caddyfile aparece `reverse_proxy grafana:3000` y no una IP.

---

## Autenticación: dos criterios

No todos los servicios se protegen igual, y la regla es simple:

**Si el servicio trae login propio, Caddy solo hace de proxy.** Es el caso de Grafana, Wallabag, FreshRSS, Jellyfin, Seerr, Radarr, Sonarr, Prowlarr, Bazarr, qBittorrent y Home Assistant.

Seerr es un caso lindo: no tiene contraseña propia porque **entra con la de Jellyfin**. Un usuario menos que recordar, y si cambiás la de Jellyfin, Seerr la sigue sin que hagas nada.

**Si no trae login, Caddy le pone autenticación básica adelante.** Es el caso de Homepage y Prometheus.

La contraseña de esa autenticación básica vive como hash bcrypt en `caddy/.env`, nunca en texto plano y nunca versionada.

---

## Las capas de defensa

| Capa | Qué hace |
|---|---|
| **UFW** | Solo deja entrar 22, 80 y 53. Los puertos del host (8181 de Pi-hole, 8123 de Home Assistant) están bloqueados desde afuera y solo se llega vía Caddy |
| **fail2ban** | Banea por una hora tras 5 intentos fallidos, en SSH y en la autenticación de Caddy. Tu LAN y tu tailnet están exentas, porque si no te dejaba afuera a vos |
| **Caddy** | Punto único de entrada HTTP, con autenticación donde hace falta |
| **Tailscale** | Acceso remoto sin abrir un solo puerto en el router |

Nada de esto está publicado a internet. El router no tiene puertos abiertos hacia el Pi.

---

## Dónde viven los datos

Hay tres lugares distintos y conviene no confundirlos:

**Volúmenes de Docker.** Grafana, Prometheus, Wallabag, FreshRSS, Caddy y los servicios multimedia guardan acá su estado. Sobreviven a que recrees el contenedor. Se listan con `docker volume ls`.

**Carpetas del repositorio.** Las bases SQLite de fitbit, finanzas y news-filter viven en `data/` o `exports/` dentro de cada carpeta de servicio. Están en `.gitignore`, así que **no se van a GitHub**: si perdés el Pi, se pierden salvo que las tengas respaldadas aparte.

**`datos/`**, en la raíz. El feed de eventos, el estado de los avisos y las métricas que se miden cada dos días. Son unos 100 KB de historia que no se reconstruye de ningún lado, así que `respaldo.sh` los guarda. Y el estado de los avisos importa más de lo que parece: sin él, después de restaurar te llegarían de golpe treinta notificaciones de cosas que ya sabías.

**`/run/pi-services/`**, que es RAM. Lo que se reescribe entero cada hora y no tiene nada que recordar: el estado para el mensaje de bienvenida y las métricas que lee node-exporter. Va ahí y no en el disco para no desgastar la tarjeta justamente con la herramienta que vigila que no se desgaste.

**El DAS.** Todo el contenido multimedia. Ver [../media/DAS.md](../media/DAS.md).

Los archivos `.env` con contraseñas y tokens también están fuera de git. Es lo correcto, pero implica que **son lo primero que hay que respaldar**.

---

## Lo que no es Docker

Dos piezas corren directamente en el sistema, no en contenedores, y en los dos casos es a propósito:

**Pi-hole**, porque tiene que responder DNS en el puerto 53 del host de forma confiable, incluso si Docker no está andando.

**Tailscale**, por la misma razón llevada al extremo: si Docker se rompe, querés poder entrar a arreglarlo. Un Tailscale contenerizado se caería junto con el problema que venís a resolver.


---

## Un hallazgo sale por cuatro lados

El diagnóstico siempre supo qué significa "estar bien". Lo que le faltaba era que ese saber saliera de la casa: moría en un archivo que solo veías si entrabas por SSH.

```
                 diagnostico.sh
                       │
     ┌─────────────┬───┴────────┬──────────────┐
     ▼             ▼            ▼              ▼
   pantalla       ntfy         feed        metrica
     │             │            │              │
   MOTD y      celular      eventos.pi     Grafana
   terminal   (si cambio)   (la memoria)  (el historial)
```

Un motor, cuatro canillas, y **un solo punto de llamada**: las funciones `bien`, `ojo` y `mal`. Agregar un chequeo nuevo no obliga a acordarse de la métrica ni del aviso.

Tres decisiones sostienen esto y están desarrolladas en [AVISOS.md](AVISOS.md):

**El que avisa no puede romperse con lo que avisa.** Por eso las notificaciones no son un contenedor sino un `curl` en el host, y el servidor que las reparte no vive en casa. Es el mismo criterio que deja a Pi-hole y Tailscale fuera de Docker.

**Se avisa por cambio, no por estado.** Un canal que repite lo mismo cada hora se silencia en una semana. Y los chequeos de contenedores esperan a confirmar el problema en la corrida siguiente, para que un reinicio de treinta segundos no te despierte.

**Las métricas propias entran por el buzón de node-exporter**, que lee una carpeta de archivos de texto y los publica como métricas suyas. Con una línea de configuración, el diagnóstico se convierte en exporter sin ser un contenedor, y ahí llegan SMART, la red, el espacio y el score sin instalar un exporter por cada cosa.

---

## Tareas programadas

En vez de que cada servicio traiga su propio programador, hay uno solo: **Ofelia**, que dispara trabajos en los demás contenedores según etiquetas. Un único lugar donde ver y cambiar todo lo que corre periódicamente. Ver [../ofelia/README.md](../ofelia/README.md).

Ofelia es para lo que corre **adentro de un contenedor**. Lo que corre en el host (el diagnóstico, el respaldo, el aviso agrupado de media) va por timers de systemd, porque necesita ver el disco, hablar con `smartctl` y conocer el canal de ntfy.

Y en los dos casos vale lo mismo: **el horario no está escrito en el archivo que lo ejecuta**. Los de systemd salen de [`../ajustes.conf`](../ajustes.conf) y el instalador los sustituye al instalar las unidades, igual que deriva los registros DNS del Caddyfile.

### La cadencia de lo pesado

El diagnóstico corre cada hora y esa es la pulsación. Lo que no necesita esa frecuencia no trae su propio temporizador: declara cada cuánto quiere correr y se saltea el resto de las corridas.

Los discos van cada 48 horas por un motivo que no es obvio: **preguntarle a un disco cómo está lo despierta**. Un chequeo horario tendría los dos discos del DAS girando las 24 horas, o sea que la herramienta que los cuida sería la que los gasta.

**El cron de Ofelia lleva seis campos y el primero son segundos.** No es el cron de siempre. Con los cinco clásicos, `0 * * * *` no significa "cada hora" sino "cada minuto", y nadie avisa: las tareas simplemente corren sesenta veces más de lo que pensabas. Para cada hora va `0 0 * * * *`.

---

## Cómo se mantiene solo

Cada dato vive **en un solo lugar** y lo demás se deriva de ahí. Es lo que hace que agregar un servicio no sea un recorrido por seis archivos, acordándose de todos.

El costo de no hacerlo así no es el trabajo extra: es que el día que te olvidás de uno, el síntoma no se parece en nada a la causa. Un servicio sin registro DNS da un error de red. Un puerto desactualizado en una tabla hace que el diagnóstico reporte caído algo que está perfecto.

### Los nombres y los puertos salen del Caddyfile

El Caddyfile ya dice, en una línea, qué nombre atiende y contra qué puerto va:

```
http://sonarr.pi {
    import accesslog
    reverse_proxy sonarr:8989
}
```

De ahí se derivan dos cosas que antes estaban escritas a mano:

| Qué | Quién lo usa | Antes |
|---|---|---|
| Los registros DNS `*.pi` de Pi-hole | el instalador, al configurar Pi-hole | una lista fija de 15 nombres |
| El puerto interno de cada servicio | el diagnóstico, para preguntarle si responde | una tabla de 14 entradas |
| Los puertos del host que hay que abrirle a Caddy | el instalador, al configurar UFW | un solo puerto escrito a mano |

Las funciones son `hosts_del_caddyfile`, `puerto_de` y `puertos_del_host`, las tres en [../lib/comun.sh](../lib/comun.sh).

La tercera se distingue por una diferencia que ya estaba escrita en el Caddyfile sin que nadie la aprovechara: **un contenedor se nombra, el host se direcciona**. `reverse_proxy grafana:3000` contra `reverse_proxy 192.168.68.66:8123`. Los destinos que empiezan con un número son los que necesitan regla de firewall.

**Consecuencia práctica:** agregar un servicio es agregar su bloque al Caddyfile. Los registros DNS se cargan solos la próxima vez que corras el instalador, incluso si Pi-hole ya estaba andando.

Ya se cobró sola: al sumar Seerr y Home Assistant, los registros pasaron de 16 a 19 sin que nadie tocara una lista de nombres. Los tres nuevos son `seerr.pi`, `homeassistant.pi` y `casa.pi`, que es un alias del anterior.

Y también se cobró lo contrario, que es la mejor evidencia de por qué conviene: la lista de puertos del firewall **no** estaba derivada, seguía teniendo solo el 8181, y Home Assistant contestó 502 sin que nada dijera que era el firewall. Ese fue el ejemplo que la convirtió en `puertos_del_host`.

### Las API keys se leen, no se copian

Los recuadros de la homepage muestran datos en vivo solo si tienen la API key de cada servicio. Eso son cuatro claves que antes había que buscar en cuatro paneles y pegar a mano en `homepage/.env`.

Ahora el instalador las lee de la configuración de cada servicio, con `api_key_arr` y `api_key_seerr`, y las escribe solo. **Nunca pasan por tus manos ni por la pantalla**, y si regenerás una, volvés a correr el instalador y se actualiza.

Es el mismo principio que el Caddyfile: la clave ya existe en un lugar, así que ese lugar es la fuente.

### El instalador y el diagnóstico comparten lo que saben

`instalador.sh` sabe **configurar** cada servicio. `diagnostico.sh` sabe **comprobarlo**. Son la misma pregunta desde dos lados, así que si cada uno tuviera su propia idea de qué significa "Radarr está bien", en tres meses dirían cosas distintas.

Por eso todo ese conocimiento vive en [../lib/comun.sh](../lib/comun.sh), que los dos cargan: las definiciones de módulos y servicios, las variables requeridas, la detección de estado y la configuración automática por API. Cada script se queda solo con su flujo.

### Los servicios parecidos comparten código, no copias

Radarr y Sonarr son el mismo motor con distinto contenido: misma API, mismos endpoints, misma forma de configurarse. Cambian el puerto, la carpeta, y cómo llama cada uno a su categoría de descargas.

Van por una sola función, `cfg_arr`, con esas tres cosas como parámetros:

```bash
cfg_radarr() { cfg_arr radarr 7878 Radarr /data/media/movies movie "$1"; }
cfg_sonarr() { cfg_arr sonarr 8989 Sonarr /data/media/tv     tv    "$1"; }
```

Con dos copias, cualquier arreglo hay que acordarse de hacerlo dos veces, y el día que te olvidás queda un bug que solo aparece en las series. El diagnóstico usa el mismo patrón con `rev_un_arr`.

### El nombre de proyecto está fijado

Los doce compose empiezan con `name: pi-services`. Sin eso, Compose usa el nombre de la carpeta, y ese nombre prefija todos los volúmenes: levantar un módulo desde su carpeta, o clonar el repo con otro nombre, creaba un juego de volúmenes paralelo y todo aparecía vacío. Está explicado en [OPERACION.md](OPERACION.md).

### Qué sigue sin derivarse

Para ser honestos, no todo está resuelto. La lista de servicios por módulo (`SERVICIOS` en `lib/comun.sh`) sigue escrita a mano, y podría salir del `docker-compose.yml` de cada carpeta. Lo mismo la asociación servicio a módulo. Son los dos lugares que hay que tocar al agregar algo, además del Caddyfile.
