#!/bin/bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export APT_LISTCHANGES_FRONTEND=none

clear >/dev/null 2>&1 || true
rm -rf /mnt/main_install.sh

[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

RAW_BASE_URL="https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main/AIO/Configs/sing-box_proxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_ASSET_DIR=""
TARGET_BIN="/usr/local/bin/sing-box"
TARGET_RULE_SCRIPT="/usr/local/bin/singbox_rule_updata.sh"
TARGET_CONFIG_DIR="/usr/local/etc/sing-box"
TARGET_CONF_DIR="${TARGET_CONFIG_DIR}/conf"
TARGET_RULES_DIR="${TARGET_CONFIG_DIR}/rules"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
TPROXY_SERVICE_FILE="/etc/systemd/system/tproxy-router.service"
NFTABLES_FILE="/etc/nftables.conf"
STATE_DIR="/var/lib/linuxscripts-singbox-proxy"
SYSCTL_PROXY_FILE="/etc/sysctl.d/99-linuxscripts-singbox-proxy.conf"
WORK_DIR=""

red() {
    echo -e "\e[31m$1\e[0m"
}

green() {
    echo -e "\n\e[1m\e[37m\e[42m$1\e[0m\n"
}

yellow='\e[1m\e[33m'
reset='\e[0m'

white() {
    echo -e "$1"
}

cleanup_tmp() {
    if [[ -n "${WORK_DIR}" && -d "${WORK_DIR}" ]]; then
        rm -rf "${WORK_DIR}"
    fi
}

cleanup_and_exit() {
    cleanup_tmp
    [ -f /mnt/singbox.sh ] && rm -rf /mnt/singbox.sh
    exit "${1:-0}"
}

trap 'cleanup_and_exit 1' INT TERM
trap cleanup_tmp EXIT

if [[ -d "${SCRIPT_DIR}/../Configs/sing-box_proxy" ]]; then
    LOCAL_ASSET_DIR="$(cd "${SCRIPT_DIR}/../Configs/sing-box_proxy" && pwd)"
fi

back_to_main_menu() {
    white "脚本切换中，请等待..."
    [ -f /mnt/singbox.sh ] && rm -rf /mnt/singbox.sh
    wget -q -O /mnt/main_install.sh https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main/AIO/Scripts/main_install.sh && chmod +x /mnt/main_install.sh && /mnt/main_install.sh
}

download_file() {
    local url="$1"
    local destination="$2"

    mkdir -p "$(dirname "$destination")"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$destination" "$url"
    else
        red "当前系统缺少 curl 或 wget，无法下载文件"
        cleanup_and_exit 1
    fi
}

fetch_proxy_asset() {
    local relative_path="$1"
    local destination="$2"

    mkdir -p "$(dirname "$destination")"

    if [[ -n "$LOCAL_ASSET_DIR" && -f "${LOCAL_ASSET_DIR}/${relative_path}" ]]; then
        cp "${LOCAL_ASSET_DIR}/${relative_path}" "$destination"
    else
        download_file "${RAW_BASE_URL}/${relative_path}" "$destination"
    fi
}

create_work_dir() {
    cleanup_tmp
    WORK_DIR="$(mktemp -d /tmp/sing-box-proxy.XXXXXX)"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        *)
            red "当前架构暂不支持: $(uname -m)"
            cleanup_and_exit 1
            ;;
    esac
}

install_dependencies() {
    white "开始安装透明代理所需依赖..."
    apt-get update
    apt-get install -y curl wget unzip jq nftables
}

save_file_backup_once() {
    local source_file="$1"
    local backup_name="$2"

    [[ -f "$source_file" ]] || return 0
    mkdir -p "$STATE_DIR"

    if [[ ! -f "${STATE_DIR}/${backup_name}.bak" ]]; then
        cp -a "$source_file" "${STATE_DIR}/${backup_name}.bak"
    fi
}

configure_ip_forward() {
    if [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)" == "1" ]]; then
        return 0
    fi

    mkdir -p "$STATE_DIR"
    cat > "$SYSCTL_PROXY_FILE" <<'EOF'
net.ipv4.ip_forward=1
EOF
    sysctl --system >/dev/null
}

configure_systemd_resolved() {
    local resolved_conf="/etc/systemd/resolved.conf"

    [[ -f "$resolved_conf" ]] || return 0

    if grep -qE '^\s*DNSStubListener\s*=\s*no\s*$' "$resolved_conf"; then
        return 0
    fi

    save_file_backup_once "$resolved_conf" resolved.conf

    if grep -qE '^\s*#?\s*DNSStubListener\s*=' "$resolved_conf"; then
        sed -i -E 's/^\s*#?\s*DNSStubListener\s*=.*/DNSStubListener=no/' "$resolved_conf"
    else
        echo 'DNSStubListener=no' >> "$resolved_conf"
    fi

    touch "${STATE_DIR}/resolved.modified"
    systemctl reload-or-restart systemd-resolved >/dev/null 2>&1 || true
}

