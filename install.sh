#!/bin/bash

set -e
GITHUB_BASE_URL="https://github.com/TypicalTropic/pterodactyl-installer-script"

LOG_PATH="/var/log/pterodactyl-installer.log"

# exit with error status code if user is not root
if [[ $EUID -ne 0 ]]; then
  echo "* This script must be executed with root privileges (sudo)." 1>&2
  exit 1
fi

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
  exit 1
fi

output() {
  echo -e "* ${1}"
}

error() {
  COLOR_RED='\033[0;31m'
  COLOR_NC='\033[0m'

  echo ""
  echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
  echo ""
}

execute() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >> $LOG_PATH

  bash <(curl -s "$1") | tee -a $LOG_PATH
  [[ -n $2 ]] && execute "$2"
}

done=false

output

PANEL_LATEST="$GITHUB_BASE_URL/install-panel.sh"

WINGS_LATEST_x86_64="$GITHUB_BASE_URL/install-wings-x86_64.sh"

WINGS_ARM="$GITHUB_BASE_URL/install-wings-arm.sh"

while [ "$done" == false ]; do
  options=(
    "Install the panel"
    "Install Wings x86_64"
    "Install Wings ARM"
    "Install both [0] and [1] on the same machine (wings script runs after panel)\n"
    "Install Both [0] and [3] on the same machine (wings script runs after panel)"

  )

  actions=(
    "$PANEL_LATEST"
    "$WINGS_LATEST_x86_64"
    "$WINGS_ARM"
    "$PANEL_LATEST;$WINGS_LATEST_x86_64"
    "$PANEL_LATEST;$WINGS_ARM"

  )

  output "Select An Option"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")
  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"
  [[ " ${valid_input[*]} " =~ ${action} ]] && done=true && IFS=";" read -r i1 i2 <<< "${actions[$action]}" && execute "$i1" "$i2"
done

