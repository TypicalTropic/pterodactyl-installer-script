#!/bin/bash

WINGS_ARM_DL_BASE_URL="https://github.com/pterodactyl/wings/releases/download/v1.5.1/wings_linux_arm64"

ptdl_dl() {
  echo "* Installing Pterodactyl Wings .. "

  mkdir -p /etc/pterodactyl
  curl -L -o /usr/local/bin/wings "$WINGS_ARM_DL_BASE_URL"

  chmod u+x /usr/local/bin/wings

  echo "* Done."
}

ptdl_dl
