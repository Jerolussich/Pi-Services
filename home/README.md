# Casa

Home Assistant: automatizar luces, sensores, enchufes y cualquier cosa de la casa que hable por la red.

Entra por `http://casa.pi`, o por `http://homeassistant.pi`, que es el mismo lugar.

---

## Por qué este es el único que va en la red del host

Es el único contenedor del repo que está en la red del host y no en la del puente de Docker, y no es un descuido. (qBittorrent tampoco está en `pi-services`, pero por la razón contraria: lo encierra una red propia, `pi-torrent`. Ver [../docs/TORRENTS.md](../docs/TORRENTS.md).)

Home Assistant descubre los dispositivos de la casa por **mDNS, SSDP y DHCP**, que son protocolos de difusión: no atraviesan el puente de Docker. En la red del puente arranca igual y funciona, pero **no encuentra nada solo** y hay que cargar cada dispositivo a mano por IP, que es justo el trabajo que uno quiere evitar.

**Y no rompe la arquitectura**, porque no es la primera vez que pasa: Caddy ya proxea un servicio del host, el panel de Pi-hole en el 8181. La regla real de este repo nunca fue "todo en la red del puente", es **"nada se expone a tu red salvo por Caddy en el 80"**. Eso se sigue cumpliendo: el 8123 queda cerrado por UFW igual que el 8181, y solo Caddy llega.

---

## Cuatro cosas que el instalador deja hechas, y por qué

### Que funcione detrás de Caddy

Sin esto, Home Assistant ve todas las visitas llegando desde la IP de Caddy y las rechaza con un **400 Bad Request**. El síntoma es una pantalla en blanco que no menciona proxies por ningún lado, así que cuesta bastante atarlo a su causa.

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
```

Pero escribirlo no alcanza, y acá está la parte que no es obvia.

**Home Assistant no se cree esa configuración porque se la pidas.** La aplica como `pending` y espera confirmación. Si en cinco minutos no llega, la revierte, la marca `not_promoted`, y `casa.pi` contesta 400 a partir de ahí.

Y lo que confirma no es cualquier pedido: tiene que ser **autenticado y llegar por el proxy**. Un `curl` sin sesión devuelve 302, parece que anda, y cinco minutos después vuelve el 400.

Leyendo el código de Home Assistant, la **única** vía de confirmación es el comando WebSocket autenticado `http/config/promote`, que manda el frontend. O sea: hace falta usuario, sesión, y que la página cargue por el proxy que todavía no anda. Un círculo cerrado.

La salida es hacer lo mismo que hace ese comando pero con Home Assistant parado, escribiendo su store directamente. Eso es [`promover-proxy.py`](promover-proxy.py), y el instalador lo corre solo:

```python
stable = pending      # exactamente lo que hace async_promote_pending()
pending = None
yaml_migration_done = True
```

Ese `yaml_migration_done` es la mitad importante: sin él, el bloque `http:` del YAML se vuelve a escenificar como `pending` en **cada arranque**, y el problema vuelve al siguiente reinicio.

Dos detalles se aprendieron a los golpes y están comentados en el script. El primero: `pending` se deja en `null`, no se borra la clave. El cargador de HA la lee por índice directo, así que si falta, el store no carga, el componente `http` no arranca, y con él se caen el frontend, la API y la autenticación. Lo probamos sin querer. El segundo: la configuración que se promueve es **la que generó HA tal cual**, no una armada a mano, así es válida contra su propio esquema por construcción.

El resultado, si no se sabe, es el peor error posible de diagnosticar: `configuration.yaml` dice exactamente lo correcto, el contenedor está sano, y el log no menciona proxies hasta que ya es tarde.

### Que Caddy pueda llegarle

En la red del host, Home Assistant escucha en el 8123, y ese puerto **no está abierto**: UFW lo deja pasar solo desde las redes de Docker, para que llegue Caddy, y lo deniega para todo el resto. Exactamente el mismo trato que el panel de Pi-hole en el 8181.

Si falta esa regla, Caddy contesta **502** y la confirmación de arriba tampoco puede pasar, así que se cae todo en cadena. Es lo que pasó la primera vez que se instaló.

Cuáles son esos puertos sale del Caddyfile, no de una lista: los destinos que empiezan con un número son del host, los que empiezan con una letra son contenedores.

### Que no se coma la tarjeta

El **recorder** es de lejos lo que más escribe de todo Home Assistant: guarda cada cambio de cada entidad, y de fábrica retiene 10 días. En una Raspberry con microSD es el componente que más la desgasta.

Queda configurado en 3 días, con confirmación cada 30 segundos en vez de cada cambio, y sacando las entidades más ruidosas: las de hora, fecha, tiempo encendido y las del sol, que cambian cada pocos segundos y no sirven para mirar hacia atrás.

Si algún día tenés el disco externo y querés historial largo, subí `purge_keep_days` en `config/configuration.yaml`.

### Que el Bluetooth ande

Home Assistant también habla con el Bluetooth del equipo (sensores y otros aparatos que haya cerca), y para eso hacen falta dos cosas que no vienen solas: el servicio **bluez** en el host, y que el contenedor llegue a él.

Lo segundo está en el compose, y explica dos líneas que de otro modo parecen exageradas:

- **`privileged: true`**: es el acceso al hardware de la máquina, que es justamente para lo que sirve tener esto en casa y no en la nube de otro. Sin eso el contenedor no ve el adaptador.
- **`/run/dbus:/run/dbus:ro`**: bluez no vive adentro de la imagen, se maneja por DBus desde el host, y ese montaje es el cable. Va en solo lectura porque Home Assistant solo necesita hablarle al bus, no cambiarlo.

Lo primero lo hace el instalador (`cfg_ha_bluetooth`, en [`../lib/comun.sh`](../lib/comun.sh)), y lo hace con cuidado:

- **Si el equipo no tiene adaptador Bluetooth** (el caso de muchos equipos, y es lo que se detecta mirando `/sys/class/bluetooth`) no instala nada: no tiene sentido sumar un servicio sin hardware que atender.
- **Si lo tiene**, instala `bluez` (y `rfkill`) solo si faltan, habilita y prende el servicio, saca el bloqueo por software y comprueba que el adaptador figure encendido.
- **Reinicia Home Assistant solo si cambió algo**, porque él busca el servicio únicamente cuando arranca.
- **bluez corre solo en esta máquina, sin escuchar en la red.** No empareja nada ni deja el equipo visible: eso lo decide cada dispositivo que agregues desde Home Assistant.

Sin bluez, Home Assistant no encuentra a quién hablarle y deja un error cada cinco minutos en su log. No rompe nada, pero tapa los errores que sí importan. Por eso el diagnóstico lo vigila (`rev_ha_bluetooth`, solo si hay adaptador): si el servicio del equipo está apagado o no está instalado lo marca y ofrece arreglarlo con `./diagnostico.sh --arreglar` (`rep_bluetooth`, que vuelve a correr el mismo paso del instalador), y si el servicio anda pero el log de la última hora trae errores de Bluetooth lo marca también, con el comando para mirarlos. Ver [../docs/DIAGNOSTICO.md](../docs/DIAGNOSTICO.md).

---

## Lo que sí tenés que hacer vos

**Poner la ubicación.** Si en el instalador le dejaste crear las cuentas, el usuario `admin` ya existe, con tu contraseña de siempre: lo crea por la misma API que usa el asistente de bienvenida, sin navegador. Si preferiste crearlas vos, entrás a `http://casa.pi` y el asistente te pide nombre, usuario y contraseña, y ese paso queda anotado como pendiente.

