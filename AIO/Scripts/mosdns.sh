#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export APT_LISTCHANGES_FRONTEND=none

clear
rm -rf /mnt/main_install.sh
[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

red(){
    echo -e "\e[31m$1\e[0m"
}
green(){
    echo -e "\n\e[1m\e[37m\e[42m$1\e[0m\n"
}
yellow='\e[1m\e[33m'
reset='\e[0m'
white(){
    echo -e "$1"
}

SCRIPT_REPO_BASE="https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main"
SERVICE_URL="https://raw.githubusercontent.com/jasonxtt/file/main/mosdns/service/mosdns.service"
MOSDNS_RELEASES_BASE_URL="https://github.com/jasonxtt/mosdns/releases"
MOSDNS_STD_RELEASE_TAG=""
MOSDNS_STD_ASSET_PREFIX=""
MOSDNS_STD_CONFIG_ZIP_URL="https://raw.githubusercontent.com/jasonxtt/file/main/mosdns/config/config_all.zip"
MOSDNS_LITE_RELEASE_TAG=""
MOSDNS_LITE_ASSET_PREFIX=""
MOSDNS_LITE_CONFIG_ZIP_URL="https://raw.githubusercontent.com/jasonxtt/file/main/mosdns/config/config_lite_all.zip"

MOSDNS_PH_RELEASES_BASE_URL="https://github.com/yyysuo/mosdns/releases"
MOSDNS_PH_CONFIG_ZIP_URL="https://raw.githubusercontent.com/yyysuo/firetv/refs/heads/master/mosdnsconfigupdate/mosdns1225all.zip"

MOSDNS_FLAVOR_NAME=""
MOSDNS_RELEASE_TAG=""
MOSDNS_ASSET_PREFIX=""
MOSDNS_CONFIG_ZIP_URL=""
INIT_SYSTEM=""
SYSTEMD_SERVICE_FILE="/etc/systemd/system/mosdns.service"
OPENRC_SERVICE_FILE="/etc/init.d/mosdns"

ATOMDNS_RELEASE_URL="https://github.com/jasonxtt/atomdns/releases/latest/download"
ATOMDNS_BIN="/usr/local/bin/atomdns"
ATOMDNS_DIR="/usr/local/etc/atomdns"
ATOMDNS_SYSTEMD_SERVICE_FILE="/etc/systemd/system/atomdns.service"
ATOMDNS_OPENRC_SERVICE_FILE="/etc/init.d/atomdns"

is_valid_ipv4() {
    local ip="$1"
    local octet
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

is_valid_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
    ((port >= 1 && port <= 65535))
}

is_valid_host_port() {
    local value="$1"
    local host
    local port

    [[ "$value" =~ ^[^:]+:[0-9]{1,5}$ ]] || return 1
    host="${value%:*}"
    port="${value##*:}"

    is_valid_port "$port" || return 1
    is_valid_ipv4 "$host" || return 1
    return 0
}

escape_sed_replacement() {
    printf '%s' "$1" | sed -e 's/[\\&]/\\&/g'
}

get_public_ipv4() {
    local sources=(
        "https://ddns.oray.com/checkip"
        "https://ip.3322.net"
        "https://v4.yinghualuo.cn/bejson"
    )
    local source
    local body
    local ip

    for source in "${sources[@]}"; do
        body=$(curl -fsSL --max-time 8 "$source" 2>/dev/null || true)
        ip=$(printf '%s' "$body" | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | while read -r candidate; do
            if is_valid_ipv4 "$candidate"; then
                echo "$candidate"
                break
            fi
        done)

        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done

    return 1
}

detect_init_system() {
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
    else
        red "当前系统既未检测到 systemd，也未检测到 OpenRC"
        exit 1
    fi
}

install_dependencies() {
    white "开始安装依赖..."

    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -y && apt-get install -y curl wget unzip perl ca-certificates || {
            red "依赖安装失败"
            exit 1
        }
    elif command -v apk >/dev/null 2>&1; then
        apk update && apk add --no-cache bash curl wget unzip perl ca-certificates openrc || {
            red "依赖安装失败"
            exit 1
        }
    else
        red "当前系统不支持 apt-get 或 apk，无法自动安装依赖"
        exit 1
    fi

    detect_init_system
}

set_mosdns_flavor() {
    local flavor="$1"

    case "$flavor" in
        standard)
            MOSDNS_FLAVOR_NAME="Tom魔改版"
            MOSDNS_RELEASE_TAG="$MOSDNS_STD_RELEASE_TAG"
            MOSDNS_ASSET_PREFIX="$MOSDNS_STD_ASSET_PREFIX"
            MOSDNS_CONFIG_ZIP_URL="$MOSDNS_STD_CONFIG_ZIP_URL"
            MOSDNS_RELEASES_BASE_URL="https://github.com/jasonxtt/mosdns/releases"
            ;;
        lite)
            MOSDNS_FLAVOR_NAME="Tom魔改lite版"
            MOSDNS_RELEASE_TAG="$MOSDNS_LITE_RELEASE_TAG"
            MOSDNS_ASSET_PREFIX="$MOSDNS_LITE_ASSET_PREFIX"
            MOSDNS_CONFIG_ZIP_URL="$MOSDNS_LITE_CONFIG_ZIP_URL"
            MOSDNS_RELEASES_BASE_URL="https://github.com/jasonxtt/mosdns/releases"
            ;;
        ph)
            MOSDNS_FLAVOR_NAME="PH版"
            MOSDNS_RELEASE_TAG=""
            MOSDNS_ASSET_PREFIX="mosdns-"
            MOSDNS_CONFIG_ZIP_URL="$MOSDNS_PH_CONFIG_ZIP_URL"
            MOSDNS_RELEASES_BASE_URL="$MOSDNS_PH_RELEASES_BASE_URL"
            ;;
        *)
            red "未知的 Mosdns 安装类型：$flavor"
            exit 1
            ;;
    esac
}

