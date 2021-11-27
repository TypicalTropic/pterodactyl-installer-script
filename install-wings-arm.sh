#!/bin/bash
set -e

# versioning

#################################
######## General checks #########
#################################

# exit with error status code if user is not root
if [[ $EUID -ne 0 ]]; then
    echo "* This script must be executed with root privileges (sudo)." 1>&2
    exit 1
fi

# check for curl
if ! [ -x "$(command -v curl)" ]; then
    echo "* curl is required in order for this script to work."
    echo "* install using apt (Debian and derivatives)"
    exit 1
fi

#################################
########## Variables ############
#################################

# download URLs
WINGS_ARM_DL_BASE_URL="https://github.com/pterodactyl/wings/releases/download/v1.5.1/wings_linux_arm64"
GITHUB_BASE_URL="https://typicaltropic.github.io/pterodactyl-installer-script/"

COLOR_RED='\033[0;31m'
COLOR_NC='\033[0m'

INSTALL_MARIADB=false

# firewall
CONFIGURE_FIREWALL=false

CONFIGURE_FIREWALL_CMD=false

# SSL (Let's Encrypt)
CONFIGURE_LETSENCRYPT=false
FQDN=""
EMAIL=""

# Database host
CONFIGURE_DBHOST=false
MYSQL_DBHOST_USER="pterodactyluser"
MYSQL_DBHOST_PASSWORD="password"

# regex for email input
regex="^(([A-Za-z0-9]+((\.|\-|\_|\+)?[A-Za-z0-9]?)*[A-Za-z0-9]+)|[A-Za-z0-9]+)@(([A-Za-z0-9]+)+((\.|\-|\_)?([A-Za-z0-9]+)+)*)+\.([A-Za-z]{2,})+$"

#################################
####### Version checking ########
#################################

get_latest_release() {
    curl --silent "https://api.github.com/repos/$1/releases/latest" | # Get latest release from GitHub api
        grep '"tag_name":' |                                          # Get tag line
        sed -E 's/.*"([^"]+)".*/\1/'                                  # Pluck JSON value
}

echo "* Retrieving release information.."
WINGS_VERSION="$(get_latest_release "pterodactyl/wings")"

####### Other library functions ########

valid_email() {
    [[ $1 =~ ${regex} ]]
}

password_input() {
    local __resultvar=$1
    local result=''
    local default="$4"

    while [ -z "$result" ]; do
        echo -n "* ${2}"

        # modified from https://stackoverflow.com/a/22940001
        while IFS= read -r -s -n1 char; do
            [[ -z $char ]] && {
                printf '\n'
                break
            }                               # ENTER pressed; output \n and break.
            if [[ $char == $'\x7f' ]]; then # backspace was pressed
                # Only if variable is not empty
                if [ -n "$result" ]; then
                    # Remove last char from output variable.
                    [[ -n $result ]] && result=${result%?}
                    # Erase '*' to the left.
                    printf '\b \b'
                fi
            else
                # Add typed char to output variable.
                result+=$char
                # Print '*' in its stead.
                printf '*'
            fi
        done
        [ -z "$result" ] && [ -n "$default" ] && result="$default"
        [ -z "$result" ] && print_error "${3}"
    done

    eval "$__resultvar="'$result'""
}

#################################
####### Visual functions ########
#################################

print_error() {
    echo ""
    echo -e "* ${COLOR_RED}ERROR${COLOR_NC}: $1"
    echo ""
}

print_warning() {
    COLOR_YELLOW='\033[1;33m'
    COLOR_NC='\033[0m'
    echo ""
    echo -e "* ${COLOR_YELLOW}WARNING${COLOR_NC}: $1"
    echo ""
}

print_brake() {
    for ((n = 0; n < $1; n++)); do
        echo -n "#"
    done
    echo ""
}

hyperlink() {
    echo -e "\e]8;;${1}\a${1}\e]8;;\a"
}

