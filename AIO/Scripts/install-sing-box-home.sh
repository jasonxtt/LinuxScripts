#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Install and deploy a sing-box home-access server bundle.

Interactive-first usage:
  sudo ./install-sing-box-home.sh

Command-line usage:
  sudo ./install-sing-box-home.sh --host <domain-or-ip> [options]

Interactive prompts:
  - DDNS domain / public IP: required if --host not provided
  - Protocol selection: prompt shown if protocol enable/disable flags are not provided; Enter defaults to 1,2
  - Optional custom ports: prompt order follows Hy2 / SS / VLESS gRPC Reality / Trojan / AnyTLS / VLESS Brutal Reality
  - If Trojan / AnyTLS is enabled, ACME + Cloudflare inputs are prompted after DDNS/port collection
  - Install finished: print client snippets and export to /root by default

Core options:
  --host <host>                               Public host / DDNS / IP used by clients
  --enable-shadowsocks | --disable-shadowsocks
                                              Enable Shadowsocks inbound (default: enabled)
  --port <port>                               Shadowsocks service port (default: 55502)
  --name <name>                               Profile name (default: home)
  --method <method>                           SS method (default: 2022-blake3-aes-128-gcm)
  --password <password>                       Explicit SS password
  --version <version>                         sing-box version without leading v (default: latest stable)
  --listen <addr>                             Server listen address (default: ::)
  --home-cidrs <csv>                          Metadata passed through to generate-sing-box-config.sh
  --tg-rule-set <name>                        Metadata passed through to generate-sing-box-config.sh (default: geoip-tg)
  --enable-fakeip | --disable-fakeip          Manifest metadata flag (default: disabled)
  --enable-tgip   | --disable-tgip            Manifest metadata flag (default: disabled)

Additional protocols (server-side):
  --enable-hy2 | --disable-hy2                Enable hysteria2 inbound (default: enabled)
  --hy2-port <port>                           Hysteria2 port (default: 55501)
  --hy2-password <password>                   Explicit hy2 password
  --hy2-sni <domain>                          Self-signed cert CN / hy2 SNI (default: bing.com)

  --enable-trojan | --disable-trojan          Enable Trojan inbound (default: disabled)
  --trojan-port <port>                        Trojan port (default: 55503)
  --trojan-password <password>                Explicit Trojan password

  --enable-anytls | --disable-anytls          Enable AnyTLS inbound (default: disabled)
  --anytls-port <port>                        AnyTLS port (default: 55504)
  --anytls-password <password>                Explicit AnyTLS password

  --enable-vless-grpc-reality | --disable-vless-grpc-reality
                                              Enable VLESS gRPC Reality inbound (default: enabled)
  --vless-grpc-reality-port <port>            VLESS gRPC Reality port (default: 55505)
  --vless-grpc-reality-uuid <uuid>            Explicit VLESS UUID
  --vless-grpc-reality-server-name <domain>   Reality server_name / handshake host (default: www.huawei.com)
  --vless-grpc-reality-service-name <name>    gRPC service name (default: Huawei.SmartHome.Connect)
  --vless-grpc-reality-short-id <hex>         Explicit short-id

  --enable-vless-brutal-reality | --disable-vless-brutal-reality
                                              Enable VLESS Brutal Reality inbound (default: disabled)
  --vless-brutal-reality-port <port>          VLESS Brutal Reality port (default: 55506)
  --vless-brutal-reality-uuid <uuid>          Explicit UUID (default: reuse VLESS gRPC Reality UUID)
  --vless-brutal-reality-server-name <domain> Reality server_name / handshake host (default: www.huawei.com)
  --vless-brutal-reality-short-id <hex>       Explicit short-id (default: reuse VLESS gRPC Reality short-id)
  --vless-brutal-reality-up-mbps <num>        TCP Brutal upload Mbps (default: 1000)
  --vless-brutal-reality-down-mbps <num>      TCP Brutal download Mbps (default: 1000)

ACME / Cloudflare (used when Trojan or AnyTLS is enabled):
  --acme-domain <domain>                      Certificate domain (default: reuse --host / DDNS)
  --cf-key <token>                            Cloudflare Global API Key used by acme.sh dns_cf
  --cf-email <email>                          Cloudflare account email used by acme.sh dns_cf
  --acme-email <email>                        acme.sh registration email (default: reuse --cf-email)
  --acme-home <dir>                           acme.sh home (default: /root/.acme.sh)
  --cert-base-dir <dir>                       Managed cert root (default: <config-dir>/certs)

Paths / install:
  --bin-dir <dir>                             Install binary directory (default: /usr/local/bin)
  --config-dir <dir>                          Install config directory (default: /usr/local/etc/sing-box)
  --service-name <name>                       systemd unit name without suffix (default: sing-box)
  --merge-into-existing                       Merge generated server inbounds into an existing sing-box config
  --standalone                                Force standalone deployment mode (default behavior)
  --merge-config-dir <path>                   Manually specify existing sing-box config path for merge mode
  --merge-service-name <name>                 Manually specify existing sing-box service name for merge mode
  --artifact-dir <dir>                        Keep generated artifacts in this directory
  --backup-dir <dir>                          Keep backups/rollback files in this directory
  --work-dir <dir>                            Temp work directory base (default: /tmp)
  --download-url <url>                        Override release tarball URL
  --force-download                            Re-download tarball even if already cached in work dir
  --force-binary-update                       Update sing-box binary even when existing service is detected
  --uninstall                                 Uninstall sing-box + managed configs/certs and exit
  --verbose-output                            Print extended [OUT] details at the end
  -h, --help                                  Show this help
EOF
}

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
die() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

WORK_ROOT=""
ROLLBACK_ACTIVE="false"
BACKUP_DIR=""
ARTIFACT_DIR=""
ACME_ENV_TEMP=""
VBR_SKIPPED_REASON=""
VBR_EFFECTIVE_STATUS="disabled"
ACME_SKIPPED_PROTOCOLS=()
ACME_SKIP_REASON=""
INSTALLER_STATE_VERSION="2026-03-20"
DEPLOY_MODE="standalone"
DEPLOY_MODE_SOURCE="default"
MERGE_CONFIG_DIR_HINT=""
MERGE_SERVICE_NAME=""
MERGE_SERVICE_UNIT=""
MERGE_SINGBOX_BIN=""
MERGE_CONFIG_MODE=""
MERGE_CONFIG_VALUE=""
MERGE_TARGET_CONFIG=""
MERGE_TARGET_DIR=""
MERGE_TARGET_BACKUP=""
MERGE_SERVICE_NAME_HINT=""
MERGE_DETECTED_PROTOCOLS=()
MERGE_MATCHED_SERVICES=()
MERGE_CANDIDATES=()

cleanup() {
  if [[ -n "${ACME_ENV_TEMP:-}" && -f "${ACME_ENV_TEMP:-}" ]]; then
    rm -f "$ACME_ENV_TEMP"
  fi
  if [[ -n "${WORK_ROOT:-}" && -d "${WORK_ROOT:-}" ]]; then
    rm -rf "$WORK_ROOT"
  fi
}

restore_target() {
  local target="$1"
  local key="$2"
  local backup_file="$BACKUP_DIR/${key}.bak"
  local absent_marker="$BACKUP_DIR/${key}.absent"
  if [[ -f "$absent_marker" ]]; then
    rm -rf "$target"
    return
  fi
  if [[ -e "$backup_file" ]]; then
    rm -rf "$target"
    mkdir -p "$(dirname "$target")"
    cp -a "$backup_file" "$target"
  fi
}

rollback() {
  [[ "$ROLLBACK_ACTIVE" == "true" ]] || return 0
  [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]] || return 0
  warn "Deployment failed; attempting rollback from $BACKUP_DIR"
  set +e
  restore_target "$TARGET_BIN" "binary"
  restore_target "$TARGET_CONFIG" "config"
  restore_target "$SERVICE_FILE" "service"
  restore_target "$INSTALLER_STATE_FILE" "installer-state"
  restore_target "$HY2_KEY_FILE" "hy2-key"
  restore_target "$HY2_CERT_PEM" "hy2-cert-pem"
  restore_target "$HY2_CERT_CRT" "hy2-cert-crt"
  restore_target "$VGR_ENV_FILE" "vgr-env"
  restore_target "$SHARED_SECRET_ENV_FILE" "shared-secret-env"
  restore_target "$ACME_META_FILE" "acme-meta"
  restore_target "$DEFAULT_TLS_CERT_DIR" "default-cert-dir"
  restore_target "$HY2_CERT_DIR" "hysteria-cert-dir"
  restore_target "$ACME_HOME" "acme-home"
  systemctl daemon-reload >/dev/null 2>&1 || true
  if [[ -f "$SERVICE_FILE" ]]; then
    systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$SERVICE_NAME" >/dev/null 2>&1 || true
  else
    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  fi
  warn 'Rollback attempt finished'
}

on_error() {
  local line="$1"
  local exit_code="$2"
  warn "Installer failed near line $line (exit=$exit_code)"
  rollback
  exit "$exit_code"
}
trap 'on_error ${LINENO} $?' ERR
trap cleanup EXIT

require_value() { [[ -n "${2-}" ]] || die "Missing value for $1"; }
require_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }
validate_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 )) || die "Invalid port: $1"; }
validate_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" > 0 )) || die "Invalid positive integer: $1"; }
interactive_mode() { [[ -t 0 ]]; }

arch_to_singbox() {
  case "$1" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "Unsupported architecture: $1" ;;
  esac
}

pick_downloader() {
  if command -v curl >/dev/null 2>&1; then echo curl
  elif command -v wget >/dev/null 2>&1; then echo wget
  else die 'Neither curl nor wget is installed'
  fi
}

download_file() {
  case "$DOWNLOADER" in
    curl) curl -fL --retry 3 --connect-timeout 15 -o "$2" "$1" ;;
    wget) wget -O "$2" "$1" ;;
    *) die "Unsupported downloader: $DOWNLOADER" ;;
  esac
}

resolve_latest_version() {
  local url tag
  case "$DOWNLOADER" in
    curl) url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/SagerNet/sing-box/releases/latest)" ;;
    wget) url="$(wget -S --max-redirect=10 --server-response --spider https://github.com/SagerNet/sing-box/releases/latest 2>&1 | awk '/^  Location: / {print $2}' | tr -d '\r' | tail -n 1)" ;;
  esac
  [[ -n "$url" ]] || die 'Failed to resolve latest sing-box version'
  tag="${url##*/}"
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unexpected release tag: $tag"
  echo "${tag#v}"
}

prompt_if_empty() {
  local var_name="$1" prompt_text="$2" default_value="${3-}" secret_mode="${4-}"
  local current_value="${!var_name}"
  [[ -z "$current_value" ]] || return 0
  if [[ ! -t 0 ]]; then
    [[ -n "$default_value" ]] || die "$prompt_text is required in non-interactive mode"
    printf -v "$var_name" '%s' "$default_value"
    return
  fi
  local reply
  if [[ -n "$default_value" ]]; then
    if [[ "$secret_mode" == secret ]]; then read -r -s -p "$prompt_text [$default_value]: " reply; echo; else read -r -p "$prompt_text [$default_value]: " reply; fi
    reply="${reply:-$default_value}"
  else
    while true; do
      if [[ "$secret_mode" == secret ]]; then read -r -s -p "$prompt_text: " reply; echo; else read -r -p "$prompt_text: " reply; fi
      [[ -n "$reply" ]] && break
      echo '[ERR] This field is required.' >&2
    done
  fi
  printf -v "$var_name" '%s' "$reply"
}

prompt_with_default_allow_empty() {
  local var_name="$1" prompt_text="$2" default_value="${3-}"
  local current_value="${!var_name}"
  [[ -z "$current_value" ]] || return 0
  if [[ ! -t 0 ]]; then
    printf -v "$var_name" '%s' "$default_value"
    return
  fi
  local reply
  read -r -p "$prompt_text [$default_value]: " reply
  printf -v "$var_name" '%s' "${reply:-$default_value}"
}

protocol_flags_provided() {
  [[ "$ENABLE_SS_SOURCE" == flag || "$ENABLE_HY2_SOURCE" == flag || "$ENABLE_TROJAN_SOURCE" == flag || "$ENABLE_ANYTLS_SOURCE" == flag || "$ENABLE_VGR_SOURCE" == flag || "$ENABLE_VBR_SOURCE" == flag ]]
}

prompt_enabled_port() {
  local var_name="$1" label="$2" default_port="$3" port
  while true; do
    read -r -p "$label 端口 [$default_port]: " port
    port="${port:-$default_port}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
      echo '[ERR] 端口必须是 1-65535。' >&2
      continue
    fi
    printf -v "$var_name" '%s' "$port"
    return
  done
}

collect_interactive_protocol_selection() {
  local choice item valid
  while true; do
    cat <<'EOF'
请选择要安装的协议（回车默认 1,2）：
  1) Hysteria2
  2) Shadowsocks
  3) VLESS gRPC Reality
  4) Trojan（需申请证书，仅支持域名挂靠 Cloudflare）
  5) AnyTLS（需申请证书，仅支持域名挂靠 Cloudflare）
  6) VLESS Brutal Reality（需安装 brutal，若安装失败该协议不可用）
  7) 安装所有
EOF
    read -r -p '输入编号（示例：1 / 1,2 / 1,2,3 / 7）: ' choice
    choice="${choice// /}"
    choice="${choice:-1,2}"
    ENABLE_HY2=false ENABLE_SS=false ENABLE_TROJAN=false ENABLE_ANYTLS=false ENABLE_VGR=false ENABLE_VBR=false
    valid=true
    IFS=',' read -r -a items <<< "$choice"
    for item in "${items[@]}"; do
      case "$item" in
        1) ENABLE_HY2=true ;;
        2) ENABLE_SS=true ;;
        3) ENABLE_VGR=true ;;
        4) ENABLE_TROJAN=true ;;
        5) ENABLE_ANYTLS=true ;;
        6) ENABLE_VBR=true ;;
        7)
          ENABLE_HY2=true
          ENABLE_SS=true
          ENABLE_TROJAN=true
          ENABLE_ANYTLS=true
          ENABLE_VGR=true
          ENABLE_VBR=true
          ;;
        *) valid=false; break ;;
      esac
    done
    if [[ "$valid" != true || ( "$ENABLE_HY2" != true && "$ENABLE_SS" != true && "$ENABLE_TROJAN" != true && "$ENABLE_ANYTLS" != true && "$ENABLE_VGR" != true && "$ENABLE_VBR" != true ) ]]; then
      echo '[ERR] 请输入 1-7 的组合。' >&2
      continue
    fi
    ENABLE_HY2_SOURCE=interactive ENABLE_SS_SOURCE=interactive ENABLE_TROJAN_SOURCE=interactive ENABLE_ANYTLS_SOURCE=interactive ENABLE_VGR_SOURCE=interactive ENABLE_VBR_SOURCE=interactive
    return
  done
}

protocol_number() {
  case "$1" in
    hy2) echo 1 ;;
    ss) echo 2 ;;
    vgr) echo 3 ;;
    trojan) echo 4 ;;
    anytls) echo 5 ;;
    vbr) echo 6 ;;
    *) return 1 ;;
  esac
}

print_protocols_numbered() {
  local include_port="$1"
  shift || true
  local proto port
  for proto in "$@"; do
    printf '  %s) %s' "$(protocol_number "$proto")" "$(protocol_label "$proto")"
    if [[ "$include_port" == true ]]; then
      port="${CURRENT_PROTOCOL_PORTS[$proto]:-$(get_protocol_port "$proto" 2>/dev/null || true)}"
      [[ -n "$port" ]] && printf ' (%s)' "$port"
    fi
    printf '\n'
  done
}

parse_protocol_selection_list() {
  local raw="$1"
  shift || true
  local allowed=("$@") item proto
  PARSED_PROTOCOLS=()
  raw="${raw// /}"
  [[ -n "$raw" ]] || return 1
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    case "$item" in
      1) proto=hy2 ;;
      2) proto=ss ;;
      3) proto=vgr ;;
      4) proto=trojan ;;
      5) proto=anytls ;;
      6) proto=vbr ;;
      *) return 1 ;;
    esac
    array_contains "$proto" "${allowed[@]}" || return 1
    array_contains "$proto" "${PARSED_PROTOCOLS[@]}" || PARSED_PROTOCOLS+=("$proto")
  done
  (( ${#PARSED_PROTOCOLS[@]} > 0 ))
}

protocol_action_label() {
  case "$1" in
    add) echo '新增协议' ;;
    reset) echo '重置已有协议' ;;
    delete) echo '删除已有协议' ;;
    *) echo "$1" ;;
  esac
}

