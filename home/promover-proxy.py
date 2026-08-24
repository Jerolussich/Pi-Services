#!/usr/bin/env python3
"""Confirma la configuracion del proxy de Home Assistant sin pasar por el navegador.

EL PROBLEMA

Home Assistant no se cree la configuracion del proxy porque se la pidas. La toma
de configuration.yaml, la guarda como "pending", arranca con ella, y si en cinco
minutos nadie la CONFIRMA la revierte, la marca not_promoted y no la reintenta
nunca mas. A partir de ahi casa.pi contesta 400 para siempre.

Y confirmarla no es cualquier cosa: mirando el codigo de HA (components/http/),
la unica via es el comando WebSocket autenticado `http/config/promote`, que
manda el frontend. O sea que hace falta tener usuario, estar logueado, y que la
pagina cargue... por el proxy que todavia no funciona. Un circulo.

QUE HACE ESTO

Exactamente lo mismo que async_promote_pending() pero con HA parado:

    self._stable = self._pending
    self._pending = None

Y deja yaml_migration_done en true, que es lo que hace que el bloque http: de
configuration.yaml deje de re-escenificarse como pending en cada arranque. Sin
eso, el problema vuelve en el proximo reinicio.

DOS DETALLES QUE PARECEN MENORES Y NO LO SON

1. `pending` se deja en null, NO se borra la clave. El cargador de HA la lee por
   indice directo, asi que si falta, el store no carga y el componente http no
   arranca. Con eso muere todo lo que depende de el: frontend, api, auth. Lo
   probamos: "Setup failed for 'http'" y HA queda sin escuchar en el 8123.

2. La config que se promueve es la que genero HA, tal cual. No se arma una a
   mano: asi es valida contra su propio esquema por construccion.

El error not_promoted se limpia a proposito. Solo significa "nadie la confirmo a
tiempo", no que este rota; de hecho sabemos que anda, porque mientras estuvo
activa casa.pi contestaba bien.

Uso:  sudo python3 promover-proxy.py <ruta a .storage/http>
Salida: 0 promovida · 1 error · 2 no existe el archivo · 3 ya estaba lista
"""

import json
import shutil
import sys

REQUERIDAS = ("use_x_forwarded_for", "trusted_proxies")


def ya_esta_lista(estable):
    return bool(estable.get("use_x_forwarded_for")) and bool(
        estable.get("trusted_proxies")
    )


def main(ruta):
    try:
        with open(ruta) as f:
            doc = json.load(f)
    except FileNotFoundError:
        # Todavia no existe: lo crea HA al arrancar. No hay nada que promover.
        return 2
    except (ValueError, OSError):
        return 1

    datos = doc.get("data")
    if not isinstance(datos, dict):
        return 1

    estable = datos.get("stable")
    pendiente = datos.get("pending")

    if isinstance(estable, dict) and ya_esta_lista(estable):
        return 3

    if not isinstance(pendiente, dict):
        # No hay nada que promover. Quien llama tiene que borrar el archivo y
        # dejar que HA lo regenere desde configuration.yaml.
        return 1

    if not all(k in pendiente for k in REQUERIDAS):
        return 1

    shutil.copy2(ruta, ruta + ".anterior")

    promovida = dict(pendiente)
    promovida["error"] = None
    promovida["error_message"] = None

    datos["stable"] = promovida
    datos["pending"] = None          # null, no ausente. Ver el comentario de arriba.
    datos["yaml_migration_done"] = True

    with open(ruta, "w") as f:
        json.dump(doc, f, indent=2)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        sys.exit(1)
    sys.exit(main(sys.argv[1]))
