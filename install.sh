#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

repo="fsh2502/XrayRTT"
release_repo="fsh2502/XrayRTT-release"
repo_branch="main"
config_base_url="https://raw.githubusercontent.com/${repo}/${repo_branch}/release/config"
release_raw_base_url="https://raw.githubusercontent.com/${release_repo}/${repo_branch}"
github_api_base="https://api.github.com/repos/${repo}"
service_name="XrayR"
install_dir="/usr/local/XrayR"
config_dir="/etc/XrayR"
binary_path="${install_dir}/XrayR"
installer_copy="${install_dir}/install.sh"

if [[ $EUID -ne 0 ]]; then
    echo -e "${red}Error:${plain} This script must be run as root."
    exit 1
fi

release=""
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    case "${ID:-}" in
        centos|rhel|rocky|almalinux)
            release="centos"
            ;;
        ubuntu)
            release="ubuntu"
            ;;
        debian)
            release="debian"
            ;;
    esac
fi

if [[ -z "$release" && -f /etc/redhat-release ]]; then
    release="centos"
fi

if [[ -z "$release" && -f /etc/issue ]]; then
    if grep -Eqi "debian" /etc/issue; then
        release="debian"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /etc/issue; then
        release="centos"
    fi
fi

if [[ -z "$release" && -f /proc/version ]]; then
    if grep -Eqi "debian" /proc/version; then
        release="debian"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
    elif grep -Eqi "centos|red hat|redhat" /proc/version; then
        release="centos"
    fi
fi

if [[ -z "$release" ]]; then
    echo -e "${red}Error:${plain} Unsupported operating system."
    exit 1
fi

arch=$(uname -m)
case "$arch" in
    x86_64|x64|amd64)
        arch="64"
        ;;
    i386|i686)
        arch="32"
        ;;
    aarch64|arm64)
        arch="arm64-v8a"
        ;;
    armv7l|armv7)
        arch="arm32-v7a"
        ;;
    *)
        arch="64"
        echo -e "${yellow}Warning:${plain} Unknown architecture detected, defaulting to ${arch}."
        ;;
esac

echo "Detected architecture: ${arch}"

if [[ "$(getconf LONG_BIT 2>/dev/null)" != "64" && "$arch" != "32" ]]; then
    echo -e "${red}Error:${plain} This script only supports architectures with available upstream assets."
    exit 2
fi

os_version=""
if [[ -f /etc/os-release ]]; then
    os_version=$(awk -F'[=.\"]+' '/^VERSION_ID=/{print $2}' /etc/os-release)
fi
if [[ -z "$os_version" && -f /etc/lsb-release ]]; then
    os_version=$(awk -F'[=.\"]+' '/^DISTRIB_RELEASE=/{print $2}' /etc/lsb-release)
fi

if [[ -n "$os_version" ]]; then
    if [[ "$release" == "centos" && "$os_version" -le 6 ]]; then
        echo -e "${red}Error:${plain} Please use CentOS 7 or later."
        exit 1
    fi
    if [[ "$release" == "ubuntu" && "$os_version" -lt 16 ]]; then
        echo -e "${red}Error:${plain} Please use Ubuntu 16 or later."
        exit 1
    fi
    if [[ "$release" == "debian" && "$os_version" -lt 8 ]]; then
        echo -e "${red}Error:${plain} Please use Debian 8 or later."
        exit 1
    fi
fi

install_base() {
    if [[ "$release" == "centos" ]]; then
        yum install -y epel-release
        yum install -y openssl wget curl unzip tar crontabs socat
        if command -v firewall-cmd >/dev/null 2>&1; then
            firewall-cmd --zone=public --add-port=80/tcp --permanent || true
            firewall-cmd --zone=public --add-port=443/tcp --permanent || true
            firewall-cmd --reload || true
        fi
    else
        apt update -y
        apt install -y openssl wget curl unzip tar cron socat
        if command -v ufw >/dev/null 2>&1; then
            ufw allow 80 || true
            ufw allow 443 || true
        fi
    fi
}

check_status() {
    if [[ ! -f /etc/systemd/system/${service_name}.service ]]; then
        return 2
    fi

    local temp
    temp=$(systemctl is-active "${service_name}" 2>/dev/null || true)
    if [[ "$temp" == "active" ]]; then
        return 0
    fi

    return 1
}

validate_cert_modes() {
    local config_file="${config_dir}/config.yml"
    local invalid=0
    local value

    if [[ ! -f "$config_file" ]]; then
        return 0
    fi

    while IFS= read -r value; do
        value=$(printf '%s' "$value" | sed -E 's/^[[:space:]]*CertMode:[[:space:]]*//; s/[[:space:]#].*$//' | tr '[:upper:]' '[:lower:]')
        [[ -z "$value" ]] && continue

        case "$value" in
            none|file|http|tls|dns)
                ;;
            *)
                echo -e "${red}Error:${plain} Unsupported CertMode '${value}' found in ${config_file}. Supported values: none, file, http, tls, dns."
                invalid=1
                ;;
        esac
    done < <(grep -E '^[[:space:]]*CertMode:[[:space:]]*' "$config_file" || true)

    return "$invalid"
}