#################################
####### OS check funtions #######
#################################

detect_distro() {
    if [ -f /etc/os-release ]; then
        # freedesktop.org and systemd
        . /etc/os-release
        OS=$(echo "$ID" | awk '{print tolower($0)}')
        OS_VER=$VERSION_ID
    elif type lsb_release >/dev/null 2>&1; then
        # linuxbase.org
        OS=$(lsb_release -si | awk '{print tolower($0)}')
        OS_VER=$(lsb_release -sr)
    elif [ -f /etc/lsb-release ]; then
        # For some versions of Debian/Ubuntu without lsb_release command
        . /etc/lsb-release
        OS=$(echo "$DISTRIB_ID" | awk '{print tolower($0)}')
        OS_VER=$DISTRIB_RELEASE
    elif [ -f /etc/debian_version ]; then
        # Older Debian/Ubuntu/etc.
        OS="debian"
        OS_VER=$(cat /etc/debian_version)
    elif [ -f /etc/SuSe-release ]; then
        # Older SuSE/etc.
        OS="SuSE"
        OS_VER="?"
    elif [ -f /etc/redhat-release ]; then
        # Older Red Hat, CentOS, etc.
        OS="Red Hat/CentOS"
        OS_VER="?"
    else
        # Fall back to uname, e.g. "Linux <version>", also works for BSD, etc.
        OS=$(uname -s)
        OS_VER=$(uname -r)
    fi

    OS=$(echo "$OS" | awk '{print tolower($0)}')
    OS_VER_MAJOR=$(echo "$OS_VER" | cut -d. -f1)
}

check_os_comp() {
    SUPPORTED=false

    MACHINE_TYPE=$(uname -m)
    case "$MACHINE_TYPE" in
    x86_64)
        ARCH=amd64
        ;;
    arm64) ;&
        # fallthrough
    aarch64)
        print_warning "Detected architecture arm64"
        echo -e -n "* Proceed? (y/N):"
        read -r choice

        if [[ ! "$choice" =~ [Yy] ]]; then
            print_error "Installation aborted!"
            exit 1
        fi
        ARCH=arm64
        ;;
    *)
        print_error "Only x86_64 and arm64 are supported for Wings"
        exit 1
        ;;
    esac

    case "$OS" in
    ubuntu)
        [ "$OS_VER_MAJOR" == "18" ] && SUPPORTED=true
        [ "$OS_VER_MAJOR" == "20" ] && SUPPORTED=true
        ;;
    *)
        SUPPORTED=false
        ;;
    esac

    # exit if not supported
    if [ "$SUPPORTED" == true ]; then
        echo "* $OS $OS_VER is supported."
    else

        echo "* $OS $OS_VER is not supported"
        print_error "Unsupported OS"
        exit 1
    fi

    # check virtualization
    echo -e "* Installing virt-what..."
    if [ "$OS" == "ubuntu" ]; then
        # silence dpkg output
        export DEBIAN_FRONTEND=noninteractive

        # install virt-what
        apt-get -y update -qq
        apt-get install -y virt-what -qq

        # unsilence
        unset DEBIAN_FRONTEND

    else
        print_error "Invalid OS."
        exit 1
    fi

    virt_serv=$(virt-what)

    case "$virt_serv" in
    *openvz* | *lxc*)
        print_warning "Unsupported type of virtualization detected. Please consult with your hosting provider whether your server can run Docker or not. Proceed at your own risk."
        echo -e -n "* Are you sure you want to proceed? (y/N): "
        read -r CONFIRM_PROCEED
        if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
            print_error "Installation aborted!"
            exit 1
        fi
        ;;
    *)
        [ "$virt_serv" != "" ] && print_warning "Virtualization: $virt_serv detected."
        ;;
    esac

    if uname -r | grep -q "xxxx"; then
        print_error "Unsupported kernel detected."
        exit 1
    fi

}