get_mosdns_asset_candidates() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        x86_64|amd64)
            # x86 默认非 v3，避免老CPU或虚拟机指令集不完整导致不可运行
            echo "linux-amd64 linux-x86_64"
            ;;
        aarch64|arm64)
            echo "linux-arm64 linux-aarch64"
            ;;
        armv7l|armv7|armhf)
            echo "linux-armv7 linux-arm-7 linux-armv7l"
            ;;
        armv6l|armv6)
            echo "linux-armv6 linux-arm-6"
            ;;
        *)
            return 1
            ;;
    esac
}

fetch_latest_release_tag() {
    local repo="$1"
    local tag_prefix="$2"
    local api_url="https://api.github.com/repos/${repo}/releases"
    local releases_json

    releases_json=$(curl -fsSL --max-time 15 "$api_url" 2>/dev/null) || return 1

    if [ -n "$tag_prefix" ]; then
        printf '%s' "$releases_json" \
            | grep '"tag_name"' \
            | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//' \
            | sed 's/".*//' \
            | grep "^${tag_prefix}" \
            | head -n 1
        return
    fi

    printf '%s' "$releases_json" \
        | grep '"tag_name"' \
        | head -n 1 \
        | sed 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//' \
        | sed 's/".*//'
}

download_and_install_mosdns_binary() {
    local tmp_dir="/tmp/mosdns-bin-install"
    local assets_html
    local asset_urls
    local candidates
    local candidate
    local url
    local asset_url=""
    local asset_name=""
    local base_name
    local found_bin

    # Standard/Lite/PH versions fetch release tags dynamically when needed.
    if [ -z "$MOSDNS_RELEASE_TAG" ]; then
        white "正在获取最新 release 版本..."
        if [ "$MOSDNS_FLAVOR_NAME" = "Tom魔改版" ]; then
            MOSDNS_RELEASE_TAG=$(fetch_latest_release_tag "jasonxtt/mosdns" "v")
            [ -n "$MOSDNS_RELEASE_TAG" ] && MOSDNS_ASSET_PREFIX="mosdns-${MOSDNS_RELEASE_TAG#v}-"
        elif [ "$MOSDNS_FLAVOR_NAME" = "Tom魔改lite版" ]; then
            MOSDNS_RELEASE_TAG=$(fetch_latest_release_tag "jasonxtt/mosdns" "lite-v")
            [ -n "$MOSDNS_RELEASE_TAG" ] && MOSDNS_ASSET_PREFIX="mosdns-lite-${MOSDNS_RELEASE_TAG#lite-v}-"
        else
            MOSDNS_RELEASE_TAG=$(fetch_latest_release_tag "yyysuo/mosdns")
        fi
        [ -n "$MOSDNS_RELEASE_TAG" ] || {
            red "获取最新 release 版本失败"
            exit 1
        }
        white "最新版本：${yellow}${MOSDNS_RELEASE_TAG}${reset}"
    fi

    [ -n "$MOSDNS_ASSET_PREFIX" ] || {
        red "未设置 mosdns 资产前缀"
        exit 1
    }

    white "正在识别系统架构并匹配 ${MOSDNS_FLAVOR_NAME} 二进制..."
    candidates=$(get_mosdns_asset_candidates) || {
        red "不支持的CPU架构：$(uname -m)，请手动安装 mosdns 二进制"
        exit 1
    }

    assets_html=$(curl -fsSL --max-time 20 "${MOSDNS_RELEASES_BASE_URL}/expanded_assets/${MOSDNS_RELEASE_TAG}" 2>/dev/null) || {
        red "获取 ${MOSDNS_RELEASE_TAG} 资产列表失败，请稍后重试"
        exit 1
    }

    local repo_path=$(echo "$MOSDNS_RELEASES_BASE_URL" | sed 's#https://github.com/##' | sed 's#/releases##')

    asset_urls=$(printf '%s' "$assets_html" \
        | grep -oE "/${repo_path}/releases/download/${MOSDNS_RELEASE_TAG}/[^\"<> ]+" \
        | sed 's#^#https://github.com#' \
        | sort -u)

    for candidate in $candidates; do
        for url in $asset_urls; do
            base_name=$(basename "$url")
            if [[ "$base_name" == "${MOSDNS_ASSET_PREFIX}${candidate}"* ]]; then
                # x86 默认跳过 v3
                if [[ "$(uname -m)" =~ ^(x86_64|amd64)$ ]] && printf '%s' "$base_name" | grep -Eiq '(^|[-_.])v3([-.]|$)'; then
                    continue
                fi
                asset_url="$url"
                asset_name="$base_name"
                break
            fi
        done
        if [ -n "$asset_url" ]; then
            break
        fi
    done

    # x86 回退：若只有 v3 资产，仍可尝试 v3，避免无可用包直接失败
    if [ -z "$asset_url" ] && [[ "$(uname -m)" =~ ^(x86_64|amd64)$ ]]; then
        for candidate in $candidates; do
            for url in $asset_urls; do
                base_name=$(basename "$url")
                if [[ "$base_name" == "${MOSDNS_ASSET_PREFIX}${candidate}"* ]] && printf '%s' "$base_name" | grep -Eiq '(^|[-_.])v3([-.]|$)'; then
                    asset_url="$url"
                    asset_name="$base_name"
                    white "仅检测到 v3 资产，尝试使用 v3 二进制。"
                    break
                fi
            done
            if [ -n "$asset_url" ]; then
                break
            fi
        done
    fi

    if [ -z "$asset_url" ]; then
        red "未在 ${MOSDNS_RELEASE_TAG} 中找到适配 $(uname -m) 的 ${MOSDNS_FLAVOR_NAME} Linux 二进制资产"
        exit 1
    fi

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    white "下载 mosdns 资产：${yellow}${asset_name}${reset}"
    wget -q --show-progress -O "$tmp_dir/$asset_name" "$asset_url" || {
        red "下载 mosdns 二进制失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    case "$asset_name" in
        *.zip)
            unzip -o "$tmp_dir/$asset_name" -d "$tmp_dir" >/dev/null || {
                red "解压 zip 失败"
                rm -rf "$tmp_dir"
                exit 1
            }
            ;;
        *.tar.gz|*.tgz)
            tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir" || {
                red "解压 tar.gz 失败"
                rm -rf "$tmp_dir"
                exit 1
            }
            ;;
        *)
            # 某些发布直接上传裸二进制
            cp "$tmp_dir/$asset_name" "$tmp_dir/mosdns" || {
                red "处理二进制文件失败"
                rm -rf "$tmp_dir"
                exit 1
            }
            ;;
    esac

    found_bin=$(find "$tmp_dir" -type f \( -name mosdns -o -name "mosdns-linux-*" \) | head -n 1)
    if [ -z "$found_bin" ]; then
        red "未在压缩包中找到 mosdns 可执行文件"
        rm -rf "$tmp_dir"
        exit 1
    fi

    install -m 0755 "$found_bin" /usr/local/bin/mosdns || {
        red "安装 mosdns 到 /usr/local/bin 失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    rm -rf "$tmp_dir"
    green "mosdns 二进制安装完成"
}

