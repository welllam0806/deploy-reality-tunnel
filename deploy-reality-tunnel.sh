#!/usr/bin/env bash
# ============================================================================
# deploy-reality-tunnel.sh  —  xray VLESS+Reality 双端隧道一键部署
#
#   业务层保留 SS/SOCKS(落地 x-ui 面板不动),传输层用 VLESS+Reality 取代
#   realm-wss 隧道(realm/xwPF 全程退役)。
#
#   链路:
#     dae(SS节点) ──> 中转机A [ss-in → VLESS+Reality出站] ──Reality隧道──>
#           落地机B [reality-in → SS outbound] ──> 127.0.0.1:x-ui SS 端口 ──> 出口
#
#   用法:
#     ./deploy-reality-tunnel.sh server   # 每台落地机(海外/x-ui)跑一次
#     ./deploy-reality-tunnel.sh relay    # 家里 Debian12(中转机)跑,可添加多台落地
#     ./deploy-reality-tunnel.sh status   # 查看隧道服务状态
#     ./deploy-reality-tunnel.sh remove   # 停止并删除本机隧道配置
#     ./deploy-reality-tunnel.sh del      # 删除已添加的落地条目(删后重跑 relay 重装)
#
#   协议参数(server/relay 第2参数,可选,默认 shadowsocks):
#     deploy.sh server ss|socks|both   # 业务协议: ss(默认) / socks=SOCKS5 / both=SS+SOCKS双隧道
#     deploy.sh relay                   # 中转机: 条目级协议(每条末尾标 ss/socks,默认 ss),可混合
#
#   注意: 中转机 A 必须放在国内/内网,否则 dae→A 的 SS 段照样出境,隧道白套。
# ============================================================================
set -euo pipefail

CFG_DIR=/usr/local/etc/xray
XRAY_BIN=/usr/local/bin/xray
SERVICE=xray-tunnel
UNIT=/etc/systemd/system/${SERVICE}.service
SERVER_CFG=${CFG_DIR}/tunnel.json
RELAY_ENTRIES=${CFG_DIR}/relay.entries
RELAY_SSPASS=${CFG_DIR}/relay.sspass
CREDS=${CFG_DIR}/server.creds
DEST=www.cloudflare.com          # Reality 伪装目标站(别改微软系,Akamai 拒中继)

c_red()   { echo -e "\033[31m$*\033[0m"; }
c_grn()   { echo -e "\033[32m$*\033[0m"; }
c_yel()   { echo -e "\033[33m$*\033[0m"; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

check_root() {
  [ "$(id -u)" -eq 0 ] || { c_red "[!] 需要 root 权限: sudo $0 $*"; exit 1; }
}

check_arch() {
  case "$(uname -m)" in
    x86_64|amd64) ;;
    *) c_red "[!] 脚本仅支持 x86_64,当前 $(uname -m),请手动下载对应架构的 Xray"; exit 1;;
  esac
}

prompt() { # $1=提示 $2=默认值
  local v
  read -rp "$1 [$2]: " v
  echo "${v:-$2}"
}