restore_system_changes() {
    if [[ -f "$SYSCTL_PROXY_FILE" ]]; then
        rm -f "$SYSCTL_PROXY_FILE"
        sysctl --system >/dev/null 2>&1 || true
    fi

    if [[ -f "${STATE_DIR}/resolved.conf.bak" ]]; then
        cp -a "${STATE_DIR}/resolved.conf.bak" /etc/systemd/resolved.conf
        systemctl reload-or-restart systemd-resolved >/dev/null 2>&1 || true
    fi

    rm -rf "$STATE_DIR"
}

confirm_proxy_overwrite() {
    if [[ -f "$TARGET_BIN" || -d "$TARGET_CONFIG_DIR" || -f "$SERVICE_FILE" ]]; then
        white "检测到当前系统已存在 sing-box 环境。"
        white "继续安装会覆盖原有 sing-box 配置，并会新增 nft 相关设置。"
        read -r -p "是否继续？[y/N]: " answer
        if [[ ! "$answer" =~ ^[Yy]$ ]]; then
            white "已取消安装。"
            return 1
        fi
    fi

    return 0
}

download_proxy_assets() {
    local variant="$1"
    local asset_root="${WORK_DIR}/assets"

    mkdir -p "${asset_root}/sing-box/conf"

    fetch_proxy_asset "sing-box.service" "${asset_root}/sing-box.service"
    fetch_proxy_asset "tproxy-router.service" "${asset_root}/tproxy-router.service"
    fetch_proxy_asset "nftables.conf" "${asset_root}/nftables.conf"
    fetch_proxy_asset "singbox_rule_updata.sh" "${asset_root}/singbox_rule_updata.sh"
    fetch_proxy_asset "sing-box/conf/00_log.json" "${asset_root}/sing-box/conf/00_log.json"
    fetch_proxy_asset "sing-box/conf/01_experimental.json" "${asset_root}/sing-box/conf/01_experimental.json"
    fetch_proxy_asset "sing-box/conf/03_inbounds.json" "${asset_root}/sing-box/conf/03_inbounds.json"
    if [[ "$variant" == "official" ]]; then
        fetch_proxy_asset "sing-box/conf/05_route.json" "${asset_root}/sing-box/conf/05_route.json"
        fetch_proxy_asset "sing-box/conf/02_dns.json" "${asset_root}/sing-box/conf/02_dns.json"
        fetch_proxy_asset "sing-box/conf/04_outbound-official.json" "${asset_root}/sing-box/conf/04_outbound.json"
    else
        fetch_proxy_asset "sing-box/conf/05_route-ref1nd.json" "${asset_root}/sing-box/conf/05_route.json"
        fetch_proxy_asset "sing-box/conf/02_dns-ref1nd.json" "${asset_root}/sing-box/conf/02_dns.json"
        fetch_proxy_asset "sing-box/conf/04_outbound-ref1nd.json" "${asset_root}/sing-box/conf/04_outbound.json"
    fi
}

download_singbox_binary() {
    local variant="$1"
    local arch
    local api_url
    local asset_name
    local download_url
    local tarball_path
    local extract_dir
    local binary_path

    arch="$(detect_arch)"
    tarball_path="${WORK_DIR}/sing-box.tar.gz"
    extract_dir="${WORK_DIR}/release"

    if [[ "$variant" == "official" ]]; then
        api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
        local version
        version="$(curl -fsSL "$api_url" | jq -r '.tag_name')"
        asset_name="sing-box-${version#v}-linux-${arch}.tar.gz"
        download_url="https://github.com/SagerNet/sing-box/releases/download/${version}/${asset_name}"
        white "开始下载官方版 sing-box: ${yellow}${version}${reset}"
    else
        api_url="https://api.github.com/repos/herozmy/StoreHouse/releases/tags/sing-box-reF1nd"
        asset_name="sing-box-reF1nd-dev-linux-${arch}.tar.gz"
        download_url="$(curl -fsSL "$api_url" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' | head -n 1)"

        if [[ -z "$download_url" || "$download_url" == "null" ]]; then
            red "未找到适用于当前架构的 reF1nd 发布包: ${asset_name}"
            cleanup_and_exit 1
        fi

        white "开始下载 reF1nd sing-box: ${yellow}${asset_name}${reset}"
    fi

    download_file "$download_url" "$tarball_path"

    mkdir -p "$extract_dir"
    tar -xzf "$tarball_path" -C "$extract_dir"
    binary_path="$(find "$extract_dir" -type f -name 'sing-box' | head -n 1)"

    if [[ -z "$binary_path" ]]; then
        red "解压后未找到 sing-box 二进制文件"
        cleanup_and_exit 1
    fi

    install -m 0755 "$binary_path" "$TARGET_BIN"
}