show_protocol_change_plan() {
  local action="$1"
  shift || true
  local proto
  printf '本次变更计划：\n'
  printf '  - 操作类型：%s\n' "$(protocol_action_label "$action")"
  printf '  - 目标协议：\n'
  for proto in "$@"; do
    printf '    %s) %s\n' "$(protocol_number "$proto")" "$(protocol_label "$proto")"
  done
  case "$action" in
    reset) printf '  - 说明：将重新生成所选协议的配置与凭据\n' ;;
    delete) printf '  - 说明：将从当前配置中移除所选协议对应的 inbound\n' ;;
  esac
}

apply_protocol_action_selection() {
  local action="$1"
  shift || true
  local selected=("$@") proto

  ADD_PROTOCOLS=()
  RESET_PROTOCOLS=()
  DELETE_PROTOCOLS=()
  TARGET_PROTOCOLS=()

  for proto in "${PROTOCOL_KEYS[@]}"; do
    if array_contains "$proto" "${CURRENT_PROTOCOLS[@]}"; then
      set_protocol_state "$proto" true
    else
      set_protocol_state "$proto" false
    fi
  done

  case "$action" in
    add)
      ADD_PROTOCOLS=("${selected[@]}")
      for proto in "${selected[@]}"; do
        set_protocol_state "$proto" true
      done
      ;;
    reset)
      RESET_PROTOCOLS=("${selected[@]}")
      ;;
    delete)
      DELETE_PROTOCOLS=("${selected[@]}")
      for proto in "${selected[@]}"; do
        set_protocol_state "$proto" false
      done
      ;;
    *)
      die "Unknown protocol action: $action"
      ;;
  esac

  for proto in "${PROTOCOL_KEYS[@]}"; do
    [[ "$(get_protocol_state "$proto")" == true ]] && TARGET_PROTOCOLS+=("$proto")
  done
  if (( ${#TARGET_PROTOCOLS[@]} == 0 )); then
    die '不能删除全部协议；如需全部移除，请使用卸载功能'
  fi
}

collect_interactive_existing_protocol_action() {
  local action choice confirm confirm_delete
  local available=()
  local selected=()

  while true; do
    printf '已检测到的协议：\n'
    print_protocols_numbered true "${CURRENT_PROTOCOLS[@]}"

    cat <<'EOF'
请选择本次操作：
  1) 新增协议
  2) 重置已有协议
  3) 删除已有协议
EOF
    read -r -p '输入编号 [1-3]: ' action
    action="${action:-1}"
    case "$action" in
      1)
        PROTOCOL_ACTION_MODE=add
        available=()
        for choice in "${PROTOCOL_KEYS[@]}"; do
          array_contains "$choice" "${CURRENT_PROTOCOLS[@]}" || available+=("$choice")
        done
        (( ${#available[@]} > 0 )) || { echo '[ERR] 当前没有可新增的协议。' >&2; continue; }
        printf '可新增协议：\n'
        print_protocols_numbered false "${available[@]}"
        read -r -p '请输入要新增的协议编号（示例：3 / 3,4）: ' choice
        parse_protocol_selection_list "$choice" "${available[@]}" || { echo '[ERR] 请输入可新增协议对应的编号组合。' >&2; continue; }
        selected=("${PARSED_PROTOCOLS[@]}")
        ;;
      2)
        PROTOCOL_ACTION_MODE=reset
        available=("${CURRENT_PROTOCOLS[@]}")
        (( ${#available[@]} > 0 )) || { echo '[ERR] 当前没有可重置的协议。' >&2; continue; }
        printf '可重置协议：\n'
        print_protocols_numbered false "${available[@]}"
        read -r -p '请输入要重置的协议编号（示例：1 / 1,3）: ' choice
        parse_protocol_selection_list "$choice" "${available[@]}" || { echo '[ERR] 请输入可重置协议对应的编号组合。' >&2; continue; }
        selected=("${PARSED_PROTOCOLS[@]}")
        ;;
      3)
        PROTOCOL_ACTION_MODE=delete
        available=("${CURRENT_PROTOCOLS[@]}")
        (( ${#available[@]} > 0 )) || { echo '[ERR] 当前没有可删除的协议。' >&2; continue; }
        printf '可删除协议：\n'
        print_protocols_numbered false "${available[@]}"
        read -r -p '请输入要删除的协议编号（示例：2 / 2,3）: ' choice
        parse_protocol_selection_list "$choice" "${available[@]}" || { echo '[ERR] 请输入可删除协议对应的编号组合。' >&2; continue; }
        selected=("${PARSED_PROTOCOLS[@]}")
        ;;
      *)
        echo '[ERR] 请输入 1-3。' >&2
        continue
        ;;
    esac

    apply_protocol_action_selection "$PROTOCOL_ACTION_MODE" "${selected[@]}"
    show_protocol_change_plan "$PROTOCOL_ACTION_MODE" "${selected[@]}"
    read -r -p '确认继续？[Y/n]: ' confirm
    confirm="${confirm:-Y}"
    case "$confirm" in
      n|N|no|NO) continue ;;
    esac
    if [[ "$PROTOCOL_ACTION_MODE" == delete ]]; then
      read -r -p '再次确认：即将删除所选协议，是否继续？[y/N]: ' confirm_delete
      case "${confirm_delete:-N}" in
        y|Y|yes|YES) ;;
        *) continue ;;
      esac
    fi
    INTERACTIVE_PROTOCOL_ACTION_SELECTED=true
    return 0
  done
}

set_protocol_default_port() {
  case "$1" in
    hy2) HY2_PORT=55501 ;;
    ss) PORT=55502 ;;
    trojan) TROJAN_PORT=55503 ;;
    anytls) ANYTLS_PORT=55504 ;;
    vgr) VGR_PORT=55505 ;;
    vbr) VBR_PORT=55506 ;;
    *) return 1 ;;
  esac
}

default_port_for_protocol() {
  case "$1" in
    hy2) echo 55501 ;;
    ss) echo 55502 ;;
    trojan) echo 55503 ;;
    anytls) echo 55504 ;;
    vgr) echo 55505 ;;
    vbr) echo 55506 ;;
    *) return 1 ;;
  esac
}

collect_interactive_ports() {
  local customize proto var default_port current_port label
  PORT_PROMPT_PROTOCOLS=()
  for proto in "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}"; do
    array_contains "$proto" "${PORT_PROMPT_PROTOCOLS[@]}" || PORT_PROMPT_PROTOCOLS+=("$proto")
  done
  (( ${#PORT_PROMPT_PROTOCOLS[@]} > 0 )) || return 0
  printf '本次仅收集以下协议所需端口：%s\n' "$(format_protocol_list "${PORT_PROMPT_PROTOCOLS[@]}")"
  if ! interactive_mode; then
    for proto in "${PORT_PROMPT_PROTOCOLS[@]}"; do
      var="$(protocol_to_port_var "$proto")"
      default_port="$(default_port_for_protocol "$proto")"
      [[ -n "${!var:-}" ]] || printf -v "$var" '%s' "$default_port"
    done
    return 0
  fi
  while true; do
    read -r -p '是否自定义上述协议端口？[y/N]: ' customize
    customize="${customize:-N}"
    case "$customize" in
      y|Y|yes|YES)
        for proto in "${PROTOCOL_KEYS[@]}"; do
          array_contains "$proto" "${PORT_PROMPT_PROTOCOLS[@]}" || continue
          var="$(protocol_to_port_var "$proto")"
          default_port="$(default_port_for_protocol "$proto")"
          current_port="${!var:-$default_port}"
          label="$(protocol_label "$proto")"
          prompt_enabled_port "$var" "$label" "$current_port"
        done
        return ;;
      n|N|no|NO|'')
        for proto in "${PORT_PROMPT_PROTOCOLS[@]}"; do
          set_protocol_default_port "$proto"
        done
        return ;;
      *) echo '[ERR] 请输入 y 或 n。' >&2 ;;
    esac
  done
}

validate_unique_enabled_ports() {
  local pairs=() pair name port seen_pair seen_name seen_port
  [[ "$ENABLE_HY2" == true ]] && pairs+=("Hysteria2:$HY2_PORT")
  [[ "$ENABLE_SS" == true ]] && pairs+=("Shadowsocks:$PORT")
  [[ "$ENABLE_TROJAN" == true ]] && pairs+=("Trojan:$TROJAN_PORT")
  [[ "$ENABLE_ANYTLS" == true ]] && pairs+=("AnyTLS:$ANYTLS_PORT")
  [[ "$ENABLE_VGR" == true ]] && pairs+=("VLESS gRPC Reality:$VGR_PORT")
  [[ "$ENABLE_VBR" == true ]] && pairs+=("VLESS Brutal Reality:$VBR_PORT")
  local seen_pairs=()
  for pair in "${pairs[@]}"; do
    name="${pair%%:*}"; port="${pair##*:}"
    validate_port "$port"
    for seen_pair in "${seen_pairs[@]}"; do
      seen_name="${seen_pair%%:*}"; seen_port="${seen_pair##*:}"
      [[ "$port" != "$seen_port" ]] || die "Port conflict: $name and $seen_name both use $port"
    done
    seen_pairs+=("$name:$port")
  done
}

backup_target() {
  local target="$1" key="$2"
  mkdir -p "$BACKUP_DIR"
  if [[ -e "$target" ]]; then cp -a "$target" "$BACKUP_DIR/${key}.bak"; else touch "$BACKUP_DIR/${key}.absent"; fi
}

generate_hy2_cert_if_needed() {
  mkdir -p "$HY2_CERT_DIR"
  if [[ -f "$HY2_KEY_FILE" && -f "$HY2_CERT_PEM" && -f "$HY2_CERT_CRT" ]]; then
    log "Reusing existing hysteria2 certificate files under $HY2_CERT_DIR"
    return
  fi
  log "Generating hysteria2 self-signed certificate (CN=$HY2_SNI)"
  openssl ecparam -genkey -name prime256v1 -out "$HY2_KEY_FILE"
  openssl req -new -x509 -days 36500 -key "$HY2_KEY_FILE" -out "$HY2_CERT_PEM" -subj "/CN=$HY2_SNI"
  ln -sf "$HY2_CERT_PEM" "$HY2_CERT_CRT"
}

reality_protocols_selected_together() {
  array_contains vgr "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}" && array_contains vbr "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}"
}

load_reality_env_file_if_exists() {
  local env_file="$1"
  [[ -f "$env_file" ]] || return 0
  # shellcheck disable=SC1090
  source "$env_file"
}

write_reality_env_file() {
  local env_file="$1" prefix="$2"
  local private_var="${prefix}_PRIVATE_KEY" public_var="${prefix}_PUBLIC_KEY" uuid_var="${prefix}_UUID" short_id_var="${prefix}_SHORT_ID"
  cat > "$env_file" <<EOF
${prefix}_PRIVATE_KEY=${!private_var}
${prefix}_PUBLIC_KEY=${!public_var}
${prefix}_UUID=${!uuid_var}
${prefix}_SHORT_ID=${!short_id_var}
EOF
}

generate_reality_credentials_into_prefix() {
  local prefix="$1" kp_out private_key public_key uuid short_id
  kp_out="$($TARGET_BIN generate reality-keypair)"
  private_key="$(printf '%s\n' "$kp_out" | awk '/^PrivateKey: / {print $2}')"
  public_key="$(printf '%s\n' "$kp_out" | awk '/^PublicKey: / {print $2}')"
  uuid="$($TARGET_BIN generate uuid | tr -d '\r\n')"
  short_id="$($TARGET_BIN generate rand 8 --hex | tr -d '\r\n')"
  printf -v "${prefix}_PRIVATE_KEY" '%s' "$private_key"
  printf -v "${prefix}_PUBLIC_KEY" '%s' "$public_key"
  printf -v "${prefix}_UUID" '%s' "$uuid"
  printf -v "${prefix}_SHORT_ID" '%s' "$short_id"
}

prepare_reality_credentials() {
  local vgr_selected=false vbr_selected=false
  local old_vgr_private='' old_vgr_public=''
  mkdir -p "$CREDENTIALS_DIR"
  load_reality_env_file_if_exists "$VGR_ENV_FILE"
  load_reality_env_file_if_exists "$VBR_ENV_FILE"
  old_vgr_private="${VGR_PRIVATE_KEY:-}"
  old_vgr_public="${VGR_PUBLIC_KEY:-}"
  array_contains vgr "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}" && vgr_selected=true || true
  array_contains vbr "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}" && vbr_selected=true || true

  if [[ "$vgr_selected" == true ]]; then
    VGR_PRIVATE_KEY=''; VGR_PUBLIC_KEY=''; VGR_UUID=''; VGR_SHORT_ID=''
  fi
  if [[ "$vbr_selected" == true ]]; then
    VBR_PRIVATE_KEY=''; VBR_PUBLIC_KEY=''; VBR_UUID=''; VBR_SHORT_ID=''
  fi

  if [[ -n "${VBR_PRIVATE_KEY:-}" && -z "${VBR_PUBLIC_KEY:-}" && -n "$old_vgr_private" && -n "$old_vgr_public" && "$VBR_PRIVATE_KEY" == "$old_vgr_private" ]]; then
    VBR_PUBLIC_KEY="$old_vgr_public"
  fi

  if reality_protocols_selected_together && [[ "$ENABLE_VGR" == true && "$ENABLE_VBR" == true ]]; then
    generate_reality_credentials_into_prefix VGR
    VBR_PRIVATE_KEY="$VGR_PRIVATE_KEY"
    VBR_PUBLIC_KEY="$VGR_PUBLIC_KEY"
    VBR_UUID="$VGR_UUID"
    VBR_SHORT_ID="$VGR_SHORT_ID"
    log "Generated shared VLESS Reality credentials for current operation: $VGR_ENV_FILE and $VBR_ENV_FILE"
  else
    if [[ "$ENABLE_VGR" == true && "$vgr_selected" == true && ( -z "${VGR_PRIVATE_KEY:-}" || -z "${VGR_PUBLIC_KEY:-}" || -z "${VGR_UUID:-}" || -z "${VGR_SHORT_ID:-}" ) ]]; then
      generate_reality_credentials_into_prefix VGR
      log "Generated dedicated VLESS gRPC Reality credentials at $VGR_ENV_FILE"
    fi
    if [[ "$ENABLE_VBR" == true && "$vbr_selected" == true && ( -z "${VBR_PRIVATE_KEY:-}" || -z "${VBR_PUBLIC_KEY:-}" || -z "${VBR_UUID:-}" || -z "${VBR_SHORT_ID:-}" ) ]]; then
      generate_reality_credentials_into_prefix VBR
      log "Generated dedicated VLESS Brutal Reality credentials at $VBR_ENV_FILE"
    fi
  fi

  if [[ "$ENABLE_VGR" == true && ( -z "${VGR_PRIVATE_KEY:-}" || -z "${VGR_PUBLIC_KEY:-}" || -z "${VGR_UUID:-}" || -z "${VGR_SHORT_ID:-}" ) ]]; then
    die '缺少现有 VLESS gRPC Reality 凭据；请改为重置该协议后再继续'
  fi
  if [[ "$ENABLE_VBR" == true && ( -z "${VBR_PRIVATE_KEY:-}" || -z "${VBR_PUBLIC_KEY:-}" || -z "${VBR_UUID:-}" || -z "${VBR_SHORT_ID:-}" ) ]]; then
    die '缺少现有 VLESS Brutal Reality 凭据；请改为重置该协议后再继续'
  fi

  if [[ "$ENABLE_VGR" == true ]]; then
    write_reality_env_file "$VGR_ENV_FILE" VGR
  fi
  if [[ "$ENABLE_VBR" == true ]]; then
    write_reality_env_file "$VBR_ENV_FILE" VBR
  fi
  return 0
}