# 选择 Reality 伪装目标站(均为常见 TLS1.3 + X25519 大站)
# 菜单一律打 stderr:本函数在 $(...) 命令替换中运行,stdout 只允许输出最终结果
pick_sni() {
  local options=(
    "www.cloudflare.com" "www.apple.com" "www.google.com" "dl.google.com"
    "www.nvidia.com" "www.tesla.com" "www.amazon.com"
  )
  echo "请选择 Reality 伪装目标 (dest/SNI):" >&2
  for i in "${!options[@]}"; do
    echo "  [$((i+1))] ${options[$i]}" >&2
  done
  echo "  [$(( ${#options[@]} + 1 ))] 自定义" >&2
  local sel custom
  read -rp "请输入数字 [1-$(( ${#options[@]} + 1 ))](回车=1): " sel
  sel=${sel:-1}
  if [[ "$sel" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#options[@]} )); then
    echo "${options[$((sel-1))]}"
  elif [[ "$sel" =~ ^[0-9]+$ ]] && (( sel == ${#options[@]} + 1 )); then
    read -rp "自定义 dest/SNI 域名: " custom
    echo "${custom:-$DEST}"
  else
    echo "$DEST"
  fi
}

# 验证目标站支持 TLS1.3 + X25519(仅警告,不阻断)
verify_sni() {
  command -v openssl >/dev/null || return 0
  local out
  out=$(echo | timeout 8 openssl s_client -connect "$1:443" -servername "$1" -tls1_3 -curves X25519 2>/dev/null) || true
  if echo "$out" | grep -q "New, TLSv1.3" && echo "$out" | grep -q "Server Temp Key: X25519"; then
    c_grn "    ✓ $1 支持 TLS1.3 + X25519"
  else
    c_yel "    [!] $1 验证失败(可能被 CDN 边缘拒绝),客户端连不上就换目标站"
  fi
}

# ---------------------------------------------------------------------------
# 优先复用 x-ui / 3x-ui 面板自带 xray(在 /usr/local/x-ui/bin,不在 PATH)
find_xui_xray() {
  local d f
  for d in /usr/local/x-ui/bin /opt/x-ui/bin; do
    [ -d "$d" ] || continue
    for f in "$d"/xray "$d"/xray-linux-amd64 "$d"/xray-linux-arm64 "$d"/xray-linux-arm32-v7a; do
      [ -x "$f" ] && { echo "$f"; return 0; }
    done
    for f in $(ls "$d" 2>/dev/null | grep -i xray); do
      [ -x "$d/$f" ] && { echo "$d/$f"; return 0; }
    done
  done
  local pid exe
  for pid in $(pgrep -f '/x-ui/' 2>/dev/null); do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    case "$exe" in
      *xray*) echo "$exe"; return 0;;
    esac
  done
  return 1
}

install_xray() {
  local xui
  xui=$(find_xui_xray) || true
  if [ -n "$xui" ]; then
    XRAY_BIN=$xui
    c_grn "[i] 复用 x-ui 面板自带 xray: ${XRAY_BIN} ($($XRAY_BIN version 2>/dev/null | head -1))"
    return 0
  fi
  command -v xray >/dev/null 2>&1 && { XRAY_BIN=$(command -v xray); return 0; }
  echo "[*] 未检测到 xray,开始安装..."
  if bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1; then
    XRAY_BIN=/usr/local/bin/xray
    return 0
  fi
  c_yel "[*] 官方安装脚本失败,尝试直接下载 release..."
  local LATEST URL
  LATEST=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null \
           | grep -oP '"tag_name":\s*"\K[^"]+' || true)
  [ -z "$LATEST" ] && { c_red "[!] 获取版本失败,请手动安装 xray 后再跑"; exit 1; }
  for URL in \
      "https://ghproxy.net/https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-64.zip" \
      "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/Xray-linux-64.zip"; do
    echo "    -> $URL"
    curl -fsSL -o /tmp/xray.zip "$URL" && break
  done
  [ -s /tmp/xray.zip ] || { c_red "[!] 下载失败,请检查网络"; exit 1; }
  if command -v unzip >/dev/null; then
    unzip -oq /tmp/xray.zip -d /usr/local/xray
  else
    mkdir -p /usr/local/xray && python3 -c "import zipfile;zipfile.ZipFile('/tmp/xray.zip').extractall('/usr/local/xray')"
  fi
  cp -f /usr/local/xray/xray /usr/local/bin/xray && chmod +x /usr/local/bin/xray
  XRAY_BIN=/usr/local/bin/xray
  c_grn "    xray 安装完成: ${XRAY_BIN}"
}

listening() { # $1=端口. 端口被占用返回0(匹配 :端口+空格,避免 IP 段误报)
  ss -lntup 2>/dev/null | grep -qE ":${1} "
}

# ---------------------------------------------------------------------------
gen_uuid()   { $XRAY_BIN uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }

gen_keys() { # 兼容新旧两种 x25519 输出格式(旧:PrivateKey:/Password (PublicKey):,新:Private key:/Public key:)
  local out
  out=$($XRAY_BIN x25519)
  PRIVATE_KEY=$(echo "$out" | awk '/PrivateKey:|Private key:/{print $NF}')
  PUBLIC_KEY=$(echo "$out" | awk '/Password \(PublicKey\):|Public key:/{print $NF}')
  if [ -z "$PRIVATE_KEY" ] || [ -z "$PUBLIC_KEY" ]; then
    echo "$out" >&2
    c_red "[!] 解析 x25519 输出失败,请先升级 xray 到最新版"
    exit 1
  fi
}

load_or_gen_creds() {
  if [ -f "$CREDS" ]; then
    . "$CREDS"
    c_yel "[i] 复用已有凭据(重跑不换 key,客户端不用改): $CREDS"
  else
    gen_uuid >/dev/null    # 触发生成
    UUID=$(gen_uuid)
    gen_keys
    SHORT_ID=$(openssl rand -hex 8)
    cat > "$CREDS" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
EOF
    chmod 600 "$CREDS"
  fi
}

write_unit() { # $1=config 路径
  cat > "$UNIT" <<EOF
[Unit]
Description=Xray Reality Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${XRAY_BIN} run -c $1
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$SERVICE" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# 落地机模式: Reality 入站(443) → SS outbound → 本机 x-ui SS
# ---------------------------------------------------------------------------
cmd_server() {
  check_root "$@"
  check_arch
  install_xray
  mkdir -p "$CFG_DIR"

  # 已部署检测:提供删除重置入口
  if [ -f "$CREDS" ]; then
    c_yel "[i] 检测到本机已部署过(server.creds 存在)"
    local act
    read -rp "    [y]=沿用凭据重新生成  [d]=删除部署重新开始  [回车]=沿用: " act
    case "$act" in
      d|D|del|delete)
        systemctl disable --now "$SERVICE" 2>/dev/null || true
        rm -f "$CREDS" "$SERVER_CFG" "$UNIT"
        systemctl daemon-reload
        c_grn "    ✓ 已删除本机部署,开始全新部署"
        ;;
    esac
  fi
  load_or_gen_creds

  # 业务协议: 默认 shadowsocks,可选 socks5 / both(第2参数或交互选择,凭据里持久化)
  PROTO=${MODE:-ss}
  if [ -n "${2:-}" ]; then
    case "$2" in
      ss|shadowsocks)    PROTO=ss ;;
      socks|socks5)      PROTO=socks ;;
      both|duo|ss-socks) PROTO=both ;;
      *) c_red "[!] 未知协议参数: $2 (可用 ss / socks / both)"; exit 1 ;;
    esac
  elif [ -z "${MODE:-}" ]; then
    local pt
    read -rp "  业务协议? [1]=Shadowsocks(默认)  [2]=SOCKS5  [3]=两者都要: " pt
    case "$pt" in
      2|socks|SOCKS|Socks) PROTO=socks ;;
      3|both|duo)          PROTO=both ;;
      *) PROTO=ss ;;
    esac
  fi

  SRV_PORT=$(prompt "Reality 监听端口" 443)
  while listening "$SRV_PORT" && ! systemctl is-active --quiet "$SERVICE"; do
    c_yel "[!] 端口 ${SRV_PORT} 已被占用: $(ss -lntup | grep -E ":${SRV_PORT} " | head -1)"
    read -rp "    输入新端口,或回车强制使用: " p2
    [ -n "$p2" ] || break
    SRV_PORT=$p2
  done
  local sni
  sni=$(pick_sni)
  verify_sni "$sni"

  # 业务参数: SS 与 SOCKS5 两组,按 PROTO 收集(both 时都问)
  local SS_PORT="" SS_PASS="" SS_METHOD="" SOCKS_PORT="" SOCKS_USER="" SOCKS_PASS="" SRV_SOCKS_PORT=""
  case "$PROTO" in
    socks)
      SOCKS_PORT=$(prompt "本机 SOCKS5 服务端口" 1080)
      SOCKS_USER=$(prompt "SOCKS 用户名(可选,回车=无认证)" "")
      [ -n "$SOCKS_USER" ] && SOCKS_PASS=$(prompt "SOCKS 密码" "")
      if ! listening "$SOCKS_PORT"; then
        c_yel "[!] 警告: 127.0.0.1:${SOCKS_PORT} 没有监听,确认 SOCKS5 服务已启用"
        read -rp "   继续?[y/N]: " ok; [ "${ok,,}" = y ] || exit 1
      fi
      ;;
    both)
      SRV_SOCKS_PORT=$(prompt "SOCKS5 隧道监听端口(落地)" 8443)
      while :; do
        local p3
        if [ "$SRV_SOCKS_PORT" = "$SRV_PORT" ]; then
          c_red "  [!] SOCKS5 隧道端口不能与 SS 隧道端口(${SRV_PORT})相同"
          read -rp "    输入新端口: " p3
          [ -n "$p3" ] || { c_red "  必须给一个不同端口"; p3=$SRV_SOCKS_PORT; }
          SRV_SOCKS_PORT=$p3; continue
        fi
        if listening "$SRV_SOCKS_PORT" && ! systemctl is-active --quiet "$SERVICE"; then
          c_yel "  [!] 端口 ${SRV_SOCKS_PORT} 已被占用: $(ss -lntup | grep -E ":${SRV_SOCKS_PORT} " | head -1)"
          read -rp "    输入新端口,或回车强制使用: " p3
          if [ -n "$p3" ]; then SRV_SOCKS_PORT=$p3; continue; fi
        fi
        break
      done
      SS_PORT=$(prompt "SS 隧道 → 本机 x-ui SS 端口" 8388)
      SS_PASS=$(prompt "SS 入站密码" "")
      [ -n "$SS_PASS" ] || { c_red "[!] SS 密码必填"; exit 1; }
      SS_METHOD=$(prompt "SS 加密方式" "aes-256-gcm")
      if ! listening "$SS_PORT"; then
        c_yel "[!] 警告: 127.0.0.1:${SS_PORT} 没有监听,确认 x-ui 的 SS 已启用"
        read -rp "   继续?[y/N]: " ok; [ "${ok,,}" = y ] || exit 1
      fi
      SOCKS_PORT=$(prompt "SOCKS5 隧道 → 本机 SOCKS5 端口" 1080)
      SOCKS_USER=$(prompt "SOCKS 用户名(可选,回车=无认证)" "")
      [ -n "$SOCKS_USER" ] && SOCKS_PASS=$(prompt "SOCKS 密码" "")
      if ! listening "$SOCKS_PORT"; then
        c_yel "[!] 警告: 127.0.0.1:${SOCKS_PORT} 没有监听,确认 SOCKS5 服务已启用"
        read -rp "   继续?[y/N]: " ok; [ "${ok,,}" = y ] || exit 1
      fi
      ;;
    *)
      SS_PORT=$(prompt "本机 x-ui 的 SS 入站端口" 8388)
      SS_PASS=$(prompt "本机 x-ui 的 SS 入站密码" "")
      [ -n "$SS_PASS" ] || { c_red "[!] SS 密码必填"; exit 1; }
      SS_METHOD=$(prompt "SS 加密方式(建议 aes-256-gcm)" "aes-256-gcm")
      if ! listening "$SS_PORT"; then
        c_yel "[!] 警告: 127.0.0.1:${SS_PORT} 上没有监听,确认 x-ui 的 SS 已启用"
        read -rp "   继续?[y/N]: " ok; [ "${ok,,}" = y ] || exit 1
      fi
      ;;
  esac

  # 持久化凭据 + 协议参数(重跑沿用,不换 key)
  cat > "$CREDS" <<EOF
