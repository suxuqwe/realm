
#!/usr/bin/env bash
set -uo pipefail

BASE="/etc/realm"
BIN="/usr/local/bin/realm"
RULES="$BASE/rules.tsv"
CONF="$BASE/config.toml"
MODE="$BASE/mode"
SERVICE="/etc/systemd/system/realm.service"

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 用户运行。"
    exit 1
fi

mkdir -p "$BASE"
touch "$RULES"
chmod 600 "$RULES"
[[ -s "$MODE" ]] || echo "tcp_udp" > "$MODE"
chmod 600 "$MODE"

pause() {
    echo
    read -r -p "按回车键返回菜单..." _
}

valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] &&
        (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

valid_host() {
    python3 - "$1" <<'PY'
import sys, ipaddress
h = sys.argv[1].strip()
if not h or any(c.isspace() for c in h) or "/" in h:
    raise SystemExit(1)
try:
    ipaddress.ip_address(h)
except ValueError:
    h = h.rstrip(".")
    if len(h) > 253 or not h or not all(
        len(x) <= 63 and x and x[0].isalnum()
        and x[-1].isalnum()
        and all(c.isalnum() or c == "-" for c in x)
        for x in h.split(".")
    ):
        raise SystemExit(1)
PY
}

format_addr() {
    local host="$1" port="$2"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

port_busy() {
    ss -H -lntu 2>/dev/null |
        awk -v p="$1" '
        {
            a=$5
            sub(/^.*:/,"",a)
            if (a == p) found=1
        }
        END { exit !found }'
}

rule_port_exists() {
    awk -F '\t' -v p="$1" '$1==p {f=1} END {exit !f}' "$RULES"
}

random_port() {
    local p i
    for ((i=0; i<1000; i++)); do
        p=$(shuf -i 10000-65535 -n 1) || return 1
        if ! port_busy "$p" && ! rule_port_exists "$p"; then
            echo "$p"
            return 0
        fi
    done
    echo "没有找到可用端口。"
    return 1
}

install_realm() {
    local arch tmp asset found
    case "$(uname -m)" in
        x86_64|amd64) arch="x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) arch="aarch64-unknown-linux-gnu" ;;
        *) echo "不支持的 CPU 架构：$(uname -m)"; return 1 ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || return 1
        apt-get install -y curl ca-certificates tar python3 iproute2 util-linux file || return 1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl ca-certificates tar python3 iproute util-linux file || return 1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl ca-certificates tar python3 iproute util-linux file || return 1
    else
        echo "不支持的包管理器。"
        return 1
    fi

    tmp=$(mktemp -d) || return 1
    echo "正在获取 Realm 官方版本信息..."

    if ! curl -fsSL --retry 3 \
        https://api.github.com/repos/zhboner/realm/releases/latest \
        -o "$tmp/release.json"; then
        echo "获取官方版本信息失败。"
        rm -rf "$tmp"
        return 1
    fi

    asset=$(python3 - "$tmp/release.json" "$arch" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
arch = sys.argv[2]
items = [
    a for a in data.get("assets", [])
    if arch in a.get("name", "")
    and "realm-slim" in a.get("name", "")
    and a.get("name", "").endswith(".tar.gz")
]
if items:
    items.sort(key=lambda x: ("glibc" not in x["name"], x["name"]))
    print(items[0]["browser_download_url"])
PY
)

    if [[ -z "$asset" ]]; then
        echo "没有找到适合本机架构的 Realm 压缩包。"
        rm -rf "$tmp"
        return 1
    fi

    echo "正在下载 Realm..."
    if ! curl -fL --retry 3 "$asset" -o "$tmp/realm.tar.gz"; then
        echo "下载失败。"
        rm -rf "$tmp"
        return 1
    fi

    if ! tar -xzf "$tmp/realm.tar.gz" -C "$tmp"; then
        echo "解压失败。"
        rm -rf "$tmp"
        return 1
    fi

    found=$(find "$tmp" -type f \
        \( -name realm-slim -o -name realm \) -print -quit)

    if [[ -z "$found" ]] || ! file "$found" | grep -q ELF; then
        echo "压缩包内没有找到有效的 Realm 程序。"
        rm -rf "$tmp"
        return 1
    fi

    if ! install -o root -g root -m 755 "$found" "$BIN"; then
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"

    if ! "$BIN" --help >/dev/null 2>&1; then
        echo "Realm 程序检查失败。"
        return 1
    fi

    echo "Realm 安装成功。"
    "$BIN" --version 2>&1 || true
}

