# Ofelia

Scheduler centralizado para tareas cron en contenedores Docker. Reemplaza el patrón de tener un daemon `cron` corriendo dentro de cada contenedor.

---

## Por qué Ofelia en lugar de cron-en-contenedor

### El problema con cron-en-contenedor

El patrón tradicional es instalar cron dentro del contenedor y hacer que sea PID 1:

```dockerfile
RUN apt-get install -y cron
CMD ["cron", "-f"]
```

Esto tiene varios problemas:

**PID 1 no maneja señales correctamente** — PID 1 es el proceso init del contenedor. Cron no fue diseñado para este rol. Cuando Docker envía `SIGTERM` para detener el contenedor, cron lo ignora o no lo propaga a los procesos hijos. Docker espera 10 segundos y fuerza un `SIGKILL`. Los shutdowns nunca son limpios.

**Las variables de entorno no llegan al script** — Cron spawna procesos en un entorno limpio, sin heredar las variables que Docker inyectó en el contenedor. `WALLABAG_URL`, `FRESHRSS_API_PASSWORD`, etc. no están disponibles a menos que se haga un workaround explícito.

**El schedule está enterrado en el Dockerfile** — Cada contenedor tiene su propio schedule hardcodeado en el `RUN` del Dockerfile. Para cambiar el horario hay que modificar el Dockerfile y reconstruir la imagen.

**Un daemon cron por servicio** — Si tenés 5 servicios con cron, tenés 5 daemons cron corriendo en paralelo, cada uno consumiendo recursos innecesarios.

### Cómo lo resuelve Ofelia

Ofelia es un contenedor dedicado exclusivamente al scheduling. Usa `docker exec` para correr comandos en otros contenedores en los horarios definidos.

```
Ofelia
  → 0 8 * * *  : docker exec news-filter python /app/filter.py
  → 0 * * * *  : docker exec itau-tracker python /app/fetch.py
```

**Las variables de entorno están disponibles** — `docker exec` corre el comando dentro del contexto del contenedor destino, con todas sus variables de entorno ya inyectadas por Docker.

**Shutdown limpio** — Los contenedores `news-filter` e `itau-tracker` ahora corren `sleep infinity` como PID 1. `sleep` maneja `SIGTERM` correctamente y el contenedor se detiene limpiamente.

**El schedule está en el compose** — Los horarios se definen como labels en el `docker-compose.yml` de cada servicio, no en el Dockerfile. Cambiar el horario es editar una línea y hacer `docker compose restart ofelia`.

**Un solo scheduler para todo** — Sin importar cuántos servicios agregues, hay un único Ofelia manejando todos los schedules.

---

## Arquitectura

```
Ofelia (accede al Docker socket)
  ├── lee labels de contenedores activos al iniciar
  ├── 0 8 * * *  → docker exec news-filter python /app/filter.py
  └── 0 * * * *  → docker exec itau-tracker python /app/fetch.py

news-filter (CMD: sleep infinity)
  └── espera ser invocado por Ofelia o por el UI

itau-tracker (CMD: sleep infinity)
  └── espera ser invocado por Ofelia o por el UI
```

---

## Directorio

```
ofelia/
├── docker-compose.yml
└── README.md
```

---

## Configuración

El scheduling se define como labels en el `docker-compose.yml` de cada servicio:

```yaml
services:
  news-filter:
    labels:
      ofelia.enabled: "true"
      ofelia.job-exec.news-filter.schedule: "0 8 * * *"
      ofelia.job-exec.news-filter.command: "python /app/filter.py"
```

| Label | Descripción |
|---|---|
| `ofelia.enabled` | Activa Ofelia para este contenedor |
| `ofelia.job-exec.<nombre>.schedule` | Cron expression del schedule |
| `ofelia.job-exec.<nombre>.command` | Comando a ejecutar vía `docker exec` |

El nombre del job (`news-filter` en el ejemplo) puede ser cualquier string único — se usa solo para identificar el job en los logs.

---

## Interacción con el mecanismo de pausa de la UI

Los botones **⏸ Pause** y **▶ Resume** de la UI siguen funcionando igual. Ofelia dispara `docker exec` en el horario definido, pero el script verifica al inicio si existe el archivo `data/paused` y sale inmediatamente si está pausado.

```
Ofelia → docker exec news-filter python /app/filter.py
                    ↓
           ¿existe data/paused?
           ├── Sí → exit (respeta la pausa de la UI)
           └── No → corre normalmente
```

El botón **▶ Run now** de la UI también sigue funcionando — ejecuta `filter.py` directamente vía `subprocess.Popen`, independientemente de Ofelia.

---

## Comportamiento con contenedores detenidos

Si el contenedor destino está detenido cuando Ofelia intenta correr el job, Ofelia registra el error en su log y continúa con el siguiente schedule. No crashea ni afecta otros jobs.

```
ofelia  | [ERROR] exec news-filter: container is not running
```

Cuando el contenedor vuelve a estar activo, el próximo disparo del schedule funciona normalmente.

---

## Agregar nuevos servicios

Para que Ofelia maneje un nuevo servicio, solo hay que agregar labels al `docker-compose.yml` del servicio y reiniciar Ofelia:

```bash
docker compose restart ofelia
```

Ofelia rescana los contenedores activos y detecta los nuevos labels automáticamente.

Para que Ofelia **ignore** un servicio, simplemente no se le agregan labels.

---

## Logs

```bash
docker logs ofelia
docker logs ofelia --follow
```

Ofelia loguea cada ejecución con timestamp, nombre del job, y resultado (success/error).

---

## Setup

Ofelia está incluido en el root `docker-compose.yml`. No requiere configuración adicional.

```bash
docker compose up -d ofelia
docker logs ofelia | tail -10
```