UUID=$UUID
PRIVATE_KEY=$PRIVATE_KEY
PUBLIC_KEY=$PUBLIC_KEY
SHORT_ID=$SHORT_ID
MODE=$PROTO
EOF
  {
    [ -n "$SS_PORT" ]      && echo "SS_PORT=$SS_PORT"
    [ -n "$SS_PASS" ]      && echo "SS_PASS=$SS_PASS"
    [ -n "$SS_METHOD" ]    && echo "SS_METHOD=$SS_METHOD"
    [ -n "$SOCKS_PORT" ]   && echo "SOCKS_PORT=$SOCKS_PORT"
    [ -n "$SOCKS_USER" ]   && echo "SOCKS_USER=$SOCKS_USER"
    [ -n "$SOCKS_PASS" ]   && echo "SOCKS_PASS=$SOCKS_PASS"
  } >> "$CREDS"
  chmod 600 "$CREDS"

  PORT=$SRV_PORT SOCKS_EXT=${SRV_SOCKS_PORT:-8443} SNI=$sni PROTO=$PROTO \
  SS_PORT=$SS_PORT SS_PASS=$SS_PASS SS_METHOD=${SS_METHOD:-aes-256-gcm} \
  SOCKS_PORT=$SOCKS_PORT SOCKS_USER=${SOCKS_USER:-} SOCKS_PASS=${SOCKS_PASS:-} \
  UUID=$UUID PRIVATE_KEY=$PRIVATE_KEY SHORT_ID=$SHORT_ID \
  python3 - "$SERVER_CFG" <<'PY'