prepare_trojan_anytls_passwords() {
  local trojan_selected=false anytls_selected=false shared_secret=''
  array_contains trojan "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}" && trojan_selected=true || true
  array_contains anytls "${ADD_PROTOCOLS[@]}" "${RESET_PROTOCOLS[@]}" && anytls_selected=true || true

  if [[ "$trojan_selected" == true && "$anytls_selected" == true && "$ENABLE_TROJAN" == true && "$ENABLE_ANYTLS" == true ]]; then
    shared_secret="$($TARGET_BIN generate uuid | tr -d '\r\n')"
    TROJAN_PASSWORD="$shared_secret"
    ANYTLS_PASSWORD="$shared_secret"
    ACCESS_UUID="$shared_secret"
    return 0
  fi

  if [[ "$ENABLE_TROJAN" == true && "$trojan_selected" == true && -z "${TROJAN_PASSWORD:-}" ]]; then
    TROJAN_PASSWORD="$($TARGET_BIN generate uuid | tr -d '\r\n')"
  fi
  if [[ "$ENABLE_ANYTLS" == true && "$anytls_selected" == true && -z "${ANYTLS_PASSWORD:-}" ]]; then
    ANYTLS_PASSWORD="$($TARGET_BIN generate uuid | tr -d '\r\n')"
  fi
  if [[ "$ENABLE_TROJAN" == true && -z "${TROJAN_PASSWORD:-}" ]]; then
    die '缺少现有 Trojan 密码；请改为重置该协议后再继续'
  fi
  if [[ "$ENABLE_ANYTLS" == true && -z "${ANYTLS_PASSWORD:-}" ]]; then
    die '缺少现有 AnyTLS 密码；请改为重置该协议后再继续'
  fi
  if [[ -n "${TROJAN_PASSWORD:-}" && "${TROJAN_PASSWORD:-}" == "${ANYTLS_PASSWORD:-}" ]]; then
    ACCESS_UUID="$TROJAN_PASSWORD"
  else
    ACCESS_UUID=''
  fi
  return 0
}

acme_protocol_needed() { [[ "$ENABLE_TROJAN" == true || "$ENABLE_ANYTLS" == true ]]; }

collect_acme_inputs_if_needed() {
  acme_protocol_needed || return 0
  prompt_if_empty ACME_DOMAIN '证书域名（默认复用 DDNS 域名）' "$HOST"
  prompt_if_empty CF_KEY 'Cloudflare CF_Key（Global API Key）'
  prompt_if_empty CF_EMAIL 'Cloudflare CF_Email'
  prompt_if_empty ACME_EMAIL 'acme 注册邮箱（回车默认复用 CF_Email）' "$CF_EMAIL"
}

install_acme_dependencies() {
  local missing=()
  command -v socat >/dev/null 2>&1 || missing+=(socat)
  command -v wget >/dev/null 2>&1 || missing+=(wget)
  if (( ${#missing[@]} > 0 )); then
    log "Installing ACME dependencies via apt: ${missing[*]}"
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

install_or_reuse_acmesh() {
  if [[ -x "$ACME_BIN" ]]; then log "Reusing existing acme.sh at $ACME_BIN"; return; fi
  log "Installing acme.sh into $ACME_HOME"
  mkdir -p "$ACME_HOME"
  local installer="$WORK_ROOT/get-acme.sh"
  wget -qO "$installer" https://get.acme.sh
  sh "$installer" "email=$ACME_EMAIL" --home "$ACME_HOME"
  [[ -x "$ACME_BIN" ]] || die "acme.sh installation failed"
}

ensure_acme_account() {
  "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt
  if ! grep -qs '^ACCOUNT_EMAIL=' "$ACME_HOME/account.conf" 2>/dev/null; then
    "$ACME_BIN" --home "$ACME_HOME" --register-account -m "$ACME_EMAIL" --server letsencrypt
  fi
}

write_acme_meta() {
  cat > "$ACME_META_FILE" <<EOF
ACME_ENABLED=true
ACME_HOME=$ACME_HOME
ACME_CA=letsencrypt
ACME_DOMAIN=$ACME_DOMAIN
ACME_EMAIL=$ACME_EMAIL
DEFAULT_TLS_CERT_DIR=$DEFAULT_TLS_CERT_DIR
EOF
}

issue_or_install_acme_cert() {
  local cert_dir="$1" key_path="$2" cert_path="$3"
  mkdir -p "$cert_dir"
  ACME_ENV_TEMP="$WORK_ROOT/acme.env"
  cat > "$ACME_ENV_TEMP" <<EOF
export CF_Key=$(printf '%q' "$CF_KEY")
export CF_Email=$(printf '%q' "$CF_EMAIL")
EOF
  # shellcheck disable=SC1090
  source "$ACME_ENV_TEMP"
  "$ACME_BIN" --home "$ACME_HOME" --issue --dns dns_cf -d "$ACME_DOMAIN" --server letsencrypt
  "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$ACME_DOMAIN" --key-file "$key_path" --fullchain-file "$cert_path"
  if [[ ! -s "$key_path" || ! -s "$cert_path" ]]; then
    warn "ACME 安装后未发现完整证书文件：key=$key_path cert=$cert_path"
    rm -f "$ACME_ENV_TEMP"
    ACME_ENV_TEMP=""
    return 1
  fi
  chmod 600 "$key_path"
  chmod 644 "$cert_path"
  rm -f "$ACME_ENV_TEMP"
  ACME_ENV_TEMP=""
  return 0
}

mark_acme_failed_protocols_skipped() {
  ACME_SKIP_REASON='ACME failed'
  ACME_SKIPPED_PROTOCOLS=()
  if [[ "$ENABLE_TROJAN" == true ]]; then
    ENABLE_TROJAN=false
    ACME_SKIPPED_PROTOCOLS+=(trojan)
  fi
  if [[ "$ENABLE_ANYTLS" == true ]]; then
    ENABLE_ANYTLS=false
    ACME_SKIPPED_PROTOCOLS+=(anytls)
  fi
  if (( ${#ACME_SKIPPED_PROTOCOLS[@]} > 0 )); then
    warn 'Trojan/AnyTLS skipped because ACME failed'
    warn "已自动跳过：$(format_protocol_list "${ACME_SKIPPED_PROTOCOLS[@]}")（原因：$ACME_SKIP_REASON）"
  fi
}

format_port_mapping_line() {
  local proto="$1" network port
  port="$(get_protocol_port "$proto")"
  if [[ "$proto" == hy2 ]]; then network='UDP'; else network='TCP'; fi
  printf '  - %s: %s %s\n' "$(protocol_label "$proto")" "$network" "$port"
}

show_final_human_summary() {
  local enabled=() proto
  for proto in "${TARGET_PROTOCOLS[@]}"; do
    if [[ "$(get_protocol_state "$proto")" == true ]]; then
      enabled+=("$proto")
    fi
  done

  printf '\n========== 安装完成 ==========' 
  printf '\n已启用协议：%s\n' "$(format_protocol_list "${enabled[@]}")"
  printf '端口映射建议：\n'
  for proto in "${enabled[@]}"; do
    format_port_mapping_line "$proto"
  done
  printf '请去主路由做好上述端口映射。\n'
  printf '注意：Hy2（Hysteria2）走 UDP，其余协议走 TCP。\n'
  if (( ${#ACME_SKIPPED_PROTOCOLS[@]} > 0 )); then
    printf '以下协议已跳过：%s（原因：%s）\n' "$(format_protocol_list "${ACME_SKIPPED_PROTOCOLS[@]}")" "$ACME_SKIP_REASON"
  fi
  if [[ "$VBR_EFFECTIVE_STATUS" == skipped ]]; then
    printf '以下协议已跳过：VLESS Brutal Reality（原因：%s）\n' "$VBR_SKIPPED_REASON"
  fi
  printf '配置文件：%s\n' "$TARGET_CONFIG"
  printf '客户端配置输出目录：%s\n' "$ARTIFACT_DIR/client"
}

collect_generated_client_snippets() {
  CLIENT_SB_SNIPPETS=()
  CLIENT_CLASH_SNIPPETS=()
  local base="$ARTIFACT_DIR/client"
  local file

  for file in \
    "$base/hy2-singbox-outbound.json" \
    "$base/ss-singbox-outbound.json" \
    "$base/trojan-singbox-outbound.json" \
    "$base/anytls-singbox-outbound.json" \
    "$base/vless-grpc-reality-singbox-outbound.json" \
    "$base/vless-brutal-reality-singbox-outbound.json"; do
    if [[ -f "$file" ]]; then
      CLIENT_SB_SNIPPETS+=("$file")
    fi
  done

  for file in \
    "$base/hy2-mihomo-proxy.yaml" \
    "$base/ss-mihomo-proxy.yaml" \
    "$base/trojan-mihomo-proxy.yaml" \
    "$base/anytls-mihomo-proxy.yaml" \
    "$base/vless-grpc-reality-mihomo-proxy.yaml" \
    "$base/vless-brutal-reality-mihomo-proxy.yaml"; do
    if [[ -f "$file" ]]; then
      CLIENT_CLASH_SNIPPETS+=("$file")
    fi
  done
}

show_client_snippets() {
  local title="$1"
  shift || true
  local file
  printf '\n%s\n' "$title"
  for file in "$@"; do
    printf '\n--- %s ---\n' "$file"
    cat "$file"
    printf '\n'
  done
}

export_singbox_nodes_to_root() {
  local base_dir="${1:-/root}"
  local out_file="$base_dir/sing-box-nodes.json"
  (( ${#CLIENT_SB_SNIPPETS[@]} > 0 )) || return 0
  mkdir -p "$base_dir"
  python3 - "$out_file" "${CLIENT_SB_SNIPPETS[@]}" <<'PY'
import json
import sys

result = []
out_file = sys.argv[1]
for path in sys.argv[2:]:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    if isinstance(data, list):
        result.extend(data)
    else:
        result.append(data)
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)
PY
  printf '\n已生成 sing-box 客户端文件：%s\n' "$out_file"
}

export_clash_nodes_to_root() {
  local base_dir="${1:-/root}"
  local out_file="$base_dir/clash-nodes.yaml"
  (( ${#CLIENT_CLASH_SNIPPETS[@]} > 0 )) || return 0
  mkdir -p "$base_dir"
  : > "$out_file"
  local file
  for file in "${CLIENT_CLASH_SNIPPETS[@]}"; do
    cat "$file" >> "$out_file"
    printf '\n' >> "$out_file"
  done
  printf '\n已生成 clash/mihomo 节点文件：%s\n' "$out_file"
}

prompt_export_destination_if_needed() {
  EXPORT_NODE_DIR="/root"
  interactive_mode || return 0
  local confirm reply
  read -r -p '是否导出节点信息到目录？[Y/n]: ' confirm
  confirm="${confirm:-Y}"
  case "$confirm" in
    n|N|no|NO)
      log '已取消导出节点文件'
      return 1
      ;;
  esac
  read -r -p '导出目录（回车默认 /root）: ' reply
  EXPORT_NODE_DIR="${reply:-/root}"
  return 0
}

post_install_client_export_prompt() {
  collect_generated_client_snippets
  if (( ${#CLIENT_SB_SNIPPETS[@]} == 0 && ${#CLIENT_CLASH_SNIPPETS[@]} == 0 )); then
    warn '未发现可导出的客户端节点片段，跳过导出向导'
    return 0
  fi

  printf '\n========== 客户端节点 ==========\n'
  if (( ${#CLIENT_SB_SNIPPETS[@]} > 0 )); then
    show_client_snippets '以下为已完成协议对应的 sing-box 客户端片段：' "${CLIENT_SB_SNIPPETS[@]}"
    export_singbox_nodes_to_root "/root"
  else
    warn '当前没有可导出的 sing-box 节点片段'
  fi

  if (( ${#CLIENT_CLASH_SNIPPETS[@]} > 0 )); then
    show_client_snippets '以下为已完成协议对应的 clash/mihomo 客户端片段：' "${CLIENT_CLASH_SNIPPETS[@]}"
    export_clash_nodes_to_root "/root"
  else
    warn '当前没有可导出的 clash/mihomo 节点片段'
  fi

  return 0
}

detect_vbr_environment() {
  log 'VLESS Brutal Reality: probing environment before install'
  if grep -qa container=lxc /proc/1/environ 2>/dev/null || [[ -f /run/.containerenv ]]; then log 'VBR probe: container-like environment detected'; fi
  if [[ -f /proc/1/status ]]; then
    local uid_map
    uid_map="$(awk '/^Uid:/ {print $2":"$3":"$4":"$5}' /proc/1/status 2>/dev/null || true)"
    if [[ -n "$uid_map" ]]; then
      log "VBR probe: PID1 Uid map $uid_map"
    fi
  fi
  if [[ -e /dev/net/tun ]]; then log 'VBR probe: /dev/net/tun exists'; else log 'VBR probe: /dev/net/tun missing'; fi
  if command -v brutal >/dev/null 2>&1; then log "VBR probe: brutal helper present at $(command -v brutal)"; else log 'VBR probe: brutal helper binary not found (this can be normal)'; fi
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]]; then
    log "VBR probe: tcp_available_congestion_control=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
  fi
  if [[ -r /proc/sys/net/ipv4/tcp_allowed_congestion_control ]]; then
    log "VBR probe: tcp_allowed_congestion_control=$(cat /proc/sys/net/ipv4/tcp_allowed_congestion_control)"
  fi
  return 0
}

vbr_kernel_ready() {
  command -v brutal >/dev/null 2>&1 && return 0
  if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] && grep -qw brutal /proc/sys/net/ipv4/tcp_available_congestion_control; then
    return 0
  fi
  if [[ -r /proc/sys/net/ipv4/tcp_allowed_congestion_control ]] && grep -qw brutal /proc/sys/net/ipv4/tcp_allowed_congestion_control; then
    return 0
  fi
  if command -v lsmod >/dev/null 2>&1 && lsmod 2>/dev/null | awk '{print $1}' | grep -Fxq brutal; then
    return 0
  fi
  return 1
}

try_install_brutal() {
  detect_vbr_environment
  if vbr_kernel_ready; then
    log 'VLESS Brutal Reality: brutal capability already available, skip bootstrap'
    return 0
  fi
  local install_log="$WORK_ROOT/brutal-install.log"
  log 'VLESS Brutal Reality: installing brutal dependencies and brutal itself'
  if {
    apt-get update &&
    DEBIAN_FRONTEND=noninteractive apt-get install -y clang llvm lld curl &&
    bash <(curl -fsSL https://tcp.hy2.sh/)
  } > >(tee -a "$install_log") 2> >(tee -a "$install_log" >&2); then
    modprobe brutal >/dev/null 2>&1 || true
    if vbr_kernel_ready; then
      log 'VLESS Brutal Reality: brutal capability detected after bootstrap'
      return 0
    fi
    VBR_SKIPPED_REASON="brutal bootstrap finished but kernel capability not detected (see $install_log)"
    return 1
  fi
  VBR_SKIPPED_REASON="brutal bootstrap failed (see $install_log)"
  return 1
}

prepare_vbr_or_skip() {
  [[ "$ENABLE_VBR" == true ]] || { VBR_EFFECTIVE_STATUS=disabled; return 0; }
  if try_install_brutal; then
    VBR_EFFECTIVE_STATUS=enabled
  else
    warn 'VLESS Brutal Reality: skipped'
    [[ -n "$VBR_SKIPPED_REASON" ]] && warn "VLESS Brutal Reality skip reason: $VBR_SKIPPED_REASON"
    ENABLE_VBR=false
    VBR_EFFECTIVE_STATUS=skipped
  fi
}

PROTOCOL_KEYS=(hy2 ss vgr trojan anytls vbr)
array_contains() { local needle="$1"; shift || true; local item; for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done; return 1; }
join_by() { local sep="$1"; shift || true; local first=true item; for item in "$@"; do [[ -n "$item" ]] || continue; if [[ "$first" == true ]]; then printf '%s' "$item"; first=false; else printf '%s%s' "$sep" "$item"; fi; done; }
protocol_label() { case "$1" in hy2) echo 'Hysteria2' ;; ss) echo 'Shadowsocks' ;; trojan) echo 'Trojan' ;; anytls) echo 'AnyTLS' ;; vgr) echo 'VLESS gRPC Reality' ;; vbr) echo 'VLESS Brutal Reality' ;; *) echo "$1" ;; esac; }
protocol_to_flag_var() { case "$1" in hy2) echo ENABLE_HY2 ;; ss) echo ENABLE_SS ;; trojan) echo ENABLE_TROJAN ;; anytls) echo ENABLE_ANYTLS ;; vgr) echo ENABLE_VGR ;; vbr) echo ENABLE_VBR ;; *) return 1 ;; esac; }
protocol_to_port_var() { case "$1" in hy2) echo HY2_PORT ;; ss) echo PORT ;; trojan) echo TROJAN_PORT ;; anytls) echo ANYTLS_PORT ;; vgr) echo VGR_PORT ;; vbr) echo VBR_PORT ;; *) return 1 ;; esac; }
set_protocol_state() { local var; var="$(protocol_to_flag_var "$1")" || return 1; printf -v "$var" '%s' "$2"; }
get_protocol_state() { local var; var="$(protocol_to_flag_var "$1")" || return 1; printf '%s' "${!var}"; }
get_protocol_port() { local var; var="$(protocol_to_port_var "$1")" || return 1; printf '%s' "${!var}"; }
service_exists() { systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "${SERVICE_NAME}.service"; }
service_active() { systemctl is-active --quiet "$SERVICE_NAME"; }
prompt_yes_no_default_no() { local reply; interactive_mode || return 1; read -r -p "$1" reply; reply="${reply:-N}"; case "$reply" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac; }
load_existing_state() {
  local source="" parsed line proto port
  CURRENT_PROTOCOLS=()
  declare -gA CURRENT_PROTOCOL_PORTS=()
  [[ -f "$INSTALLER_STATE_FILE" ]] && source="$INSTALLER_STATE_FILE"
  [[ -z "$source" && -f "$TARGET_CONFIG" ]] && source="$TARGET_CONFIG"
  [[ -n "$source" ]] || return 0
  parsed="$(python3 - "$source" <<'PY2'
import json, sys
path = sys.argv[1]

def load_json_relaxed(path):
    text = open(path, encoding='utf-8').read()
    out = []
    in_string = False
    escape = False
    line_comment = False
    block_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n':
                line_comment = False
                out.append(ch)
        elif block_comment:
            if ch == '*' and nxt == '/':
                block_comment = False
                i += 1
        elif in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '/' and nxt == '/':
                line_comment = True
                i += 1
            elif ch == '/' and nxt == '*':
                block_comment = True
                i += 1
            else:
                out.append(ch)
                if ch == '"':
                    in_string = True
        i += 1
    cleaned = ''.join(out)
    out = []
    in_string = False
    escape = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ',':
            j = i + 1
            while j < len(cleaned) and cleaned[j] in ' \t\r\n':
                j += 1
            if j < len(cleaned) and cleaned[j] in '}]':
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads(''.join(out))

try:
    data = load_json_relaxed(path)
except Exception:
    raise SystemExit(0)
protocols=[]
ports={}
if isinstance(data, dict) and 'enabled_protocols' in data:
    for x in data.get('enabled_protocols') or []:
        if x in {'hy2','ss','trojan','anytls','vgr','vbr'} and x not in protocols:
            protocols.append(x)
    for k, v in (data.get('ports') or {}).items():
        if k in {'hy2','ss','trojan','anytls','vgr','vbr'}:
            ports[k]=v
else:
    for ib in data.get('inbounds', []) if isinstance(data, dict) else []:
        tag=ib.get('tag','')
        typ=ib.get('type','')
        listen_port=ib.get('listen_port')
        proto=None
        if typ=='hysteria2' or tag=='hy2-in': proto='hy2'
        elif typ=='shadowsocks' or tag=='shadowsocks-in': proto='ss'
        elif typ=='trojan' or tag=='trojan-in': proto='trojan'
        elif typ=='anytls' or tag=='anytls-in': proto='anytls'
        elif tag=='vless-grpc-reality-in': proto='vgr'
        elif tag=='vless-brutal-reality-in': proto='vbr'
        if proto and proto not in protocols:
            protocols.append(proto)
        if proto and listen_port:
            ports[proto]=listen_port
for p in protocols:
    print(f'PROTO\t{p}')
for k, v in ports.items():
    print(f'PORT\t{k}\t{v}')
PY2
)"
  while IFS=$'\t' read -r kind proto port; do
    case "$kind" in
      PROTO) CURRENT_PROTOCOLS+=("$proto") ;;
      PORT) CURRENT_PROTOCOL_PORTS["$proto"]="$port" ;;
    esac
  done <<< "$parsed"
}
apply_existing_protocol_ports() { local proto var; for proto in "${CURRENT_PROTOCOLS[@]}"; do [[ -n "${CURRENT_PROTOCOL_PORTS[$proto]:-}" ]] || continue; var="$(protocol_to_port_var "$proto")"; printf -v "$var" '%s' "${CURRENT_PROTOCOL_PORTS[$proto]}"; done; }
load_existing_protocol_runtime_values() {
  local parsed kind value1 value2
  [[ "$DEPLOY_MODE" == "standalone" ]] || return 0
  [[ -f "$TARGET_CONFIG" ]] || return 0
  parsed="$(python3 - "$TARGET_CONFIG" <<'PY2'
import json, sys
path = sys.argv[1]
try:
    data = json.load(open(path, encoding='utf-8'))
except Exception:
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)
for ib in data.get('inbounds', []):
    if not isinstance(ib, dict):
        continue
    tag = ib.get('tag', '')
    typ = ib.get('type', '')
    users = ib.get('users', [])
    user0 = users[0] if isinstance(users, list) and users and isinstance(users[0], dict) else {}
    tls = ib.get('tls', {}) if isinstance(ib.get('tls'), dict) else {}
    reality = tls.get('reality', {}) if isinstance(tls.get('reality'), dict) else {}
    transport = ib.get('transport', {}) if isinstance(ib.get('transport'), dict) else {}
    short_id = reality.get('short_id')
    short_id_0 = ''
    if isinstance(short_id, list) and short_id:
        short_id_0 = short_id[0]
    elif isinstance(short_id, str):
        short_id_0 = short_id
    if typ == 'hysteria2' or tag == 'hy2-in':
        if user0.get('password'): print('HY2_PASSWORD\t' + str(user0.get('password')))
        if tls.get('server_name'): print('HY2_SNI\t' + str(tls.get('server_name')))
    elif typ == 'shadowsocks' or tag == 'shadowsocks-in':
        if ib.get('password'): print('SS_PASSWORD\t' + str(ib.get('password')))
        if ib.get('method'): print('SS_METHOD\t' + str(ib.get('method')))
    elif typ == 'trojan' or tag == 'trojan-in':
        if user0.get('password'): print('TROJAN_PASSWORD\t' + str(user0.get('password')))
    elif typ == 'anytls' or tag == 'anytls-in':
        if user0.get('password'): print('ANYTLS_PASSWORD\t' + str(user0.get('password')))
    elif tag == 'vless-grpc-reality-in':
        if user0.get('uuid'): print('VGR_UUID\t' + str(user0.get('uuid')))
        if tls.get('server_name'): print('VGR_SERVER_NAME\t' + str(tls.get('server_name')))
        if transport.get('service_name'): print('VGR_SERVICE_NAME\t' + str(transport.get('service_name')))
        if reality.get('private_key'): print('VGR_PRIVATE_KEY\t' + str(reality.get('private_key')))
        if short_id_0: print('VGR_SHORT_ID\t' + str(short_id_0))
    elif tag == 'vless-brutal-reality-in':
        if user0.get('uuid'): print('VBR_UUID\t' + str(user0.get('uuid')))
        if tls.get('server_name'): print('VBR_SERVER_NAME\t' + str(tls.get('server_name')))
        if reality.get('private_key'): print('VBR_PRIVATE_KEY\t' + str(reality.get('private_key')))
        if short_id_0: print('VBR_SHORT_ID\t' + str(short_id_0))