############################
## INSTALLATION FUNCTIONS ##
############################

apt_update() {
    apt update -q -y && apt upgrade -y
}

enable_docker() {
    systemctl start docker
    systemctl enable docker
}

install_docker() {
    echo "* Installing docker .."
    if [ "$OS" == "ubuntu" ]; then
        curl -sSL https://get.docker.com/ | CHANNEL=stable bash

        # Make sure docker is enabled
        enable_docker

    fi

    echo "* Docker has now been installed."
}

ptdl_dl() {
    echo "* Installing Pterodactyl Wings .. "

    mkdir -p /etc/pterodactyl
    curl -L -o /usr/local/bin/wings "$WINGS_ARM_DL_BASE_URL"

    chmod u+x /usr/local/bin/wings

    echo "* Done."
}

systemd_file() {
    echo "* Installing systemd service.."
    curl -o /etc/systemd/system/wings.service $GITHUB_BASE_URL/configs/wings.service
    systemctl daemon-reload
    systemctl enable wings
    echo "* Installed systemd service!"
}

install_mariadb() {
    MARIADB_URL="https://downloads.mariadb.com/MariaDB/mariadb_repo_setup"

    case "$OS" in
    ubuntu)
        [ "$OS_VER_MAJOR" == "18" ] && curl -sS $MARIADB_URL | sudo bash
        apt install -y mariadb-server
        ;;

    esac

    systemctl enable mariadb
    systemctl start mariadb
}

ask_database_user() {
    echo -n "* Do you want to automatically configure a user for database hosts? (y/N): "
    read -r CONFIRM_DBHOST

    if [[ "$CONFIRM_DBHOST" =~ [Yy] ]]; then
        CONFIGURE_DBHOST=true
    fi
}

configure_mysql() {
    echo "* Performing MySQL queries.."

    echo "* Creating MySQL user..."
    mysql -u root -e "CREATE USER '${MYSQL_DBHOST_USER}'@'127.0.0.1' IDENTIFIED BY '${MYSQL_DBHOST_PASSWORD}';"

    echo "* Granting privileges.."
    mysql -u root -e "GRANT ALL PRIVILEGES ON *.* TO '${MYSQL_DBHOST_USER}'@'127.0.0.1' WITH GRANT OPTION;"

    echo "* Flushing privileges.."
    mysql -u root -e "FLUSH PRIVILEGES;"

    echo "* Changing MySQL bind address.."
    case "$OS" in
    debian | ubuntu)
        sed -ne 's/^bind-address            = 127.0.0.1$/bind-address=0.0.0.0/' /etc/mysql/mariadb.conf.d/50-server.cnf
        ;;

    esac

    echo "* MySQL configured!"
}

#################################
##### OS SPECIFIC FUNCTIONS #####
#################################

ask_letsencrypt() {
    if [ "$CONFIGURE_FIREWALL_CMD" == false ]; then
        print_warning "Let's Encrypt requires port 80/443 to be opened! You have opted out of the automatic firewall configuration; use this at your own risk (if port 80/443 is closed, the script will fail)!"
    fi

    print_warning "You cannot use Let's Encrypt with your hostname as an IP address! It must be a FQDN (e.g. node.example.org)."

    echo -e -n "* Do you want to automatically configure HTTPS using Let's Encrypt? (If previously installed using panel option do not configure) (y/N): "
    read -r CONFIRM_SSL

    if [[ "$CONFIRM_SSL" =~ [Yy] ]]; then
        CONFIGURE_LETSENCRYPT=true
    fi
}