import json, os, sys
proto = os.environ["PROTO"]
sni = os.environ["SNI"]
def in_tunnel(tag, port):
    return {"tag": tag, "listen": "0.0.0.0", "port": int(port),
            "protocol": "vless",
            "settings": {"clients": [{"id": os.environ["UUID"], "flow": ""}], "decryption": "none"},
            "streamSettings": {"network": "tcp", "security": "reality",
              "realitySettings": {"dest": sni + ":443", "serverNames": [sni],
                "privateKey": os.environ["PRIVATE_KEY"], "shortIds": [os.environ["SHORT_ID"]]}}}
def ss_out(tag, port, method, password):
    return {"tag": tag, "protocol": "shadowsocks",
            "settings": {"servers": [{"address": "127.0.0.1",
              "port": int(port), "method": method, "password": password}]}}
def socks_out(tag, port):
    srv = {"address": "127.0.0.1", "port": int(port)}
    if os.environ.get("SOCKS_USER"):
        srv["user"] = os.environ["SOCKS_USER"]
        srv["pass"] = os.environ["SOCKS_PASS"]
    return {"tag": tag, "protocol": "socks", "settings": {"servers": [srv]}}

inbounds, outbounds, rules = [], [], []
if proto == "both":
    inbounds = [in_tunnel("reality-in-ss", os.environ["PORT"]),
                in_tunnel("reality-in-socks", os.environ["SOCKS_EXT"])]
    outbounds = [ss_out("ss-to-xui", os.environ["SS_PORT"], os.environ["SS_METHOD"], os.environ["SS_PASS"]),
                 socks_out("socks-to-biz", os.environ["SOCKS_PORT"]),
                 {"tag": "direct", "protocol": "freedom"}]
    rules = [{"type": "field", "inboundTag": ["reality-in-ss"], "outboundTag": "ss-to-xui"},
             {"type": "field", "inboundTag": ["reality-in-socks"], "outboundTag": "socks-to-biz"}]