PY2
)"
  while IFS=$'\t' read -r kind value1 value2; do
    case "$kind" in
      HY2_PASSWORD) [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$value1" ;;
      HY2_SNI) [[ "$HY2_SNI" != "bing.com" ]] || HY2_SNI="$value1" ;;
      SS_PASSWORD) [[ -n "$PASSWORD" ]] || PASSWORD="$value1" ;;
      SS_METHOD) [[ "$METHOD" != "2022-blake3-aes-128-gcm" ]] || METHOD="$value1" ;;
      TROJAN_PASSWORD) [[ -n "$TROJAN_PASSWORD" ]] || TROJAN_PASSWORD="$value1" ;;
      ANYTLS_PASSWORD) [[ -n "$ANYTLS_PASSWORD" ]] || ANYTLS_PASSWORD="$value1" ;;
      VGR_UUID) [[ -n "$VGR_UUID" ]] || VGR_UUID="$value1" ;;
      VGR_SERVER_NAME) [[ "$VGR_SERVER_NAME" != "www.huawei.com" ]] || VGR_SERVER_NAME="$value1" ;;
      VGR_SERVICE_NAME) [[ "$VGR_SERVICE_NAME" != "Huawei.SmartHome.Connect" ]] || VGR_SERVICE_NAME="$value1" ;;
      VGR_PRIVATE_KEY) [[ -n "$VGR_PRIVATE_KEY" ]] || VGR_PRIVATE_KEY="$value1" ;;
      VGR_SHORT_ID) [[ -n "$VGR_SHORT_ID" ]] || VGR_SHORT_ID="$value1" ;;
      VBR_UUID) [[ -n "$VBR_UUID" ]] || VBR_UUID="$value1" ;;
      VBR_SERVER_NAME) [[ "$VBR_SERVER_NAME" != "www.huawei.com" ]] || VBR_SERVER_NAME="$value1" ;;
      VBR_PRIVATE_KEY) [[ -n "$VBR_PRIVATE_KEY" ]] || VBR_PRIVATE_KEY="$value1" ;;
      VBR_SHORT_ID) [[ -n "$VBR_SHORT_ID" ]] || VBR_SHORT_ID="$value1" ;;
    esac
  done <<< "$parsed"
}
apply_incremental_protocol_plan() { local proto; KEEP_PROTOCOLS=(); ADD_PROTOCOLS=(); EXISTING_NOT_SELECTED_PROTOCOLS=(); TARGET_PROTOCOLS=(); RESET_PROTOCOLS=(); for proto in "${PROTOCOL_KEYS[@]}"; do if array_contains "$proto" "${CURRENT_PROTOCOLS[@]}"; then TARGET_PROTOCOLS+=("$proto"); if [[ "$(get_protocol_state "$proto")" == true ]]; then KEEP_PROTOCOLS+=("$proto"); else EXISTING_NOT_SELECTED_PROTOCOLS+=("$proto"); set_protocol_state "$proto" true; fi; elif [[ "$(get_protocol_state "$proto")" == true ]]; then ADD_PROTOCOLS+=("$proto"); TARGET_PROTOCOLS+=("$proto"); fi; done; }
format_protocol_list() { local proto items=(); for proto in "$@"; do items+=("$(protocol_label "$proto")"); done; if (( ${#items[@]} == 0 )); then printf '无'; else join_by ', ' "${items[@]}"; fi; }
show_environment_status() {
  printf '当前环境检查：\n'
  if [[ "$DEPLOY_MODE" == "merge" ]]; then
    printf '  - 运行模式：合并到已有 sing-box 配置\n'
  else
    printf '  - 运行模式：独立部署回家 sing-box\n'
  fi
  printf '  - sing-box 已安装：%s\n' "$([[ "$BINARY_EXISTS" == true ]] && echo 是 || echo 否)"
  printf '  - service 已存在：%s\n' "$([[ "$SERVICE_EXISTS" == true ]] && echo 是 || echo 否)"
  printf '  - service 运行中：%s\n' "$([[ "$SERVICE_ACTIVE" == true ]] && echo 是 || echo 否)"
  printf '  - config 已存在：%s\n' "$([[ "$CONFIG_EXISTS" == true ]] && echo 是 || echo 否)"
  printf '  - 当前已配置协议：%s\n' "$(format_protocol_list "${CURRENT_PROTOCOLS[@]}")"
}
show_main_menu_if_needed() {
  [[ "$HAD_CLI_ARGS" == true ]] && return 0
  interactive_mode || return 0
  local choice
  while true; do
    cat <<'EOF'

========== 主菜单 ==========
1) 配置 sing-box 回家
2) 卸载
3) 退出脚本
4) 导出客户端节点信息
EOF
    read -r -p '请输入编号 [1-4]: ' choice
    choice="${choice:-3}"
    case "$choice" in
      1) return 0 ;;
      2) run_uninstall_flow; exit 0 ;;
      3) log '已退出'; exit 0 ;;
      4) run_export_only_flow; exit 0 ;;
      *) echo '[ERR] 请输入 1-4。' >&2 ;;
    esac
  done
}

collect_deploy_mode_if_needed() {
  [[ "$DEPLOY_MODE_SOURCE" == "flag" ]] && return 0
  interactive_mode || return 0
  local choice
  while true; do
    cat <<'EOF'

========== 部署模式 ==========
1) 独立部署回家 sing-box
2) 合并到已有 sing-box 配置（仅追加 inbounds）
EOF
    read -r -p '请输入编号 [1-2]（默认 1）: ' choice
    choice="${choice:-1}"
    case "$choice" in
      1) DEPLOY_MODE="standalone"; return 0 ;;
      2) DEPLOY_MODE="merge"; return 0 ;;
      *) echo '[ERR] 请输入 1 或 2。' >&2 ;;
    esac
  done
}

