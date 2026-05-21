#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Generate a minimal sing-box home-access bundle.

Usage:
  generate-sing-box-config.sh --host <domain-or-ip> [options]

Required:
  --host <host>                               Server host / DDNS / IP

Core options:
  --enable-shadowsocks | --disable-shadowsocks
                                              Include Shadowsocks inbound (default: enabled)
  --port <port>                               Shadowsocks port (default: 55501)
  --name <node-name>                          Profile name (default: home)
  --method <method>                           SS method (default: 2022-blake3-aes-128-gcm)
  --outdir <dir>                              Output directory (default: ./output/<name>)
  --listen <addr>                             Server listen address (default: ::)
  --password <password>                       Explicit SS password instead of auto-generating
  --sing-box-bin <path>                       sing-box binary path (default: sing-box)
  --service-config-path <path>                Target config path inside systemd unit
  --service-bin <path>                        Target sing-box binary path in systemd unit

Routing metadata:
  --home-cidrs <csv>                          Home CIDRs for later client routing metadata
  --tg-rule-set <name>                        Telegram geoip/rule-set tag (default: geoip-tg)
  --enable-fakeip | --disable-fakeip          Manifest-only metadata flag (default: disabled)
  --enable-tgip   | --disable-tgip            Manifest-only metadata flag (default: disabled)

Additional server protocols:
  --enable-hy2 | --disable-hy2                Include hysteria2 inbound (default: disabled)
  --hy2-port <port>                           Hysteria2 listen port (default: 55502)
  --hy2-password <password>                   Explicit hy2 password instead of auto-generating
  --hy2-sni <domain>                          Hysteria2 certificate CN / SNI (default: bing.com)
  --hy2-cert-path <path>                      Hysteria2 cert path (default: /usr/local/etc/sing-box/certs/hysteria/cert.pem)
  --hy2-key-path <path>                       Hysteria2 key path (default: /usr/local/etc/sing-box/certs/hysteria/private.key)

  --enable-vless-grpc-reality | --disable-vless-grpc-reality
                                              Include VLESS gRPC Reality inbound (default: disabled)
  --vless-grpc-reality-port <port>            VLESS gRPC Reality listen port (default: 55505)
  --vless-grpc-reality-uuid <uuid>            Explicit VLESS UUID instead of auto-generating/shared reuse
  --vless-grpc-reality-server-name <domain>   Reality server_name / handshake host (default: www.huawei.com)
  --vless-grpc-reality-service-name <name>    gRPC service name (default: Huawei.SmartHome.Connect)
  --vless-grpc-reality-private-key <key>      Reality private key (required if enabled)
  --vless-grpc-reality-public-key <key>       Reality public key for manifest / client snippets
  --vless-grpc-reality-short-id <hex>         Reality short-id (default: random 8-byte hex)

  --enable-vless-brutal-reality | --disable-vless-brutal-reality
                                              Include VLESS Brutal Reality inbound (default: disabled)
  --vless-brutal-reality-port <port>          VLESS Brutal Reality listen port (default: 55506)
  --vless-brutal-reality-uuid <uuid>          Explicit UUID (default: reuse VLESS gRPC Reality UUID / shared access UUID)
  --vless-brutal-reality-server-name <domain> Reality server_name / handshake host (default: www.huawei.com)
  --vless-brutal-reality-private-key <key>    Reality private key (required if enabled)
  --vless-brutal-reality-public-key <key>     Reality public key for manifest / client snippets
  --vless-brutal-reality-short-id <hex>       Reality short-id (default: reuse VLESS gRPC Reality short-id or random 8-byte hex)
  --vless-brutal-reality-up-mbps <num>        TCP Brutal upload Mbps (default: 1000)
  --vless-brutal-reality-down-mbps <num>      TCP Brutal download Mbps (default: 1000)

  --enable-trojan | --disable-trojan          Include Trojan inbound (default: disabled)
  --trojan-port <port>                        Trojan listen port (default: 55503)
  --trojan-password <password>                Trojan password (default: shared UUID-like secret)
  --trojan-server-name <domain>               Trojan TLS server_name for clients (default: --host)
  --trojan-cert-path <path>                   Trojan cert path (default: /usr/local/etc/sing-box/certs/default/cert.crt)
  --trojan-key-path <path>                    Trojan key path (default: /usr/local/etc/sing-box/certs/default/private.key)

  --enable-anytls | --disable-anytls          Include AnyTLS inbound (default: disabled)
  --anytls-port <port>                        AnyTLS listen port (default: 55504)
  --anytls-password <password>                AnyTLS password (default: shared UUID-like secret)
  --anytls-server-name <domain>               AnyTLS TLS server_name for clients (default: --host)
  --anytls-cert-path <path>                   AnyTLS cert path (default: /usr/local/etc/sing-box/certs/default/cert.crt)
  --anytls-key-path <path>                    AnyTLS key path (default: /usr/local/etc/sing-box/certs/default/private.key)
  --anytls-idle-timeout <duration>            AnyTLS idle timeout (default: 15m)
  --anytls-min-idle-streams <num>             AnyTLS min idle streams (default: 8)

  -h, --help                                  Show this help
EOF
}

require_value() {
  local flag="$1"
  local value="${2-}"
  [[ -n "$value" ]] || { echo "[ERR] Missing value for $flag" >&2; exit 1; }
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "[ERR] Invalid port: $1" >&2; exit 1; }
  (( "$1" >= 1 && "$1" <= 65535 )) || { echo "[ERR] Port out of range: $1" >&2; exit 1; }
}