elif proto == "socks":
    inbounds = [in_tunnel("reality-in", os.environ["PORT"])]
    outbounds = [socks_out("socks-to-biz", os.environ["SOCKS_PORT"]),
                 {"tag": "direct", "protocol": "freedom"}]
    rules = [{"type": "field", "inboundTag": ["reality-in"], "outboundTag": "socks-to-biz"}]
else:
    inbounds = [in_tunnel("reality-in", os.environ["PORT"])]
    outbounds = [ss_out("ss-to-xui", os.environ["SS_PORT"], os.environ["SS_METHOD"], os.environ["SS_PASS"]),
                 {"tag": "direct", "protocol": "freedom"}]
    rules = [{"type": "field", "inboundTag": ["reality-in"], "outboundTag": "ss-to-xui"}]
cfg = {"log": {"loglevel": "warning"},
       "inbounds": inbounds, "outbounds": outbounds,
       "routing": {"rules": rules}}
with open(sys.argv[1], "w") as f:
    json.dump(cfg, f, indent=2)
PY

  write_unit "$SERVER_CFG"
  sleep 1

  if systemctl is-active --quiet "$SERVICE"; then
    c_grn ""
    c_grn "==================== 落地机已就绪 ===================="
    c_grn " 连接参数(交给中转机/家里 relay 模式填写):"
    c_grn ""
    c_grn "  落地IP     : $(curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo 请手动填公网IP)"
    c_grn "  监听端口   : ${SRV_PORT}"
    c_grn "  UUID       : ${UUID}"
    c_grn "  PublicKey  : ${PUBLIC_KEY}"
    c_grn "  shortId    : ${SHORT_ID}"
    c_grn "  SNI/dest   : ${sni}"
    if [ "$PROTO" = "both" ]; then
      c_grn "  隧道① : ${SRV_PORT}  → SS 业务(127.0.0.1:${SS_PORT}/${SS_METHOD})"
      c_grn "  隧道② : ${SRV_SOCKS_PORT:-8443} → SOCKS5(127.0.0.1:${SOCKS_PORT})${SOCKS_USER:+ 认证 ${SOCKS_USER}}"
      c_grn "  (relay 端加两条条目:落地端口 ${SRV_PORT} 与 ${SRV_SOCKS_PORT:-8443})"
    elif [ "$PROTO" = "socks" ]; then
      c_grn "  业务SOCKS  : 127.0.0.1:${SOCKS_PORT}"
      [ -n "$SOCKS_USER" ] && c_grn "  认证       : ${SOCKS_USER} / ${SOCKS_PASS}"
    else
      c_grn "  业务SS     : 127.0.0.1:${SS_PORT} (${SS_METHOD})"
    fi
    c_grn "  私钥已存   : ${CREDS}  (不要外传)"
    c_grn "======================================================"
  else
    c_red "[!] 服务启动失败,日志:"
    journalctl -u "$SERVICE" --no-pager -n 20 -o cat || true
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 中转机模式: 多个 SS 入站 → 各自 Reality 出站(每落地一个端口)
# ---------------------------------------------------------------------------
cmd_relay() {
  check_root "$@"
  check_arch
  install_xray
  mkdir -p "$CFG_DIR"

  if [ -f "$RELAY_SSPASS" ]; then
    SS_PASS=$(cat "$RELAY_SSPASS")
  else
    SS_PASS=$(openssl rand -hex 16)
    echo -n "$SS_PASS" > "$RELAY_SSPASS"
    chmod 600 "$RELAY_SSPASS"
  fi

  # SOCKS5 入站认证:读已有;没有则等添加 socks 条目时设置;生成配置前兜底
  SOCKS_UAUTH=""
  if [ -f "$CFG_DIR/relay.socksauth" ]; then
    SOCKS_UAUTH=$(cat "$CFG_DIR/relay.socksauth")
    SOCKS_USER=${SOCKS_UAUTH%% *}
    SOCKS_PASS=${SOCKS_UAUTH#* }
    c_yel "  [i] SOCKS5 入站认证: ${SOCKS_USER} / ${SOCKS_PASS}(存 ${CFG_DIR}/relay.socksauth)"
  fi

  local add_more=0
  if [ -f "$RELAY_ENTRIES" ]; then
    while :; do
      if [ -s "$RELAY_ENTRIES" ]; then
        c_yel "[i] 已有落地条目:"
        cat "$RELAY_ENTRIES"
        read -rp "    [y]=追加条目  [d]=删除条目  [回车]=直接用现有: " ok
      else
        c_yel "[i] 条目已清空,进入添加模式"
        add_more=1
        break
      fi
      case "${ok,,}" in
        y) add_more=1; break ;;
        d) delete_entries ;;
        *) add_more=0; break ;;
      esac
    done
    local next; next=$(tail -1 "$RELAY_ENTRIES" 2>/dev/null | awk '{print $1+1}')
    SS_PORT=${next:-8388}
  else
    add_more=1
    SS_PORT=8388
  fi

  local first=1
  if [ "$add_more" -eq 0 ]; then
    c_yel "[i] 沿用已有条目($(wc -l < "$RELAY_ENTRIES" | tr -d ' ') 条),直接生成配置"
  else
  echo "[*] 添加落地机条目(本地端口回车默认递增,可自行修改)"
  while :; do
    if [ "$first" -eq 0 ]; then
      read -rp "  继续添加下一台?(y/N): " cont
      [ "${cont,,}" = "y" ] || { c_grn "  已结束添加."; break; }
    fi
    first=0
    echo "----------------------------------------"
    while :; do
      SS_PORT=$(prompt "  本地端口(daed 节点填这个端口)" "$SS_PORT")
      local busy_port again
      busy_port=$(ss -lntup 2>/dev/null | grep -E ":${SS_PORT} " | head -1)
      if [ -n "$busy_port" ]; then
        c_yel "  [!] 端口 ${SS_PORT} 已被占用: $busy_port"
        read -rp "    输入新端口,或回车强制使用: " again
        if [ -n "$again" ]; then SS_PORT=$again; continue; fi
      fi
      if [ -s "$RELAY_ENTRIES" ] && grep -qE "^${SS_PORT} " "$RELAY_ENTRIES"; then
        c_yel "  [!] 端口 ${SS_PORT} 已在现有条目中使用(启动会失败)"
        read -rp "    输入新端口,或回车强制使用: " again
        if [ -n "$again" ]; then SS_PORT=$again; continue; fi
      fi
      break
    done
    local ip uport uuid pub sid remark
    ip=$(prompt "  落地IP(直接回车结束)" "")
    [ -n "$ip" ] || break
    uport=$(prompt "  落地 Reality 端口" 443)
    uuid=$(prompt "  UUID" "")
    pub=$(prompt "  PublicKey" "")
    sid=$(prompt "  shortId" "")
    [ -n "$uuid" ] && [ -n "$pub" ] && [ -n "$sid" ] || { c_red "  [!] UUID/公钥/shortId 必填,该条丢弃"; continue; }
    sni=$(pick_sni)
    remark=$(prompt "  备注(可选)" "")
    proto=$(prompt "  本条协议(回车=SS / 输入socks=SOCKS5)" "ss")
    case "$proto" in socks|SOCKS|s5|S5) proto=socks ;; *) proto=ss ;; esac
    if [ "$proto" = "socks" ] && [ ! -f "$CFG_DIR/relay.socksauth" ]; then
      local su sp
      read -rp "  SOCKS5 入站用户名(回车=自动生成): " su
      if [ -n "$su" ]; then
        read -rp "  SOCKS5 入站密码(回车=自动生成): " sp
        [ -n "$sp" ] || sp=$(openssl rand -hex 12)
      else
        su="socks$(openssl rand -hex 3)"
        sp=$(openssl rand -hex 12)
      fi
      SOCKS_UAUTH="$su $sp"
      SOCKS_USER=$su
      SOCKS_PASS=$sp
      echo -n "$SOCKS_UAUTH" > "$CFG_DIR/relay.socksauth"
      chmod 600 "$CFG_DIR/relay.socksauth"
      c_grn "  ✓ SOCKS5 入站认证已设置: ${SOCKS_USER} / ${SOCKS_PASS}"
    fi
    echo "${SS_PORT} ${ip} ${uport} ${uuid} ${pub} ${sid} ${sni} ${remark} ${proto}" >> "$RELAY_ENTRIES"
    SS_PORT=$((SS_PORT + 1))
    c_grn "  ✓ 已添加 ${ip}:${uport} [${proto}]"
  done
  fi

  [ -s "$RELAY_ENTRIES" ] || { c_red "[!] 没有有效条目,退出"; exit 1; }

  # 兜底:存在 socks 条目却没认证文件(例如手动编辑过 entries)
  if [ -z "$SOCKS_UAUTH" ] && grep -qE ' socks$' "$RELAY_ENTRIES" 2>/dev/null; then
    local su sp
    read -rp "  [!] 检测到 SOCKS5 条目但未设认证:回车=自动生成(n=保持无认证): " _a
    if [ "${_a,,}" != "n" ]; then
      su="socks$(openssl rand -hex 3)"
      sp=$(openssl rand -hex 12)
      SOCKS_UAUTH="$su $sp"
      SOCKS_USER=$su
      SOCKS_PASS=$sp
      echo -n "$SOCKS_UAUTH" > "$CFG_DIR/relay.socksauth"
      chmod 600 "$CFG_DIR/relay.socksauth"
      c_grn "  ✓ SOCKS5 认证已生成: ${SOCKS_USER} / ${SOCKS_PASS}"
    fi
  fi

  echo "[*] 生成配置..."

  SS_PASS="$SS_PASS" SOCKS_UAUTH="$SOCKS_UAUTH" \
  python3 - "$RELAY_ENTRIES" "$CFG_DIR/tunnel-relay.json" <<'PY'
