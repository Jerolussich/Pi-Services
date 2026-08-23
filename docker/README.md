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

Los dos límites juntos, más `log2ram` manteniendo `/var/log` en RAM, cierran las tres vías por las que los logs pueden llenar la tarjeta.