read_multiline_input() {
    local prompt="$1"
    local result=""
    local line=""
    local saw_end="false"

    echo "$prompt" >&2
    echo "输入完成后，请单独输入一行 END 结束。" >&2

    while IFS= read -r line; do
        if [[ "$line" == "END" ]]; then
            saw_end="true"
            break
        fi
        result+="${line}"$'\n'
    done

    if [[ "$saw_end" != "true" ]]; then
        return 1
    fi

    printf '%s' "$result"
}

configure_official_outbounds() {
    local outbound_file="${TARGET_CONF_DIR}/04_outbound.json"
    local user_input
    local normalized_nodes
    local node_tags

    while true; do
        if ! user_input="$(read_multiline_input "请粘贴至少一个完整的出站节点 JSON（支持单个对象或对象数组）:")"; then
            red "未读取到完整的节点 JSON，安装终止。"
            cleanup_and_exit 1
        fi

        if [[ -z "${user_input//[$'\t\r\n ']}" ]]; then
            red "节点 JSON 不能为空，请重新输入。"
            continue
        fi

        if ! normalized_nodes="$(printf '%s' "$user_input" | jq -c 'if type == "array" then . elif type == "object" then [.] else error("节点格式必须是对象或数组") end')" ; then
            red "节点 JSON 格式无效，请重新输入。"
            continue
        fi

        if ! printf '%s' "$normalized_nodes" | jq -e 'length > 0 and all(.[]; type == "object" and (.tag | type == "string") and (.tag | length > 0))' >/dev/null; then
            red "每个节点都必须是对象，并且必须包含非空 tag。请重新输入。"
            continue
        fi

        node_tags="$(printf '%s' "$normalized_nodes" | jq -c '[.[].tag]')"

        jq --argjson nodes "$normalized_nodes" --argjson tags "$node_tags" '
            .outbounds |= (
                map(if .tag == "Proxy" then .outbounds = $tags else . end)
                | [.[0]] + $nodes + (.[1:] | map(select(.tag != "节点1" and .tag != "节点2")))
            )
        ' "$outbound_file" > "${outbound_file}.tmp"
        mv "${outbound_file}.tmp" "$outbound_file"
        break
    done
}

configure_ref1nd_outbounds() {
    local outbound_file="${TARGET_CONF_DIR}/04_outbound.json"
    local subscription_url=""

    while true; do
        if ! read -r -p "请输入机场订阅链接: " subscription_url; then
            red "未读取到订阅链接，安装终止。"
            cleanup_and_exit 1
        fi
        if [[ -n "$subscription_url" ]]; then
            break
        fi
        red "订阅链接不能为空，请重新输入。"
    done

    jq --arg subscription "$subscription_url" '
        (.providers[] | select(.tag == "🛫 机场") | .url) = $subscription
    ' "$outbound_file" > "${outbound_file}.tmp"
    mv "${outbound_file}.tmp" "$outbound_file"
}

install_proxy_files() {
    local asset_root="${WORK_DIR}/assets"

    rm -rf "$TARGET_CONFIG_DIR"
    mkdir -p "$TARGET_CONF_DIR"

    install -m 0644 "${asset_root}/sing-box.service" "$SERVICE_FILE"
    install -m 0644 "${asset_root}/tproxy-router.service" "$TPROXY_SERVICE_FILE"
    install -m 0644 "${asset_root}/nftables.conf" "$NFTABLES_FILE"
    install -m 0755 "${asset_root}/singbox_rule_updata.sh" "$TARGET_RULE_SCRIPT"

    install -m 0644 "${asset_root}/sing-box/conf/00_log.json" "${TARGET_CONF_DIR}/00_log.json"
    install -m 0644 "${asset_root}/sing-box/conf/01_experimental.json" "${TARGET_CONF_DIR}/01_experimental.json"
    install -m 0644 "${asset_root}/sing-box/conf/02_dns.json" "${TARGET_CONF_DIR}/02_dns.json"
    install -m 0644 "${asset_root}/sing-box/conf/03_inbounds.json" "${TARGET_CONF_DIR}/03_inbounds.json"
    install -m 0644 "${asset_root}/sing-box/conf/04_outbound.json" "${TARGET_CONF_DIR}/04_outbound.json"
    install -m 0644 "${asset_root}/sing-box/conf/05_route.json" "${TARGET_CONF_DIR}/05_route.json"
}

update_rule_sets() {
    mkdir -p "$TARGET_RULES_DIR"
    "$TARGET_RULE_SCRIPT"
}

start_proxy_services() {
    systemctl daemon-reload
    systemctl enable --now tproxy-router
    nft flush ruleset
    nft -f "$NFTABLES_FILE"
    systemctl enable --now nftables
    systemctl restart nftables
    systemctl enable --now sing-box
}

