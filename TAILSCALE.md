# Tailscale

Acceso remoto al Pi y a toda la red de casa, sin abrir puertos en el router.

---

## Por qué va en el host y no en Docker

Todo lo demás en este repo es un contenedor. Tailscale es la excepción deliberada, por tres razones concretas:

1. **Sobrevive a que Docker se rompa.** Si el demonio de Docker no arranca, un Tailscale contenerizado se cae con él, justo cuando más necesitás entrar a arreglarlo. En el host sigue en pie.
2. **Subnet router.** Para llegar a toda tu red `192.168.68.0/22` desde afuera, y no solo al Pi, necesita reenvío de IP a nivel del host.
3. **MagicDNS y `tailscale ssh`** funcionan sin vueltas cuando corre en el host.

---

## Instalación

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

Habilitá el reenvío de IP, necesario para el subnet router:

```bash
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-tailscale.conf
echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
```

Levantalo anunciando tu red local:

```bash
sudo tailscale up --advertise-routes=192.168.68.0/22 --accept-dns=false
```

Te va a imprimir una URL para autenticar desde el navegador.

Dos aclaraciones sobre esos parámetros:

- `--advertise-routes` publica tu red de casa. **Hay que aprobar la ruta a mano** en la consola de Tailscale, en `Machines → <el nombre de esta máquina> → Edit route settings`. Hasta que la apruebes, no funciona.
- `--accept-dns=false` evita que Tailscale te pise el DNS del Pi. Como este Pi **es** tu servidor DNS con Pi-hole, dejarlo en `true` genera un conflicto donde el resolvedor se apunta a sí mismo.

---

## Pi-hole desde afuera

Una vez aprobada la ruta, en la consola de Tailscale poné el Pi como **nameserver global** con su IP `192.168.68.66`. Con eso tenés el bloqueo de publicidad de Pi-hole en el celular estando en la calle, sin VPN aparte.

### El paso que falta, y que no da ningún error

Con lo anterior solo no alcanza. Pi-hole viene con `dns.listeningMode` en **`LOCAL`**, que quiere decir que atiende a los equipos de tu red de casa y **descarta en silencio** las consultas que llegan desde otra subred. Tailscale es otra subred (`100.64.0.0/10`), así que sus consultas se caen sin respuesta.

El síntoma engaña bastante: la VPN conecta, `tailscale status` muestra todo verde, llegás al servidor por IP, y sin embargo ningún nombre `.pi` resuelve, como si el DNS no existiera. Nada dice que el problema sea Pi-hole.

Lo arregla el instalador junto con los registros, pero si lo estás haciendo a mano:

```bash
sudo pihole-FTL --config dns.listeningMode ALL
sudo systemctl restart pihole-FTL
```

Para comprobarlo, preguntale a Pi-hole por su **IP de Tailscale**, no por la de la red de casa, que es lo que va a hacer tu celular:

```bash
dig @$(tailscale ip -4) homepage.pi +short
```

Con `ALL`, Pi-hole responde en todas sus interfaces. En esta configuración no queda expuesto a internet porque no hay ningún puerto redirigido en el router, pero es algo a tener presente si algún día lo hubiera.

De paso, `ALL` hace que deje de importar `dns.interface`, que guarda el nombre de la placa de red de la máquina donde instalaste la primera vez. Si mudás el servidor de hardware, ese nombre no coincide y es una fuente silenciosa de problemas.

---

## Verificación

```bash
tailscale status
```

```bash
tailscale ip -4
```

---

## Interacción con UFW

Tailscale se agrega solo a las reglas de firewall cuando detecta UFW, así que no hace falta abrir nada a mano. Si algún día no llegás a un servicio por Tailscale pero sí desde la LAN, revisá primero:

```bash
sudo ufw status verbose
```

El tráfico entra por la interfaz `tailscale0`, no por `eth0`.

---

## Nota de seguridad

`tailscale up` sin `--ssh` no habilita el SSH de Tailscale. Si lo activás con `--ssh`, tené presente que el control de acceso pasa a estar en las ACL de tu tailnet, no en `authorized_keys` del Pi. Son dos sistemas de permisos distintos y conviene no mezclarlos sin entender cuál manda.
