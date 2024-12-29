#!/bin/bash
set -e

# Load configuration
CONFIG_FILE="./post-setup.cfg"
if [[ -f $CONFIG_FILE ]]; then
    # Parse configuration file
    STANDARD_CONFIGS=$(grep "^STANDARD " "$CONFIG_FILE" | sed 's/^STANDARD //')
    OPTIONAL_CONFIGS=$(grep "^OPTIONAL " "$CONFIG_FILE" | sed 's/^OPTIONAL //')
    DISABLED_CONFIGS=$(grep "^DISABLED " "$CONFIG_FILE" | sed 's/^DISABLED //')
else
    echo "Configuration file ($CONFIG_FILE) not found!"
    exit 1
fi

# Helper functions
log() {
    echo -e "[\033[1;34mINFO\033[0m] $1"
}

error_exit() {
    echo -e "[\033[1;31mERROR\033[0m] $1" >&2
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
            eval "$command"
        else
            log "Skipped $description."
        fi
    else
        eval "$command"
    fi
}

# Prompt for interactive mode
INTERACTIVE=$(ask "Run in interactive mode?" "yes")
if [[ "$INTERACTIVE" =~ ^[Yy](es)?$ ]]; then
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# Process configurations
log "Applying standard configurations..."
for CONFIG in $STANDARD_CONFIGS; do
    eval "$CONFIG"
done

log "Processing optional configurations..."
for CONFIG in $OPTIONAL_CONFIGS; do
    eval "$CONFIG"
done

log "Skipping disabled configurations..."
for CONFIG in $DISABLED_CONFIGS; do
    log "Disabled: $CONFIG"
done

# Execute changes
log "Starting post-setup script..."

# 1. Configure Ansible User
if [[ "$ENABLE_ANSIBLE_USER" == true ]]; then
    apply_setting "creating Ansible user" "
        adduser --disabled-password --gecos '' $ANSIBLE_ACCOUNT_NAME
        mkdir -p /home/$ANSIBLE_ACCOUNT_NAME/.ssh
        curl -s https://github.com/$ANSIBLE_GITHUB_USERNAME.keys -o /home/$ANSIBLE_ACCOUNT_NAME/.ssh/authorized_keys
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
fi

log "Post-setup script completed successfully."

