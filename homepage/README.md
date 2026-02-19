# Homepage

Dashboard unificado para todos los servicios del Pi. Corre como contenedor Docker y sirve como punto de entrada visual a toda la infraestructura.

---

## Arquitectura

```
homepage/
├── docker-compose.yml
├── .env                  ← gitignored
├── .env.example
└── config/               ← Bind-mounted en el contenedor
    ├── services.yaml     ← Links a los servicios
    ├── settings.yaml     ← Configuración general
    ├── widgets.yaml      ← Widgets del dashboard
    ├── bookmarks.yaml    ← Bookmarks externos
    ├── docker.yaml       ← Integración Docker (opcional)
    └── kubernetes.yaml   ← Integración K8s (opcional)
```

---

## Setup

### 1. Configurar el .env

```bash
cp .env.example .env
```

Editar `.env`:

```
PI_IP=your_pi_ip
```

### 2. Levantar el contenedor

Desde la raíz del repo:

```bash
docker compose up -d homepage
```

O solo este servicio desde su carpeta:

```bash
cd homepage
docker compose up -d
```

### 3. Verificar

```bash
docker logs homepage
```

Acceder en: `http://<pi_ip>:3001`

---

## Configuración

Todos los archivos de config están en `config/` y son bind-mounted al contenedor. Cualquier cambio que hagas en los archivos se refleja automáticamente sin necesidad de reiniciar el contenedor.

### services.yaml
Define los links a los servicios organizados por grupo. Estructura actual:

| Grupo | Servicios |
|---|---|
| Network | Pi-hole, Grafana |
| Reading | Wallabag |
| FitbitDashboard | Fitbit Main, Fitbit Insights |
| Tools | System Stats |

Para agregar un servicio nuevo:

```yaml
- MiGrupo:
    - MiServicio:
        icon: nombre-icono.png
        href: http://<pi_ip>:<puerto>
        description: Descripción corta
```

Los íconos disponibles se pueden buscar en [https://github.com/walkxcode/dashboard-icons](https://github.com/walkxcode/dashboard-icons). Para íconos MDI usar el prefijo `mdi-`, ejemplo: `mdi-heart-pulse`.

### settings.yaml
Configuración general del dashboard — tema, colores, hosts permitidos. Si cambiás la IP del Pi, actualizá `allowedHosts` acá y `PI_IP` en el `.env`.

### widgets.yaml
Widgets que aparecen en la barra superior:

| Widget | Descripción |
|---|---|
| `search` | Buscador Google |
| `datetime` | Fecha y hora |
| `resources` | CPU, RAM y disco del Pi |
| `greeting` | Texto de bienvenida |

### bookmarks.yaml
Links externos agrupados por categoría. Actualmente: GitHub, Reddit, YouTube.

---

## Variables de entorno

| Variable | Descripción | Ejemplo |
|---|---|---|
| `PI_IP` | IP del Pi en la red local | `192.168.68.66` |

`PI_IP` se usa para setear `HOMEPAGE_ALLOWED_HOSTS` — sin esto Homepage rechaza las conexiones con un error de host validation.

---

## Notas

- El contenedor expone el puerto `3001` (Homepage corre internamente en `3000`)
- Los archivos de config se editan directamente en el host, no hace falta entrar al contenedor
- Si agregás un servicio en `services.yaml`, el dashboard se actualiza al recargar el browser
- `docker.yaml` y `kubernetes.yaml` están incluidos pero vacíos — se pueden completar para mostrar el estado de los contenedores directamente en el dashboard