generate_config() {
    python3 - "$RULES" "$CONF" "$MODE" <<'PY'
import sys, json, ipaddress, os

rules_file, conf_file, mode_file = sys.argv[1:4]
mode = open(mode_file, encoding="utf-8").read().strip()
if mode not in ("tcp", "tcp_udp"):
    raise SystemExit("转发模式不正确。")

rules = []
with open(rules_file, encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\r\n")
        if not line:
            continue
        fields = line.split("\t")
        if len(fields) != 4:
            raise SystemExit("规则文件格式错误：" + repr(line))
        lp, host, rp, name = fields
        if not lp.isdigit() or not rp.isdigit():
            raise SystemExit("规则端口格式错误：" + repr(line))
        if not (1 <= int(lp) <= 65535 and 1 <= int(rp) <= 65535):
            raise SystemExit("规则端口超出范围。")
        try:
            ip = ipaddress.ip_address(host.strip("[]"))
            if ip.version == 6:
                host = "[" + str(ip) + "]"
            else:
                host = str(ip)
        except ValueError:
            if ":" in host and not host.startswith("["):
                host = "[" + host + "]"
        rules.append((lp, host, rp))

if not rules:
    raise SystemExit("没有转发规则，不生成配置。")

lines = [
    "# Realm 自动生成配置",
    "",
    "[network]",
    "no_tcp = false",
    "use_udp = " + ("true" if mode == "tcp_udp" else "false"),
    "",
]

for lp, host, rp in rules:
    lines.extend([
        "[[endpoints]]",
        "listen = " + json.dumps("0.0.0.0:" + lp),
        "remote = " + json.dumps(host + ":" + rp),
        "",
    ])

tmp = conf_file + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))
os.chmod(tmp, 0o600)
os.replace(tmp, conf_file)
PY
}

install_service() {
    cat > "$SERVICE" <<'UNIT'
[Unit]
Description=Realm TCP and UDP Forwarding Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/realm -c /etc/realm/config.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
}

reload_realm() {
    if [[ ! -s "$RULES" ]]; then
        echo "当前没有转发规则，停止 Realm 服务。"
        systemctl stop realm.service 2>/dev/null || true
        systemctl disable realm.service >/dev/null 2>&1 || true
        return 0
    fi

    if ! generate_config; then
        echo "配置生成失败，未重启服务。"
        return 1
    fi

    install_service || return 1
    systemctl enable realm.service >/dev/null || return 1

    echo "正在重启 Realm..."
    if systemctl restart realm.service; then
        sleep 1
        if systemctl is-active --quiet realm.service; then
            echo "Realm 运行正常。"
            return 0
        fi
    fi

    echo "启动失败，最近日志："
    journalctl -u realm.service -n 30 --no-pager
    return 1
}

show_rules() {
    echo
    echo "================ 转发规则 ================"
    if [[ ! -s "$RULES" ]]; then
        echo "当前没有转发规则。"
        return
    fi

    printf "%-5s %-10s %-32s %-10s %s\n" 编号 监听端口 目标地址 目标端口 备注
    local i=0 lp host rp name
    while IFS=$'\t' read -r lp host rp name; do
        [[ -n "${lp:-}" ]] || continue
        ((i+=1))
        printf "%-5s %-10s %-32s %-10s %s\n" \
            "$i" "$lp" "$(format_addr "$host" "$rp")" "$rp" "${name:--}"
    done < "$RULES"
    echo "=========================================="
}