validate_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] || { echo "[ERR] Invalid numeric value: $1" >&2; exit 1; }
  (( "$1" > 0 )) || { echo "[ERR] Value must be > 0: $1" >&2; exit 1; }
}

json_array_from_csv() {
  local csv="$1"
  local first=1
  printf '['
  if [[ -n "$csv" ]]; then
    IFS=',' read -r -a items <<< "$csv"
    for raw in "${items[@]}"; do
      local item
      item="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
      [[ -z "$item" ]] && continue
      if [[ $first -eq 0 ]]; then
        printf ', '
      fi
      printf '"%s"' "$item"
      first=0
    done
  fi
  printf ']'
}

yaml_list_from_csv() {
  local csv="$1"
  if [[ -z "$csv" ]]; then
    printf '[]\n'
    return
  fi
  IFS=',' read -r -a items <<< "$csv"
  for raw in "${items[@]}"; do
    local item
    item="$(echo "$raw" | sed 's/^ *//;s/ *$//')"
    [[ -z "$item" ]] && continue
    printf '  - %s\n' "$item"
  done
}

password_length_for_method() {
  case "$1" in
    2022-blake3-aes-128-gcm) echo 16 ;;
    2022-blake3-aes-256-gcm) echo 32 ;;
    *)
      echo "[ERR] Unsupported method for auto password generation: $1" >&2
      exit 1
      ;;
  esac
}

generate_rand_base64() {
  local len="$1"
  "$SING_BOX_BIN" generate rand "$len" --base64 | tr -d '\r\n'
}

generate_rand_hex() {
  local len="$1"
  "$SING_BOX_BIN" generate rand "$len" --hex | tr -d '\r\n'
}

append_json_item() {
  local var_name="$1"
  local item="$2"
  if [[ -n "${!var_name}" ]]; then
    printf -v "$var_name" '%s,\n%s' "${!var_name}" "$item"
  else
    printf -v "$var_name" '%s' "$item"
  fi
}

HOST=""
ENABLE_SS="true"
PORT="55502"
NAME="home"
METHOD="2022-blake3-aes-128-gcm"
LISTEN="::"
HOME_CIDRS="10.0.0.0/24,192.168.2.0/24"
TG_RULE_SET="geoip-tg"
ENABLE_FAKEIP="false"
ENABLE_TGIP="false"
PASSWORD=""
GENERATED_PASSWORD="false"
SING_BOX_BIN="sing-box"
SERVICE_CONFIG_PATH="/usr/local/etc/sing-box/config.json"
SERVICE_BIN="/usr/local/bin/sing-box"
OUTDIR=""

ENABLE_HY2="false"
HY2_PORT="55501"
HY2_PASSWORD=""
GENERATED_HY2_PASSWORD="false"
HY2_SNI="bing.com"
HY2_CERT_PATH="/usr/local/etc/sing-box/certs/hysteria/cert.pem"
HY2_KEY_PATH="/usr/local/etc/sing-box/certs/hysteria/private.key"

ENABLE_TROJAN="false"
TROJAN_PORT="55503"
TROJAN_PASSWORD=""
GENERATED_TROJAN_PASSWORD="false"
TROJAN_SERVER_NAME=""
TROJAN_CERT_PATH="/usr/local/etc/sing-box/certs/default/cert.crt"
TROJAN_KEY_PATH="/usr/local/etc/sing-box/certs/default/private.key"

ENABLE_ANYTLS="false"
ANYTLS_PORT="55504"
ANYTLS_PASSWORD=""
GENERATED_ANYTLS_PASSWORD="false"
ANYTLS_SERVER_NAME=""
ANYTLS_CERT_PATH="/usr/local/etc/sing-box/certs/default/cert.crt"
ANYTLS_KEY_PATH="/usr/local/etc/sing-box/certs/default/private.key"
ANYTLS_IDLE_TIMEOUT="15m"
ANYTLS_MIN_IDLE_STREAMS="8"

ENABLE_VLESS_GRPC_REALITY="false"
VGR_PORT="55505"
VGR_UUID=""
GENERATED_VGR_UUID="false"
VGR_SERVER_NAME="www.huawei.com"
VGR_SERVICE_NAME="Huawei.SmartHome.Connect"
VGR_PRIVATE_KEY=""
VGR_PUBLIC_KEY=""
VGR_SHORT_ID=""
GENERATED_VGR_SHORT_ID="false"

ENABLE_VLESS_BRUTAL_REALITY="false"
VBR_PORT="55506"
VBR_UUID=""
GENERATED_VBR_UUID="false"
VBR_SERVER_NAME="www.huawei.com"
VBR_PRIVATE_KEY=""
VBR_PUBLIC_KEY=""
VBR_SHORT_ID=""
GENERATED_VBR_SHORT_ID="false"
VBR_UP_MBPS="1000"
VBR_DOWN_MBPS="1000"

