#!/bin/bash

GITHUB_BASE_URL="https://typicaltropic.github.io/pterodactyl-installer-script/"

install_pteroq() {
  echo "* Installing pteroq service.."

  curl -o /etc/systemd/system/pteroq.service $GITHUB_BASE_URL/configs/pteroq.service
}

install_pteroq