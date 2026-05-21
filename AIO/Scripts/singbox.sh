#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
export APT_LISTCHANGES_FRONTEND=none

clear
rm -rf /mnt/main_install.sh

[[ $EUID -ne 0 ]] && echo -e "错误：必须使用root用户运行此脚本！\n" && exit 1

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

cleanup_and_exit() {
    [ -f /mnt/singbox.sh ] && rm -rf /mnt/singbox.sh
    exit "${1:-0}"
}

back_to_main_menu() {
    white "脚本切换中，请等待..."
    [ -f /mnt/singbox.sh ] && rm -rf /mnt/singbox.sh
    wget -q -O /mnt/main_install.sh https://raw.githubusercontent.com/jasonxtt/LinuxScripts/main/AIO/Scripts/main_install.sh && chmod +x /mnt/main_install.sh && /mnt/main_install.sh
}

prepare_storehouse_tools() {
    local storehouse_installer="/mnt/storehouse-install.sh"
    local storehouse_url="https://raw.githubusercontent.com/herozmy/StoreHouse/refs/heads/latest/install.sh"

    if [ -f /usr/local/bin/tools/sing-box.sh ] && [ -f /usr/local/bin/tools/common.sh ]; then
        return 0
    fi

    white "开始准备 StoreHouse 安装环境..."
    wget -q -O "$storehouse_installer" "$storehouse_url"
    if [ ! -f "$storehouse_installer" ]; then
        red "StoreHouse 安装脚本下载失败，请检查网络后重试"
        cleanup_and_exit 1
    fi
    chmod +x "$storehouse_installer"

    if [ -d /usr/local/bin/tools ]; then
        white "检测到已有 StoreHouse 目录，开始重新安装工具文件..."
        printf 'y\nn\n' | bash "$storehouse_installer"
    else
        white "开始安装 StoreHouse 基础工具..."
        printf 'n\n' | bash "$storehouse_installer"
    fi

    chmod +x /usr/local/bin/tools/*.sh /usr/local/bin/tools/menu.sh /usr/local/bin/tools/proxytool >/dev/null 2>&1 || true

    if [ ! -f /usr/local/bin/tools/sing-box.sh ] || [ ! -f /usr/local/bin/tools/common.sh ]; then
        red "StoreHouse 工具安装不完整，未检测到 sing-box.sh 或 common.sh"
        cleanup_and_exit 1
    fi
}

launch_storehouse_proxy() {
    prepare_storehouse_tools
    white "开始进入 StoreHouse sing-box 透明代理脚本..."
    bash /usr/local/bin/tools/sing-box.sh
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

show_menu() {
    clear
    echo "=================================================================="
    echo -e "\t\tSing-Box相关脚本 by Tom&忧郁滴飞叶"
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
        read -p "请选择服务: " choice
        case "$choice" in
            1)
                launch_storehouse_proxy
                return
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