SHARED_ACCESS_UUID=""
GENERATED_SHARED_ACCESS_UUID="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) require_value "$1" "${2-}"; HOST="$2"; shift 2 ;;
    --enable-shadowsocks) ENABLE_SS="true"; shift ;;
    --disable-shadowsocks) ENABLE_SS="false"; shift ;;
    --port) require_value "$1" "${2-}"; PORT="$2"; shift 2 ;;
    --name) require_value "$1" "${2-}"; NAME="$2"; shift 2 ;;
    --method) require_value "$1" "${2-}"; METHOD="$2"; shift 2 ;;
    --listen) require_value "$1" "${2-}"; LISTEN="$2"; shift 2 ;;
    --outdir) require_value "$1" "${2-}"; OUTDIR="$2"; shift 2 ;;
    --home-cidrs) require_value "$1" "${2-}"; HOME_CIDRS="$2"; shift 2 ;;
    --tg-rule-set) require_value "$1" "${2-}"; TG_RULE_SET="$2"; shift 2 ;;
    --enable-fakeip) ENABLE_FAKEIP="true"; shift ;;
    --disable-fakeip) ENABLE_FAKEIP="false"; shift ;;
    --enable-tgip) ENABLE_TGIP="true"; shift ;;
    --disable-tgip) ENABLE_TGIP="false"; shift ;;
    --password) require_value "$1" "${2-}"; PASSWORD="$2"; shift 2 ;;
    --sing-box-bin) require_value "$1" "${2-}"; SING_BOX_BIN="$2"; shift 2 ;;
    --service-config-path) require_value "$1" "${2-}"; SERVICE_CONFIG_PATH="$2"; shift 2 ;;
    --service-bin) require_value "$1" "${2-}"; SERVICE_BIN="$2"; shift 2 ;;

    --enable-hy2) ENABLE_HY2="true"; shift ;;
    --disable-hy2) ENABLE_HY2="false"; shift ;;
    --hy2-port) require_value "$1" "${2-}"; HY2_PORT="$2"; shift 2 ;;
    --hy2-password) require_value "$1" "${2-}"; HY2_PASSWORD="$2"; shift 2 ;;
    --hy2-sni) require_value "$1" "${2-}"; HY2_SNI="$2"; shift 2 ;;
    --hy2-cert-path) require_value "$1" "${2-}"; HY2_CERT_PATH="$2"; shift 2 ;;
    --hy2-key-path) require_value "$1" "${2-}"; HY2_KEY_PATH="$2"; shift 2 ;;

    --enable-trojan) ENABLE_TROJAN="true"; shift ;;
    --disable-trojan) ENABLE_TROJAN="false"; shift ;;
    --trojan-port) require_value "$1" "${2-}"; TROJAN_PORT="$2"; shift 2 ;;
    --trojan-password) require_value "$1" "${2-}"; TROJAN_PASSWORD="$2"; shift 2 ;;
    --trojan-server-name) require_value "$1" "${2-}"; TROJAN_SERVER_NAME="$2"; shift 2 ;;
    --trojan-cert-path) require_value "$1" "${2-}"; TROJAN_CERT_PATH="$2"; shift 2 ;;
    --trojan-key-path) require_value "$1" "${2-}"; TROJAN_KEY_PATH="$2"; shift 2 ;;

    --enable-anytls) ENABLE_ANYTLS="true"; shift ;;
    --disable-anytls) ENABLE_ANYTLS="false"; shift ;;
    --anytls-port) require_value "$1" "${2-}"; ANYTLS_PORT="$2"; shift 2 ;;
    --anytls-password) require_value "$1" "${2-}"; ANYTLS_PASSWORD="$2"; shift 2 ;;
    --anytls-server-name) require_value "$1" "${2-}"; ANYTLS_SERVER_NAME="$2"; shift 2 ;;
    --anytls-cert-path) require_value "$1" "${2-}"; ANYTLS_CERT_PATH="$2"; shift 2 ;;
    --anytls-key-path) require_value "$1" "${2-}"; ANYTLS_KEY_PATH="$2"; shift 2 ;;
    --anytls-idle-timeout) require_value "$1" "${2-}"; ANYTLS_IDLE_TIMEOUT="$2"; shift 2 ;;
    --anytls-min-idle-streams) require_value "$1" "${2-}"; ANYTLS_MIN_IDLE_STREAMS="$2"; shift 2 ;;

    --enable-vless-grpc-reality) ENABLE_VLESS_GRPC_REALITY="true"; shift ;;
    --disable-vless-grpc-reality) ENABLE_VLESS_GRPC_REALITY="false"; shift ;;
    --vless-grpc-reality-port) require_value "$1" "${2-}"; VGR_PORT="$2"; shift 2 ;;
    --vless-grpc-reality-uuid) require_value "$1" "${2-}"; VGR_UUID="$2"; shift 2 ;;
    --vless-grpc-reality-server-name) require_value "$1" "${2-}"; VGR_SERVER_NAME="$2"; shift 2 ;;
    --vless-grpc-reality-service-name) require_value "$1" "${2-}"; VGR_SERVICE_NAME="$2"; shift 2 ;;
    --vless-grpc-reality-private-key) require_value "$1" "${2-}"; VGR_PRIVATE_KEY="$2"; shift 2 ;;
    --vless-grpc-reality-public-key) require_value "$1" "${2-}"; VGR_PUBLIC_KEY="$2"; shift 2 ;;
    --vless-grpc-reality-short-id) require_value "$1" "${2-}"; VGR_SHORT_ID="$2"; shift 2 ;;

    --enable-vless-brutal-reality) ENABLE_VLESS_BRUTAL_REALITY="true"; shift ;;
    --disable-vless-brutal-reality) ENABLE_VLESS_BRUTAL_REALITY="false"; shift ;;
    --vless-brutal-reality-port) require_value "$1" "${2-}"; VBR_PORT="$2"; shift 2 ;;
    --vless-brutal-reality-uuid) require_value "$1" "${2-}"; VBR_UUID="$2"; shift 2 ;;
    --vless-brutal-reality-server-name) require_value "$1" "${2-}"; VBR_SERVER_NAME="$2"; shift 2 ;;
    --vless-brutal-reality-private-key) require_value "$1" "${2-}"; VBR_PRIVATE_KEY="$2"; shift 2 ;;
    --vless-brutal-reality-public-key) require_value "$1" "${2-}"; VBR_PUBLIC_KEY="$2"; shift 2 ;;
    --vless-brutal-reality-short-id) require_value "$1" "${2-}"; VBR_SHORT_ID="$2"; shift 2 ;;
    --vless-brutal-reality-up-mbps) require_value "$1" "${2-}"; VBR_UP_MBPS="$2"; shift 2 ;;
    --vless-brutal-reality-down-mbps) require_value "$1" "${2-}"; VBR_DOWN_MBPS="$2"; shift 2 ;;

    -h|--help) usage; exit 0 ;;
    *) echo "[ERR] Unknown argument: $1" >&2; usage >&2; exit 1 ;;
  esac