download_and_prepare_config() {
    local tmp_dir="/tmp/mosdns-config-install"
    local extracted_dir=""
    local config_filename

    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir"

    [ -n "$MOSDNS_CONFIG_ZIP_URL" ] || {
        red "未设置 mosdns 配置包地址"
        exit 1
    }

    config_filename=$(basename "$MOSDNS_CONFIG_ZIP_URL")
    white "下载配置包 ${config_filename} ..."
    wget -q --show-progress -O "$tmp_dir/$config_filename" "$MOSDNS_CONFIG_ZIP_URL" || {
        red "下载配置包失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    unzip -o "$tmp_dir/$config_filename" -d "$tmp_dir" >/dev/null || {
        red "解压配置包失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    if [ -d "$tmp_dir/config_all" ]; then
        extracted_dir="$tmp_dir/config_all"
    else
        extracted_dir=$(find "$tmp_dir" -type f -name "config_custom.yaml" -print | head -n 1 | xargs -I{} dirname "{}")
    fi

    if [ -z "$extracted_dir" ] || [ ! -d "$extracted_dir" ]; then
        red "未找到有效配置目录（缺少 config_custom.yaml）"
        rm -rf "$tmp_dir"
        exit 1
    fi

    mkdir -p /cus
    rm -rf /cus/mosdns
    mkdir -p /cus/mosdns
    cp -a "$extracted_dir"/. /cus/mosdns/ || {
        red "复制配置到 /cus/mosdns 失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    rm -rf "$tmp_dir"
    green "${MOSDNS_FLAVOR_NAME} 配置文件已部署到 /cus/mosdns"
}

setup_mosdns_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        white "下载并安装 mosdns systemd 服务文件..."
        curl -fsSL "$SERVICE_URL" -o "$SYSTEMD_SERVICE_FILE" || {
            red "下载 mosdns.service 失败"
            exit 1
        }
        systemctl daemon-reload || {
            red "systemd 重载失败"
            exit 1
        }
        systemctl enable mosdns.service || {
            red "设置开机启动失败"
            exit 1
        }
    else
        white "生成并安装 mosdns OpenRC 服务文件..."
        cat > "$OPENRC_SERVICE_FILE" <<'EOF'
#!/sbin/openrc-run
name="mosdns"
description="MosDNS service"
command="/usr/local/bin/mosdns"
command_args="start -d /cus/mosdns -c /cus/mosdns/config_custom.yaml"
command_background="yes"
pidfile="/run/mosdns.pid"
output_log="/var/log/mosdns.log"
error_log="/var/log/mosdns.log"
respawn_delay=120

start_pre() {
    checkpath --file --mode 0644 "$output_log"
}

depend() {
    need net
}
EOF
        chmod 0755 "$OPENRC_SERVICE_FILE"
        rc-update add mosdns default
    fi
}

release_port_53() {
    white "解除系统 53 端口占用..."
    if [ "$INIT_SYSTEM" = "systemd" ] && [ -f /etc/systemd/resolved.conf ]; then
        sed -i.bak -E 's/^\s*#?\s*DNSStubListener\s*=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
        systemctl reload-or-restart systemd-resolved || true
    fi
}

start_mosdns_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart mosdns.service
        systemctl is-active --quiet mosdns.service
    else
        rc-service mosdns restart
        rc-service mosdns status >/dev/null 2>&1
    fi
}