firewall_firewalld() {
    echo -e "\n* Enabling firewall_cmd (firewalld)"
    echo "* Opening port 22 (SSH), 8080 (Daemon Port), 2022 (Daemon SFTP Port)"

    # Install
    [ "$OS" == "ubuntu" ] && sudo apt -y install firewalld

    # Enable
    systemctl --now enable firewalld # Enable and start
    systemctl disable ufw #Disables UFW 

    # Configure
    firewall-cmd --add-service=ssh --permanent -q                                           # Port 22
    firewall-cmd --add-port 8080/tcp --permanent -q                                         # Port 8080
    firewall-cmd --add-port 2022/tcp --permanent -q                                         # Port 2022
    [ "$CONFIGURE_LETSENCRYPT" == true ] && firewall-cmd --add-service=http --permanent -q  # Port 80
    [ "$CONFIGURE_LETSENCRYPT" == true ] && firewall-cmd --add-service=https --permanent -q # Port 443

    firewall-cmd --permanent --zone=trusted --change-interface=pterodactyl0 -q
    firewall-cmd --zone=trusted --add-masquerade --permanent
    firewall-cmd --permanent --zone=trusted --remove-interface=pterodactyl0
    firewall-cmd --reload -q # Enable firewall

    echo "* Firewall-cmd installed"
    print_brake 70
}

letsencrypt() {
    FAILED=false

    # Install certbot
    case "$OS" in
    debian | ubuntu)
        apt-get -y install certbot python3-certbot-nginx
        ;;
    esac

    # If user has nginx
    systemctl stop nginx || true

    # Obtain certificate
    certbot certonly --no-eff-email --email "$EMAIL" --standalone -d "$FQDN" || FAILED=true

    systemctl start nginx || true

    # Check if it succeded
    if [ ! -d "/etc/letsencrypt/live/$FQDN/" ] || [ "$FAILED" == true ]; then
        print_warning "The process of obtaining a Let's Encrypt certificate failed!"
    fi
}

####################
## MAIN FUNCTIONS ##
####################

perform_install() {
    echo "* Installing pterodactyl wings.."
    [ "$OS" == "ubuntu" ] && apt_update
    [ "$CONFIGURE_FIREWALL_CMD" == true ] && firewall_firewalld
    install_docker
    ptdl_dl
    systemd_file
    [ "$INSTALL_MARIADB" == true ] && install_mariadb
    [ "$CONFIGURE_DBHOST" == true ] && configure_mysql
    [ "$CONFIGURE_LETSENCRYPT" == true ] && letsencrypt

    # return true if script has made it this far
    return 0
}

