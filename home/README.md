# Casa

Home Assistant: automatizar luces, sensores, enchufes y cualquier cosa de la casa que hable por la red.

Entra por `http://casa.pi`, o por `http://homeassistant.pi`, que es el mismo lugar.

---

## Por qué este es el único que va en la red del host

Es el único contenedor del repo que no está en la red `pi-services`, y no es un descuido.

Home Assistant descubre los dispositivos de la casa por **mDNS, SSDP y DHCP**, que son protocolos de difusión: no atraviesan el puente de Docker. En la red del puente arranca igual y funciona, pero **no encuentra nada solo** y hay que cargar cada dispositivo a mano por IP, que es justo el trabajo que uno quiere evitar.

**Y no rompe la arquitectura**, porque no es la primera vez que pasa: Caddy ya proxea un servicio del host, el panel de Pi-hole en el 8181. La regla real de este repo nunca fue "todo en la red del puente", es **"nada se expone a tu red salvo por Caddy en el 80"**. Eso se sigue cumpliendo: el 8123 queda cerrado por UFW igual que el 8181, y solo Caddy llega.

---

## Dos cosas que el instalador deja hechas, y por qué

### Que funcione detrás de Caddy

Sin esto, Home Assistant ve todas las visitas llegando desde la IP de Caddy y las rechaza con un **400 Bad Request**. El síntoma es una pantalla en blanco que no menciona proxies por ningún lado, así que cuesta bastante atarlo a su causa.

```yaml
http:
  use_x_forwarded_for: true
  trusted_proxies:
    - 172.16.0.0/12
```

### Que no se coma la tarjeta

El **recorder** es de lejos lo que más escribe de todo Home Assistant: guarda cada cambio de cada entidad, y de fábrica retiene 10 días. En una Raspberry con microSD es el componente que más la desgasta.

Queda configurado en 3 días, con confirmación cada 30 segundos en vez de cada cambio, y sacando las entidades más ruidosas: las de hora, fecha, tiempo encendido y las del sol, que cambian cada pocos segundos y no sirven para mirar hacia atrás.

Si algún día tenés el disco externo y querés historial largo, subí `purge_keep_days` en `config/configuration.yaml`.

---

## Lo que sí tenés que hacer vos

**Crear tu usuario.** La primera vez que entres a `http://casa.pi` te pide nombre, contraseña y ubicación. Eso no se puede automatizar: Home Assistant genera claves criptográficas por instalación durante ese paso, y sembrarlas de antemano sería peor que hacerlo a mano.

Son dos minutos y es una sola vez.

**Después, agregar tus dispositivos.** En `Ajustes → Dispositivos y servicios` vas a ver que ya descubrió solo lo que hay en tu red, justamente por estar en la red del host.

---

## Estructura

```
home/
├── docker-compose.yml
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