extract_service_execstart_line() {
  local unit="$1"
  systemctl cat "$unit" 2>/dev/null | awk '
    BEGIN { in_service=0 }
    /^\[Service\]/ { in_service=1; next }
    /^\[/ { in_service=0 }
    in_service && /^ExecStart=/ { sub(/^ExecStart=/, "", $0); print; exit }
  '
}

parse_singbox_execstart() {
  local execstart_line="$1"
  python3 - "$execstart_line" <<'PY'
import os
import shlex
import sys

line = sys.argv[1].strip()
if not line:
    raise SystemExit(1)
if line.startswith("-"):
    line = line[1:].lstrip()
try:
    tokens = shlex.split(line)
except Exception:
    raise SystemExit(1)

bin_index = -1
for i, tok in enumerate(tokens):
    base = os.path.basename(tok)
    if base in ("sing-box", "singbox"):
        bin_index = i
        break
if bin_index < 0:
    raise SystemExit(1)

run_index = -1
for i in range(bin_index + 1, len(tokens)):
    if tokens[i] == "run":
        run_index = i
        break
if run_index < 0:
    raise SystemExit(1)

mode = ""
path = ""
workdir = ""
for i in range(run_index + 1, len(tokens)):
    tok = tokens[i]
    if tok in ("-c", "--config"):
        if i + 1 < len(tokens):
            mode = "c"
            path = tokens[i + 1]
            break
    elif tok.startswith("-c="):
        mode = "c"
        path = tok.split("=", 1)[1]
        break
    elif tok.startswith("--config="):
        mode = "c"
        path = tok.split("=", 1)[1]
        break
    elif tok in ("-C", "--config-directory"):
        if i + 1 < len(tokens):
            mode = "C"
            path = tokens[i + 1]
            break
    elif tok.startswith("-C="):
        mode = "C"
        path = tok.split("=", 1)[1]
        break
    elif tok.startswith("--config-directory="):
        mode = "C"
        path = tok.split("=", 1)[1]
        break
    elif tok in ("-D", "--directory"):
        if i + 1 < len(tokens):
            workdir = tokens[i + 1]
    elif tok.startswith("-D="):
        workdir = tok.split("=", 1)[1]
    elif tok.startswith("--directory="):
        workdir = tok.split("=", 1)[1]

if (not mode or not path) and workdir:
    workdir = os.path.realpath(workdir)
    config_path = os.path.join(workdir, "config.json")
    config_dir = os.path.join(workdir, "conf")
    if os.path.isfile(config_path):
        mode = "c"
        path = config_path
    elif os.path.isdir(config_dir):
        mode = "C"
        path = config_dir

if not mode or not path:
    raise SystemExit(1)

print(tokens[bin_index])
print(mode)
print(path)
PY
}

discover_merge_candidates() {
  local unit execstart_line
  local -a unit_list=()
  MERGE_CANDIDATES=()
  mapfile -t unit_list < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Ei 'sing-?box.*\.service$' | sort -u || true)
  if (( ${#unit_list[@]} == 0 )); then
    mapfile -t unit_list < <(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | sort -u)
  fi
  for unit in "${unit_list[@]}"; do
    [[ "$unit" == *.service ]] || continue
    execstart_line="$(extract_service_execstart_line "$unit" 2>/dev/null || true)"
    [[ -n "$execstart_line" ]] || continue
    mapfile -t _meta < <(parse_singbox_execstart "$execstart_line" 2>/dev/null || true)
    (( ${#_meta[@]} == 3 )) || continue
    MERGE_CANDIDATES+=("${unit}|${_meta[0]}|${_meta[1]}|${_meta[2]}")
  done
}

json_has_top_level_inbounds_array() {
  local json_file="$1"
  python3 - "$json_file" <<'PY'
import json
import sys
path = sys.argv[1]

def load_json_relaxed(path):
    text = open(path, encoding="utf-8").read()
    out = []
    in_string = False
    escape = False
    line_comment = False
    block_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
                out.append(ch)
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == "/" and nxt == "/":
                line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                block_comment = True
                i += 1
            else:
                out.append(ch)
                if ch == '"':
                    in_string = True
        i += 1
    cleaned = "".join(out)
    out = []
    in_string = False
    escape = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < len(cleaned) and cleaned[j] in " \t\r\n":
                j += 1
            if j < len(cleaned) and cleaned[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads("".join(out))

try:
    data = load_json_relaxed(path)
except Exception:
    raise SystemExit(1)
if isinstance(data, dict) and isinstance(data.get("inbounds"), list):
    raise SystemExit(0)
raise SystemExit(1)
PY
}

find_first_inbounds_json_in_dir() {
  local dir="$1"
  python3 - "$dir" <<'PY'
import json
import os
import sys
root = sys.argv[1]

def load_json_relaxed(path):
    text = open(path, encoding="utf-8").read()
    out = []
    in_string = False
    escape = False
    line_comment = False
    block_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if ch == "\n":
                line_comment = False
                out.append(ch)
        elif block_comment:
            if ch == "*" and nxt == "/":
                block_comment = False
                i += 1
        elif in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == "/" and nxt == "/":
                line_comment = True
                i += 1
            elif ch == "/" and nxt == "*":
                block_comment = True
                i += 1
            else:
                out.append(ch)
                if ch == '"':
                    in_string = True
        i += 1
    cleaned = "".join(out)
    out = []
    in_string = False
    escape = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ",":
            j = i + 1
            while j < len(cleaned) and cleaned[j] in " \t\r\n":
                j += 1
            if j < len(cleaned) and cleaned[j] in "}]":
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads("".join(out))

paths = []
for base, _dirs, files in os.walk(root):
    for name in files:
        if name.endswith(".json"):
            paths.append(os.path.join(base, name))
for path in sorted(paths):
    try:
        data = load_json_relaxed(path)
    except Exception:
        continue
    if isinstance(data, dict) and isinstance(data.get("inbounds"), list):
        print(path)
        break
PY
}

normalize_fs_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY
}

resolve_merge_bin_path() {
  if [[ -n "$MERGE_SINGBOX_BIN" && -x "$MERGE_SINGBOX_BIN" ]]; then
    return 0
  fi
  if command -v sing-box >/dev/null 2>&1; then
    MERGE_SINGBOX_BIN="$(command -v sing-box)"
    return 0
  fi
  if command -v singbox >/dev/null 2>&1; then
    MERGE_SINGBOX_BIN="$(command -v singbox)"
    return 0
  fi
  die 'Unable to locate sing-box binary for merge mode'
}

set_merge_service_from_candidate() {
  local candidate="$1" unit bin _mode _value
  IFS='|' read -r unit bin _mode _value <<< "$candidate"
  MERGE_SERVICE_UNIT="$unit"
  MERGE_SERVICE_NAME="${unit%.service}"
  MERGE_SINGBOX_BIN="$bin"
}

set_merge_target_from_candidate() {
  local candidate="$1" unit bin mode value
  IFS='|' read -r unit bin mode value <<< "$candidate"
  MERGE_SERVICE_UNIT="$unit"
  MERGE_SERVICE_NAME="${unit%.service}"
  MERGE_SINGBOX_BIN="$bin"
  MERGE_CONFIG_MODE="$mode"
  MERGE_CONFIG_VALUE="$value"
}

resolve_merge_target_from_file() {
  local file="$1" candidate unit bin mode value file_norm value_norm
  [[ -f "$file" ]] || die "Merge config file not found: $file"
  json_has_top_level_inbounds_array "$file" || die "Config file has no top-level inbounds array: $file"
  file_norm="$(normalize_fs_path "$file")"
  MERGE_TARGET_CONFIG="$file_norm"
  MERGE_TARGET_DIR="$(dirname "$file_norm")"
  MERGE_CONFIG_MODE="c"
  MERGE_CONFIG_VALUE="$file_norm"
  MERGE_MATCHED_SERVICES=()
  for candidate in "${MERGE_CANDIDATES[@]}"; do
    IFS='|' read -r unit bin mode value <<< "$candidate"
    value_norm="$(normalize_fs_path "$value" 2>/dev/null || printf '%s' "$value")"
    if [[ "$mode" == "c" && "$value_norm" == "$file_norm" ]]; then
      MERGE_MATCHED_SERVICES+=("$candidate")
    fi
  done
}

resolve_merge_target_from_dir() {
  local dir="$1" candidate unit bin mode value target_file dir_norm value_norm
  [[ -d "$dir" ]] || die "Merge config directory not found: $dir"
  dir_norm="$(normalize_fs_path "$dir")"
  target_file="$(find_first_inbounds_json_in_dir "$dir_norm")"
  [[ -n "$target_file" ]] || die "No JSON with top-level inbounds array found under: $dir"
  MERGE_TARGET_DIR="$dir_norm"
  MERGE_TARGET_CONFIG="$target_file"
  MERGE_CONFIG_MODE="C"
  MERGE_CONFIG_VALUE="$dir_norm"
  MERGE_MATCHED_SERVICES=()
  for candidate in "${MERGE_CANDIDATES[@]}"; do
    IFS='|' read -r unit bin mode value <<< "$candidate"
    value_norm="$(normalize_fs_path "$value" 2>/dev/null || printf '%s' "$value")"
    if [[ "$mode" == "C" && "$value_norm" == "$dir_norm" ]]; then
      MERGE_MATCHED_SERVICES+=("$candidate")
      continue
    fi
    if [[ "$mode" == "c" && "$(normalize_fs_path "$(dirname "$value")" 2>/dev/null || dirname "$value")" == "$dir_norm" ]]; then
      MERGE_MATCHED_SERVICES+=("$candidate")
    fi
  done
  if (( ${#MERGE_MATCHED_SERVICES[@]} == 1 )); then
    IFS='|' read -r unit bin mode value <<< "${MERGE_MATCHED_SERVICES[0]}"
    if [[ "$mode" == "c" && -f "$value" ]]; then
      target_file="$(normalize_fs_path "$value")"
      MERGE_TARGET_CONFIG="$target_file"
      MERGE_TARGET_DIR="$(dirname "$target_file")"
      MERGE_CONFIG_MODE="c"
      MERGE_CONFIG_VALUE="$target_file"
    fi
  fi
}

resolve_merge_service_from_hint() {
  local unit candidate
  [[ -n "$MERGE_SERVICE_NAME_HINT" ]] || return 1
  unit="$MERGE_SERVICE_NAME_HINT"
  [[ "$unit" == *.service ]] || unit="${unit}.service"
  for candidate in "${MERGE_CANDIDATES[@]}"; do
    if [[ "${candidate%%|*}" == "$unit" ]]; then
      set_merge_service_from_candidate "$candidate"
      return 0
    fi
  done
  if systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -Fxq "$unit"; then
    MERGE_SERVICE_UNIT="$unit"
    MERGE_SERVICE_NAME="${unit%.service}"
    return 0
  fi
  die "Specified merge service not found: $unit"
}

prompt_merge_service_name_if_needed() {
  local input
  if resolve_merge_service_from_hint; then
    return 0
  fi
  if (( ${#MERGE_MATCHED_SERVICES[@]} == 1 )); then
    set_merge_service_from_candidate "${MERGE_MATCHED_SERVICES[0]}"
    return 0
  fi
  if (( ${#MERGE_MATCHED_SERVICES[@]} > 1 )); then
    warn 'Multiple sing-box services match this config path; please specify which service to restart'
  elif (( ${#MERGE_CANDIDATES[@]} == 1 )); then
    set_merge_service_from_candidate "${MERGE_CANDIDATES[0]}"
    return 0
  elif (( ${#MERGE_CANDIDATES[@]} == 0 )); then
    warn 'No sing-box service was auto-detected; service name is required for restart in merge mode'
  else
    warn 'Could not uniquely map this config path to a sing-box service; service name is required'
  fi
  interactive_mode || die 'Merge mode requires --merge-service-name when service auto-detection is ambiguous'
  while true; do
    read -r -p '请输入要重启的 sing-box service 名称（例如 sing-box 或 singbox）: ' input
    [[ -n "$input" ]] || { echo '[ERR] service 名称不能为空。' >&2; continue; }
    MERGE_SERVICE_NAME_HINT="$input"
    if resolve_merge_service_from_hint; then
      return 0
    fi
  done
}

resolve_merge_target_from_path() {
  local path="$1"
  if [[ -d "$path" ]]; then
    resolve_merge_target_from_dir "$path"
  elif [[ -f "$path" ]]; then
    resolve_merge_target_from_file "$path"
  else
    die "Merge config path not found: $path"
  fi
  prompt_merge_service_name_if_needed
}

prompt_merge_config_path_if_needed() {
  local path_input
  if [[ -n "$MERGE_CONFIG_DIR_HINT" ]]; then
    resolve_merge_target_from_path "$MERGE_CONFIG_DIR_HINT"
    return 0
  fi
  interactive_mode || die 'Merge mode could not auto-detect target config path in non-interactive mode; provide --merge-config-dir'
  while true; do
    read -r -p '请输入现有 sing-box 配置路径（config.json 或 conf 目录）: ' path_input
    [[ -n "$path_input" ]] || { echo '[ERR] 配置路径不能为空。' >&2; continue; }
    if [[ ! -e "$path_input" ]]; then
      echo "[ERR] 路径不存在：$path_input" >&2
      continue
    fi
    if resolve_merge_target_from_path "$path_input"; then
      return 0
    fi
  done
}

setup_merge_mode_target() {
  local candidate
  discover_merge_candidates
  if (( ${#MERGE_CANDIDATES[@]} == 1 )); then
    candidate="${MERGE_CANDIDATES[0]}"
    set_merge_target_from_candidate "$candidate"
    if [[ "$MERGE_CONFIG_MODE" == "c" ]]; then
      if [[ -f "$MERGE_CONFIG_VALUE" ]] && json_has_top_level_inbounds_array "$MERGE_CONFIG_VALUE"; then
        MERGE_TARGET_CONFIG="$(normalize_fs_path "$MERGE_CONFIG_VALUE")"
        MERGE_TARGET_DIR="$(dirname "$MERGE_TARGET_CONFIG")"
        MERGE_CONFIG_VALUE="$MERGE_TARGET_CONFIG"
        prompt_merge_service_name_if_needed
      else
        warn "Auto-detected -c config is not suitable: $MERGE_CONFIG_VALUE"
        prompt_merge_config_path_if_needed
      fi
    else
      if [[ -d "$MERGE_CONFIG_VALUE" ]]; then
        MERGE_TARGET_DIR="$(normalize_fs_path "$MERGE_CONFIG_VALUE")"
        MERGE_CONFIG_VALUE="$MERGE_TARGET_DIR"
        MERGE_TARGET_CONFIG="$(find_first_inbounds_json_in_dir "$MERGE_TARGET_DIR")"
      fi
      prompt_merge_service_name_if_needed
      [[ -n "$MERGE_TARGET_CONFIG" ]] || {
        warn "Auto-detected -C directory has no top-level inbounds JSON: $MERGE_CONFIG_VALUE"
        prompt_merge_config_path_if_needed
      }
    fi
  else
    if (( ${#MERGE_CANDIDATES[@]} > 1 )); then
      warn 'Multiple sing-box services were detected; manual config path input is required'
    else
      warn 'No sing-box service with detectable run -c/-C/-D was found; manual config path input is required'
    fi
    prompt_merge_config_path_if_needed
  fi

  [[ -n "$MERGE_TARGET_CONFIG" && -f "$MERGE_TARGET_CONFIG" ]] || die 'Merge target config file is not available'
  [[ -n "$MERGE_TARGET_DIR" && -d "$MERGE_TARGET_DIR" ]] || die 'Merge target config directory is not available'
  resolve_merge_bin_path
  SERVICE_NAME="$MERGE_SERVICE_NAME"
  TARGET_CONFIG="$MERGE_TARGET_CONFIG"
  TARGET_BIN="$MERGE_SINGBOX_BIN"
}

load_existing_inbound_ports_for_merge() {
  local parsed port owner
  unset MERGE_EXISTING_PORT_MAP
  declare -gA MERGE_EXISTING_PORT_MAP=()
  parsed="$(python3 - "$MERGE_CONFIG_MODE" "$MERGE_TARGET_CONFIG" "$MERGE_TARGET_DIR" <<'PY'
import json
import os
import sys
mode = sys.argv[1]
target_config = sys.argv[2]
target_dir = sys.argv[3]

def load_json_relaxed(path):
    text = open(path, encoding='utf-8').read()
    out = []
    in_string = False
    escape = False
    line_comment = False
    block_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n':
                line_comment = False
                out.append(ch)
        elif block_comment:
            if ch == '*' and nxt == '/':
                block_comment = False
                i += 1
        elif in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '/' and nxt == '/':
                line_comment = True
                i += 1
            elif ch == '/' and nxt == '*':
                block_comment = True
                i += 1
            else:
                out.append(ch)
                if ch == '"':
                    in_string = True
        i += 1
    cleaned = ''.join(out)
    out = []
    in_string = False
    escape = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ',':
            j = i + 1
            while j < len(cleaned) and cleaned[j] in ' \t\r\n':
                j += 1
            if j < len(cleaned) and cleaned[j] in '}]':
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads(''.join(out))

paths = []
if mode == 'C':
    for base, _dirs, files in os.walk(target_dir):
        for name in files:
            if name.endswith('.json'):
                paths.append(os.path.join(base, name))
    paths.sort()
else:
    paths = [target_config]

for path in paths:
    try:
        data = load_json_relaxed(path)
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    for ib in data.get('inbounds', []):
        if not isinstance(ib, dict):
            continue
        lp = ib.get('listen_port')
        if isinstance(lp, int):
            owner = ib.get('tag') or ib.get('type') or 'existing'
            if mode == 'C':
                rel = os.path.relpath(path, target_dir)
                owner = f'{rel}:{owner}'
            print(f"{lp}\t{owner}")
PY
)"
  while IFS=$'\t' read -r port owner; do
    [[ -n "$port" ]] || continue
    MERGE_EXISTING_PORT_MAP["$port"]="$owner"
  done <<< "$parsed"
}

validate_ports_against_merge_target() {
  local conflicts=() proto port var owner other other_port label raw
  load_existing_inbound_ports_for_merge
  while true; do
    conflicts=()
    for proto in "${PROTOCOL_KEYS[@]}"; do
      [[ "$(get_protocol_state "$proto")" == true ]] || continue
      port="$(get_protocol_port "$proto")"
      if [[ -n "${MERGE_EXISTING_PORT_MAP[$port]:-}" ]]; then
        conflicts+=("$proto")
      fi
    done
    (( ${#conflicts[@]} == 0 )) && return 0
    if ! interactive_mode; then
      die "Port conflicts with existing inbounds in $MERGE_TARGET_CONFIG; provide non-conflicting ports via CLI flags"
    fi
    printf '检测到与已有 inbounds 端口冲突，需手动调整：\n'
    for proto in "${conflicts[@]}"; do
      port="$(get_protocol_port "$proto")"
      owner="${MERGE_EXISTING_PORT_MAP[$port]}"
      printf '  - %s 使用端口 %s，与现有 inbound [%s] 冲突\n' "$(protocol_label "$proto")" "$port" "$owner"
    done
    for proto in "${conflicts[@]}"; do
      var="$(protocol_to_port_var "$proto")"
      label="$(protocol_label "$proto")"
      while true; do
        read -r -p "请为 ${label} 输入新的端口: " raw
        [[ "$raw" =~ ^[0-9]+$ ]] || { echo '[ERR] 端口必须是数字。' >&2; continue; }
        (( raw >= 1 && raw <= 65535 )) || { echo '[ERR] 端口必须在 1-65535。' >&2; continue; }
        if [[ -n "${MERGE_EXISTING_PORT_MAP[$raw]:-}" ]]; then
          echo "[ERR] 端口 $raw 与现有 inbound 冲突（${MERGE_EXISTING_PORT_MAP[$raw]}）。" >&2
          continue
        fi
        local duplicate=false
        for other in "${PROTOCOL_KEYS[@]}"; do
          [[ "$other" == "$proto" ]] && continue
          [[ "$(get_protocol_state "$other")" == true ]] || continue
          other_port="$(get_protocol_port "$other")"
          if [[ "$raw" == "$other_port" ]]; then
            duplicate=true
            echo "[ERR] 端口 $raw 与 $(protocol_label "$other") 冲突。" >&2
            break
          fi
        done
        [[ "$duplicate" == true ]] && continue
        printf -v "$var" '%s' "$raw"
        break
      done
    done
  done
}

merge_generated_inbounds_into_target_config() {
  local target_config="$1" generated_config="$2"
  python3 - "$target_config" "$generated_config" <<'PY'
import json
import os
import sys

target_path = sys.argv[1]
generated_path = sys.argv[2]

def load_json_relaxed(path):
    text = open(path, encoding='utf-8').read()
    out = []
    in_string = False
    escape = False
    line_comment = False
    block_comment = False
    i = 0
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ''
        if line_comment:
            if ch == '\n':
                line_comment = False
                out.append(ch)
        elif block_comment:
            if ch == '*' and nxt == '/':
                block_comment = False
                i += 1
        elif in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
        else:
            if ch == '/' and nxt == '/':
                line_comment = True
                i += 1
            elif ch == '/' and nxt == '*':
                block_comment = True
                i += 1
            else:
                out.append(ch)
                if ch == '"':
                    in_string = True
        i += 1
    cleaned = ''.join(out)
    out = []
    in_string = False
    escape = False
    i = 0
    while i < len(cleaned):
        ch = cleaned[i]
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_string = False
            i += 1
            continue
        if ch == '"':
            in_string = True
            out.append(ch)
            i += 1
            continue
        if ch == ',':
            j = i + 1
            while j < len(cleaned) and cleaned[j] in ' \t\r\n':
                j += 1
            if j < len(cleaned) and cleaned[j] in '}]':
                i += 1
                continue
        out.append(ch)
        i += 1
    return json.loads(''.join(out))

target = load_json_relaxed(target_path)
with open(generated_path, encoding='utf-8') as f:
    generated = json.load(f)

if not isinstance(target, dict) or not isinstance(target.get('inbounds'), list):
    raise SystemExit('target config has no top-level inbounds array')
if not isinstance(generated, dict) or not isinstance(generated.get('inbounds'), list):
    raise SystemExit('generated config has no top-level inbounds array')

generated_tags = {
    ib.get('tag')
    for ib in generated['inbounds']
    if isinstance(ib, dict) and isinstance(ib.get('tag'), str) and ib.get('tag')
}
if generated_tags:
    target['inbounds'] = [
        ib for ib in target['inbounds']
        if not (isinstance(ib, dict) and ib.get('tag') in generated_tags)
    ]
target['inbounds'].extend(generated['inbounds'])
tmp = target_path + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    json.dump(target, f, ensure_ascii=False, indent=2)
    f.write('\n')
os.replace(tmp, target_path)
PY
}

validate_merge_config() {
  if [[ "$MERGE_CONFIG_MODE" == "c" ]]; then
    "$TARGET_BIN" check -c "$MERGE_CONFIG_VALUE"
  else
    "$TARGET_BIN" check -C "$MERGE_CONFIG_VALUE"
  fi
}

apply_merge_mode_changes() {
  local generated_server_config="$ARTIFACT_DIR/server/config.json" service_was_active=false
  if systemctl is-active --quiet "$MERGE_SERVICE_NAME"; then
    service_was_active=true
  fi
  MERGE_TARGET_BACKUP="$BACKUP_DIR/merge-target-config.bak"
  cp -a "$MERGE_TARGET_CONFIG" "$MERGE_TARGET_BACKUP"
  merge_generated_inbounds_into_target_config "$MERGE_TARGET_CONFIG" "$generated_server_config"
  if ! validate_merge_config; then
    warn 'Merge-mode config validation failed; restoring target config from backup'
    cp -a "$MERGE_TARGET_BACKUP" "$MERGE_TARGET_CONFIG"
    die 'Merged config check failed and has been rolled back'
  fi
  if [[ "$service_was_active" == true ]]; then
    if ! systemctl restart "$MERGE_SERVICE_NAME"; then
      warn 'Restart failed after merge; restoring previous config and retrying original service state'
      cp -a "$MERGE_TARGET_BACKUP" "$MERGE_TARGET_CONFIG"
      systemctl restart "$MERGE_SERVICE_NAME" >/dev/null 2>&1 || systemctl start "$MERGE_SERVICE_NAME" >/dev/null 2>&1 || true
      die 'Merged config was rolled back because service restart failed'
    fi
  else
    if ! systemctl start "$MERGE_SERVICE_NAME"; then
      warn 'Service start failed after merge; restoring previous config'
      cp -a "$MERGE_TARGET_BACKUP" "$MERGE_TARGET_CONFIG"
      systemctl start "$MERGE_SERVICE_NAME" >/dev/null 2>&1 || true
      die 'Merged config was rolled back because service start failed'
    fi
  fi
  systemctl --no-pager --full status "$MERGE_SERVICE_NAME" || true
}
remove_acme_domain_artifacts() {
  local domain="$1"
  [[ -n "$domain" ]] || return 0
  [[ -d "$ACME_HOME" ]] || return 0
  rm -rf "$ACME_HOME/$domain" "$ACME_HOME/${domain}_ecc"
  rm -f "$ACME_HOME/${domain}.conf" "$ACME_HOME/${domain}_ecc.conf"
}
run_uninstall_flow() {
  local uninstall_acme_domain=""
  if [[ -f "$ACME_META_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ACME_META_FILE" || true
    uninstall_acme_domain="${ACME_DOMAIN:-}"
  fi
  if [[ "$BINARY_EXISTS" != true && "$SERVICE_EXISTS" != true && "$CONFIG_EXISTS" != true ]]; then
    warn '未检测到已安装的 sing-box 或相关配置'
  fi
  if ! { [[ "$RUN_UNINSTALL" == true && ! -t 0 ]] || prompt_yes_no_default_no '是否完全删除 sing-box、配置文件及 ACME 相关证书（brutal 不处理）？ [y/N]: '; }; then
    log '已取消卸载'
    return 0
  fi
  set +e
  systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  rm -f "$TARGET_BIN" "$TARGET_BIN_NEW"
  rm -rf "$CONFIG_DIR"
  remove_acme_domain_artifacts "$uninstall_acme_domain"
  systemctl daemon-reload >/dev/null 2>&1 || true
  set -e
  log '卸载完成：已删除 sing-box、service、配置目录及脚本管理的 ACME 域名证书数据'
}
run_export_only_flow() {
  local artifacts_base="$CONFIG_DIR/deploy-artifacts"
  local latest="" candidate
  [[ -d "$artifacts_base" ]] || die "未找到可导出的客户端产物目录：$artifacts_base（请先完成一次安装/更新）"
  while IFS= read -r candidate; do
    if [[ -f "$candidate/client/hy2-singbox-outbound.json" || -f "$candidate/client/ss-singbox-outbound.json" || -f "$candidate/client/trojan-singbox-outbound.json" || -f "$candidate/client/anytls-singbox-outbound.json" || -f "$candidate/client/vless-grpc-reality-singbox-outbound.json" || -f "$candidate/client/vless-brutal-reality-singbox-outbound.json" || -f "$candidate/client/hy2-mihomo-proxy.yaml" || -f "$candidate/client/ss-mihomo-proxy.yaml" || -f "$candidate/client/trojan-mihomo-proxy.yaml" || -f "$candidate/client/anytls-mihomo-proxy.yaml" || -f "$candidate/client/vless-grpc-reality-mihomo-proxy.yaml" || -f "$candidate/client/vless-brutal-reality-mihomo-proxy.yaml" ]]; then
      latest="$candidate"
      break
    fi
  done < <(find "$artifacts_base" -mindepth 1 -maxdepth 1 -type d | sort -r)
  [[ -n "$latest" ]] || die "未在 $artifacts_base 找到包含客户端片段的产物目录"
  ARTIFACT_DIR="$latest"
  log "导出节点信息模式：复用最近可用产物目录 $ARTIFACT_DIR"
  collect_generated_client_snippets
  if (( ${#CLIENT_SB_SNIPPETS[@]} == 0 && ${#CLIENT_CLASH_SNIPPETS[@]} == 0 )); then
    die '未发现可导出的客户端节点片段'
  fi
  if (( ${#CLIENT_SB_SNIPPETS[@]} > 0 )); then
    show_client_snippets '以下为 sing-box 节点信息：' "${CLIENT_SB_SNIPPETS[@]}"
  fi
  if (( ${#CLIENT_CLASH_SNIPPETS[@]} > 0 )); then
    show_client_snippets '以下为 clash/mihomo 节点信息：' "${CLIENT_CLASH_SNIPPETS[@]}"
  fi
  if prompt_export_destination_if_needed; then
    if (( ${#CLIENT_SB_SNIPPETS[@]} > 0 )); then
      export_singbox_nodes_to_root "$EXPORT_NODE_DIR"
    fi
    if (( ${#CLIENT_CLASH_SNIPPETS[@]} > 0 )); then
      export_clash_nodes_to_root "$EXPORT_NODE_DIR"
    fi
  fi
  return 0
}
show_incremental_plan() {
  if [[ "$DEPLOY_MODE" == "merge" ]]; then
    printf '配置增量计划：\n'
    printf '  - 目标配置已识别协议：%s\n' "$(format_protocol_list "${MERGE_DETECTED_PROTOCOLS[@]}")"
    printf '  - 本次拟新增协议：%s\n' "$(format_protocol_list "${TARGET_PROTOCOLS[@]}")"
    return 0
  fi
  printf '配置增量计划：\n'
  printf '  - 当前已配置：%s\n' "$(format_protocol_list "${CURRENT_PROTOCOLS[@]}")"
  printf '  - 拟新增协议：%s\n' "$(format_protocol_list "${ADD_PROTOCOLS[@]}")"
  printf '  - 已存在并保留：%s\n' "$(format_protocol_list "${KEEP_PROTOCOLS[@]}")"
  printf '  - 未选但仍保留：%s\n' "$(format_protocol_list "${EXISTING_NOT_SELECTED_PROTOCOLS[@]}")"
}
collect_reset_certificates_if_needed() {
  RESET_CERTS=false
  (array_contains trojan "${RESET_PROTOCOLS[@]}" || array_contains anytls "${RESET_PROTOCOLS[@]}") || return 0
  [[ -f "$TROJAN_CERT_FILE" && -f "$TROJAN_KEY_FILE" ]] || return 0
  prompt_yes_no_default_no '检测到已有 Trojan/AnyTLS 证书，是否重置证书并重新申请？ [y/N]: ' && RESET_CERTS=true || true
}
collect_reset_protocols_if_needed() {
  local raw proto item
  RESET_PROTOCOLS=()
  (( ${#KEEP_PROTOCOLS[@]} > 0 )) || return 0
  prompt_yes_no_default_no '是否重置已有协议？ [y/N]: ' || return 0
  printf '可重置协议（编号如下）：\n'
  array_contains hy2 "${KEEP_PROTOCOLS[@]}" && printf '  1) Hysteria2\n'
  array_contains ss "${KEEP_PROTOCOLS[@]}" && printf '  2) Shadowsocks\n'
  array_contains vgr "${KEEP_PROTOCOLS[@]}" && printf '  3) VLESS gRPC Reality\n'
  array_contains trojan "${KEEP_PROTOCOLS[@]}" && printf '  4) Trojan\n'
  array_contains anytls "${KEEP_PROTOCOLS[@]}" && printf '  5) AnyTLS\n'
  array_contains vbr "${KEEP_PROTOCOLS[@]}" && printf '  6) VLESS Brutal Reality\n'
  printf '  7) 重置上述全部协议\n'
  read -r -p '输入要重置的协议编号（示例：2,3 或 7；回车默认不重置）: ' raw
  raw="${raw// /}"
  [[ -n "$raw" ]] || return 0
  IFS=',' read -r -a items <<< "$raw"
  for item in "${items[@]}"; do
    case "$item" in
      1) proto=hy2 ;;
      2) proto=ss ;;
      3) proto=vgr ;;
      4) proto=trojan ;;
      5) proto=anytls ;;
      6) proto=vbr ;;
      7)
        RESET_PROTOCOLS=("${KEEP_PROTOCOLS[@]}")
        return 0
        ;;
      *) die '只允许输入 1-7 的协议编号' ;;
    esac
    array_contains "$proto" "${KEEP_PROTOCOLS[@]}" || die "协议 $(protocol_label "$proto") 不在可重置列表中"
    array_contains "$proto" "${RESET_PROTOCOLS[@]}" || RESET_PROTOCOLS+=("$proto")
  done
}
needs_protocol_inputs() { array_contains "$1" "${ADD_PROTOCOLS[@]}" || array_contains "$1" "${RESET_PROTOCOLS[@]}"; }
acme_reissue_required() {
  ! acme_protocol_needed && return 1
  [[ "$RESET_CERTS" == true ]] && return 0
  [[ -f "$TROJAN_CERT_FILE" && -f "$TROJAN_KEY_FILE" ]] || return 0
  return 1
}
collect_host_if_needed() {
  prompt_if_empty HOST 'DDNS 域名 / 公网 IP（用于申请证书，并将复用为客户端 server）'
}
collect_protocol_specific_inputs() {
  EXISTING_ACME_DOMAIN=''
  if [[ -f "$ACME_META_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ACME_META_FILE" || true
    EXISTING_ACME_DOMAIN="${ACME_DOMAIN:-}"
  fi
  if [[ "$RESET_CERTS" == true ]]; then
    # Reset cert means old ACME domain must not silently override the new DDNS/domain input.
    ACME_DOMAIN=''
  fi
  if [[ -z "$HOST" && "$RESET_CERTS" != true && -n "${ACME_DOMAIN:-}" && -f "$TROJAN_CERT_FILE" && -f "$TROJAN_KEY_FILE" ]]; then
    HOST="$ACME_DOMAIN"
    log "Reusing existing certificate domain as host: $HOST"
  fi
  collect_host_if_needed
  collect_interactive_ports
  if acme_reissue_required; then
    prompt_if_empty ACME_DOMAIN '证书域名（默认复用 DDNS 域名）' "$HOST"
    prompt_if_empty CF_KEY 'Cloudflare CF_Key（Global API Key）'
    prompt_if_empty CF_EMAIL 'Cloudflare CF_Email'
    prompt_if_empty ACME_EMAIL 'acme 注册邮箱（回车默认复用 CF_Email）' "${ACME_EMAIL:-$CF_EMAIL}"
  fi
}
purge_existing_acme_materials_if_needed() {
  [[ "$RESET_CERTS" == true ]] || return 0
  local old_domain="${EXISTING_ACME_DOMAIN:-}"
  log 'Reset certificate selected: cleaning existing ACME metadata and managed cert files'
  rm -rf "$DEFAULT_TLS_CERT_DIR"
  mkdir -p "$DEFAULT_TLS_CERT_DIR"
  rm -f "$ACME_META_FILE"
  remove_acme_domain_artifacts "$old_domain"
}
reset_protocol_credentials_if_needed() { local proto; for proto in "${RESET_PROTOCOLS[@]}"; do case "$proto" in hy2) HY2_PASSWORD='' ;; ss) PASSWORD='' ;; trojan) TROJAN_PASSWORD='' ; ACCESS_UUID='' ;; anytls) ANYTLS_PASSWORD='' ; ACCESS_UUID='' ;; vgr) VGR_UUID='' ; VGR_SHORT_ID='' ; VGR_PRIVATE_KEY='' ; VGR_PUBLIC_KEY='' ;; vbr) VBR_UUID='' ; VBR_SHORT_ID='' ; VBR_PRIVATE_KEY='' ; VBR_PUBLIC_KEY='' ;; esac; done; }
write_installer_state() { local tmp="$WORK_ROOT/installer-state.json" proto first key value pair; mkdir -p "$(dirname "$INSTALLER_STATE_FILE")"; { printf '{\n  "script_version": "%s",\n  "deployed_at": "%s",\n  "enabled_protocols": [' "$INSTALLER_STATE_VERSION" "$(date -Iseconds)"; first=true; for proto in "${TARGET_PROTOCOLS[@]}"; do [[ "$first" == true ]] && first=false || printf ', '; printf '"%s"' "$proto"; done; printf '],\n  "ports": {'; first=true; for proto in "${TARGET_PROTOCOLS[@]}"; do [[ "$first" == true ]] && first=false || printf ', '; printf '"%s": %s' "$proto" "$(get_protocol_port "$proto")"; done; printf '},\n  "shared_credentials": {'; first=true; for pair in "access_uuid:${ACCESS_UUID:-}" "vless_uuid:${VGR_UUID:-}" "reality_short_id:${VGR_SHORT_ID:-}" "reality_public_key:${VGR_PUBLIC_KEY:-}"; do key="${pair%%:*}"; value="${pair#*:}"; [[ -n "$value" ]] || continue; [[ "$first" == true ]] && first=false || printf ', '; printf '"%s": "%s"' "$key" "$value"; done; printf '},\n  "paths": {'; first=true; for pair in "hy2_key:$HY2_KEY_FILE" "hy2_cert:$HY2_CERT_PEM" "default_tls_cert:$TROJAN_CERT_FILE" "default_tls_key:$TROJAN_KEY_FILE" "shared_secret_env:$SHARED_SECRET_ENV_FILE" "vgr_env:$VGR_ENV_FILE"; do key="${pair%%:*}"; value="${pair#*:}"; [[ "$first" == true ]] && first=false || printf ', '; printf '"%s": "%s"' "$key" "$value"; done; printf '}\n}\n'; } > "$tmp"; install -m 0644 "$tmp" "$INSTALLER_STATE_FILE"; }

HOST=""
HAD_CLI_ARGS=false
[[ $# -gt 0 ]] && HAD_CLI_ARGS=true
RUN_UNINSTALL=false
ENABLE_SS=true; ENABLE_SS_SOURCE=default; PORT=55502; NAME="home"; METHOD="2022-blake3-aes-128-gcm"; PASSWORD=""
VERSION=latest; LISTEN='::'; HOME_CIDRS='10.0.0.0/24,192.168.2.0/24'; TG_RULE_SET='geoip-tg'; ENABLE_FAKEIP=false; ENABLE_TGIP=false
ENABLE_HY2=true; ENABLE_HY2_SOURCE=default; HY2_PORT=55501; HY2_PASSWORD=''; HY2_SNI='bing.com'
ENABLE_TROJAN=false; ENABLE_TROJAN_SOURCE=default; TROJAN_PORT=55503; TROJAN_PASSWORD=''
ENABLE_ANYTLS=false; ENABLE_ANYTLS_SOURCE=default; ANYTLS_PORT=55504; ANYTLS_PASSWORD=''
ENABLE_VGR=true; ENABLE_VGR_SOURCE=default; VGR_PORT=55505; VGR_UUID=''; VGR_SERVER_NAME='www.huawei.com'; VGR_SERVICE_NAME='Huawei.SmartHome.Connect'; VGR_SHORT_ID=''; VGR_PRIVATE_KEY=''; VGR_PUBLIC_KEY=''
ENABLE_VBR=false; ENABLE_VBR_SOURCE=default; VBR_PORT=55506; VBR_UUID=''; VBR_SERVER_NAME='www.huawei.com'; VBR_SHORT_ID=''; VBR_PRIVATE_KEY=''; VBR_PUBLIC_KEY=''; VBR_UP_MBPS=1000; VBR_DOWN_MBPS=1000
ACME_DOMAIN=''; CF_KEY=''; CF_EMAIL=''; ACME_EMAIL=''
BIN_DIR='/usr/local/bin'; CONFIG_DIR='/usr/local/etc/sing-box'; SERVICE_NAME='sing-box'; WORK_BASE='/tmp'; DOWNLOAD_URL=''; FORCE_DOWNLOAD=false; FORCE_BINARY_UPDATE=false; USER_ARTIFACT_DIR=''; USER_BACKUP_DIR=''; USER_ACME_HOME=''; USER_CERT_BASE_DIR=''
VERBOSE_OUTPUT=false
RESET_CERTS=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) require_value "$1" "${2-}"; HOST="$2"; shift 2 ;;
    --enable-shadowsocks) ENABLE_SS=true; ENABLE_SS_SOURCE=flag; shift ;;
    --disable-shadowsocks) ENABLE_SS=false; ENABLE_SS_SOURCE=flag; shift ;;
    --port) require_value "$1" "${2-}"; PORT="$2"; shift 2 ;;
    --name) require_value "$1" "${2-}"; NAME="$2"; shift 2 ;;
    --method) require_value "$1" "${2-}"; METHOD="$2"; shift 2 ;;
    --password) require_value "$1" "${2-}"; PASSWORD="$2"; shift 2 ;;
    --version) require_value "$1" "${2-}"; VERSION="$2"; shift 2 ;;
    --listen) require_value "$1" "${2-}"; LISTEN="$2"; shift 2 ;;
    --home-cidrs) require_value "$1" "${2-}"; HOME_CIDRS="$2"; shift 2 ;;
    --tg-rule-set) require_value "$1" "${2-}"; TG_RULE_SET="$2"; shift 2 ;;
    --enable-fakeip) ENABLE_FAKEIP=true; shift ;;
    --disable-fakeip) ENABLE_FAKEIP=false; shift ;;
    --enable-tgip) ENABLE_TGIP=true; shift ;;
    --disable-tgip) ENABLE_TGIP=false; shift ;;

    --enable-hy2) ENABLE_HY2=true; ENABLE_HY2_SOURCE=flag; shift ;;
    --disable-hy2) ENABLE_HY2=false; ENABLE_HY2_SOURCE=flag; shift ;;
    --hy2-port) require_value "$1" "${2-}"; HY2_PORT="$2"; shift 2 ;;
    --hy2-password) require_value "$1" "${2-}"; HY2_PASSWORD="$2"; shift 2 ;;
    --hy2-sni) require_value "$1" "${2-}"; HY2_SNI="$2"; shift 2 ;;

    --enable-trojan) ENABLE_TROJAN=true; ENABLE_TROJAN_SOURCE=flag; shift ;;
    --disable-trojan) ENABLE_TROJAN=false; ENABLE_TROJAN_SOURCE=flag; shift ;;
    --trojan-port) require_value "$1" "${2-}"; TROJAN_PORT="$2"; shift 2 ;;
    --trojan-password) require_value "$1" "${2-}"; TROJAN_PASSWORD="$2"; shift 2 ;;

    --enable-anytls) ENABLE_ANYTLS=true; ENABLE_ANYTLS_SOURCE=flag; shift ;;
    --disable-anytls) ENABLE_ANYTLS=false; ENABLE_ANYTLS_SOURCE=flag; shift ;;
    --anytls-port) require_value "$1" "${2-}"; ANYTLS_PORT="$2"; shift 2 ;;
    --anytls-password) require_value "$1" "${2-}"; ANYTLS_PASSWORD="$2"; shift 2 ;;

    --enable-vless-grpc-reality) ENABLE_VGR=true; ENABLE_VGR_SOURCE=flag; shift ;;
    --disable-vless-grpc-reality) ENABLE_VGR=false; ENABLE_VGR_SOURCE=flag; shift ;;
    --vless-grpc-reality-port) require_value "$1" "${2-}"; VGR_PORT="$2"; shift 2 ;;
    --vless-grpc-reality-uuid) require_value "$1" "${2-}"; VGR_UUID="$2"; shift 2 ;;
    --vless-grpc-reality-server-name) require_value "$1" "${2-}"; VGR_SERVER_NAME="$2"; shift 2 ;;
    --vless-grpc-reality-service-name) require_value "$1" "${2-}"; VGR_SERVICE_NAME="$2"; shift 2 ;;
    --vless-grpc-reality-short-id) require_value "$1" "${2-}"; VGR_SHORT_ID="$2"; shift 2 ;;

    --enable-vless-brutal-reality) ENABLE_VBR=true; ENABLE_VBR_SOURCE=flag; shift ;;
    --disable-vless-brutal-reality) ENABLE_VBR=false; ENABLE_VBR_SOURCE=flag; shift ;;
    --vless-brutal-reality-port) require_value "$1" "${2-}"; VBR_PORT="$2"; shift 2 ;;
    --vless-brutal-reality-uuid) require_value "$1" "${2-}"; VBR_UUID="$2"; shift 2 ;;
    --vless-brutal-reality-server-name) require_value "$1" "${2-}"; VBR_SERVER_NAME="$2"; shift 2 ;;
    --vless-brutal-reality-short-id) require_value "$1" "${2-}"; VBR_SHORT_ID="$2"; shift 2 ;;
    --vless-brutal-reality-up-mbps) require_value "$1" "${2-}"; VBR_UP_MBPS="$2"; shift 2 ;;
    --vless-brutal-reality-down-mbps) require_value "$1" "${2-}"; VBR_DOWN_MBPS="$2"; shift 2 ;;

    --acme-domain) require_value "$1" "${2-}"; ACME_DOMAIN="$2"; shift 2 ;;
    --cf-key) require_value "$1" "${2-}"; CF_KEY="$2"; shift 2 ;;
    --cf-email) require_value "$1" "${2-}"; CF_EMAIL="$2"; shift 2 ;;
    --acme-email) require_value "$1" "${2-}"; ACME_EMAIL="$2"; shift 2 ;;
    --acme-home) require_value "$1" "${2-}"; USER_ACME_HOME="$2"; shift 2 ;;
    --cert-base-dir) require_value "$1" "${2-}"; USER_CERT_BASE_DIR="$2"; shift 2 ;;

    --bin-dir) require_value "$1" "${2-}"; BIN_DIR="$2"; shift 2 ;;
    --config-dir) require_value "$1" "${2-}"; CONFIG_DIR="$2"; shift 2 ;;
    --service-name) require_value "$1" "${2-}"; SERVICE_NAME="$2"; shift 2 ;;
    --merge-into-existing) DEPLOY_MODE='merge'; DEPLOY_MODE_SOURCE='flag'; shift ;;
    --standalone) DEPLOY_MODE='standalone'; DEPLOY_MODE_SOURCE='flag'; shift ;;
    --merge-config-dir) require_value "$1" "${2-}"; MERGE_CONFIG_DIR_HINT="$2"; shift 2 ;;
    --merge-service-name) require_value "$1" "${2-}"; MERGE_SERVICE_NAME_HINT="$2"; shift 2 ;;
    --artifact-dir) require_value "$1" "${2-}"; USER_ARTIFACT_DIR="$2"; shift 2 ;;
    --backup-dir) require_value "$1" "${2-}"; USER_BACKUP_DIR="$2"; shift 2 ;;
    --work-dir) require_value "$1" "${2-}"; WORK_BASE="$2"; shift 2 ;;
    --download-url) require_value "$1" "${2-}"; DOWNLOAD_URL="$2"; shift 2 ;;
    --force-download) FORCE_DOWNLOAD=true; shift ;;
    --force-binary-update) FORCE_BINARY_UPDATE=true; shift ;;
    --uninstall) RUN_UNINSTALL=true; shift ;;
    --verbose-output) VERBOSE_OUTPUT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