start_enabled_service() {
    if validate_cert_modes; then
        systemctl start "${service_name}"
        sleep 2
        check_status
        if [[ $? -eq 0 ]]; then
            echo -e "XrayR started successfully and will auto-start on VPS boot."
        else
            echo -e "${yellow}Warning:${plain} XrayR is enabled for VPS boot, but it may not have started correctly right now. Check logs with: XrayR log"
        fi
    else
        echo -e "${yellow}Warning:${plain} XrayR was enabled for VPS boot, but it was not started because the current config contains unsupported CertMode values."
    fi
}

install_acme() {
    curl -fsSL https://get.acme.sh | sh
}

get_latest_version() {
    local version

    version=$(
        curl -fsSL "${github_api_base}/releases?per_page=1" \
            | grep '"tag_name":' \
            | head -n 1 \
            | sed -E 's/.*"([^"]+)".*/\1/'
    )

    if [[ -z "$version" ]]; then
        version=$(
            curl -fsSL "${github_api_base}/tags?per_page=1" \
                | grep '"name":' \
                | head -n 1 \
                | sed -E 's/.*"([^"]+)".*/\1/'
        )
    fi

    printf '%s' "$version"
}

download_repo_config() {
    local source_name="$1"
    local target_name="${2:-$1}"
    curl -fsSL -o "${config_dir}/${target_name}" "${config_base_url}/${source_name}"
}

