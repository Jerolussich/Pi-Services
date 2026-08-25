# Mantenimiento

Salud del Pi, qué revisar cada tanto, y cómo evitar el problema que casi te cuesta todo.

---

## La lección del 20 de agosto de 2026

Ese día el Pi estaba caído: sin SSH, sin DNS, sin servicios web, y `apt` roto. La investigación llegó a una sola causa raíz.

**Los apagones y el apagado por botón corrompieron archivos del sistema de archivos.** Bloques de un archivo terminaron adentro de otro. La cadena fue así:

```
apagado sucio
      ▼
libglib2.0 y libpopt corruptos
      ▼
logrotate deja de funcionar (19 de marzo)
      ▼
pihole.log crece sin parar 5 meses hasta 1,8 GB
      ▼
disco lleno
      ▼
13 servicios caidos, apt roto, iptables con bus error
      ▼
Docker no arranca y UFW no funciona
      ▼
sin SSH
```

Lo que se encontró en total: 123 archivos con checksum incorrecto en 68 paquetes, 13 estructuras internas de dpkg dañadas, la base de containerd corrupta, 987 archivos huérfanos en `/lost+found`, 128 objetos de git dañados, y `seen.db` del news-filter ilegible.

El detalle completo está en [INCIDENTE-2026-08-20.md](INCIDENTE-2026-08-20.md).

---

## Las reglas que salen de eso

### 1. Nunca apagar por botón

```bash
sudo poweroff
```

Cada corte a mitad de una escritura deja bloques inconsistentes. No es una probabilidad remota: es lo que ya pasó, y varias veces.

### 2. Una UPS es la única defensa real

Contra los cortes de luz no hay solución por software. Alcanza una chica que aguante el minuto y medio de un apagado ordenado, o un HAT con batería. Sin esto, todo lo demás es paliativo.

### 3. Vigilar el disco

Es el indicador que anticipa el desastre. El log creció cinco meses sin que nadie lo notara.

```bash
df -h /
```

```bash
sudo du -xsh /var/log/* | sort -rh | head -5
```

Tenés Prometheus y Grafana andando: **una alerta al 80% de uso te habría avisado en marzo**.

### 4. Verificar que logrotate sigue vivo

Fue la pieza que falló en silencio.

```bash
sudo /usr/sbin/logrotate --version
```

Si eso da error de librería, estás en el mismo camino de la vez pasada.

### 5. Chequeo periódico del disco

Ya está activado: cada 30 montajes se corre un `fsck` automático. Estaba desactivado, y por eso nadie detectaba el daño.

```bash
sudo tune2fs -l /dev/mmcblk0p2 | grep -i "mount count\|Filesystem state"
```

Si el estado dice `clean with errors`, hay que forzar una revisión:

```bash
sudo touch /forcefsck && sudo reboot
```

---

## Grafana se cae al arrancar, una de cada dos veces

Descubierto el 25 de agosto de 2026. Vale la pena dejarlo escrito porque el síntoma no se parece en nada a la causa y se pierde mucho tiempo buscando en el lugar equivocado.

**El síntoma.** Grafana entra en bucle de reinicio y en su log aparece:

```
fatal error: slice bounds out of range
panic during panic
runtime.pcvalue ... runtime/symtab.go
```

Los stack traces caen en lugares **sin relación entre sí**: `regexp`, el registro de rutas, `slice.go`. Y no es determinista: el mismo contenedor con la misma configuración arranca bien una vez y se cae la siguiente.

**Lo que no es.** No es un tablero mal formado, ni un plugin, ni los datasources, ni memoria (12 GB libres, sin OOM), ni la tarjeta (`Filesystem state: clean`). Grafana **pelado**, sin un solo tablero ni plugin, se cae en 4 de cada 5 arranques.

**La causa.** El Pi 5 corre el kernel de páginas de 16 KB:

```bash
getconf PAGESIZE
```

Si eso dice `16384`, los binarios de Go compilados asumiendo páginas de 4 KB fallan de forma aleatoria dentro del propio runtime. Prometheus, Caddy y node-exporter no lo sufren; Grafana sí.

**Por qué aparece de golpe.** Un contenedor que ya está arriba sigue andando: el problema es solo el arranque. Así que Grafana puede pasar semanas bien y romperse el día que lo recrees, actualices o reinicies el equipo. Si acabás de correr `docker compose pull`, la imagen nueva se estrena en el siguiente arranque y ahí se nota.