done

[[ -n "$HOST" ]] || { echo "[ERR] --host is required" >&2; usage >&2; exit 1; }
[[ -n "$OUTDIR" ]] || OUTDIR="./output/$NAME"

TROJAN_SERVER_NAME="${TROJAN_SERVER_NAME:-$HOST}"
ANYTLS_SERVER_NAME="${ANYTLS_SERVER_NAME:-$HOST}"
VBR_SERVER_NAME="${VBR_SERVER_NAME:-www.huawei.com}"

NEED_SING_BOX="false"
if [[ "$ENABLE_SS" == "true" && -z "$PASSWORD" ]]; then NEED_SING_BOX="true"; fi
if [[ "$ENABLE_HY2" == "true" && -z "$HY2_PASSWORD" ]]; then NEED_SING_BOX="true"; fi
if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" && ( -z "$VGR_UUID" || -z "$VGR_SHORT_ID" ) ]]; then NEED_SING_BOX="true"; fi
if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" && ( -z "$VBR_UUID" || -z "$VBR_SHORT_ID" ) ]]; then NEED_SING_BOX="true"; fi
if [[ ( "$ENABLE_TROJAN" == "true" || "$ENABLE_ANYTLS" == "true" ) && ( -z "$TROJAN_PASSWORD" || -z "$ANYTLS_PASSWORD" || ( -z "$VGR_UUID" && -z "$VBR_UUID" ) ) ]]; then NEED_SING_BOX="true"; fi

if [[ "$NEED_SING_BOX" == "true" ]] && ! command -v "$SING_BOX_BIN" >/dev/null 2>&1; then
  echo "[ERR] sing-box binary not found: $SING_BOX_BIN" >&2
  echo "      Run this script on a host with sing-box installed, or pass enough explicit secrets/IDs." >&2
  exit 1
fi

for p in \
  "$([[ "$ENABLE_HY2" == "true" ]] && echo "$HY2_PORT")" \
  "$([[ "$ENABLE_SS" == "true" ]] && echo "$PORT")" \
  "$([[ "$ENABLE_TROJAN" == "true" ]] && echo "$TROJAN_PORT")" \
  "$([[ "$ENABLE_ANYTLS" == "true" ]] && echo "$ANYTLS_PORT")" \
  "$([[ "$ENABLE_VLESS_GRPC_REALITY" == "true" ]] && echo "$VGR_PORT")" \
  "$([[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" ]] && echo "$VBR_PORT")"; do
  [[ -n "$p" ]] && validate_port "$p"
done
validate_positive_int "$VBR_UP_MBPS"
validate_positive_int "$VBR_DOWN_MBPS"

if [[ "$ENABLE_SS" != "true" && "$ENABLE_HY2" != "true" && "$ENABLE_TROJAN" != "true" && "$ENABLE_ANYTLS" != "true" && "$ENABLE_VLESS_GRPC_REALITY" != "true" && "$ENABLE_VLESS_BRUTAL_REALITY" != "true" ]]; then
  echo "[ERR] At least one protocol must be enabled" >&2
  exit 1
fi

if [[ "$ENABLE_SS" == "true" && -z "$PASSWORD" ]]; then
  PASSWORD="$(generate_rand_base64 "$(password_length_for_method "$METHOD")")"
  GENERATED_PASSWORD="true"
fi
if [[ "$ENABLE_HY2" == "true" && -z "$HY2_PASSWORD" ]]; then
  HY2_PASSWORD="$(generate_rand_base64 16)"
  GENERATED_HY2_PASSWORD="true"
fi

if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" && -z "$VGR_UUID" ]]; then
  VGR_UUID="$($SING_BOX_BIN generate uuid | tr -d '\r\n')"
  GENERATED_VGR_UUID="true"
fi
if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" && -z "$VGR_SHORT_ID" ]]; then
  VGR_SHORT_ID="$(generate_rand_hex 8)"
  GENERATED_VGR_SHORT_ID="true"
fi
if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" && -z "$VBR_UUID" ]]; then
  if [[ -n "$VGR_UUID" ]]; then
    VBR_UUID="$VGR_UUID"
  else
    VBR_UUID="$($SING_BOX_BIN generate uuid | tr -d '\r\n')"
    GENERATED_VBR_UUID="true"
  fi
fi
if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" && -z "$VBR_SHORT_ID" ]]; then
  if [[ -n "$VGR_SHORT_ID" ]]; then
    VBR_SHORT_ID="$VGR_SHORT_ID"
  else
    VBR_SHORT_ID="$(generate_rand_hex 8)"
    GENERATED_VBR_SHORT_ID="true"
  fi
fi