show_mosdns_status() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl status mosdns --no-pager || true
    else
        rc-service mosdns status || true
        [ -f /var/log/mosdns.log ] && tail -n 30 /var/log/mosdns.log || true
    fi
}

apply_custom_overrides() {
    local socks5_input="$1"
    local fakeip_upstream_input="$2"
    local ecs_ipv4="$3"
    local dns_routing_mode="${4:-A}"
    local config_overrides="/cus/mosdns/config_overrides.json"
    local upstream_overrides="/cus/mosdns/upstream_overrides.json"
    local switch17_file="/cus/mosdns/rule/switch17.txt"
    local socks_escaped
    local ecs_escaped
    local upstream_addr

    [ -f "$config_overrides" ] || config_overrides="/cus/mosdns/webinfo/config_overrides.json"
    [ -f "$config_overrides" ] || {
        red "未找到 config_overrides.json"
        exit 1
    }

    [ -f "$upstream_overrides" ] || upstream_overrides="/cus/mosdns/webinfo/upstream_overrides.json"
    [ -f "$upstream_overrides" ] || {
        red "未找到 upstream_overrides.json"
        exit 1
    }

    socks_escaped=$(escape_sed_replacement "$socks5_input")
    sed -i -E "s#(\"socks5\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\\1${socks_escaped}\\2#" "$config_overrides"

    if [ -n "$ecs_ipv4" ]; then
        ecs_escaped=$(escape_sed_replacement "$ecs_ipv4")
        sed -i -E "s#(\"ecs\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")#\\1${ecs_escaped}\\2#" "$config_overrides"
    fi

    mkdir -p "$(dirname "$switch17_file")"
    printf '%s\n' "$dns_routing_mode" > "$switch17_file"

    if [ "$dns_routing_mode" = "A" ] && [ -n "$fakeip_upstream_input" ]; then
        upstream_addr=$(escape_sed_replacement "$fakeip_upstream_input")
        UPSTREAM_ADDR="$upstream_addr" perl -0pi -e 's#("nocnfake"\s*:\s*\[\s*\{.*?"addr"\s*:\s*")udp://[^"]*(")#${1}udp://$ENV{UPSTREAM_ADDR}${2}#s' "$upstream_overrides"
    fi
}