import json, os, sys
auth = os.environ.get("SOCKS_UAUTH", "").strip()
lines = [l for l in open(sys.argv[1]) if l.strip() and not l.startswith("#")]
inbounds, outbounds, rules = [], [], []
for i, raw in enumerate(lines):
    e = raw.split()
    proto = "ss"
    if e and e[-1] in ("ss", "socks"):      # 行尾协议标记(向后兼容:无标记=ss)
        proto = e.pop()
    lp, ip, rp, uuid, pub, sid = e[0], e[1], e[2], e[3], e[4], e[5]
    sni = e[6] if len(e) > 6 else "www.cloudflare.com"
    remark = " ".join(e[7:])
    in_tag = f"in-{i}" if proto == "socks" else f"ss-in-{i}"
    if proto == "socks":
        settings = {"auth": "noauth"}
        if auth:
            u, p = auth.split(" ", 1)
            settings = {"auth": "password", "accounts": [{"user": u, "pass": p}]}
        inbounds.append({"tag": in_tag, "listen": "0.0.0.0", "port": int(lp),
                         "protocol": "socks", "settings": settings})
    else:
        inbounds.append({"tag": in_tag, "listen": "0.0.0.0", "port": int(lp),
                         "protocol": "shadowsocks",
                         "settings": {"method": "aes-256-gcm", "password": os.environ["SS_PASS"],
                                      "network": "tcp,udp"}})
    outbounds.append({"tag": f"out-{i}", "protocol": "vless",
                      "settings": {"vnext": [{"address": ip, "port": int(rp),
                        "users": [{"id": uuid, "encryption": "none", "flow": ""}]}]},
                      "streamSettings": {"network": "tcp", "security": "reality",
                        "realitySettings": {"serverName": sni,
                          "fingerprint": "chrome", "publicKey": pub, "shortId": sid}}})
    rules.append({"type": "field", "inboundTag": [in_tag], "outboundTag": f"out-{i}"})