if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" || "$ENABLE_VLESS_BRUTAL_REALITY" == "true" || "$ENABLE_TROJAN" == "true" || "$ENABLE_ANYTLS" == "true" ]]; then
  if [[ -n "$VGR_UUID" ]]; then
    SHARED_ACCESS_UUID="$VGR_UUID"
  elif [[ -n "$VBR_UUID" ]]; then
    SHARED_ACCESS_UUID="$VBR_UUID"
  else
    SHARED_ACCESS_UUID="$($SING_BOX_BIN generate uuid | tr -d '\r\n')"
    GENERATED_SHARED_ACCESS_UUID="true"
  fi
fi

if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" && -z "$VGR_PRIVATE_KEY" ]]; then
  echo "[ERR] --vless-grpc-reality-private-key is required when --enable-vless-grpc-reality is used" >&2
  exit 1
fi
if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" && -z "$VBR_PRIVATE_KEY" ]]; then
  echo "[ERR] --vless-brutal-reality-private-key is required when --enable-vless-brutal-reality is used" >&2
  exit 1
fi
if [[ "$ENABLE_TROJAN" == "true" && -z "$TROJAN_PASSWORD" ]]; then
  TROJAN_PASSWORD="$SHARED_ACCESS_UUID"
  GENERATED_TROJAN_PASSWORD="true"
fi
if [[ "$ENABLE_ANYTLS" == "true" && -z "$ANYTLS_PASSWORD" ]]; then
  ANYTLS_PASSWORD="$SHARED_ACCESS_UUID"
  GENERATED_ANYTLS_PASSWORD="true"
fi
if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" && -z "$VBR_PUBLIC_KEY" && -n "$VGR_PUBLIC_KEY" && "$VBR_PRIVATE_KEY" == "$VGR_PRIVATE_KEY" ]]; then
  VBR_PUBLIC_KEY="$VGR_PUBLIC_KEY"
fi

mkdir -p "$OUTDIR/server" "$OUTDIR/client"
SERVER_CONFIG="$OUTDIR/server/config.json"
SERVICE_FILE="$OUTDIR/server/sing-box.service"
MANIFEST_FILE="$OUTDIR/manifest.json"
NOTES_FILE="$OUTDIR/README.txt"

SS_SB_SNIPPET="$OUTDIR/client/ss-singbox-outbound.json"
SS_MIHOMO_SNIPPET="$OUTDIR/client/ss-mihomo-proxy.yaml"
HY2_SB_SNIPPET="$OUTDIR/client/hy2-singbox-outbound.json"
HY2_MIHOMO_SNIPPET="$OUTDIR/client/hy2-mihomo-proxy.yaml"
TROJAN_SB_SNIPPET="$OUTDIR/client/trojan-singbox-outbound.json"
TROJAN_MIHOMO_SNIPPET="$OUTDIR/client/trojan-mihomo-proxy.yaml"
ANYTLS_SB_SNIPPET="$OUTDIR/client/anytls-singbox-outbound.json"
ANYTLS_MIHOMO_SNIPPET="$OUTDIR/client/anytls-mihomo-proxy.yaml"
VGR_SB_SNIPPET="$OUTDIR/client/vless-grpc-reality-singbox-outbound.json"
VGR_MIHOMO_SNIPPET="$OUTDIR/client/vless-grpc-reality-mihomo-proxy.yaml"
VBR_SB_SNIPPET="$OUTDIR/client/vless-brutal-reality-singbox-outbound.json"
VBR_MIHOMO_SNIPPET="$OUTDIR/client/vless-brutal-reality-mihomo-proxy.yaml"

INBOUNDS_JSON=""
PROTOCOLS_JSON=""
CLIENT_FILES=()
ENABLED_PROTOCOLS=()

if [[ "$ENABLE_HY2" == "true" ]]; then
  ENABLED_PROTOCOLS+=("hysteria2")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"hysteria2\",\n      \"tag\": \"hy2-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $HY2_PORT,\n      \"users\": [\n        {\n          \"password\": \"$HY2_PASSWORD\"\n        }\n      ],\n      \"ignore_client_bandwidth\": true,\n      \"tls\": {\n        \"enabled\": true,\n        \"alpn\": [\"h3\"],\n        \"certificate_path\": \"$HY2_CERT_PATH\",\n        \"key_path\": \"$HY2_KEY_PATH\"\n      }\n    }"
  append_json_item PROTOCOLS_JSON "    \"hysteria2\": {\n      \"enabled\": true,\n      \"port\": $HY2_PORT,\n      \"password\": \"$HY2_PASSWORD\",\n      \"server_name\": \"$HY2_SNI\",\n      \"certificate_path\": \"$HY2_CERT_PATH\",\n      \"key_path\": \"$HY2_KEY_PATH\"\n    }"
  cat > "$HY2_SB_SNIPPET" <<EOF
{
  "type": "hysteria2",
  "tag": "$NAME-hy2",
  "server": "$HOST",
  "server_port": $HY2_PORT,
  "password": "$HY2_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "$HY2_SNI",
    "insecure": true,
    "alpn": ["h3"]
  }
}
EOF
  cat > "$HY2_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-hy2
  type: hysteria2
  server: $HOST
  port: $HY2_PORT
  password: $HY2_PASSWORD
  up: "50 Mbps"
  down: "55 Mbps"
  sni: $HY2_SNI
  skip-cert-verify: true
  alpn:
    - h3
EOF
  CLIENT_FILES+=("- client/hy2-singbox-outbound.json" "- client/hy2-mihomo-proxy.yaml")
fi

