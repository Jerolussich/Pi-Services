# Incidente del 20 de agosto de 2026

Registro de qué pasó, cómo se diagnosticó y qué se reparó. Sirve como referencia si algo parecido vuelve a aparecer.

---

## Síntomas iniciales

- `npm install` terminaba en segmentation fault
- SSH daba `Connection timed out`, no `refused`
- Ningún servicio web respondía
- `sudo ufw status` tiraba un traceback de Python
- `iptables` moría con bus error

---

## Causa raíz

**Apagados sucios**, por cortes de luz y por apagar con el botón. Cada corte a mitad de una escritura dejó bloques inconsistentes en el sistema de archivos, con contenido de un archivo apareciendo dentro de otro.

Evidencia que lo confirma:

| Evidencia | Qué significa |
|---|---|
| `libpopt.so.0` con texto `nteger\0visual_pa` en vez de la firma ELF | contenido de otro archivo adentro |
| `containerd.io.list` con `Kusto.Language.EngineComm` | idem, en la base de dpkg |
| `fetch.py` conteniendo logs de Prometheus | un `.py` sobrescrito con otro archivo |
| `/lost+found` con **987 archivos huérfanos** | ya hubo `fsck` de rescate antes |
| `rm` devolviendo `EBADMSG` | falla de checksum de metadatos de ext4 |
| `Filesystem state: clean with errors` | el propio sistema de archivos se declara dañado |
| `Maximum mount count: -1` | las verificaciones automáticas estaban **desactivadas** |

---

## La cadena de fallas

```
apagado sucio
      ▼
libpopt.so.0 corrupta  ──▶  logrotate muere (19 de marzo)
                                    ▼
                        pihole.log crece 5 meses a 1,8 GB
                                    ▼
                              disco al 95%
                                    ▼
                    13 servicios caidos + dpkg roto
                                    ▼
libglib2.0 corrupta  ──▶  cada operacion de apt termina en SIGILL
                                    ▼
5 extensiones de xtables corruptas  ──▶  iptables con bus error
                                    ▼
                    Docker no arranca  +  UFW no funciona
                                    ▼
                              sin acceso SSH
```

El detalle clave: **`iptables` era la pieza que sostenía Docker y UFW a la vez.** Repararla destrabó las dos.

---

## Todo lo que estaba dañado

| Componente | Daño | Reparación |
|---|---|---|
| `libpopt.so.0` | contenido ajeno | reinstalación del paquete |
| `libglib2.0-0t64` | corrupta, causaba SIGILL en todo apt | reinstalación |
| 5 extensiones de `xtables` | corruptas, no las detecta `ldd` | reinstalación de `iptables` |
| `pigz` / `unpigz` | SIGILL, containerd no extraía capas | reinstalación |
| binario `docker` | segfault | reinstalación de `docker-ce-cli` |
| `docker-buildx` | segfault al construir imágenes | reinstalación |
| 13 archivos de control de dpkg | contenido binario ajeno | vaciados y regenerados |
| base bbolt de containerd | `panic: Page expected to be 357` | renombrada, se reconstruyó sola |
| caché `.pyc` de Python | `bad marshal data`, rompía UFW | borrada, se regenera sola |
| **123 archivos en 68 paquetes** | checksum incorrecto | reinstalación masiva, 0 fallos |
| 128 objetos de git | `inflate: data stream error` | clon nuevo desde GitHub |
| 4 archivos del repo | contenido binario | restaurados desde git |
| `seen.db` del news-filter | `database disk image is malformed` | recuperada, 5053 filas |

---

## Espacio liberado

| Qué | Tamaño |
|---|---|
| `pihole.log` y `FTL.log` | 1,9 GB |
| `/var/lib/containerd.broken`, abandonado desde abril | 7,1 GB |
| Caché de apt | 213 MB |
| Escritorio completo, 111+ paquetes | varios GB |

El disco pasó del **95% al 55%**.

---

## Cambios permanentes aplicados

**Rotación de logs reparada**, que era la falla original.

**Verificación periódica del disco activada**: cada 30 montajes corre `fsck`. Estaba desactivada.

**Escritorio removido**: `lightdm`, `cups`, `chromium`, `vlc`, `xserver`, `labwc`. Menos superficie que se pueda corromper. Los servicios caídos pasaron de 13 a 0.

**Jail de fail2ban arreglado.** Antes apuntaba al log JSON de Docker, cuya ruta incluye el ID del contenedor: al recrear Caddy, la ruta cambiaba y fail2ban no arrancaba. Ahora Caddy escribe a `/var/log/caddy/access.log`, una ruta fija montada desde el host, y **la rotación la hace el propio Caddy**, sin depender de logrotate.

**UFW reactivado** con sus reglas originales y habilitado en el arranque.

---

## Aprendizajes de diagnóstico

Cosas que no eran obvias y conviene recordar:

**`Connection timed out` no es `refused`.** Refused significa servicio caído. Timed out significa paquetes descartados, o sea firewall.

**El estado ARP distingue capa 2 de capa 3.** Si el vecino figura `Reachable` pero no responde a nada IP, la máquina está viva y el bloqueo es de firewall. Si figura `Stale`, no está en la red.

**`file` solo mira los primeros bytes.** Un binario puede tener cabecera válida y estar corrupto por dentro. Para eso sirve `debsums`, que compara checksums completos.

**`ldd` no muestra las extensiones cargadas en tiempo de ejecución.** Las librerías de `iptables` estaban sanas, pero las extensiones que carga con `dlopen` no.

**`git status` no detecta corrupción.** Git decide si releer un archivo por tamaño y fecha, y la corrupción de bloques no cambia ninguno de los dos. Hay que comparar hashes explícitamente.

**`pkill -f patron` se mata a sí mismo** si el patrón aparece en la línea de comando que uno está ejecutando.

---

## Lo que sigue pendiente

- **UPS o HAT con batería**: la única defensa real contra los cortes
- **log2ram**: menos escrituras a la SD
- **Arranque desde SSD por USB**: el salto de robustez más grande
- **Alerta de disco en Grafana**: habría avisado en marzo
- **Reinicio** para que corra el `fsck` programado
