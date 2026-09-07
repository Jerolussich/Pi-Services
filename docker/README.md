# Configuración del demonio de Docker

Un solo archivo, `daemon.json`, y existe por una razón concreta: **de fábrica Docker guarda los logs de cada contenedor sin ningún límite de tamaño.**

```bash
sudo cp docker/daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

El instalador lo hace solo.

---

## Por qué importa acá más que en otros lados

Un contenedor sano escribe poco. El problema es el que **entra en bucle de reinicio**: arranca, falla, escribe el error, y vuelve a empezar. Puede repetir eso varias veces por segundo, toda la noche, sin que nadie se entere.

Medido en este equipo: un solo contenedor en bucle durante una tarde dejó un `json.log` de **10,9 MB**. Sin límite, la cuenta es simple: nada impide que llegue a llenar la tarjeta.

Y una tarjeta llena no es solo un inconveniente. Cuando el disco se acaba, las bases de datos se corrompen al escribir, que es exactamente la forma en que este equipo ya perdió una microSD. O sea que un servicio roto puede tumbar a todos los demás, por una vía que no tiene nada que ver con el problema original.

## Qué queda configurado

| Opción | Valor | Qué significa |
|---|---|---|
| `max-size` | `5m` | cada archivo de log llega a 5 MB y rota |
| `max-file` | `3` | se guardan 3, o sea 15 MB de historia por contenedor |

Con 21 contenedores, el techo total son unos **315 MB**. Suficiente historia para diagnosticar cualquier cosa, y un límite que no puede sorprenderte.

## Un detalle que hace tropezar

**Los contenedores que ya existen conservan su configuración de logs vieja.** Cambiar `daemon.json` y reiniciar Docker no los afecta: la opción se fija cuando el contenedor se crea.

Para que tome efecto en todos:

```bash
cd ~/pi-services && docker compose up -d --force-recreate
```

Se puede comprobar cuál quedó con cuál:

```bash
docker inspect <contenedor> -f '{{.HostConfig.LogConfig}}'
```

## El otro que crece

El journal de systemd también acumula, y ahí van los errores del kernel. Está limitado en `/etc/systemd/journald.conf`:

```
SystemMaxUse=100M
RuntimeMaxUse=50M
```

Los dos límites juntos, más `log2ram` manteniendo `/var/log` en RAM cuando corrés desde una microSD, cierran las tres vías por las que los logs pueden llenar el disco.

---

## `init: true`, y de dónde salen los procesos zombie

Ubuntu avisa **"There is 1 zombie process"** en el mensaje de bienvenida y no dice de dónde sale. Sale de un contenedor.

Un proceso zombie es uno que ya terminó pero que nadie recogió: cuando un proceso muere, su padre tiene que leer su código de salida para que el sistema borre la entrada. Si el padre no lo hace, queda ahí. No consume memoria ni CPU, solo un número de proceso, pero señala que alguien no está haciendo su trabajo.

En Docker, el PID 1 del contenedor hereda a todos los procesos que quedan huérfanos, y tiene la obligación de recolectarlos. El problema es que casi ningún PID 1 de contenedor está escrito para eso: son el servidor de la aplicación, no un init.

Acá se juntaron las dos condiciones en **homepage**: su healthcheck corre un `wget` cada diez segundos y su PID 1 es `next-server`, o sea Next.js, que no recolecta nada. El resultado fue un `wget` en estado `Z` durante 22 minutos.

La solución es una línea en el `docker-compose.yml` del servicio:

```yaml
init: true
```

Docker mete `tini` como PID 1 y `tini` sí recolecta. Está puesto en **homepage** y en **jellyfin**, los dos que tienen healthcheck y un PID 1 que no hace de init.

**No está en wallabag**, que también tiene healthcheck, porque ese arranca con `s6-svscan`, que ya recolecta bien. Ponerlo ahí sería ruido.

Para ver si hay zombies y de quién son:

```bash
ps -eo pid,ppid,stat,etime,comm --no-headers | awk '$3 ~ /^Z/'
```
