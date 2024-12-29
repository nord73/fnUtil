#!/bin/bash
set -e

# Check for root privileges
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root" 
   exit 1
fi

# Define default log file and optional logging
LOG_FILE="/var/log/post-setup.log"
LOGGING_ENABLED=false

# Function to handle cleanup on exit
cleanup() {
    log "INFO" "Cleaning up before exit"
}
trap cleanup EXIT

# Parse command-line options
while getopts "l:" opt; do
  case $opt in
    l)
      LOGGING_ENABLED=true
      LOG_FILE=$OPTARG
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
  esac
done

# Log function with optional file output
log() {
    local level=$1
    shift
    local message=$@
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo -e "[$timestamp] [\033[1;34m$level\033[0m] $message"
    if [ "$LOGGING_ENABLED" = true ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    fi
}

# Load configuration
CONFIG_FILE="./post-setup.cfg"
if [[ -f $CONFIG_FILE ]]; then
    # Parse configuration file
    readarray -t STANDARD_CONFIGS < <(grep "^STANDARD " "$CONFIG_FILE" | sed 's/^STANDARD //')
    readarray -t OPTIONAL_CONFIGS < <(grep "^OPTIONAL " "$CONFIG_FILE" | sed 's/^OPTIONAL //')
    readarray -t DISABLED_CONFIGS < <(grep "^DISABLED " "$CONFIG_FILE" | sed 's/^DISABLED //')
else
    log "ERROR" "Configuration file ($CONFIG_FILE) not found!"
    exit 1
fi

# Helper functions
error_exit() {
    log "ERROR" "$1"
    exit 1
}

ask() {
    local prompt=$1
    local default=$2
    read -p "$prompt [$default]: " response
    echo "${response:-$default}"
}

apply_setting() {
    local description="$1"
    local command="$2"
    if [[ $INTERACTIVE == true ]]; then
        response=$(ask "Apply $description?" "yes")
        if [[ "$response" =~ ^[Yy](es)?$ ]]; then
            $command || error_exit "Failed to apply $description"
        else
            log "INFO" "Skipped $description."
        fi
    else
        $command || error_exit "Failed to apply $description"
    fi
}

configure_ansible_user() {
    log "INFO" "Configuring Ansible user..."
    apply_setting "creating Ansible user" "
        adduser --disabled-password --gecos '' $ANSIBLE_ACCOUNT_NAME
        mkdir -p /home/$ANSIBLE_ACCOUNT_NAME/.ssh
        echo \"$ANSIBLE_PUBLIC_KEY\" > /home/$ANSIBLE_ACCOUNT_NAME/.ssh/authorized_keys
        chmod 700 /home/$ANSIBLE_ACCOUNT_NAME/.ssh
        chmod 600 /home/$ANSIBLE_ACCOUNT_NAME/.ssh/authorized_keys
        chown -R $ANSIBLE_ACCOUNT_NAME:$ANSIBLE_ACCOUNT_NAME /home/$ANSIBLE_ACCOUNT_NAME/.ssh
    "

    if [[ "$ANSIBLE_PASSWORDLESS" == true ]]; then
        apply_setting "disabling password for Ansible user" "
            passwd -d $ANSIBLE_ACCOUNT_NAME
            passwd -l $ANSIBLE_ACCOUNT_NAME
        "
    fi

    if [[ "$ANSIBLE_SUDO_PASSWORDLESS" == true ]]; then
        apply_setting "granting password-less sudo for Ansible user" "
            echo \"$ANSIBLE_ACCOUNT_NAME ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/$ANSIBLE_ACCOUNT_NAME
            chmod 440 /etc/sudoers.d/$ANSIBLE_ACCOUNT_NAME
        "
    fi
}




configure_wireguard() {
    log "INFO" "Configuring WireGuard..."
    apply_setting "installing and configuring WireGuard" "
        apt install -y wireguard qrencode
        wg genkey | tee /etc/wireguard/privatekey | wg pubkey > /etc/wireguard/publickey
        chmod 600 /etc/wireguard/privatekey
        PRIVATE_KEY=\$(cat /etc/wireguard/privatekey)
        cat <<EOF > /etc/wireguard/$WIREGUARD_INTERFACE.conf
[Interface]
Address = 10.0.0.1/24
ListenPort = $WIREGUARD_PORT
PrivateKey = \$PRIVATE_KEY
SaveConfig = true
EOF
        systemctl enable --now wg-quick@$WIREGUARD_INTERFACE
    "
}

configure_tailscale() {
    log "INFO" "Configuring Tailscale..."
    apply_setting "installing and configuring Tailscale" "
        curl -fsSL https://tailscale.com/install.sh | sh
        systemctl enable --now tailscaled
        tailscale up --authkey $TAILSCALE_AUTH_KEY --hostname $TAILSCALE_HOSTNAME --advertise-routes $TAILSCALE_ADVERTISE_ROUTES
    "
}

configure_common_tools() {
    log "INFO" "Installing common tools..."
    apply_setting "common tools installation" "
        apt install -y $COMMON_TOOLS
    "
}

configure_firewall() {
    log "INFO" "Configuring firewall..."
    apply_setting "setting up UFW firewall" "
        apt install -y ufw
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow $ALLOW_SSH_PORT
        ufw enable
    "
}

configure_fail2ban() {
    log "INFO" "Configuring Fail2Ban..."
    apply_setting "installing and configuring Fail2Ban" "
        apt install -y fail2ban
        cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = $FAIL2BAN_BANTIME
findtime = $FAIL2BAN_FINDTIME
maxretry = $FAIL2BAN_MAXRETRY

[sshd]
enabled = true
EOF
        systemctl restart fail2ban
    "
}

configure_ssh_hardening() {
    log "INFO" "Hardening SSH..."
    apply_setting "configuring SSH security settings" "
        sed -i.bak -E 's/^#?Port .*/Port $SSH_PORT/' /etc/ssh/sshd_config
        sed -i.bak -E 's/^#?PermitRootLogin .*/PermitRootLogin $SSH_DISABLE_ROOT/' /etc/ssh/sshd_config
        sed -i.bak -E 's/^#?PasswordAuthentication .*/PasswordAuthentication $SSH_DISABLE_PASSWORD_AUTH/' /etc/ssh/sshd_config
        systemctl reload sshd
    "
}

configure_docker() {
    log "INFO" "Installing Docker..."
    apply_setting "installing Docker and Docker Compose" "
        apt install -y apt-transport-https ca-certificates curl software-properties-common
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
        add-apt-repository \"deb [arch=amd64] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable\"
        apt update
        apt install -y docker-ce
        curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-\$(uname -s)-\$(uname -m)\" -o /usr/local/bin/docker-compose
        chmod +x /usr/local/bin/docker-compose
    "
}

# Prompt for interactive mode
INTERACTIVE=$(ask "Run in interactive mode?" "yes")
if [[ "$INTERACTIVE" =~ ^[Yy](es)?$ ]]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# Apply configurations
log "INFO" "Applying standard configurations..."
for CONFIG in "${STANDARD_CONFIGS[@]}"; do
    $CONFIG || error_exit "Failed to apply standard configuration: $CONFIG"
done

log "INFO" "Processing optional configurations..."
for CONFIG in "${OPTIONAL_CONFIGS[@]}"; do
    $CONFIG || log "INFO" "Failed to apply optional configuration: $CONFIG"
done

log "INFO" "Skipping disabled configurations..."
for CONFIG in "${DISABLED_CONFIGS[@]}"; do
    log "INFO" "Disabled: $CONFIG"
done

# Execute changes
log "INFO" "Starting post-setup script..."

if [[ "$ENABLE_ANSIBLE_USER" == true ]]; then
    configure_ansible_user
fi

if [[ "$ENABLE_WIREGUARD" == true ]]; then
    configure_wireguard
fi

if [[ "$ENABLE_TAILSCALE" == true ]]; then
    configure_tailscale
fi

if [[ "$INSTALL_COMMON_TOOLS" == true ]]; then
    configure_common_tools
fi

if [[ "$ENABLE_FIREWALL" == true ]]; then
    configure_firewall
fi

if [[ "$ENABLE_FAIL2BAN" == true ]]; then
    configure_fail2ban
fi

if [[ "$HARDEN_SSH" == true ]]; then
    configure_ssh_hardening
fi

if [[ "$INSTALL_DOCKER" == true ]]; then
    configure_docker
fi

log "INFO" "Post-setup script completed successfully."