if [[ "$ENABLE_SS" == "true" ]]; then
  ENABLED_PROTOCOLS+=("shadowsocks")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"shadowsocks\",\n      \"tag\": \"shadowsocks-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $PORT,\n      \"method\": \"$METHOD\",\n      \"password\": \"$PASSWORD\"\n    }"
  append_json_item PROTOCOLS_JSON "    \"shadowsocks\": {\n      \"enabled\": true,\n      \"port\": $PORT,\n      \"method\": \"$METHOD\",\n      \"password\": \"$PASSWORD\"\n    }"
  cat > "$SS_SB_SNIPPET" <<EOF
{
  "type": "shadowsocks",
  "tag": "$NAME-shadowsocks",
  "server": "$HOST",
  "server_port": $PORT,
  "method": "$METHOD",
  "password": "$PASSWORD"
}
EOF
  cat > "$SS_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-shadowsocks
  type: ss
  server: $HOST
  port: $PORT
  cipher: $METHOD
  password: $PASSWORD
EOF
  CLIENT_FILES+=("- client/ss-singbox-outbound.json" "- client/ss-mihomo-proxy.yaml")
fi

if [[ "$ENABLE_TROJAN" == "true" ]]; then
  ENABLED_PROTOCOLS+=("trojan")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"trojan\",\n      \"tag\": \"trojan-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $TROJAN_PORT,\n      \"tcp_fast_open\": true,\n      \"tcp_multi_path\": true,\n      \"users\": [\n        {\n          \"name\": \"$NAME\",\n          \"password\": \"$TROJAN_PASSWORD\"\n        }\n      ],\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"$TROJAN_SERVER_NAME\",\n        \"certificate_path\": \"$TROJAN_CERT_PATH\",\n        \"key_path\": \"$TROJAN_KEY_PATH\"\n      },\n      \"multiplex\": {\n        \"enabled\": true,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": false,\n          \"up_mbps\": 55,\n          \"down_mbps\": 500\n        }\n      }\n    }"
  append_json_item PROTOCOLS_JSON "    \"trojan\": {\n      \"enabled\": true,\n      \"port\": $TROJAN_PORT,\n      \"password\": \"$TROJAN_PASSWORD\",\n      \"server_name\": \"$TROJAN_SERVER_NAME\",\n      \"certificate_path\": \"$TROJAN_CERT_PATH\",\n      \"key_path\": \"$TROJAN_KEY_PATH\"\n    }"
  cat > "$TROJAN_SB_SNIPPET" <<EOF
{
  "type": "trojan",
  "tag": "$NAME-trojan",
  "server": "$HOST",
  "server_port": $TROJAN_PORT,
  "password": "$TROJAN_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "$TROJAN_SERVER_NAME",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  },
  "multiplex": {
    "enabled": true,
    "protocol": "h2mux",
    "max_connections": 1,
    "min_streams": 4,
    "padding": false,
    "brutal": {
      "enabled": false,
      "up_mbps": 50,
      "down_mbps": 55
    }
  }
}
EOF
  cat > "$TROJAN_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-trojan
  type: trojan
  server: $HOST
  port: $TROJAN_PORT
  password: $TROJAN_PASSWORD
  udp: true
  sni: $TROJAN_SERVER_NAME
  alpn:
    - h2
    - http/1.1
  skip-cert-verify: null
  servername: $TROJAN_SERVER_NAME
  tls: true
EOF
  CLIENT_FILES+=("- client/trojan-singbox-outbound.json" "- client/trojan-mihomo-proxy.yaml")
fi

if [[ "$ENABLE_ANYTLS" == "true" ]]; then
  ENABLED_PROTOCOLS+=("anytls")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"anytls\",\n      \"tag\": \"anytls-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $ANYTLS_PORT,\n      \"users\": [\n        {\n          \"password\": \"$ANYTLS_PASSWORD\"\n        }\n      ],\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"$ANYTLS_SERVER_NAME\",\n        \"certificate_path\": \"$ANYTLS_CERT_PATH\",\n        \"key_path\": \"$ANYTLS_KEY_PATH\"\n      }\n    }"
  append_json_item PROTOCOLS_JSON "    \"anytls\": {\n      \"enabled\": true,\n      \"port\": $ANYTLS_PORT,\n      \"password\": \"$ANYTLS_PASSWORD\",\n      \"server_name\": \"$ANYTLS_SERVER_NAME\",\n      \"certificate_path\": \"$ANYTLS_CERT_PATH\",\n      \"key_path\": \"$ANYTLS_KEY_PATH\",\n      \"idle_timeout\": \"$ANYTLS_IDLE_TIMEOUT\",\n      \"min_idle_streams\": ${ANYTLS_MIN_IDLE_STREAMS}\n    }"
  cat > "$ANYTLS_SB_SNIPPET" <<EOF
{
  "type": "anytls",
  "tag": "$NAME-anytls",
  "server": "$HOST",
  "server_port": $ANYTLS_PORT,
  "password": "$ANYTLS_PASSWORD",
  "tls": {
    "enabled": true,
    "server_name": "$ANYTLS_SERVER_NAME"
  },
  "idle_session_timeout": "$ANYTLS_IDLE_TIMEOUT",
  "min_idle_session": $ANYTLS_MIN_IDLE_STREAMS
}
EOF
  cat > "$ANYTLS_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-anytls
  type: anytls
  server: $HOST
  port: $ANYTLS_PORT
  password: "$ANYTLS_PASSWORD"
  client-fingerprint: chrome
  udp: true
  idle-session-check-interval: 30
  idle-session-timeout: 30
  min-idle-session: 0
  tls: true
  sni: "$ANYTLS_SERVER_NAME"
  alpn:
    - h2
    - http/1.1
  skip-cert-verify: true