add_rule() {
    [[ -x "$BIN" ]] || {
        echo "请先选择菜单 1 安装 Realm。"
        return 1
    }

    local host rp name lp
    read -r -p "目标服务器 IP 或域名：" host
    host="${host#[}"
    host="${host%]}"

    if ! valid_host "$host"; then
        echo "目标地址格式不正确。"
        return 1
    fi

    read -r -p "目标端口：" rp
    if ! valid_port "$rp"; then
        echo "目标端口必须是 1-65535。"
        return 1
    fi

    read -r -p "备注（可留空）：" name
    name=${name//$'\t'/ }
    name=${name//$'\n'/ }

    lp=$(random_port) || return 1
    printf '%s\t%s\t%s\t%s\n' "$lp" "$host" "$rp" "$name" >> "$RULES"

    if reload_realm; then
        echo "添加成功：本机端口 $lp -> $(format_addr "$host" "$rp")"
        echo "当前模式：$(cat "$MODE")"
        echo "请确认云安全组和系统防火墙放行端口 $lp。"
    else
        echo "启动失败，撤销本次规则。"
        sed -i '$d' "$RULES"
        reload_realm || true
        return 1
    fi
}

delete_rule() {
    show_rules
    [[ -s "$RULES" ]] || return 0

    local n total tmp
    total=$(awk 'NF {n++} END {print n+0}' "$RULES")
    read -r -p "请输入要删除的编号（1-$total）：" n

    if [[ ! "$n" =~ ^[0-9]+$ ]] || (( n < 1 || n > total )); then
        echo "编号无效。"
        return 1
    fi

    tmp=$(mktemp) || return 1
    awk -v n="$n" 'NF {i++; if (i != n) print}' "$RULES" > "$tmp"
    cat "$tmp" > "$RULES"
    rm -f "$tmp"

    reload_realm
}

switch_mode() {
    local old choice new
    old=$(cat "$MODE" 2>/dev/null || echo tcp_udp)

    echo
    echo "当前模式：$([[ "$old" == tcp ]] && echo TCP || echo TCP+UDP)"
    echo "1. 仅 TCP"
    echo "2. TCP + UDP"
    echo "0. 返回"
    read -r -p "请选择：" choice

    case "$choice" in
        1) new=tcp ;;
        2) new=tcp_udp ;;
        0) return 0 ;;
        *) echo "无效选项。"; return 1 ;;
    esac

    printf '%s\n' "$new" > "$MODE"

    if reload_realm; then
        echo "模式已设置为：$([[ "$new" == tcp ]] && echo TCP || echo TCP+UDP)"
    else
        printf '%s\n' "$old" > "$MODE"
        reload_realm || true
        echo "切换失败，已恢复原模式。"
        return 1
    fi
}

status_realm() {
    systemctl --no-pager --full status realm.service || true
    echo
    journalctl -u realm.service -n 20 --no-pager || true
}

menu() {
    while true; do
        echo
        echo "======================================"
        echo "       Realm 随机端口转发管理器"
        echo "======================================"
        echo "1. 安装 / 更新 Realm"
        echo "2. 添加转发规则（随机端口）"
        echo "3. 查看全部规则"
        echo "4. 删除转发规则"
        echo "5. 查看服务状态和日志"
        echo "6. 重启 Realm"
        echo "7. 设置开机自启"
        echo "8. 切换 TCP / TCP+UDP 模式"
        echo "9. 退出"
        echo "======================================"
        read -r -p "请输入选项 [1-9]：" choice

        case "$choice" in
            1)
                if install_realm; then
                    echo "安装完成。添加转发规则后才会启动服务。"
                    if [[ -s "$RULES" ]]; then
                        reload_realm
                    fi
                fi
                pause
                ;;
            2) add_rule; pause ;;
            3) show_rules; pause ;;
            4) delete_rule; pause ;;
            5) status_realm; pause ;;
            6) reload_realm; pause ;;
            7)
                if [[ -s "$RULES" ]]; then
                    reload_realm
                else
                    echo "没有转发规则，暂不启用服务。"
                fi
                pause
                ;;
            8) switch_mode; pause ;;
            9) exit 0 ;;
            *) echo "无效选项。" ;;
        esac
    done
}

menu
