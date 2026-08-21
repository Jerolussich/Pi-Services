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