install_mosdns() {
    local flavor="$1"
    local socks5_input
    local fakeip_upstream_input=""
    local ecs_ipv4
    local dns_routing_mode="A"
    local dns_routing_mode_label="FakeIP 分流"
    local dns_mode_choice

    set_mosdns_flavor "$flavor"
    white "当前安装版本：${yellow}${MOSDNS_FLAVOR_NAME}${reset}"

    while true; do
        read -p "请输入 socks5 代理（默认 10.0.0.2:7890）：" socks5_input
        socks5_input="${socks5_input:-10.0.0.2:7890}"
        if is_valid_host_port "$socks5_input"; then
            break
        else
            red "输入格式无效，请输入 host:port，例如 10.0.0.2:7890"
        fi
    done

    while true; do
        echo
        white "请选择 DNS 分流模式："
        echo "1. FakeIP 分流（默认，需要 sing-box/mihomo FakeIP DNS 上游）"
        echo "2. RealIP 分流（redir-host/realip，不需要 FakeIP 上游，国外域名使用“国外代理上游”）"
        read -p "请输入选项 [1-2，默认 1]：" dns_mode_choice
        dns_mode_choice="${dns_mode_choice:-1}"
        case "$dns_mode_choice" in
            1)
                dns_routing_mode="A"
                dns_routing_mode_label="FakeIP 分流"
                break
                ;;
            2)
                dns_routing_mode="B"
                dns_routing_mode_label="RealIP 分流"
                break
                ;;
            *)
                red "请输入 1 或 2"
                ;;
        esac
    done

    if [ "$dns_routing_mode" = "A" ]; then
        while true; do
            read -p "请输入 fakeip DNS 上游地址（默认 10.0.0.2:6666）：" fakeip_upstream_input
            fakeip_upstream_input="${fakeip_upstream_input:-10.0.0.2:6666}"
            if is_valid_host_port "$fakeip_upstream_input"; then
                break
            else
                red "输入格式无效，请输入 host:port，例如 10.0.0.2:6666"
            fi
        done
    fi

    install_dependencies

    white "正在获取公网 IPv4（依次尝试 3 个源）..."
    ecs_ipv4=$(get_public_ipv4) || ecs_ipv4=""
    if [ -n "$ecs_ipv4" ]; then
        white "公网 IPv4 检测结果：${yellow}${ecs_ipv4}${reset}"
    else
        red "公网 IPv4 获取失败，稍后你仍可在 WebUI 中手动填写 ECS"
    fi

    setup_mosdns_service
    download_and_install_mosdns_binary
    download_and_prepare_config
    apply_custom_overrides "$socks5_input" "$fakeip_upstream_input" "$ecs_ipv4" "$dns_routing_mode"
    release_port_53

    white "启动 mosdns 服务..."
    if ! start_mosdns_service; then
        red "mosdns 服务启动失败，请检查服务状态和日志"
        show_mosdns_status
        exit 1
    fi

    rm -rf /mnt/mosdns.sh
    green "Mosdns（${MOSDNS_FLAVOR_NAME}）安装完成"
    echo
    echo -e "运行目录：${yellow}/cus/mosdns${reset}"
    echo -e "socks5: ${yellow}${socks5_input}${reset}"
    echo -e "DNS 分流模式: ${yellow}${dns_routing_mode_label}${reset}"
    if [ "$dns_routing_mode" = "A" ]; then
        echo -e "fakeip 上游: ${yellow}udp://${fakeip_upstream_input}${reset}"
    else
        echo -e "fakeip 上游: ${yellow}已跳过（RealIP 模式）${reset}"
    fi
    if [ -n "$ecs_ipv4" ]; then
        echo -e "ecs: ${yellow}${ecs_ipv4}${reset}"
    else
        echo -e "\e[1m\e[31mECS 设置失败，请前往 UI 手动设置 ECS IP\e[0m"
    fi
    echo
    show_mosdns_status
}