En los dos casos, al entrar la primera vez te pide **la ubicación en un mapa** y si querés mandar estadísticas de uso. Esos dos pasos los deja a propósito para vos: la ubicación es tu casa y no la va a inventar, y ponerla bien vale la pena porque de ahí salen el amanecer y el atardecer, que es con lo que se disparan la mitad de las automatizaciones de una casa. Lo de las estadísticas es una decisión de privacidad, y anotarte sin preguntar estaría mal.

Son dos minutos y es una sola vez. La configuración del proxy ya está confirmada, así que no importa por dónde entres.

**Después, agregar tus dispositivos.** En `Ajustes → Dispositivos y servicios` vas a ver que ya descubrió solo lo que hay en tu red, justamente por estar en la red del host.

**Y si querés el recuadro con datos en vivo en la homepage**, ahí sí hace falta un token. En `casa.pi`, tu perfil, abajo de todo, **Crear token**; lo pegás en `homepage/.env` como `HOMEPAGE_VAR_HA_TOKEN` y descomentás el bloque `widget` en `homepage/config/services.yaml`. El instalador no puede leerlo solo como hace con los de Radarr o Seerr, porque ese token no existe hasta que exista tu usuario.

---

## Estructura

```
home/
├── docker-compose.yml
├── promover-proxy.py        ← confirma la config del proxy sin navegador
├── .env
├── .env.example
└── config/
    ├── configuration.yaml    ← lo que deja el instalador
    ├── automations.yaml      ← tus automatizaciones
    ├── scripts.yaml
    └── scenes.yaml
```

A diferencia del resto del repo, la configuración va en una carpeta del repo y no en un volumen de Docker. Es a propósito: `configuration.yaml` es un archivo que vas a editar seguido, y tenerlo a mano vale más que la prolijidad de un volumen.

**Ojo:** eso significa que tus automatizaciones **no están en git** salvo que las agregues. Sí entran en el respaldo diario.

---

## Levantar y bajar

```bash
cd ~/pi-services && docker compose up -d homeassistant
```

```bash
cd ~/pi-services && docker compose restart homeassistant
```

Después de tocar `configuration.yaml` hay que reiniciarlo, o usar `Herramientas de desarrollo → YAML → Recargar` desde la propia interfaz.

---

## Lo que hay que saber antes de meterse

Home Assistant **no es un servicio más**. Es un proyecto en sí mismo: tiene versiones nuevas todos los meses, a veces con cambios que rompen, y una comunidad enorme con documentación propia. Instalarlo es media hora; sacarle provecho es un pasatiempo.

La variante que corre acá es **Home Assistant Container**, que es la oficial para Docker. Comparada con Home Assistant OS, se pierden los "add-ons" (los complementos de un clic, como Node-RED o Zigbee2MQTT). Eso no es un problema en este repo: acá los add-ons serían contenedores más, que es como ya se hace todo.