**Cómo se arregla.** Volver al kernel de 4 KB, que es una línea en `/boot/firmware/config.txt` y un reinicio:

```
kernel=kernel8.img
```

Es reversible: se saca la línea y se vuelve a reiniciar.

**Cómo comprobar que estás en este caso** antes de tocar nada, sin arriesgar el Grafana que usás:

```bash
for i in 1 2 3 4 5; do docker rm -f gtest >/dev/null 2>&1; docker run -d --name gtest grafana/grafana-oss >/dev/null; sleep 32; docker ps --filter name=gtest --format "{{.Status}}"; done; docker rm -f gtest
```

Si de cinco arranques varios no dicen `Up`, es esto.

---

## Detectar corrupción antes de que duela

Estas tres verificaciones encuentran daño que no se ve a simple vista.

**Archivos del sistema contra los checksums de sus paquetes:**

```bash
sudo debsums -c
```

Lo que salga ahí se repara reinstalando el paquete correspondiente:

```bash
sudo apt-get install --reinstall -y <paquete>
```

**Integridad del repositorio git:**

```bash
cd ~/pi-services && git fsck
```

Un detalle importante: **`git status` no sirve para detectar corrupción.** Git decide si releer un archivo mirando tamaño y fecha, y la corrupción de bloques cambia el contenido sin tocar ninguno de los dos. Para comparar de verdad:

```bash
cd ~/pi-services && git ls-files -s | while read m h s f; do [ "$h" != "$(git hash-object "$f")" ] && echo "$f"; done
```

**Integridad de las bases SQLite:**

```bash
sqlite3 ~/pi-services/finance/finance-tracker/data/finance.db "PRAGMA integrity_check;"
```

Si una devuelve `malformed`, se puede recuperar casi siempre:

```bash
sqlite3 rota.db ".recover" | sqlite3 nueva.db
```

---

## Reducir el desgaste de la SD

La SD se muere por escrituras. Cuantas menos haya, menos ventanas hay para que un corte te agarre en el peor momento.

**El escritorio ya se sacó.** `lightdm`, `cups`, `chromium`, `vlc`, `xserver` y `labwc` fueron removidos: eran gigas de superficie inútil en un servidor headless, y varios de los servicios que fallaban eran justamente esos.

**log2ram** mantiene los logs en RAM y los baja a disco una vez por día. Es la mejora más grande que queda pendiente. Requiere agregar un repositorio externo, así que hace falta tu autorización explícita.

**Arrancar desde SSD por USB** es el salto de calidad más grande. El Pi 5 lo soporta, y mejora robustez y velocidad a la vez.

---

## Si te quedás sin SSH

El orden que funcionó, del más probable al menos:

**1. ¿Está en la red?** Desde otra máquina de la casa:

```bash
ping 192.168.68.66
```

Si no responde ni al ping pero el ARP dice `Reachable`, está viva y el bloqueo es de firewall. Si el ARP dice `Stale`, no está en la red.

**2. Timeout no es lo mismo que refused.** `Connection refused` significa que sshd está caído. `Connection timed out` significa que los paquetes se descartan, o sea firewall o problema de red.

**3. Desde el monitor**, lo mínimo:

```bash
hostname -I; systemctl status ssh; sudo ufw status
```

**4. Si UFW quedó a medias** y te bloquea, se saca del arranque sin necesitar iptables:

```bash
sudo systemctl disable ufw && sudo reboot
```

**5. Si `iptables` da bus error**, es corrupción. Las extensiones que carga en tiempo de ejecución no las muestra `ldd`:

```bash
sudo apt-get install --reinstall -y iptables
```

**Tailscale evita todo esto.** Instalarlo en el host te da un camino de entrada que no depende ni de Docker ni de las reglas locales de firewall. Ver [../TAILSCALE.md](../TAILSCALE.md).

---

## Rutina sugerida

| Cada | Qué |
|---|---|
| Semana | `df -h /` |
| Mes | `sudo debsums -c` y `git fsck` en el repo |
| Mes | Backup de los `.env`, tokens y bases, **fuera del Pi** |
| Siempre | Apagar con `sudo poweroff`, nunca por botón |