uninstall_mosdns() {
    white "停止并卸载 Mosdns..."

    detect_init_system
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop mosdns.service 2>/dev/null || true
        systemctl disable mosdns.service 2>/dev/null || true
    else
        rc-service mosdns stop 2>/dev/null || true
        rc-update del mosdns default 2>/dev/null || true
    fi

    rm -f "$SYSTEMD_SERVICE_FILE"
    rm -f "$OPENRC_SERVICE_FILE"
    rm -f /usr/local/bin/mosdns
    rm -rf /cus/mosdns

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl daemon-reload || true
        systemctl reset-failed || true
    fi

    rm -rf /mnt/mosdns.sh
    green "Mosdns 已卸载（service、二进制、配置目录均已删除）"
}

atomdns_needs_musl() {
    local ldd_out glibc_ver

    ldd_out=$(ldd --version 2>&1 | head -n 1)
    # musl 系统（Alpine 等）没有 glibc
    if [ -f /etc/alpine-release ] || printf '%s' "$ldd_out" | grep -qi musl; then
        return 0
    fi
    # glibc amd64 包要求 glibc >= 2.39，更低的系统用静态 musl 包
    glibc_ver=$(printf '%s' "$ldd_out" | grep -oE '[0-9]+\.[0-9]+$')
    [ -n "$glibc_ver" ] && [ "$(printf '%s\n' 2.39 "$glibc_ver" | sort -V | head -n 1)" != "2.39" ]
}

get_atomdns_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64)
            if atomdns_needs_musl; then
                echo "atomdns-linux-amd64-musl.tar.gz"
            else
                # 默认非 v3，避免老CPU或虚拟机指令集不完整导致不可运行
                echo "atomdns-linux-amd64.tar.gz"
            fi
            ;;
        aarch64|arm64)
            echo "atomdns-linux-arm64.tar.gz"
            ;;
        armv7l|armv7|armhf)
            echo "atomdns-linux-armv7.tar.gz"
            ;;
        *)
            return 1
            ;;
    esac
}