main() {
    # check if we can detect an already existing installation
    if [ -d "/etc/pterodactyl" ]; then
        print_warning "The script has detected that you already have Pterodactyl wings on your system! You cannot run the script multiple times, it will fail!"
        echo -e -n "* Are you sure you want to proceed? (y/N): "
        read -r CONFIRM_PROCEED
        if [[ ! "$CONFIRM_PROCEED" =~ [Yy] ]]; then
            print_error "Installation aborted!"
            exit 1
        fi
    fi

    # detect distro
    detect_distro

    print_brake 70
    echo "* Running $OS version $OS_VER."
    echo "* Latest pterodactyl/wings is $WINGS_VERSION"
    print_brake 70

    # checks if the system is compatible with this installation script
    check_os_comp

    echo "* "
    echo "* The installer will install Docker, required dependencies for Wings"
    echo "* as well as Wings itself. But it's still required to create the node"
    echo "* on the panel and then place the configuration file on the node manually after"
    echo "* the installation has finished. Read more about this process on the"
    echo "* official documentation: $(hyperlink 'https://pterodactyl.io/wings/1.0/installing.html#configure')"
    echo "* "
    echo -e "* ${COLOR_RED}Note${COLOR_NC}: this script will not start Wings automatically (will install systemd service, not start it)."
    echo -e "* ${COLOR_RED}Note${COLOR_NC}: this script will not enable swap (for docker)."
    print_brake 42

    #Configures Database

    ask_database_user

    if [ "$CONFIGURE_DBHOST" == true ]; then
        type mysql >/dev/null 2>&1 && HAS_MYSQL=true || HAS_MYSQL=false

        if [ "$HAS_MYSQL" == false ]; then
            INSTALL_MARIADB=true
        fi

        echo -n "* Database host username (pterodactyluser): "
        read -r MYSQL_DBHOST_USER_INPUT

        [ -z "$MYSQL_DBHOST_USER_INPUT" ] || MYSQL_DBHOST_USER=$MYSQL_DBHOST_USER_INPUT

        password_input MYSQL_DBHOST_PASSWORD "Database host password: " "Password cannot be empty"
    fi

    # Firewalld will be used for Ubuntu
    if [ "$OS" == "ubuntu" ]; then
        echo -e -n "* Do you want to automatically configure Firewalld (firewall)? (y/N): "
        read -r CONFIRM_FIREWALL_CMD

        if [[ "$CONFIRM_FIREWALL_CMD" =~ [Yy] ]]; then
            CONFIGURE_FIREWALL_CMD=true
            CONFIGURE_FIREWALL=true
        fi
    fi

    ask_letsencrypt

    if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
        while [ -z "$FQDN" ]; do
            echo -n "* Set the FQDN to use for Let's Encrypt (node.example.com): "
            read -r FQDN

            ASK=false

            [ -z "$FQDN" ] && print_error "FQDN cannot be empty"                                                            # check if FQDN is empty
            bash <(curl -s $GITHUB_BASE_URL/lib/verify-fqdn.sh) "$FQDN" "$OS" || ASK=true                                   # check if FQDN is valid
            [ -d "/etc/letsencrypt/live/$FQDN/" ] && print_error "A certificate with this FQDN already exists!" && ASK=true # check if cert exists

            [ "$ASK" == true ] && FQDN=""
            [ "$ASK" == true ] && echo -e -n "* Do you still want to automatically configure HTTPS using Let's Encrypt? (y/N): "
            [ "$ASK" == true ] && read -r CONFIRM_SSL

            if [[ ! "$CONFIRM_SSL" =~ [Yy] ]] && [ "$ASK" == true ]; then
                CONFIGURE_LETSENCRYPT=false
                FQDN="none"
            fi
        done
    fi

    if [ "$CONFIGURE_LETSENCRYPT" == true ]; then
        # set EMAIL
        while ! valid_email "$EMAIL"; do
            echo -n "* Enter email address for Let's Encrypt: "
            read -r EMAIL

            valid_email "$EMAIL" || print_error "Email cannot be empty or invalid"
        done
    fi

    echo -n "* Proceed with installation? (y/N): "

    read -r CONFIRM
    [[ "$CONFIRM" =~ [Yy] ]] && perform_install && return

    print_error "Installation aborted"
    exit 0
}

function goodbye {
    echo ""
    print_brake 70
    echo "* Wings installation completed"
    echo "*"
    echo "* To continue, you need to configure Wings to run with your panel"
    echo "* Please refer to the official guide, $(hyperlink 'https://pterodactyl.io/wings/1.0/installing.html#configure')"
    echo "* "
    echo "* You can either copy the configuration file from the panel manually to /etc/pterodactyl/config.yml"
    echo "* or, you can use the \"auto deploy\" button from the panel and simply paste the command in this terminal"
    echo "* "
    echo "* You can then start Wings manually to verify that it's working"
    echo "*"
    echo "* sudo wings"
    echo "*"
    echo "* Once you have verified that it is working, use CTRL+C and then start Wings as a service (runs in the background)"
    echo "*"
    echo "* systemctl start wings"
    echo "*"
    echo -e "* ${COLOR_RED}Note${COLOR_NC}: It is recommended to enable swap (for Docker, read more about it in official documentation)."
    [ "$CONFIGURE_FIREWALL" == false ] && echo -e "* ${COLOR_RED}Note${COLOR_NC}: If you haven't configured your firewall, ports 8080 and 2022 needs to be open."
    print_brake 70
    echo ""
}

# run script
main
goodbye