EOF
  CLIENT_FILES+=("- client/anytls-singbox-outbound.json" "- client/anytls-mihomo-proxy.yaml")
fi

if [[ "$ENABLE_VLESS_GRPC_REALITY" == "true" ]]; then
  ENABLED_PROTOCOLS+=("vless-grpc-reality")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"vless\",\n      \"tag\": \"vless-grpc-reality-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $VGR_PORT,\n      \"users\": [\n        {\n          \"uuid\": \"$VGR_UUID\",\n          \"flow\": \"\"\n        }\n      ],\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"www.huawei.com\",\n        \"reality\": {\n          \"enabled\": true,\n          \"handshake\": {\n            \"server\": \"www.huawei.com\",\n            \"server_port\": 443\n          },\n          \"private_key\": \"$VGR_PRIVATE_KEY\",\n          \"short_id\": [\"$VGR_SHORT_ID\"]\n        }\n      },\n      \"transport\": {\n        \"type\": \"grpc\",\n        \"service_name\": \"$VGR_SERVICE_NAME\"\n      }\n    }"
  append_json_item PROTOCOLS_JSON "    \"vless_grpc_reality\": {\n      \"enabled\": true,\n      \"port\": $VGR_PORT,\n      \"uuid\": \"$VGR_UUID\",\n      \"server_name\": \"$VGR_SERVER_NAME\",\n      \"service_name\": \"$VGR_SERVICE_NAME\",\n      \"private_key\": \"$VGR_PRIVATE_KEY\",\n      \"public_key\": \"$VGR_PUBLIC_KEY\",\n      \"short_id\": \"$VGR_SHORT_ID\"\n    }"
  cat > "$VGR_SB_SNIPPET" <<EOF
{
  "type": "vless",
  "tag": "$NAME-vless-grpc-reality",
  "server": "$HOST",
  "server_port": $VGR_PORT,
  "uuid": "$VGR_UUID",
  "tls": {
    "enabled": true,
    "server_name": "www.huawei.com",
    "reality": {
      "enabled": true,
      "public_key": "$VGR_PUBLIC_KEY",
      "short_id": "$VGR_SHORT_ID"
    },
      "utls": {
        "enabled": true,
        "fingerprint": "chrome"
      }
  },
  "transport": {
    "type": "grpc",
    "service_name": "Huawei.SmartHome.Connect"
  }
}
EOF
  cat > "$VGR_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-vless-grpc-reality
  type: vless
  server: $HOST
  port: $VGR_PORT
  uuid: $VGR_UUID
  tls: true
  udp: false
  servername: www.huawei.com
  network: grpc
  reality-opts:
    public-key: $VGR_PUBLIC_KEY
    short-id: $VGR_SHORT_ID
  grpc-opts:
    grpc-service-name: Huawei.SmartHome.Connect
  client-fingerprint: chrome
EOF
  CLIENT_FILES+=("- client/vless-grpc-reality-singbox-outbound.json" "- client/vless-grpc-reality-mihomo-proxy.yaml")
fi

if [[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" ]]; then
  ENABLED_PROTOCOLS+=("vless-brutal-reality")
  append_json_item INBOUNDS_JSON "    {\n      \"type\": \"vless\",\n      \"tag\": \"vless-brutal-reality-in\",\n      \"listen\": \"$LISTEN\",\n      \"listen_port\": $VBR_PORT,\n      \"users\": [\n        {\n          \"uuid\": \"$VBR_UUID\",\n          \"flow\": \"\"\n        }\n      ],\n      \"tls\": {\n        \"enabled\": true,\n        \"server_name\": \"www.huawei.com\",\n        \"reality\": {\n          \"enabled\": true,\n          \"handshake\": {\n            \"server\": \"www.huawei.com\",\n            \"server_port\": 443\n          },\n          \"private_key\": \"$VBR_PRIVATE_KEY\",\n          \"short_id\": [\"$VBR_SHORT_ID\"]\n        }\n      },\n      \"multiplex\": {\n        \"enabled\": true,\n        \"padding\": false,\n        \"brutal\": {\n          \"enabled\": true,\n          \"up_mbps\": $VBR_UP_MBPS,\n          \"down_mbps\": $VBR_DOWN_MBPS\n        }\n      }\n    }"
  append_json_item PROTOCOLS_JSON "    \"vless_brutal_reality\": {\n      \"enabled\": true,\n      \"port\": $VBR_PORT,\n      \"uuid\": \"$VBR_UUID\",\n      \"server_name\": \"$VBR_SERVER_NAME\",\n      \"private_key\": \"$VBR_PRIVATE_KEY\",\n      \"public_key\": \"$VBR_PUBLIC_KEY\",\n      \"short_id\": \"$VBR_SHORT_ID\",\n      \"up_mbps\": $VBR_UP_MBPS,\n      \"down_mbps\": $VBR_DOWN_MBPS,\n      \"shared_with_vless_grpc_reality\": $([[ -n "$VGR_UUID" && "$VBR_UUID" == "$VGR_UUID" && -n "$VGR_SHORT_ID" && "$VBR_SHORT_ID" == "$VGR_SHORT_ID" ]] && echo true || echo false)
    }"
  cat > "$VBR_SB_SNIPPET" <<EOF
{
  "type": "vless",
  "tag": "$NAME-vless-brutal-reality",
  "server": "$HOST",
  "server_port": $VBR_PORT,
  "uuid": "$VBR_UUID",
  "flow": "",
  "packet_encoding": "xudp",
  "tls": {
    "enabled": true,
    "server_name": "$VBR_SERVER_NAME",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "$VBR_PUBLIC_KEY",
      "short_id": "$VBR_SHORT_ID"
    }
  },
  "multiplex": {
    "enabled": true,
    "protocol": "h2mux",
    "max_connections": 1,
    "min_streams": 4,
    "padding": true,
    "brutal": {
      "enabled": true,
      "up_mbps": $VBR_UP_MBPS,
      "down_mbps": $VBR_DOWN_MBPS
    }
  }
}
EOF
  cat > "$VBR_MIHOMO_SNIPPET" <<EOF