download_and_install_atomdns_binary() {
    local tmp_dir
    local asset_name
    local expected_sha
    local actual_sha
    local found_bin

    asset_name=$(get_atomdns_asset_name) || {
        red "不支持的CPU架构：$(uname -m)，请手动安装 atomdns 二进制"
        exit 1
    }

    tmp_dir=$(mktemp -d /tmp/atomdns-install.XXXXXX)

    white "下载 atomdns 更新清单..."
    wget -q -O "$tmp_dir/manifest.json" "${ATOMDNS_RELEASE_URL}/atomdns-update-manifest.json" || {
        red "下载更新清单失败"
        rm -rf "$tmp_dir"
        exit 1
    }
    expected_sha=$(awk -v n="\"$asset_name\"" 'index($0, n) {f=1} f && /"sha256"/ {gsub(/.*"sha256"[ ]*:[ ]*"|".*/, ""); print; exit}' "$tmp_dir/manifest.json")
    [ -n "$expected_sha" ] || {
        red "更新清单中未找到 ${asset_name} 的 sha256"
        rm -rf "$tmp_dir"
        exit 1
    }

    white "下载 atomdns 资产：${yellow}${asset_name}${reset}"
    wget -q --show-progress -O "$tmp_dir/$asset_name" "${ATOMDNS_RELEASE_URL}/${asset_name}" || {
        red "下载 atomdns 二进制失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    actual_sha=$(sha256sum "$tmp_dir/$asset_name" | awk '{print $1}')
    if [ "$actual_sha" != "$expected_sha" ]; then
        red "sha256 校验失败（期望 ${expected_sha}，实际 ${actual_sha}）"
        rm -rf "$tmp_dir"
        exit 1
    fi

    tar -xzf "$tmp_dir/$asset_name" -C "$tmp_dir" || {
        red "解压 tar.gz 失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    found_bin=$(find "$tmp_dir" -type f -name atomdns | head -n 1)
    if [ -z "$found_bin" ]; then
        red "未在压缩包中找到 atomdns 可执行文件"
        rm -rf "$tmp_dir"
        exit 1
    fi

    install -m 0755 "$found_bin" "$ATOMDNS_BIN" || {
        red "安装 atomdns 到 /usr/local/bin 失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    rm -rf "$tmp_dir"
    green "atomdns 二进制安装完成：$("$ATOMDNS_BIN" version 2>/dev/null | head -n 1)"
}

download_and_prepare_atomdns_config() {
    local tmp_dir

    tmp_dir=$(mktemp -d /tmp/atomdns-config.XXXXXX)

    white "下载配置包 config_rust.zip ..."
    wget -q --show-progress -O "$tmp_dir/config_rust.zip" "${ATOMDNS_RELEASE_URL}/config_rust.zip" || {
        red "下载配置包失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    mkdir -p "$ATOMDNS_DIR"
    unzip -q -o "$tmp_dir/config_rust.zip" -d "$ATOMDNS_DIR" || {
        red "解压配置包失败"
        rm -rf "$tmp_dir"
        exit 1
    }

    rm -rf "$tmp_dir"
    [ -f "$ATOMDNS_DIR/config_custom.yaml" ] || {
        red "配置包无效（缺少 config_custom.yaml）"
        exit 1
    }
    green "配置文件已部署到 ${ATOMDNS_DIR}"
}

setup_atomdns_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        white "安装 atomdns systemd 服务文件..."
        cat > "$ATOMDNS_SYSTEMD_SERVICE_FILE" <<EOF
[Unit]
Description=AtomDNS
After=network.target

[Service]
Type=simple
ExecStart=${ATOMDNS_BIN} start -d ${ATOMDNS_DIR} -c config_custom.yaml
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload || {
            red "systemd 重载失败"
            exit 1
        }
        systemctl enable atomdns.service || {
            red "设置开机启动失败"
            exit 1
        }
    else
        white "安装 atomdns OpenRC 服务文件..."
        cat > "$ATOMDNS_OPENRC_SERVICE_FILE" <<EOF
#!/sbin/openrc-run
name="atomdns"
description="AtomDNS service"
command="${ATOMDNS_BIN}"
command_args="start -d ${ATOMDNS_DIR} -c config_custom.yaml"
command_background="yes"
pidfile="/run/atomdns.pid"
output_log="/var/log/atomdns.log"
error_log="/var/log/atomdns.log"

start_pre() {
    checkpath --file --mode 0644 "\$output_log"
}

depend() {
    need net
}
EOF
        chmod 0755 "$ATOMDNS_OPENRC_SERVICE_FILE"
        rc-update add atomdns default
    fi
}

stop_atomdns_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop atomdns.service 2>/dev/null || true
    else
        rc-service atomdns stop 2>/dev/null || true
    fi
}

start_atomdns_service() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl restart atomdns.service
        sleep 2
        systemctl is-active --quiet atomdns.service
    else
        rc-service atomdns restart
        sleep 2
        rc-service atomdns status >/dev/null 2>&1
    fi
}

show_atomdns_status() {
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl status atomdns --no-pager || true
    else
        rc-service atomdns status || true
        [ -f /var/log/atomdns.log ] && tail -n 30 /var/log/atomdns.log || true
    fi
}

get_local_ipv4() {
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

install_atomdns() {
    local upgrade_only="no"
    local local_ip

    if pgrep -x mosdns >/dev/null 2>&1; then
        red "检测到 mosdns 正在运行，会与 atomdns 争用 53 端口。请先在本菜单卸载 Mosdns（或手动停止）后再安装 AtomDNS"
        exit 1
    fi

    install_dependencies

    if [ -f "$ATOMDNS_DIR/config_custom.yaml" ]; then
        upgrade_only="yes"
        white "检测到已有配置 ${yellow}${ATOMDNS_DIR}${reset}，仅升级程序，配置保持不变"
        stop_atomdns_service
    fi

    download_and_install_atomdns_binary
    [ "$upgrade_only" = "yes" ] || download_and_prepare_atomdns_config
    setup_atomdns_service

    white "检查配置..."
    "$ATOMDNS_BIN" check -d "$ATOMDNS_DIR" -c config_custom.yaml || {
        red "atomdns 配置检查未通过"
        exit 1
    }

    release_port_53

    white "启动 atomdns 服务..."
    if ! start_atomdns_service; then
        red "atomdns 服务启动失败，请检查服务状态和日志"
        show_atomdns_status
        exit 1
    fi

    rm -rf /mnt/mosdns.sh
    local_ip=$(get_local_ipv4)
    green "AtomDNS 安装完成"
    echo "=================================================================="
    echo -e "程序：${yellow}${ATOMDNS_BIN}${reset}"
    echo -e "配置目录：${yellow}${ATOMDNS_DIR}${reset}"
    echo -e "请在浏览器打开：${yellow}http://${local_ip:-服务器IP}:9099${reset}"
    echo "然后在 UI 中完成设置："
    echo "  1. 上游设置：按需设置各分组的上游（FakeIP 上游默认 127.0.0.1:6666，需改成 sing-box/mihomo 的 DNS 监听地址）"
    echo "  2. 系统设置：设置 SOCKS5 代理（默认留空即直连）"
    echo "  3. 系统设置：设置 ECS 地址（默认 2408:8888::8）"
    echo "=================================================================="
    show_atomdns_status
}

uninstall_atomdns() {
    local remove_config

    white "停止并卸载 AtomDNS..."

    detect_init_system
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl stop atomdns.service 2>/dev/null || true
        systemctl disable atomdns.service 2>/dev/null || true
    else
        rc-service atomdns stop 2>/dev/null || true
        rc-update del atomdns default 2>/dev/null || true
    fi

    rm -f "$ATOMDNS_SYSTEMD_SERVICE_FILE"
    rm -f "$ATOMDNS_OPENRC_SERVICE_FILE"
    rm -f "$ATOMDNS_BIN"

    if [ "$INIT_SYSTEM" = "systemd" ]; then
        systemctl daemon-reload || true
        systemctl reset-failed || true
    fi

    read -p "是否同时删除配置目录 ${ATOMDNS_DIR}（设置和学习数据都会丢失）？[y/N]：" remove_config
    if [[ "$remove_config" =~ ^[Yy]$ ]]; then
        rm -rf "$ATOMDNS_DIR"
        green "AtomDNS 已卸载（service、二进制、配置目录均已删除）"
    else
        green "AtomDNS 已卸载（配置目录 ${ATOMDNS_DIR} 已保留）"
    fi

    rm -rf /mnt/mosdns.sh
}

mosdns_choose() {
    clear
    echo "=================================================================="
    echo -e "\t\tAtomDNS / MosDNS 脚本 by Tom&忧郁滴飞叶"
    echo -e "\t\n"
    echo "请选择要执行的服务："
    echo "=================================================================="
    echo "1. 安装AtomDNS"
    echo "2. 安装Mosdns（Tom魔改版）"
    echo "3. 安装Mosdns（Tom魔改lite版）"
    echo "4. 安装Mosdns（PH版）"
    echo "5. 卸载Mosdns"
    echo "6. 卸载AtomDNS"
    echo -e "\t"
    echo "-. 返回上级菜单"
    echo "0. 退出脚本"
    read -p "请选择服务: " choice

    case "$choice" in
        1)
            install_atomdns
            ;;
        2)
            install_mosdns standard
            ;;
        3)
            install_mosdns lite
            ;;
        4)
            install_mosdns ph
            ;;
        5)
            uninstall_mosdns
            ;;
        6)
            uninstall_atomdns
            ;;
        -)
            white "脚本切换中，请等待..."
            rm -rf /mnt/mosdns.sh
            wget -q -O /mnt/main_install.sh "${SCRIPT_REPO_BASE}/AIO/Scripts/main_install.sh" && chmod +x /mnt/main_install.sh && /mnt/main_install.sh
            ;;
        0)
            red "退出脚本，感谢使用."
            rm -rf /mnt/mosdns.sh
            ;;
        *)
            white "无效的选项，1秒后返回当前菜单，请重新选择有效的选项."
            sleep 1
            mosdns_choose
            ;;
    esac
}

mosdns_choose
