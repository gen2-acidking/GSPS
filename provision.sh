#!/bin/bash
# provision.sh - Main provisioning entry point with dependency management

set -euo pipefail

PROVISION_SERVER="http://192.168.0.103"
SCRIPT_DIR="/tmp/gentoo-provision"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

download_file() {
    local remote_path="$1"
    local local_file="$2"
    
    log "Downloading $remote_path"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$PROVISION_SERVER/$remote_path" -o "$local_file"
    elif command -v wget >/dev/null 2>&1; then
        wget -q "$PROVISION_SERVER/$remote_path" -O "$local_file"
    else
        echo "Error: Neither curl nor wget available"
        exit 1
    fi
}

download_and_run() {
    local script_path="$1"
    local config_path="$2"
    local deps="$3"  # Space-separated list of dependencies
    
    mkdir -p "$SCRIPT_DIR"
    cd "$SCRIPT_DIR"
    
    # Download main script
    download_file "scripts/$script_path" "$(basename "$script_path")"
    chmod +x "$(basename "$script_path")"
    
    # Download config if specified
    if [[ -n "$config_path" ]]; then
        download_file "configs/$config_path" "$(basename "$config_path")"
    fi
    
    # Download dependencies
    if [[ -n "$deps" ]]; then
        log "Downloading dependencies: $deps"
        for dep in $deps; do
            case "$dep" in
                tools/*)
                    download_file "resources/$dep" "$(basename "$dep")"
                    chmod +x "$(basename "$dep")"
                    ;;
                configs/*)
                    download_file "resources/$dep" "$(basename "$dep")"
                    ;;
                scripts/*)
                    download_file "resources/$dep" "$(basename "$dep")"
                    chmod +x "$(basename "$dep")"
                    ;;
                *)
                    download_file "resources/tools/$dep" "$dep"
                    chmod +x "$dep" 2>/dev/null || true
                    ;;
            esac
        done
    fi
    
    # Execute script with config
    log "Executing $script_path"
    if [[ -n "$config_path" ]]; then
        "./$(basename "$script_path")" "$(basename "$config_path")"
    else
        "./$(basename "$script_path")"
    fi
}

show_main_menu() {
    clear
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                           GSPS                               ║
║                        Version 1.0                           ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  1) Install Base                                             ║
║  2) Provision                                                ║
║  3) Update                                                   ║
║  4) Exit                                                     ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo
    read -p "Select option [1-4]: " choice
    
    case $choice in
        1) show_install_menu ;;
        2) show_provision_menu ;;
        3) show_update_menu ;;
        4) exit 0 ;;
        *) echo "Invalid option"; sleep 2; show_main_menu ;;
    esac
}

show_install_menu() {
    clear
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                        Install Base                          ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  1) base-base        - Minimal Gentoo system                 ║
║  2) vm-base          - VM optimized base                     ║
║  3) server-base      - Server base system                    ║
║  4) dev-env-base     - Development environment base          ║
║  5) Back to main menu                                        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo
    read -p "Select option [1-5]: " choice
    
    case $choice in
        1) download_and_run "install/base-base.sh" "install/base-base.conf" "genfstab" ;;
        2) download_and_run "install/vm-base.sh" "install/vm-base.conf" "genfstab vm-optimize.sh" ;;
        3) download_and_run "install/server-base.sh" "install/server-base.conf" "genfstab server-configs.tar.gz" ;;
        4) download_and_run "install/dev-env-base.sh" "install/dev-env-base.conf" "genfstab dev-tools.list" ;;
        5) show_main_menu ;;
        *) echo "Invalid option"; sleep 2; show_install_menu ;;
    esac
}

show_provision_menu() {
    clear
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                         Provision                            ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║  1) dwm-package              - DWM tiling window manager     ║
║  2) samba-server             - Samba file server             ║
║  3) kernel menu              - Samba file server             ║
║  4) Back to main menu                                        ║ 
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    echo
    read -p "Select option [1-6]: " choice
    
    case $choice in
        1) download_and_run "provision/dwm-package.sh" "provision/dwm-package.conf" "configs/dwm-config.h" ;;
        2) download_and_run "provision/samba-server.sh" "provision/samba-server.conf" "configs/smb.conf.template" ;;
        3) show_main_menu ;;
        4) show_main_menu ;;
        *) echo "Invalid option"; sleep 2; show_provision_menu ;;
    esac
}


show_update_menu() {
    clear
    cat << 'EOF'
╔══════════════════════════════════════════════════════════════╗
║                           Update                             ║
╠══════════════════════════════════════════════════════════════╣
║                                                              ║
║                  Coming Soon...                              ║
║                                                              ║
║  Press any key to return to main menu                        ║
║                                                              ║
╚══════════════════════════════════════════════════════════════╝
EOF
    read -n 1
    show_main_menu
}

# Start the menu system
show_main_menu