validate_positive_int "$VBR_UP_MBPS"; validate_positive_int "$VBR_DOWN_MBPS"
if [[ "$ENABLE_HY2" != true && "$ENABLE_SS" != true && "$ENABLE_TROJAN" != true && "$ENABLE_ANYTLS" != true && "$ENABLE_VGR" != true && "$ENABLE_VBR" != true ]]; then die 'At least one protocol must be enabled'; fi
[[ "$VERSION" == latest || "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid --version: $VERSION"
[[ "$SERVICE_NAME" =~ ^[A-Za-z0-9._@-]+$ ]] || die "Invalid --service-name: $SERVICE_NAME"
[[ "$NAME" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid --name: $NAME"
[[ "$(id -u)" -eq 0 ]] || die 'This installer must run as root'
require_command uname; require_command tar; require_command mktemp; require_command install; require_command systemctl
[[ "$ENABLE_HY2" == true ]] && require_command openssl
acme_protocol_needed && require_command apt-get

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GEN_SCRIPT="$SCRIPT_DIR/generate-sing-box-config.sh"
[[ -x "$GEN_SCRIPT" ]] || die "Generator script not found or not executable: $GEN_SCRIPT"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
WORK_ROOT="$(mktemp -d "$WORK_BASE/install-home.XXXXXX")"
EXTRACT_DIR="$WORK_ROOT/extract"
mkdir -p "$EXTRACT_DIR" "$CONFIG_DIR"
ARTIFACT_DIR="${USER_ARTIFACT_DIR:-$CONFIG_DIR/deploy-artifacts/${TIMESTAMP}-${NAME}}"
BACKUP_DIR="${USER_BACKUP_DIR:-$CONFIG_DIR/backups/${TIMESTAMP}-${SERVICE_NAME}}"
mkdir -p "$ARTIFACT_DIR" "$BACKUP_DIR"
DOWNLOADER="$(pick_downloader)"; ARCH="$(arch_to_singbox "$(uname -m)")"; OS=linux
RELEASE_BIN=''
prepare_release_binary() {
  [[ -n "$RELEASE_BIN" && -f "$RELEASE_BIN" ]] && return 0
  [[ "$VERSION" == latest ]] && VERSION="$(resolve_latest_version)"
  PKG_NAME="sing-box-${VERSION}-${OS}-${ARCH}"; TARBALL="$WORK_ROOT/${PKG_NAME}.tar.gz"
  [[ -n "$DOWNLOAD_URL" ]] || DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/${PKG_NAME}.tar.gz"
  log "Preparing sing-box $VERSION from: $DOWNLOAD_URL"
  if [[ "$FORCE_DOWNLOAD" == true || ! -f "$TARBALL" ]]; then download_file "$DOWNLOAD_URL" "$TARBALL"; fi
  log 'Extracting release package'
  tar -xzf "$TARBALL" -C "$EXTRACT_DIR"
  RELEASE_DIR="$(find "$EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
  [[ -n "$RELEASE_DIR" ]] || die 'Unable to locate extracted release dir'
  RELEASE_BIN="$RELEASE_DIR/sing-box"
  [[ -f "$RELEASE_BIN" ]] || die 'sing-box binary not found after extraction'
  chmod 0755 "$RELEASE_BIN"
}
TARGET_BIN="$BIN_DIR/sing-box"; TARGET_BIN_NEW="$TARGET_BIN.new"; SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"; TARGET_CONFIG="$CONFIG_DIR/config.json"
INSTALLER_STATE_FILE="$CONFIG_DIR/installer-state.json"
CREDENTIALS_DIR="$CONFIG_DIR/credentials"; VGR_ENV_FILE="$CREDENTIALS_DIR/vless-grpc-reality.env"; VBR_ENV_FILE="$CREDENTIALS_DIR/vless-brutal-reality.env"; SHARED_SECRET_ENV_FILE="$CREDENTIALS_DIR/shared-secrets.env"; ACME_META_FILE="$CREDENTIALS_DIR/acme.env"
CERT_BASE_DIR="${USER_CERT_BASE_DIR:-$CONFIG_DIR/certs}"; DEFAULT_TLS_CERT_DIR="$CERT_BASE_DIR/default"; HY2_CERT_DIR="$CERT_BASE_DIR/hysteria"
HY2_KEY_FILE="$HY2_CERT_DIR/private.key"; HY2_CERT_PEM="$HY2_CERT_DIR/cert.pem"; HY2_CERT_CRT="$HY2_CERT_DIR/cert.crt"
TROJAN_KEY_FILE="$DEFAULT_TLS_CERT_DIR/private.key"; TROJAN_CERT_FILE="$DEFAULT_TLS_CERT_DIR/cert.crt"; ANYTLS_KEY_FILE="$DEFAULT_TLS_CERT_DIR/private.key"; ANYTLS_CERT_FILE="$DEFAULT_TLS_CERT_DIR/cert.crt"
ACME_HOME="${USER_ACME_HOME:-/root/.acme.sh}"; ACME_BIN="$ACME_HOME/acme.sh"
mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$CREDENTIALS_DIR" "$CERT_BASE_DIR" "$DEFAULT_TLS_CERT_DIR" "$HY2_CERT_DIR"
CURRENT_PROTOCOLS=(); KEEP_PROTOCOLS=(); ADD_PROTOCOLS=(); EXISTING_NOT_SELECTED_PROTOCOLS=(); RESET_PROTOCOLS=(); DELETE_PROTOCOLS=(); TARGET_PROTOCOLS=(); PORT_PROMPT_PROTOCOLS=(); PARSED_PROTOCOLS=()
PROTOCOL_ACTION_MODE=''; INTERACTIVE_PROTOCOL_ACTION_SELECTED=false
BINARY_EXISTS=false; SERVICE_EXISTS=false; SERVICE_ACTIVE=false; CONFIG_EXISTS=false; SHOULD_UPDATE_BINARY=true
[[ -x "$TARGET_BIN" ]] && BINARY_EXISTS=true
service_exists && SERVICE_EXISTS=true || true
if [[ "$SERVICE_EXISTS" == true ]]; then service_active && SERVICE_ACTIVE=true || true; fi
[[ -f "$TARGET_CONFIG" ]] && CONFIG_EXISTS=true
if [[ "$RUN_UNINSTALL" == true ]]; then
  run_uninstall_flow
  exit 0
fi
show_main_menu_if_needed
collect_deploy_mode_if_needed
if [[ "$DEPLOY_MODE" == "merge" ]]; then
  setup_merge_mode_target
  BINARY_EXISTS=false; SERVICE_EXISTS=false; SERVICE_ACTIVE=false; CONFIG_EXISTS=false
  [[ -x "$TARGET_BIN" ]] && BINARY_EXISTS=true
  service_exists && SERVICE_EXISTS=true || true
  if [[ "$SERVICE_EXISTS" == true ]]; then service_active && SERVICE_ACTIVE=true || true; fi
  [[ -f "$TARGET_CONFIG" ]] && CONFIG_EXISTS=true
  SHOULD_UPDATE_BINARY=false
fi
load_existing_state
if [[ "$DEPLOY_MODE" == "merge" ]]; then
  MERGE_DETECTED_PROTOCOLS=("${CURRENT_PROTOCOLS[@]}")
else
  apply_existing_protocol_ports
  load_existing_protocol_runtime_values
fi
show_environment_status
if [[ "$DEPLOY_MODE" == "standalone" && "$BINARY_EXISTS" == true && "$SERVICE_EXISTS" == true && "$SERVICE_ACTIVE" == true ]]; then
  if [[ "$FORCE_BINARY_UPDATE" == true ]]; then
    SHOULD_UPDATE_BINARY=true
    log 'Existing sing-box detected; forcing binary update because --force-binary-update was provided'
  else
    SHOULD_UPDATE_BINARY=false
    if prompt_yes_no_default_no '检测到已安装并运行 sing-box，是否覆盖更新二进制？ [y/N]: '; then SHOULD_UPDATE_BINARY=true; fi
  fi
fi
if interactive_mode && ! protocol_flags_provided; then
  if [[ "$DEPLOY_MODE" == "standalone" && ${#CURRENT_PROTOCOLS[@]} -gt 0 ]]; then
    collect_interactive_existing_protocol_action
  else
    collect_interactive_protocol_selection
  fi
fi
if [[ "$DEPLOY_MODE" == "merge" ]]; then
  CURRENT_PROTOCOLS=()
  unset CURRENT_PROTOCOL_PORTS
  declare -gA CURRENT_PROTOCOL_PORTS=()
fi
if [[ "$INTERACTIVE_PROTOCOL_ACTION_SELECTED" != true ]]; then
  apply_incremental_protocol_plan
  show_incremental_plan
  collect_reset_protocols_if_needed
fi
collect_reset_certificates_if_needed
collect_protocol_specific_inputs
validate_unique_enabled_ports
if [[ "$DEPLOY_MODE" == "merge" ]]; then
  validate_ports_against_merge_target
fi
reset_protocol_credentials_if_needed
if [[ "$DEPLOY_MODE" == "standalone" ]]; then
  backup_target "$TARGET_CONFIG" config; backup_target "$SERVICE_FILE" service; backup_target "$INSTALLER_STATE_FILE" installer-state; backup_target "$VGR_ENV_FILE" vgr-env; backup_target "$VBR_ENV_FILE" vbr-env; backup_target "$SHARED_SECRET_ENV_FILE" shared-secret-env; backup_target "$ACME_META_FILE" acme-meta; backup_target "$HY2_KEY_FILE" hy2-key; backup_target "$HY2_CERT_PEM" hy2-cert-pem; backup_target "$HY2_CERT_CRT" hy2-cert-crt; backup_target "$DEFAULT_TLS_CERT_DIR" default-cert-dir; backup_target "$HY2_CERT_DIR" hysteria-cert-dir; backup_target "$ACME_HOME" acme-home
  if [[ "$SHOULD_UPDATE_BINARY" == true ]]; then backup_target "$TARGET_BIN" binary; else touch "$BACKUP_DIR/binary.absent"; fi
  ROLLBACK_ACTIVE=true
else
  ROLLBACK_ACTIVE=false
fi

if [[ "$DEPLOY_MODE" == "standalone" && "$SHOULD_UPDATE_BINARY" == true ]]; then
  prepare_release_binary
  log "Installing sing-box binary to $TARGET_BIN"
  install -m 0755 "$RELEASE_BIN" "$TARGET_BIN_NEW"
  mv -f "$TARGET_BIN_NEW" "$TARGET_BIN"
elif [[ "$DEPLOY_MODE" == "standalone" ]]; then
  log 'Skipping sing-box binary download/replace; keeping existing binary'
else
  log "Merge mode: keep existing binary at $TARGET_BIN"
fi

[[ -x "$TARGET_BIN" ]] || die "sing-box binary not found at $TARGET_BIN"

if [[ "$ENABLE_HY2" == true ]]; then
  generate_hy2_cert_if_needed
fi
if [[ "$ENABLE_VGR" == true || "$ENABLE_VBR" == true ]]; then prepare_reality_credentials; fi
if [[ "$ENABLE_TROJAN" == true || "$ENABLE_ANYTLS" == true ]]; then prepare_trojan_anytls_passwords; fi
purge_existing_acme_materials_if_needed
if acme_reissue_required; then
  if {
    install_acme_dependencies
    install_or_reuse_acmesh
    ensure_acme_account
    write_acme_meta
    issue_or_install_acme_cert "$DEFAULT_TLS_CERT_DIR" "$TROJAN_KEY_FILE" "$TROJAN_CERT_FILE"
  }; then
    log 'ACME 证书申请/安装完成'
  else
    warn 'ACME 证书申请失败，将跳过依赖证书的协议并继续安装其他协议'
    mark_acme_failed_protocols_skipped
  fi
elif acme_protocol_needed; then
  log 'Trojan / AnyTLS 仅保留现有配置，复用已有证书，不重新申请 ACME 证书'
fi

if [[ -f "$SHARED_SECRET_ENV_FILE" ]]; then # shellcheck disable=SC1090
  source "$SHARED_SECRET_ENV_FILE"
fi
if [[ -f "$VGR_ENV_FILE" ]]; then # shellcheck disable=SC1090
  source "$VGR_ENV_FILE"
fi

if [[ "$ENABLE_VBR" == true ]]; then
  VBR_UUID="${VBR_UUID:-${VGR_UUID:-}}"
  VBR_SHORT_ID="${VBR_SHORT_ID:-${VGR_SHORT_ID:-}}"
  VBR_SERVER_NAME="${VBR_SERVER_NAME:-www.huawei.com}"
  prepare_vbr_or_skip
else
  VBR_SERVER_NAME="${VBR_SERVER_NAME:-www.huawei.com}"
fi

GEN_ARGS=(
  --host "$HOST" --name "$NAME" --listen "$LISTEN" --outdir "$ARTIFACT_DIR" --sing-box-bin "$TARGET_BIN" --service-config-path "$TARGET_CONFIG" --service-bin "$TARGET_BIN" --home-cidrs "$HOME_CIDRS" --tg-rule-set "$TG_RULE_SET"
)
[[ "$ENABLE_FAKEIP" == true ]] && GEN_ARGS+=(--enable-fakeip) || GEN_ARGS+=(--disable-fakeip)
[[ "$ENABLE_TGIP" == true ]] && GEN_ARGS+=(--enable-tgip) || GEN_ARGS+=(--disable-tgip)
if [[ "$ENABLE_HY2" == true ]]; then GEN_ARGS+=(--enable-hy2 --hy2-port "$HY2_PORT" --hy2-sni "$HY2_SNI" --hy2-cert-path "$HY2_CERT_PEM" --hy2-key-path "$HY2_KEY_FILE"); [[ -n "$HY2_PASSWORD" ]] && GEN_ARGS+=(--hy2-password "$HY2_PASSWORD"); else GEN_ARGS+=(--disable-hy2); fi
if [[ "$ENABLE_SS" == true ]]; then GEN_ARGS+=(--enable-shadowsocks --port "$PORT" --method "$METHOD"); [[ -n "$PASSWORD" ]] && GEN_ARGS+=(--password "$PASSWORD"); else GEN_ARGS+=(--disable-shadowsocks); fi
if [[ "$ENABLE_TROJAN" == true ]]; then GEN_ARGS+=(--enable-trojan --trojan-port "$TROJAN_PORT" --trojan-password "$TROJAN_PASSWORD" --trojan-server-name "${ACME_DOMAIN:-$HOST}" --trojan-cert-path "$TROJAN_CERT_FILE" --trojan-key-path "$TROJAN_KEY_FILE"); else GEN_ARGS+=(--disable-trojan); fi
if [[ "$ENABLE_ANYTLS" == true ]]; then GEN_ARGS+=(--enable-anytls --anytls-port "$ANYTLS_PORT" --anytls-password "$ANYTLS_PASSWORD" --anytls-server-name "${ACME_DOMAIN:-$HOST}" --anytls-cert-path "$ANYTLS_CERT_FILE" --anytls-key-path "$ANYTLS_KEY_FILE"); else GEN_ARGS+=(--disable-anytls); fi
if [[ "$ENABLE_VGR" == true ]]; then GEN_ARGS+=(--enable-vless-grpc-reality --vless-grpc-reality-port "$VGR_PORT" --vless-grpc-reality-server-name "$VGR_SERVER_NAME" --vless-grpc-reality-service-name "$VGR_SERVICE_NAME" --vless-grpc-reality-private-key "$VGR_PRIVATE_KEY" --vless-grpc-reality-public-key "$VGR_PUBLIC_KEY" --vless-grpc-reality-short-id "$VGR_SHORT_ID" --vless-grpc-reality-uuid "$VGR_UUID"); else GEN_ARGS+=(--disable-vless-grpc-reality); fi
if [[ "$ENABLE_VBR" == true ]]; then GEN_ARGS+=(--enable-vless-brutal-reality --vless-brutal-reality-port "$VBR_PORT" --vless-brutal-reality-server-name "$VBR_SERVER_NAME" --vless-brutal-reality-private-key "$VBR_PRIVATE_KEY" --vless-brutal-reality-public-key "$VBR_PUBLIC_KEY" --vless-brutal-reality-short-id "$VBR_SHORT_ID" --vless-brutal-reality-uuid "$VBR_UUID" --vless-brutal-reality-up-mbps "$VBR_UP_MBPS" --vless-brutal-reality-down-mbps "$VBR_DOWN_MBPS"); else GEN_ARGS+=(--disable-vless-brutal-reality); fi

log 'Generating deployment bundle via generate-sing-box-config.sh'
"$GEN_SCRIPT" "${GEN_ARGS[@]}"
[[ -f "$ARTIFACT_DIR/server/config.json" ]] || die 'Generated config missing'
[[ -f "$ARTIFACT_DIR/server/sing-box.service" ]] || die 'Generated service file missing'
[[ -f "$ARTIFACT_DIR/manifest.json" ]] || die 'Generated manifest missing'

if [[ "$ENABLE_SS" == true && -z "$PASSWORD" ]]; then PASSWORD="$(python3 - <<PY
import json
print(json.load(open('$ARTIFACT_DIR/manifest.json'))['protocols']['shadowsocks']['password'])
PY
)"; fi
if [[ "$ENABLE_HY2" == true && -z "$HY2_PASSWORD" ]]; then HY2_PASSWORD="$(python3 - <<PY
import json
print(json.load(open('$ARTIFACT_DIR/manifest.json'))['protocols']['hysteria2']['password'])
PY
)"; fi

TARGET_PROTOCOLS=()
for proto in "${PROTOCOL_KEYS[@]}"; do
  [[ "$(get_protocol_state "$proto")" == true ]] && TARGET_PROTOCOLS+=("$proto")
done
if [[ "$DEPLOY_MODE" == "standalone" ]]; then
  install -m 0644 "$ARTIFACT_DIR/server/config.json" "$TARGET_CONFIG"
  install -m 0644 "$ARTIFACT_DIR/server/sing-box.service" "$SERVICE_FILE"
  write_installer_state
  log 'Running config validation'
  "$TARGET_BIN" check -c "$TARGET_CONFIG"
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if systemctl is-active --quiet "$SERVICE_NAME"; then systemctl restart "$SERVICE_NAME"; else systemctl start "$SERVICE_NAME"; fi
  systemctl --no-pager --full status "$SERVICE_NAME" || true
else
  log "Merge mode: appending generated inbounds to $MERGE_TARGET_CONFIG"
  apply_merge_mode_changes
fi

ROLLBACK_ACTIVE=false
log 'Deployment completed'
show_final_human_summary
post_install_client_export_prompt
if [[ "$VERBOSE_OUTPUT" == true ]]; then
  printf '[OUT] service=%s\n' "$SERVICE_NAME"
  printf '[OUT] binary=%s\n' "$TARGET_BIN"
  printf '[OUT] config=%s\n' "$TARGET_CONFIG"
  printf '[OUT] installer_state=%s\n' "$INSTALLER_STATE_FILE"
  printf '[OUT] artifact_dir=%s\n' "$ARTIFACT_DIR"
  printf '[OUT] backup_dir=%s\n' "$BACKUP_DIR"
  printf '[OUT] brutal_status=%s\n' "$VBR_EFFECTIVE_STATUS"
  if [[ "$VBR_EFFECTIVE_STATUS" == skipped ]]; then printf '[OUT] brutal_skipped_reason=%s\n' "$VBR_SKIPPED_REASON"; fi
  [[ "$ENABLE_HY2" == true ]] && { printf '[OUT] client hy2 sing-box snippet=%s\n' "$ARTIFACT_DIR/client/hy2-singbox-outbound.json"; printf '[OUT] client hy2 mihomo snippet=%s\n' "$ARTIFACT_DIR/client/hy2-mihomo-proxy.yaml"; }
  [[ "$ENABLE_SS" == true ]] && { printf '[OUT] client ss sing-box snippet=%s\n' "$ARTIFACT_DIR/client/ss-singbox-outbound.json"; printf '[OUT] client ss mihomo snippet=%s\n' "$ARTIFACT_DIR/client/ss-mihomo-proxy.yaml"; }
  [[ "$ENABLE_TROJAN" == true ]] && { printf '[OUT] client trojan sing-box snippet=%s\n' "$ARTIFACT_DIR/client/trojan-singbox-outbound.json"; printf '[OUT] client trojan mihomo snippet=%s\n' "$ARTIFACT_DIR/client/trojan-mihomo-proxy.yaml"; }
  [[ "$ENABLE_ANYTLS" == true ]] && printf '[OUT] client anytls sing-box snippet=%s\n' "$ARTIFACT_DIR/client/anytls-singbox-outbound.json"
  [[ "$ENABLE_VGR" == true ]] && { printf '[OUT] client vgr sing-box snippet=%s\n' "$ARTIFACT_DIR/client/vless-grpc-reality-singbox-outbound.json"; printf '[OUT] client vgr mihomo snippet=%s\n' "$ARTIFACT_DIR/client/vless-grpc-reality-mihomo-proxy.yaml"; printf '[OUT] vgr_public_key=%s\n' "$VGR_PUBLIC_KEY"; printf '[OUT] vgr_uuid=%s\n' "$VGR_UUID"; printf '[OUT] vgr_short_id=%s\n' "$VGR_SHORT_ID"; }
  [[ "$ENABLE_VBR" == true ]] && { printf '[OUT] client vbr sing-box snippet=%s\n' "$ARTIFACT_DIR/client/vless-brutal-reality-singbox-outbound.json"; printf '[OUT] vbr_uuid=%s\n' "$VBR_UUID"; printf '[OUT] vbr_short_id=%s\n' "$VBR_SHORT_ID"; printf '[OUT] vbr_server_name=%s\n' "$VBR_SERVER_NAME"; }
  { [[ -n "${ACME_DOMAIN:-}" ]] || (( ${#ACME_SKIPPED_PROTOCOLS[@]} > 0 )); } && { printf '[OUT] acme_domain=%s\n' "$ACME_DOMAIN"; printf '[OUT] acme_home=%s\n' "$ACME_HOME"; }
  if (( ${#ACME_SKIPPED_PROTOCOLS[@]} > 0 )); then
    printf '[OUT] acme_skipped_protocols=%s\n' "$(join_by ',' "${ACME_SKIPPED_PROTOCOLS[@]}")"
    printf '[OUT] acme_skip_reason=%s\n' "$ACME_SKIP_REASON"
  fi
  printf '[OUT] manifest=%s\n' "$ARTIFACT_DIR/manifest.json"
fi
