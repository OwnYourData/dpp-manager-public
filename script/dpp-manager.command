#!/bin/bash
#
# Double-click this file to start the DPP Manager. On macOS the Finder runs a
# .command file in Terminal; on Linux, run it from a file manager or with
# `bash script/dpp-manager.command`.
#
# It is written to be read by somebody who is not going to read it: every step
# says what it is doing and what to do if it fails, and it never does anything
# to the computer beyond starting one container and creating one folder.
set -euo pipefail

APP="dpp-manager"
DATA="${HOME}/DPP Manager"
PORT="${DPP_MANAGER_PORT:-3000}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "DPP Manager"
echo "==========="
echo

# 1. Docker has to be running. Everything else in this script assumes it.
if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is not installed."
  echo
  echo "Install Docker Desktop from https://www.docker.com/products/docker-desktop"
  echo "start it once, and then double-click this file again."
  read -r -p "Press return to close this window. " _
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is installed but not running."
  echo
  echo "Start Docker Desktop, wait until its whale icon stops moving,"
  echo "and then double-click this file again."
  read -r -p "Press return to close this window. " _
  exit 1
fi

# 2. The folder the data lives in. One file will appear in it, and that file is
#    everything: passports, keys, settings, the log. Backing up means copying
#    this folder.
mkdir -p "${DATA}"
echo "Your data folder:  ${DATA}"
echo "Everything the application knows is one file in there."
echo

# 3. The image. Built here the first time, which takes a few minutes; after
#    that this step is instant because Docker keeps it.
if ! docker image inspect "${APP}" >/dev/null 2>&1; then
  echo "Building the application — this happens once and takes a few minutes."
  echo
  docker build -t "${APP}" "${HERE}"
  echo
fi

# 4. One container at a time. Restarting is the ordinary way to apply a new
#    version, so an existing one is replaced rather than refused.
docker rm -f "${APP}" >/dev/null 2>&1 || true

docker run -d \
  --name "${APP}" \
  -p "${PORT}:3000" \
  -v "${DATA}:/data" \
  "${APP}" >/dev/null

# 5. Wait for it to answer before opening a browser at it, or the first thing
#    the operator sees is an error page from their browser.
printf "Starting"
for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:${PORT}/up" >/dev/null 2>&1; then
    echo " — ready."
    echo
    echo "The application is at  http://localhost:${PORT}"
    echo
    if command -v open >/dev/null 2>&1; then
      open "http://localhost:${PORT}"
    elif command -v xdg-open >/dev/null 2>&1; then
      xdg-open "http://localhost:${PORT}" >/dev/null 2>&1 &
    fi
    echo "To stop it later:   docker stop ${APP}"
    echo "To start it again:  double-click this file"
    read -r -p "Press return to close this window. " _
    exit 0
  fi
  printf "."
  sleep 1
done

echo
echo "It did not answer within a minute. What the application said:"
echo
docker logs --tail 30 "${APP}" || true
read -r -p "Press return to close this window. " _
exit 1
