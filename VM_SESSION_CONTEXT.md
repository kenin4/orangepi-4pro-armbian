# Contexto de Sesion para VM (Orange Pi 4 Pro)

Fecha: 2026-04-28
Repo: https://github.com/kenin4/orangepi-4pro-armbian
Branch: main

## Objetivo

Generar una imagen Armbian booteable para Orange Pi 4 Pro con soporte Tailscale (CONFIG_TUN) y mantener todos los cambios en este fork.

## Estado actual

- Kernel: configurado con TUN y WireGuard como modulos.
- Build: hubo compilaciones exitosas de imagen en corridas previas.
- U-Boot: el ultimo bloqueo por defconfig faltante fue corregido.
- Commit mas reciente relevante: 66f411d

## Cambios clave ya aplicados

1. `config/boards/orangepi-4pro.conf`
   - BOOTCONFIG restaurado a `sun60iw2p1_t736_defconfig`.
   - Alias de compatibilidad: BRANCH=mainline se mapea a current.

2. `config/sources/families/sun60iw2.conf`
   - late_family_config fuerza valores de U-Boot despues de overrides globales.
   - BOOTDIR='u-boot'
   - BOOTSOURCE='https://github.com/orangepi-xunlong/u-boot-orangepi.git'
   - BOOTBRANCH='branch:v2018.05-sun60iw2'
   - BOOTBRANCH_BOARD='branch:v2018.05-sun60iw2'
   - BOOTPATCHDIR='none'

## Comando recomendado para reintentar en VM Linux

Ejecutar desde la raiz del repo:

```bash
./compile.sh build \
  BOARD=orangepi-4pro \
  BRANCH=current \
  BUILD_MINIMAL=yes \
  KERNEL_CONFIGURE=no \
  KERNEL_GIT=shallow \
  NO_HOST_RELEASE_CHECK=yes \
  RELEASE=bookworm \
  SKIP_EXTERNAL_DRIVERS=yes
```

## Si vuelve a fallar

Recolectar y compartir el primer error real (no solo el tail):

```bash
latest=$(ls -1t output/logs/*.log.ans | head -1)
perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' "$latest" | grep -n -m 1 -B 40 -A 80 'Error 2|fatal error:|error:'
```

Tambien compartir:

```bash
echo "$latest"
```

## Prompt para continuar la sesion (copiar/pegar)

```text
Estoy continuando la sesion de build de Armbian para Orange Pi 4 Pro en mi fork.

Contexto:
- Repo: kenin4/orangepi-4pro-armbian
- Branch: main
- Objetivo: imagen booteable con soporte Tailscale (CONFIG_TUN)
- Estado: ya se corrigio el error de defconfig faltante en U-Boot
- Commit clave: 66f411d (restore vendor u-boot defconfig/source for opi4pro)
- Archivo de contexto: VM_SESSION_CONTEXT.md

Tarea:
1) Revisar el estado actual de configuracion en config/boards/orangepi-4pro.conf y config/sources/families/sun60iw2.conf.
2) Guiarme para ejecutar el build en esta VM.
3) Si falla, localizar el primer error real en el log y proponer un parche minimo.
4) Aplicar el parche y validar nuevamente.

Importante:
- Prioriza estabilidad de arranque.
- No regreses cambios ya funcionales.
- Mantener todas las correcciones dentro de este fork.
```