install_proxy_variant() {
    local variant="$1"

    confirm_proxy_overwrite || return
    create_work_dir
    install_dependencies
    download_proxy_assets "$variant"
    download_singbox_binary "$variant"
    install_proxy_files

    if [[ "$variant" == "official" ]]; then
        configure_official_outbounds
    else
        configure_ref1nd_outbounds
    fi

    update_rule_sets
    configure_ip_forward
    configure_systemd_resolved
    start_proxy_services

    green "sing-box 透明代理安装完成"
    white "二进制路径：${yellow}${TARGET_BIN}${reset}"
    white "配置目录：${yellow}${TARGET_CONFIG_DIR}${reset}"
    white "服务名称：${yellow}sing-box / tproxy-router${reset}"
}

write_empty_nftables_file() {
    cat > "$NFTABLES_FILE" <<'EOF'
#!/usr/sbin/nft -f
flush ruleset
EOF
}

uninstall_proxy() {
    white "开始卸载 sing-box 透明代理..."

    systemctl disable --now sing-box >/dev/null 2>&1 || true
    systemctl disable --now tproxy-router >/dev/null 2>&1 || true
    systemctl disable --now nftables >/dev/null 2>&1 || true

    nft flush ruleset >/dev/null 2>&1 || true
    write_empty_nftables_file

    rm -f "$TARGET_BIN"
    rm -f "$TARGET_RULE_SCRIPT"
    rm -rf "$TARGET_CONFIG_DIR"
    rm -f "$SERVICE_FILE"
    rm -f "$TPROXY_SERVICE_FILE"

    restore_system_changes

    systemctl daemon-reload

    green "sing-box 已卸载完成"
}

download_home_scripts() {
    wget -q -O /mnt/install-sing-box-home.sh https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main/AIO/Scripts/install-sing-box-home.sh
    wget -q -O /mnt/generate-sing-box-config.sh https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main/AIO/Scripts/generate-sing-box-config.sh

    if [ ! -f /mnt/install-sing-box-home.sh ] || [ ! -f /mnt/generate-sing-box-config.sh ]; then
        red "回家脚本下载失败，请检查网络后重试"
        cleanup_and_exit 1
    fi

    chmod +x /mnt/install-sing-box-home.sh /mnt/generate-sing-box-config.sh
}

launch_home_installer() {
    white "开始进入 sing-box 回家安装器..."
    download_home_scripts
    /mnt/install-sing-box-home.sh
}

show_proxy_menu() {
    clear >/dev/null 2>&1 || true
    echo "=================================================================="
    echo -e "\t\tSing-Box 透明代理安装器"
    echo -e "\t\n"
    echo "请选择要执行的操作："
    echo "=================================================================="
    echo "1. 安装官方版 sing-box（仅推荐 VPS 用户使用）"
    echo "2. 安装 reF1nd sing-box（推荐机场用户使用）"
    echo "3. 卸载sing-box"
    echo -e "\t"
    echo "-. 返回上级菜单"
    echo "0) 退出脚本"
}

launch_proxy_manager() {
    local choice

    while true; do
        show_proxy_menu
        read -r -p "请选择操作: " choice
        case "$choice" in
            1)
                if install_proxy_variant "official"; then
                    cleanup_and_exit 0
                fi
                ;;
            2)
                if install_proxy_variant "ref1nd"; then
                    cleanup_and_exit 0
                fi
                ;;
            3)
                uninstall_proxy
                cleanup_and_exit 0
                ;;
            0)
                red "退出脚本，感谢使用."
                cleanup_and_exit 0
                ;;
            -)
                return
                ;;
            *)
                white "无效的选项，1秒后返回当前菜单，请重新选择有效的选项."
                sleep 1
                ;;
        esac
    done
}

show_menu() {
    clear >/dev/null 2>&1 || true
    echo "=================================================================="
    echo -e "\t\tSing-Box相关脚本 by Tom"
    echo -e "\t\n"
    echo "欢迎使用Sing-Box相关脚本"
    echo "请选择要执行的服务："
    echo "=================================================================="
    echo "1. 安装sing-box透明代理"
    echo "2. 配置sing-box回家"
    echo -e "\t"
    echo "-. 返回上级菜单"
    echo "0) 退出脚本"
}

main() {
    local choice

    while true; do
        show_menu
        read -r -p "请选择服务: " choice
        case "$choice" in
            1)
                launch_proxy_manager
                ;;
            2)
                launch_home_installer
                return
                ;;
            0)
                red "退出脚本，感谢使用."
                cleanup_and_exit 0
                ;;
            -)
                back_to_main_menu
                return
                ;;
            *)
                white "无效的选项，1秒后返回当前菜单，请重新选择有效的选项."
                sleep 1
                ;;
        esac
    done
}

main