- name: ${NAME}-vless-brutal-reality
  type: vless
  server: $HOST
  port: $VBR_PORT
  uuid: $VBR_UUID
  network: tcp
  packet-encoding: xudp
  tls: true
  servername: $VBR_SERVER_NAME
  client-fingerprint: chrome
  reality-opts:
    public-key: $VBR_PUBLIC_KEY
    short-id: "$VBR_SHORT_ID"
  smux:
    enabled: true
    protocol: h2mux
    max-connections: 1
    min-streams: 4
    padding: true
  brutal-opts:
    enabled: true
    up: $VBR_UP_MBPS Mbps
    down: $VBR_DOWN_MBPS Mbps
EOF
  CLIENT_FILES+=("- client/vless-brutal-reality-singbox-outbound.json" "- client/vless-brutal-reality-mihomo-proxy.yaml")
fi

cat > "$SERVER_CONFIG" <<EOF
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
$(printf '%b' "$INBOUNDS_JSON")
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "final": "direct"
  },
  "experimental": {
    "clash_api": {
      "external_controller": "0.0.0.0:9090",
      "external_ui": "/usr/local/etc/sing-box/ui",
      "secret": ""
    },
    "cache_file": {
      "enabled": true
    }
  }
}
EOF

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=$SERVICE_BIN run -c $SERVICE_CONFIG_PATH
Restart=on-failure
RestartSec=1800s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

cat > "$MANIFEST_FILE" <<EOF
{
  "profile": "$NAME",
  "server": "$HOST",
  "listen": "$LISTEN",
  "service": {
    "binary": "$SERVICE_BIN",
    "config_path": "$SERVICE_CONFIG_PATH"
  },
  "protocols": {
$(printf '%b' "$PROTOCOLS_JSON")
  },
  "shared_credentials": {
    "access_uuid": "$SHARED_ACCESS_UUID",
    "reused_by": {
      "vless_grpc_reality": $([[ "$ENABLE_VLESS_GRPC_REALITY" == "true" ]] && echo true || echo false),
      "vless_brutal_reality": $([[ "$ENABLE_VLESS_BRUTAL_REALITY" == "true" ]] && echo true || echo false),
      "trojan": $([[ "$ENABLE_TROJAN" == "true" ]] && echo true || echo false),
      "anytls": $([[ "$ENABLE_ANYTLS" == "true" ]] && echo true || echo false)
    }
  },
  "routing_profile": {
    "home_cidrs": $(json_array_from_csv "$HOME_CIDRS"),
    "fakeip_route": $ENABLE_FAKEIP,
    "telegram_ip_route": $ENABLE_TGIP,
    "telegram_rule_set": "$TG_RULE_SET"
  },
  "generated_at": "$(date -Iseconds)"
}
EOF

cat > "$NOTES_FILE" <<EOF
Generated bundle: $NAME

Files:
- server/config.json
- server/sing-box.service
- manifest.json
$(printf '%s\n' "${CLIENT_FILES[@]}")

Enabled protocols:
$(printf '%s\n' "${ENABLED_PROTOCOLS[@]}" | sed 's/^/- /')

Routing policy metadata for next stage:
- Home CIDRs:
$(yaml_list_from_csv "$HOME_CIDRS")
- fakeip_route: $ENABLE_FAKEIP
- telegram_ip_route: $ENABLE_TGIP
- telegram_rule_set: $TG_RULE_SET

Notes:
- Trojan and AnyTLS reuse /usr/local/etc/sing-box/certs/default by default.
- VLESS Brutal Reality reuses Trojan-like server_name semantics by default; it is still Reality and does not require ACME certs itself.
- mihomo snippet is provided for SS / Hy2 / Trojan / AnyTLS / VLESS gRPC Reality / VLESS Brutal Reality.
EOF

cat <<EOF
[OK] Generated bundle: $NAME
[OUT] $OUTDIR
[INFO] SS password generated: $GENERATED_PASSWORD
[INFO] Hy2 password generated: $GENERATED_HY2_PASSWORD
[INFO] Shared access UUID generated: $GENERATED_SHARED_ACCESS_UUID
[INFO] VLESS gRPC Reality UUID generated: $GENERATED_VGR_UUID
[INFO] VLESS gRPC Reality short-id generated: $GENERATED_VGR_SHORT_ID
[INFO] VLESS Brutal Reality UUID generated: $GENERATED_VBR_UUID
[INFO] VLESS Brutal Reality short-id generated: $GENERATED_VBR_SHORT_ID
[INFO] Trojan password generated from shared access UUID: $GENERATED_TROJAN_PASSWORD
[INFO] AnyTLS password generated from shared access UUID: $GENERATED_ANYTLS_PASSWORD
[INFO] Next: review server/config.json and merge needed client snippets.
EOF