cfg = {"log": {"loglevel": "warning"},
       "inbounds": inbounds, "outbounds": outbounds + [{"tag": "direct", "protocol": "freedom"}],
       "routing": {"rules": rules}}
with open(sys.argv[2], "w") as f:
    json.dump(cfg, f, indent=2)
PY

  write_unit "$CFG_DIR/tunnel-relay.json"
  sleep 1

  if systemctl is-active --quiet "$SERVICE"; then
    c_grn ""
    c_grn "==================== 中转机已就绪 ===================="
    local me
    me=$(curl -fsSL -4 https://api.ipify.org 2>/dev/null || echo "你的IP")
    c_grn "  客户端接入(每落地一条,协议按条目标注):"
    local ss_n=0 socks_n=0
    while read -r e; do
      [ -n "$e" ] && [ "${e:0:1}" != "#" ] || continue
      local lp ip remark p
      lp=$(echo "$e" | awk '{print $1}'); ip=$(echo "$e" | awk '{print $2}')
      p=$(echo "$e" | awk '{print $NF}')
      remark=$(echo "$e" | awk '{if (NF>=9) print $(NF-1); else print ""}')
      if [ "$p" = "socks" ]; then
        socks_n=$((socks_n+1))
        echo "    SOCKS5  ${me}:${lp}  ${remark:+#${remark}}"
      else
        ss_n=$((ss_n+1))
        echo "    ss://$(echo -n "aes-256-gcm:${SS_PASS}@${me}:${lp}" | base64 -w0)#${remark:-${ip}}"
      fi
    done < "$RELAY_ENTRIES"
    if [ "$ss_n" -gt 0 ]; then
      c_grn "  SS 密码: ${SS_PASS}(存 ${RELAY_SSPASS});→ daed 添加上面的 ss:// 节点"
    fi
    if [ "$socks_n" -gt 0 ]; then
      if [ -n "$SOCKS_UAUTH" ]; then
        c_grn "  SOCKS5 认证: ${SOCKS_USER} / ${SOCKS_PASS}(存 ${CFG_DIR}/relay.socksauth);→ 应用填账号密码"
      else
        c_yel "  SOCKS5 无认证(仅限内网)——建议设认证(重跑 relay 或写 relay.socksauth)"
      fi
    fi
    c_grn "======================================================"
  else
    c_red "[!] 服务启动失败,日志:"
    journalctl -u "$SERVICE" --no-pager -n 20 -o cat || true
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# 删除落地条目(交互),relay 菜单与 del 子命令共用
delete_entries() {
  if [ ! -s "$RELAY_ENTRIES" ]; then
    c_yel "  [i] 没有条目可删"
    return
  fi
  echo "  [i] 当前落地条目:"
  local i line ip uport remark lst=/tmp/.relay_lines
  : > "$lst"
  i=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in \#*) continue;; esac
    echo "$line" >> "$lst"
    ip=$(echo "$line"     | awk '{print $2}')
    uport=$(echo "$line"  | awk '{print $3}')
    remark=$(echo "$line" | awk '{print $NF}')
    echo "    [$i] ${ip}:${uport}${remark:+ [${remark}]}"
    i=$((i+1))
  done < "$RELAY_ENTRIES"
  local sel
  read -rp "  删除哪条?(序号,逗号分隔多条 / a=全部 / 回车取消): " sel
  if [ -z "$sel" ]; then
    echo "    已取消"; rm -f "$lst"; return
  fi
  local lines=() line2 n idx skip nums
  mapfile -t lines < "$lst"
  if [ "$sel" = "a" ] || [ "${sel,,}" = "all" ]; then
    rm -f "$RELAY_ENTRIES" "$CFG_DIR/tunnel-relay.json"
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    c_grn "  ✓ 已清空全部条目,服务已停"
    rm -f "$lst"; return
  fi
  IFS=',' read -ra nums <<< "$sel"
  : > "$RELAY_ENTRIES"
  n=0
  for line2 in "${lines[@]}"; do
    n=$((n+1)); skip=0
    for idx in "${nums[@]}"; do
      [ "$idx" -eq "$n" ] && { skip=1; break; }
    done
    [ "$skip" -eq 0 ] && echo "$line2" >> "$RELAY_ENTRIES"
  done
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$CFG_DIR/tunnel-relay.json"
  c_grn "  ✓ 已删除"
  if [ -s "$RELAY_ENTRIES" ]; then
    echo "    剩余条目:"
    cat "$RELAY_ENTRIES"
  fi
  rm -f "$lst"
}

cmd_del() {
  check_root "$@"
  delete_entries
  c_yel "[i] 删除后可重跑 relay 重新安装/添加"
}

# ---------------------------------------------------------------------------
cmd_status() {
  echo "== 服务 =="
  systemctl is-active "$SERVICE" 2>/dev/null || echo "未安装/未运行"
  systemctl status "$SERVICE" --no-pager 2>/dev/null | sed -n '1,5p' || true
  echo "== 监听端口 =="
  ss -lntup | grep -E "$SERVICE|:44[0-9]|:838[0-9]" | head -10 || true
  echo "== 配置文件 =="
  ls -la "$SERVER_CFG" "$CFG_DIR/tunnel-relay.json" "$RELAY_ENTRIES" 2>/dev/null || true
}

cmd_remove() {
  check_root "$@"
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "$UNIT" "$SERVER_CFG" "$CFG_DIR/tunnel-relay.json"
  read -rp "是否连凭据/条目一起删除(删除后需从对端重新录入)?[y/N]: " ok
  [ "${ok,,}" = y ] && rm -f "$CREDS" "$RELAY_ENTRIES" "$RELAY_SSPASS"
  systemctl daemon-reload
  c_grn "[ok] 已清理"
}

# ---------------------------------------------------------------------------
case "${1:-}" in
  server) cmd_server "$@" ;;
  relay)  cmd_relay "$@" ;;
  del|delete) cmd_del "$@" ;;
  status) cmd_status ;;
  remove) cmd_remove "$@" ;;
  *) usage ;;
esac