persist_installer_copy() {
    local source_path=""

    if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
        source_path="${BASH_SOURCE[0]}"
    elif [[ -n "${0:-}" ]]; then
        source_path="$0"
    fi

    case "$source_path" in
        /dev/fd/*|/proc/self/fd/*)
            echo -e "${yellow}Warning:${plain} Installer was launched from a file descriptor, so it cannot safely persist itself to ${installer_copy}."
            return 0
            ;;
    esac

    if [[ -n "$source_path" && -r "$source_path" ]]; then
        cp -f "$source_path" "${installer_copy}"
        chmod +x "${installer_copy}"
    else
        echo -e "${yellow}Warning:${plain} Could not persist the installer script to ${installer_copy}."
    fi
}

create_systemd_service() {
    if curl -fsSL -o "/etc/systemd/system/${service_name}.service" "${release_raw_base_url}/XrayR.service"; then
        return 0
    fi

    cat > "/etc/systemd/system/${service_name}.service" <<EOF
[Unit]
Description=${service_name} Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${install_dir}
ExecStart=${binary_path} -c ${config_dir}/config.yml
Restart=on-failure
RestartSec=5s
LimitNOFILE=51200

[Install]
WantedBy=multi-user.target
EOF
}

create_manager_script() {
    cat > /usr/bin/XrayR <<'EOF'
#!/bin/bash

service_name="XrayR"
install_dir="/usr/local/XrayR"
binary_path="${install_dir}/XrayR"
installer_copy="${install_dir}/install.sh"
config_file="/etc/XrayR/config.yml"

show_help() {
    echo "XrayR management commands:"
    echo "  XrayR start              - Start XrayR"
    echo "  XrayR stop               - Stop XrayR"
    echo "  XrayR restart            - Restart XrayR"
    echo "  XrayR status             - Show XrayR status"
    echo "  XrayR enable             - Enable auto-start"
    echo "  XrayR disable            - Disable auto-start"
    echo "  XrayR log                - Show XrayR logs"
    echo "  XrayR config             - Show the config file"
    echo "  XrayR version            - Show installed version"
    echo "  XrayR update [version]   - Re-run the bundled installer"
    echo "  XrayR install [version]  - Re-run the bundled installer"
    echo "  XrayR uninstall          - Remove XrayR"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This command must be run as root."
        exit 1
    fi
}

case "${1:-}" in
    "")
        show_help
        ;;
    start|stop|restart|enable|disable)
        require_root
        systemctl "$1" "${service_name}"
        ;;
    status)
        systemctl status "${service_name}" --no-pager
        ;;
    log)
        journalctl -u "${service_name}" -e --no-pager
        ;;
    config)
        cat "${config_file}"
        ;;
    version)
        "${binary_path}" version
        ;;
    update|install)
        require_root
        if [[ -x "${installer_copy}" ]]; then
            bash "${installer_copy}" "${2:-}"
        else
            echo "Bundled installer not found at ${installer_copy}"
            exit 1
        fi
        ;;
    uninstall)
        require_root
        systemctl stop "${service_name}" >/dev/null 2>&1 || true
        systemctl disable "${service_name}" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${service_name}.service"
        rm -f /usr/bin/XrayR /usr/bin/xrayr
        rm -rf /usr/local/XrayR /etc/XrayR
        systemctl daemon-reload
        echo "XrayR removed."
        ;;
    *)
        show_help
        exit 1
        ;;
esac
EOF

    chmod +x /usr/bin/XrayR
    ln -sf /usr/bin/XrayR /usr/bin/xrayr
}

install_xrayr() {
    local last_version
    local url

    rm -rf "${install_dir}"
    mkdir -p "${install_dir}"
    mkdir -p "${config_dir}"
    cd "${install_dir}" || exit 1

    if [[ $# -eq 0 || -z "${1:-}" ]]; then
        last_version=$(get_latest_version)
        if [[ -z "$last_version" ]]; then
            echo -e "${red}Error:${plain} Could not detect the latest XrayRTT version from GitHub."
            exit 1
        fi
        echo -e "Detected latest XrayRTT version: ${green}${last_version}${plain}"
    else
        last_version="$1"
        echo -e "Installing XrayRTT version: ${green}${last_version}${plain}"
    fi

    url="https://github.com/${repo}/releases/download/${last_version}/XrayR-linux-${arch}.zip"
    if ! wget -N --no-check-certificate -O "${install_dir}/XrayR-linux.zip" "$url"; then
        echo -e "${red}Error:${plain} Failed to download XrayRTT from ${url}"
        exit 1
    fi

    if ! unzip -o XrayR-linux.zip; then
        echo -e "${red}Error:${plain} Failed to unzip XrayR-linux.zip"
        exit 1
    fi

    rm -f XrayR-linux.zip

    if [[ ! -f "${binary_path}" ]]; then
        echo -e "${red}Error:${plain} XrayR binary not found after extraction."
        exit 1
    fi

    chmod +x "${binary_path}"

    create_systemd_service
    systemctl daemon-reload
    systemctl stop "${service_name}" >/dev/null 2>&1 || true
    systemctl enable "${service_name}"

    for asset in geoip.dat geosite.dat dns.json route.json custom_outbound.json custom_inbound.json; do
        if [[ -f "${install_dir}/${asset}" ]]; then
            cp -f "${install_dir}/${asset}" "${config_dir}/${asset}"
        fi
    done

    if [[ ! -f "${config_dir}/geoip.dat" ]]; then
        download_repo_config "geoip.dat"
    fi
    if [[ ! -f "${config_dir}/geosite.dat" ]]; then
        download_repo_config "geosite.dat"
    fi
    if [[ ! -f "${config_dir}/dns.json" ]]; then
        download_repo_config "dns.json"
    fi
    if [[ ! -f "${config_dir}/route.json" ]]; then
        download_repo_config "route.json"
    fi
    if [[ ! -f "${config_dir}/custom_outbound.json" ]]; then
        download_repo_config "custom_outbound.json"
    fi
    if [[ ! -f "${config_dir}/custom_inbound.json" ]]; then
        download_repo_config "custom_inbound.json"
    fi

    if [[ ! -f "${config_dir}/config.yml" ]]; then
        if [[ -f "${install_dir}/config.yml" ]]; then
            cp -f "${install_dir}/config.yml" "${config_dir}/config.yml"
        elif [[ -f "${install_dir}/config.yml.example" ]]; then
            cp -f "${install_dir}/config.yml.example" "${config_dir}/config.yml"
        elif [[ -f "${install_dir}/release/config/config.yml.example" ]]; then
            cp -f "${install_dir}/release/config/config.yml.example" "${config_dir}/config.yml"
        else
            download_repo_config "config.yml.example" "config.yml"
        fi

        echo "Fresh install detected. The config template was placed at ${config_dir}/config.yml."
        start_enabled_service
    else
        start_enabled_service
    fi

    persist_installer_copy
    create_manager_script

    echo -e "XrayRTT ${green}${last_version}${plain} installed successfully."
    echo ""
    echo "XrayR management commands:"
    echo "  XrayR                    - Show the management help"
    echo "  XrayR start              - Start XrayR"
    echo "  XrayR stop               - Stop XrayR"
    echo "  XrayR restart            - Restart XrayR"
    echo "  XrayR status             - Show XrayR status"
    echo "  XrayR enable             - Enable auto-start"
    echo "  XrayR disable            - Disable auto-start"
    echo "  XrayR log                - Show XrayR logs"
    echo "  XrayR update [version]   - Re-run the bundled installer"
    echo "  XrayR config             - Show the config file"
    echo "  XrayR uninstall          - Uninstall XrayR"
    echo "  XrayR version            - Show installed version"
}

echo -e "Starting installation..."
install_base
install_acme
install_xrayr "${1:-}"
