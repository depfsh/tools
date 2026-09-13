#!/usr/bin/env bash
#
# 伪装站点体检 —— 在一台 VPS 上挑 shadowquic 能用的 cover site，并量它的延迟。
#
#   ./probe-cover-sites.sh                  体检内置候选清单
#   ./probe-cover-sites.sh a.com b.com      只体检指定域名
#   ./probe-cover-sites.sh -n 5 -t 3        每个地址探 5 次、单次超时 3 秒
#   ./probe-cover-sites.sh -p 8443          伪装上游不在 443 时指定端口
#   ./probe-cover-sites.sh -4               只看 IPv4（默认 v6 + v4 都看）
#   ./probe-cover-sites.sh -f list.txt      从文件读候选（每行一个，# 开头是注释）
#   ./probe-cover-sites.sh -a               不做「国内是否可达」的过滤（节点不服务国内用户时）
#
# 自包含：只用 bash + python3 + openssl（curl 可选），不需要 cargo、不需要把
# 节点跑起来，直接扔到目标 VPS 上执行。
#
# ⚠️ 输出一律英文（CLAUDE.md §5：源码里不出现中文字符串，注释可用中文）。
#
#
# ## 为什么需要体检，而不是随手填一个域名
#
# JLS 的抗探测**整个建立在伪装站点上**：认证失败时节点不回任何自己的东西，
# 而是把原始 ClientHello 原样转发给伪装站点，让探测者看到一个真实站点的真实
# 响应。伪装站点选错 = 反主动探测失效，而且是**静默**失效 —— 合法用户一切
# 正常，运维看不出任何异常。
#
# `Server::bind` 的 D8 准入校验会真的去连一次伪装上游，**连不上就拒绝启动**：
# 带着一个坏上游跑起来比不启动更糟。这个脚本把那次校验提前到部署之前，免得
# 改完面板才发现节点起不来。
#
#
# ## 判据：伪装站点必须真的在 udp/<port> 上说 HTTP/3
#
# 最容易想当然的地方。**大量一线站点根本不提供 HTTP/3** —— 实测
# `www.icloud.com` / `www.apple.com` / `www.microsoft.com` / `www.tiktok.com`
# 的 TCP 443 都好得很，QUIC 一个字节不回。拿它们当伪装，节点起不来。
#
# 节点侧的判据（src/relay/upstream.rs）：
#   * ALPN 只报 **h3**；
#   * 只做 QUIC 握手，**不校验证书**（AcceptAnyCert）—— 证书过没过期、签给谁的
#     都不影响能不能用；
#   * RFC 8305 happy eyeballs：v6 那组先跑，v4 那组晚 300ms 起跑；
#   * 单次探测超时 5 秒；
#   * `MAX_PROBE_CANDIDATES = 8` 是**每族各 8 个**（`first_answering` 对 v6 与 v4
#     各自 `.take(8)`），不是两族合计 8。本脚本的 -m 默认也按每族 8 对齐。
#
#
# ## 这个脚本能证明什么、不能证明什么
#
# 能证明：
#   1. 这台 VPS 的**出网 udp/<port> 通不通**（有机房只封 UDP 不封 TCP）；
#   2. 目标 IP 的 udp/<port> 上**有没有 QUIC 在应答**，以及 RTT / 丢包；
#   3. 站点**对外宣称**支持 h3（HTTPS 响应的 `Alt-Svc`），以及 TCP/TLS 侧的
#      RTT 与证书 SAN。
#
# 不能证明：它没有做完整的 QUIC Initial + TLS 握手（那需要 AES-GCM 报文保护，
# python stdlib 做不了）。所以用的是 **Version Negotiation 触发包** —— 长包头 +
# 一个不存在的版本号 + 补齐到 1200 字节，按 RFC 9000 §6 任何合规 QUIC 服务端
# **必须**回一个 VN 包。它零加密零状态，是最干净的「这里有没有 QUIC」探针。
#
# ⚠️ **VN 应答只说明「有 QUIC」，不说明「有 h3」。** 所以结论分三档：
#   READY   VN 通 + 站点宣称 h3   —— 可以填面板
#   UNSURE  VN 通但没有 h3 证据   —— 可能是别的 QUIC 协议，节点用 ALPN h3
#                                   握手仍可能被 D8 拒；填之前先自己确认
#   NO      VN 不通               —— 不能用
# 最终判据永远是节点启动时那次 D8 准入。
#
#
# ## 出网 udp/<port> 被封是真实存在的
#
# 脚本先拿几个公认稳的 h3 端点做**对照组**（两个地址族都探）。如果对照组也
# 全灭而 TCP 正常，那不是域名选错，是**这台机器的机房封了出网 udp/<port>** ——
# 换哪个域名都没用，只能让机房放开，或者把伪装站点挪到非 443 的 UDP 端口。
# （2026-09 一台 staging 机就是这样：tcpdump 看到包正常离开网卡、iptables
# 计数器一个没动，问题在上游。）
#
#
# ## 选出来之后填哪里
#
# **面板是权威**，不要写进节点的 server.json：
#   * 节点 `sni`            = 选中的域名
#   * 节点 `cover_upstream` = `域名:<port>`（留空则节点按 `sni:443` 自取）
#
# ⚠️ 客户端的 SNI 来自**同一个** `sni` 字段（经订阅下发），两边必须逐字节一致。
# 这也是为什么这两个值只能有一个权威来源。
#
# 除了「能不能用」，挑的时候还要看：
#   * **在用户所在地没有被墙**：见下，这条比其它几条都硬。
#   * **像不像正常流量**：这台节点的用户平时会不会访问它；冷门域名本身就是特征。
#   * **每个地址都应答**：有的地址回 QUIC、有的一个包不回，就是每次启动抽一次签 ——
#     节点启动时解析一次、只试拿到的那批地址，某次全落在不应答的那批上，D8 准入
#     过不了、节点起不来，而且是随机的（运维看到的现象是「节点有时候起不来」）。
#     脚本把这种标成 mixed，但**只报现象不报成因**：可能是第二家 CDN、灰度、限流
#     或纯丢包，探针分不出来。实测 `www.amazon.com` 那次是 CloudFront（18.65.x）
#     与 Akamai（23.41.x）在摇摆 —— 那是手工核 IP 段核出来的，不是脚本的结论。
#     而且摇摆更常发生在**两次解析之间**（同一台机器前后几分钟一次全 CloudFront、
#     一次全 Akamai），那种一次运行看不出来，所以选定之前要隔开时间多跑几次。
#   * **双栈**：v6 是主路径（CLAUDE.md §3.6），优先选 AAAA + A 都有的。
#   * **延迟**：每次认证失败都要付一次到伪装站点的往返，节点启动时也要付一次。
#
#
# ## ⚠️ 探得通 ≠ 能用：伪装域名同时是**客户端的 SNI**
#
# 这个脚本是在**节点那台 VPS 上**跑的，它量的是「节点能不能连到伪装站点」。
# 但伪装域名还有第二个身份：客户端连节点时用的就是这个 SNI（经订阅下发的
# 同一个 `sni` 字段）。所以域名必须在**用户那一侧**也是通的。
#
# 最典型的坑是 Google 系（`*.google.com` / `googleapis` / `gstatic` / `youtube`
# 等）：香港、日本的 VPS 连它们又快又稳，脚本会痛快地报 READY；可国内用户拿
# `fonts.gstatic.com` 当 SNI 去连一个境外 IP，GFW 在 SNI 上直接就掐了 ——
# **节点一个用户都接不到，而节点侧的日志完全正常**（连接根本没到）。
#
# 脚本没法从境外 VPS 上探到这件事，所以把它写成了一份已知清单
# （`CN_BLOCKED`）：命中的域名一律不进 READY，单独归到 BLOCKED-CN 并说明原因。
# 这台节点不服务国内用户时用 `-a` 关掉这个判断。
#
# 清单是**启发式**的，不可能全。加候选之前自己想一遍：用户在的那个网络里，
# 这个域名平时能不能打开。

set -euo pipefail

PROBES=3          # 每个地址探几次
TIMEOUT=2         # 单次探测超时（秒）；节点侧是 5 秒，这里紧一点好把慢站点显出来
PORT=443
MAX_IPS=8         # 每族最多探几个地址；与节点的 MAX_PROBE_CANDIDATES 对齐
WANT_V6=1
WANT_V4=1
CHECK_CN=1        # 是否把「国内打不开」的域名挑出来；-a 关掉
CANDIDATES=()

# 在中国大陆被墙 / 长期不可达的域名（扩展正则，匹配整个域名）。
#
# 命中的域名**不进 READY** —— 它们当伪装 SNI 会让国内用户在 GFW 那一关就被掐，
# 而这件事从境外 VPS 上探不出来。清单是启发式的，不可能全。
CN_BLOCKED='(^|\.)(google|googleapis|googleusercontent|gstatic|youtube|ytimg|blogspot|doubleclick|facebook|fbcdn|instagram|whatsapp|twitter|twimg|x|telegram|t|wikipedia|wikimedia|pinterest|tumblr|dropbox|medium)\.(com|org|net|me|co)$'

# 对照组：公认长期提供 h3 的端点。它们全灭 ⇒ 是本机出网 UDP 的问题。
#
# 刻意选**两个不同的服务商**（Cloudflare + Fastly）：同一家出故障或被针对时，
# 单一对照组会把它误报成「出网被封」。也刻意**不用 Google** —— 在国内的机器上
# 跑这个脚本时，Google 必然不通，那会直接得出一个假的「出网 UDP 被封」。
CONTROL=(cloudflare-quic.com www.fastly.com)

usage() { grep '^#' "$0" | sed 's/^#\{1,2\} \{0,1\}//'; exit 0; }

while getopts "n:t:p:m:46af:h" o; do
  case "$o" in
    n) PROBES=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    p) PORT=$OPTARG ;;
    m) MAX_IPS=$OPTARG ;;
    a) CHECK_CN=0 ;;
    4) WANT_V6=0 ;;
    6) WANT_V4=0 ;;
    # `read` 在最后一行没有换行符时会带着值返回非零 —— 循环体不执行，那个域名
    # 被静默丢掉。`|| [[ -n $l ]]` 把它捞回来。
    f) while read -r l || [[ -n $l ]]; do
         [[ -n $l && $l != \#* ]] && CANDIDATES+=("$l")
       done < "$OPTARG" ;;
    h|*) usage ;;
  esac
done
shift $((OPTIND - 1))
[[ $# -gt 0 ]] && CANDIDATES+=("$@")

# 节点每族固定只试前 8 个（upstream.rs 的 `.take(MAX_PROBE_CANDIDATES)`）。探到
# 第 9 个之后的地址并据此报 READY，就是在推荐一个节点根本不会去试的上游。
if [[ $MAX_IPS -gt 8 ]]; then
  echo "-m $MAX_IPS exceeds the node's per-family probe limit; clamping to 8" >&2
  MAX_IPS=8
fi

# 内置候选：**故意混了几个已知不支持 h3 的**（icloud / apple / microsoft），
# 好让「不可用」长什么样一眼看到，别以为脚本坏了。
if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
  # 没有 Google 系 —— 它们在国内被墙，当 SNI 用等于把国内用户全挡在外面
  # （见头注释「探得通 ≠ 能用」）。这里选的都是国内平时打得开的 CDN。
  # AWS 侧要挑对**具体主机名**：走 CloudFront 的（www.amazon.com、d1.awsstatic.com）
  # 有 h3，而 S3 端点（s3.amazonaws.com、s3.<region>.amazonaws.com）和
  # console.aws.amazon.com 实测一个 QUIC 包都不回 —— 「AWS 支持 h3」这句话
  # 落到具体域名上并不成立。
  CANDIDATES=(
    cdn.jsdelivr.net cdnjs.cloudflare.com unpkg.com cdn.bootcdn.net
    www.cloudflare.com www.fastly.com
    www.amazon.com d1.awsstatic.com aws.amazon.com
    www.lazada.com
    www.bing.com www.samsung.com
    www.icloud.com www.apple.com www.microsoft.com
  )
fi

# 域名不区分大小写，而证书 SAN 一律是小写 —— 在入口统一规范化，免得
# `WWW.EXAMPLE.COM` 在证书那一列被误报成 SAN 不覆盖。
for i in "${!CANDIDATES[@]}"; do CANDIDATES[$i]=${CANDIDATES[$i],,}; done

command -v python3 >/dev/null || { echo "python3 is required (it sends the QUIC probe)" >&2; exit 1; }
HAVE_OPENSSL=0; command -v openssl >/dev/null && HAVE_OPENSSL=1
HAVE_CURL=0;    command -v curl    >/dev/null && HAVE_CURL=1

if [[ -t 1 ]]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; N=$'\033[0m'
else B=; G=; Y=; R=; D=; N=; fi

# 带颜色转义的字段不能直接交给 printf 的 %-Ns，宽度会被转义字符吃掉。
#
# ⚠️ 不能写成 `local txt=$1 n=$((w-${#txt}))` —— `local` 是内建命令，它**全部**
# 参数的展开都发生在赋值生效之前，那时 `txt` 还不存在（set -u 下直接报 unbound）。
pad() {
  local txt=$1 w=$2 col=${3:-}
  local n=$((w - ${#txt}))
  ((n < 1)) && n=1
  printf '%s%s%s%*s' "$col" "$txt" "$N" "$n" ''
}

# ——— QUIC Version-Negotiation 探针 ———
#
# 长包头、版本号填 0x0a0a0a0a（保留的 greasing 版本，没有服务端会真支持），补齐到
# 1200 字节（不够大服务端可以直接丢）。合规服务端必须回 VN 包：版本字段为 0，
# 且把我们的 SCID/DCID 对调着回来。
#
# 连接态 UDP socket 会把 ICMP port unreachable 变成 ECONNREFUSED —— 那说明包
# **到了那台主机**、只是没有 QUIC 在听；和「石沉大海」是两种完全不同的故障。
quic_probe() {
  python3 - "$1" "$2" "$PROBES" "$TIMEOUT" <<'PY'
import os, socket, statistics, struct, sys, time

ip, port, n, timeout = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4])
fam = socket.AF_INET6 if ':' in ip else socket.AF_INET
rtts, refused = [], 0

for _ in range(n):
    dcid, scid = os.urandom(8), os.urandom(8)
    pkt = bytes([0xc0]) + struct.pack('!I', 0x0a0a0a0a) + bytes([8]) + dcid + bytes([8]) + scid
    pkt += b'\x00' * (1200 - len(pkt))
    s = socket.socket(fam, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        s.connect((ip, port))
        t0 = time.monotonic()
        s.send(pkt)
        data = s.recv(2048)
        dt = (time.monotonic() - t0) * 1000
        # VN 包：首字节最高位=1，版本字段=0。任何应答都证明「这里有 QUIC」，
        # 形状对不上也照记 RTT —— 判据是「有没有人说话」。
        if len(data) >= 5 and data[0] & 0x80:
            rtts.append(dt)
    except socket.timeout:
        pass
    except ConnectionRefusedError:
        refused += 1
    except OSError as e:
        print(f'error {e.strerror or e}')
        sys.exit(0)
    finally:
        s.close()

if rtts:
    print(f'ok {statistics.median(rtts):.1f} {len(rtts)}/{n}')
elif refused:
    print(f'refused {refused}/{n}')
else:
    print(f'silent 0/{n}')
PY
}

tcp_probe() {
  python3 - "$1" "$2" "$TIMEOUT" <<'PY'
import socket, sys, time
ip, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
fam = socket.AF_INET6 if ':' in ip else socket.AF_INET
s = socket.socket(fam, socket.SOCK_STREAM); s.settimeout(timeout)
t0 = time.monotonic()
try:
    s.connect((ip, port))
    print(f'ok {(time.monotonic()-t0)*1000:.1f}')
except Exception as e:
    print(f'fail {type(e).__name__}')
finally:
    s.close()
PY
}

# 解析：AAAA 与 A 分开，和节点的 happy eyeballs 一个视角。
resolve() {
  python3 - "$1" "$2" <<'PY'
import socket, sys
host, fam = sys.argv[1], sys.argv[2]
af = socket.AF_INET6 if fam == '6' else socket.AF_INET
try:
    seen, out = set(), []
    for r in socket.getaddrinfo(host, 443, af, socket.SOCK_DGRAM):
        ip = r[4][0]
        if ip not in seen:
            seen.add(ip); out.append(ip)
    print('\n'.join(out))
except Exception:
    pass
PY
}

# 站点自己宣称支持 h3 吗（Alt-Svc）。**要带上 -p 指定的端口** —— 换端口时
# 443 上宣称的 h3 可能属于另一个服务，拿来判断 host:$PORT 是错的。
alt_svc() {
  [[ $HAVE_CURL -eq 1 ]] || { echo "?"; return; }
  local hdr v authority aport
  hdr=$(curl -sS -m 6 -o /dev/null -D - "https://$1:$PORT/" 2>/dev/null \
        | tr -d '\r' | grep -i '^alt-svc:') || true
  [[ -z $hdr ]] && { echo "-"; return; }
  # `h3="host:port"` 里的 **authority 才是 h3 真正服务的地方**，host 省略 = 同一台
  # 主机。只看有没有 `h3=` 会把「443 上有 h3」当成「-p 指定的那个端口上有 h3」，
  # 而节点是对着配置里那个 host:port 用 ALPN h3 握手的。
  # 只认 `h3=`，不认 `h3-29=` 这类草案版本 —— 节点报的 ALPN 就是 h3。
  while read -r v; do
    authority=${v#*\"}; authority=${authority%\"}
    aport=${authority##*:}
    [[ -z $aport || $aport == "$authority" ]] && aport=443
    [[ $aport == "$PORT" ]] && { echo yes; return; }
  done < <(grep -oiE '(^|[ ,;])h3="[^"]*"' <<<"$hdr" | grep -oiE 'h3="[^"]*"')
  echo "-"
}

# 证书 SAN 覆不覆盖这个 SNI。节点**不校验证书**，所以这条不影响能不能启动；
# 但 sni 与 upstream 指到两个不同站点的话，探测者拿 SNI=A 连过来看到 B 的证书,
# 那本身就是个特征。
cert_covers() {
  [[ $HAVE_OPENSSL -eq 1 ]] || { echo "?"; return; }
  local host=$1 san
  san=$(echo | timeout 8 openssl s_client -connect "$host:$PORT" -servername "$host" 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | tr -d ' ' | tr ',' '\n' | sed 's/^DNS://') || true
  [[ -z $san ]] && { echo "?"; return; }
  local base="${host#*.}"
  if grep -qx -- "$host" <<<"$san" || grep -qx -- "\*.$base" <<<"$san"; then echo yes; else echo no; fi
}

# ——— 本机自己有没有全局 IPv6 ———
#
# 没有的话每个 AAAA 都会以 ENETUNREACH 立刻失败，逐行刷红会把真信息淹掉。
# 这件事本身要报出来：v6 是主路径（CLAUDE.md §3.6），一台没有全局 v6 的节点
# 只能走 v4，伪装站点的 v6 侧再好也用不上。
if [[ $WANT_V6 -eq 1 ]] && ! ip -6 route show default 2>/dev/null | grep -q .; then
  printf '%s\n' "${Y}This host has no IPv6 default route; skipping all v6 probes.${N}"
  printf '%s\n\n' "It can only reach camouflage sites over v4. Since v6 is the primary path, this is worth fixing with the provider."
  WANT_V6=0
fi

# ——— 对照组：判本机出网 UDP 通不通 ———
#
# **两个启用的地址族都要探。** 只看 v4 的话，一台 v6-only 的机器会被误判成
# 「出网 UDP 被封」，而它的 v6 侧其实完全可达。
#
# **对照组固定打 443。** 这些公开 h3 站点只在 443 上服务；跟着 -p 去打一个
# 任意端口，它们必然全灭，然后脚本就会得出「出网被封」这个假结论。代价是
# -p 非 443 时对照组只能证明 udp/443 的出网，证明不了 udp/$PORT —— 那一点
# 下面明说。
CONTROL_PORT=443
printf '%s\n' "${B}== Control: outbound udp/$CONTROL_PORT ==${N}"
[[ $PORT != "$CONTROL_PORT" ]] && printf '%s\n' "${D}(the public control endpoints only serve h3 on $CONTROL_PORT, so this says nothing about udp/$PORT)${N}"
CONTROL_OK=0
for c in "${CONTROL[@]}"; do
  for fam in 6 4; do
    [[ $fam == 6 && $WANT_V6 -eq 0 ]] && continue
    [[ $fam == 4 && $WANT_V4 -eq 0 ]] && continue
    ip=$(resolve "$c" "$fam" | head -1)
    [[ -z $ip ]] && continue
    r=$(quic_probe "$ip" "$CONTROL_PORT")
    printf '  %-24s %-4s %-40s %s\n' "$c" "v$fam" "$ip" "$r"
    [[ $r == ok* ]] && CONTROL_OK=1
  done
done
if [[ $CONTROL_OK -eq 0 ]]; then
  printf '\n%s\n' "${R}Every control endpoint failed: outbound udp/$CONTROL_PORT is most likely blocked on this host.${N}"
  printf '%s\n' "Check the TCP column below. If TCP works and UDP never does, no choice of domain will help:"
  printf '%s\n' "either get the provider to open outbound UDP, or move the camouflage site to a UDP port that is open."
fi

# ——— 逐个候选体检 ———
printf '\n%s\n' "${B}== Candidates ==${N}  ${D}($PROBES probes per address, ${TIMEOUT}s timeout, up to $MAX_IPS addresses per family)${N}"
printf '%-26s %-3s %-40s %-22s %-9s %-5s %s\n' DOMAIN FAM ADDRESS "QUIC udp/$PORT" "TCP $PORT" CERT ALT-SVC
printf '%s\n' "$(printf '%.0s-' $(seq 1 118))"

SUMMARY=()   # "rtt|domain|fam|alt|cert|cn|mix"，rtt 毫秒整数、不可用记 -1；cn=blocked 国内不可达；mix=mixed 多 CDN
for dom in "${CANDIDATES[@]}"; do
  cert=$(cert_covers "$dom")
  alt=$(alt_svc "$dom")
  disp=$dom; dcert=$cert; dalt=$alt
  best=-1; bestfam=""; printed=0; nok=0; nbad=0
  for fam in 6 4; do
    [[ $fam == 6 && $WANT_V6 -eq 0 ]] && continue
    [[ $fam == 4 && $WANT_V4 -eq 0 ]] && continue
    mapfile -t ips < <(resolve "$dom" "$fam")
    [[ ${#ips[@]} -eq 0 ]] && continue
    # 节点对**每一族**各试前 8 个，所以超限提示也按族给。
    [[ ${#ips[@]} -gt 8 ]] && printf '  %s\n' "${D}${dom} resolves to ${#ips[@]} v${fam} addresses; the node only probes the first 8 per family${N}"
    for ip in "${ips[@]:0:$MAX_IPS}"; do
      q=$(quic_probe "$ip" "$PORT")
      t=$(tcp_probe  "$ip" "$PORT")
      case $q in
        ok*)      read -r _ rtt got <<<"$q"
                  qtxt="${rtt}ms  $got"; qcol=$G
                  r_int=$(awk -v x="$rtt" 'BEGIN{printf "%d", x+0.5}')
                  { [[ $best -lt 0 ]] || [[ $r_int -lt $best ]]; } && { best=$r_int; bestfam="v$fam"; }
                  nok=$((nok + 1)) ;;
        refused*) qtxt="refused (nothing listening)"; qcol=$R; nbad=$((nbad + 1)) ;;
        silent*)  qtxt="no answer";                   qcol=$R; nbad=$((nbad + 1)) ;;
        *)        qtxt="$q";                          qcol=$R; nbad=$((nbad + 1)) ;;
      esac
      case $t in
        ok*) read -r _ trtt <<<"$t"; ttxt="${trtt}ms"; tcol="" ;;
        *)   ttxt="unreachable"; tcol=$R ;;
      esac
      printf '%-26s %-3s %-40s ' "$disp" "v$fam" "$ip"
      pad "$qtxt" 22 "$qcol"; pad "$ttxt" 9 "$tcol"
      printf '%-5s %s\n' "$dcert" "$dalt"
      disp=""; dcert=""; dalt=""; printed=1
    done
  done
  [[ $printed -eq 0 ]] && printf '%-26s %s\n' "$dom" "${R}no address resolved${N}"
  cn=ok
  # 域名本身不区分大小写，`WWW.GOOGLE.COM` 和小写是同一个主机名 —— 用 -i，
  # 否则手输一个大写域名就绕过了拦截。
  [[ $CHECK_CN -eq 1 ]] && grep -qiE "$CN_BLOCKED" <<<"$dom" && cn=blocked
  # 同一个域名，有的地址回 QUIC、有的一个包不回。
  #
  # ⚠️ 只报**现象**，不报成因。`nok`/`nbad` 证明不了这些 IP 属于不同 CDN ——
  # 同一家的灰度、临时丢包、限流都会长成这样。`www.amazon.com` 那次确实是
  # CloudFront（18.65.x）与 Akamai（23.41.x）在摇摆，但那是手工核过 IP 段才
  # 敢下的结论，脚本没有这个依据。
  #
  # 不管成因是什么，操作上的风险是同一个：节点启动时解析一次、只试拿到的那批
  # 地址，某次全落在不应答的那批上，D8 准入就过不了、节点起不来。
  mix=uniform
  [[ $nok -gt 0 && $nbad -gt 0 ]] && mix=mixed
  SUMMARY+=("$best|$dom|$bestfam|$alt|$cert|$cn|$mix")
done

# ——— 结论 ———
#
# VN 应答只证明「有 QUIC」，不证明「有 h3」。没有 h3 证据的单独归到 UNSURE，
# 不能和 READY 混在一起报 —— 节点是拿 ALPN h3 去握手的，混报会把人引到
# 一个 D8 会拒的上游上。
printf '\n%s\n' "${B}== Verdict ==${N}"
READY=$(printf  '%s\n' "${SUMMARY[@]}" | awk -F'|' '$1>=0 && $4=="yes" && $6!="blocked"' | sort -t'|' -k1,1n || true)
UNSURE=$(printf '%s\n' "${SUMMARY[@]}" | awk -F'|' '$1>=0 && $4!="yes" && $6!="blocked"' | sort -t'|' -k1,1n || true)
# 被墙**且**在这台 VPS 上也探不通的，要留在 NO 里 —— BLOCKED-CN 那一档的标题
# 断言了「从这台 VPS 可达」，把一个 DNS/UDP 本来就有问题的域名塞进去会把那个
# 问题盖掉，而它同样会让 D8 准入失败。
BLOCKED=$(printf '%s\n' "${SUMMARY[@]}" | awk -F'|' '$6=="blocked" && $1>=0' | sort -t'|' -k1,1n || true)
NOGO=$(printf   '%s\n' "${SUMMARY[@]}" | awk -F'|' '$1<0' || true)

if [[ -n $READY ]]; then
  printf '%s\n' "${G}READY${N}  ${D}(QUIC answers and the site advertises h3; sorted by fastest address)${N}"
  printf '  %-26s %-9s %-5s %-5s %s\n' DOMAIN BEST-RTT FAM CERT ALT-SVC
  while IFS='|' read -r rtt dom fam alt cert _ mix; do
    [[ $mix == mixed ]] && flag="  ${Y}<- mixed: some of its addresses answer, some do not${N}" || flag=""
    printf '  %-26s %-9s %-5s %-5s %s%s\n' "$dom" "${rtt}ms" "$fam" "$cert" "$alt" "$flag"
  done <<< "$READY"
  if grep -q 'mixed$' <<<"$READY"; then
    printf '\n%s\n' "  ${Y}a domain with mixed reachability is a gamble at every boot:${N} the node resolves once at startup and"
    printf '%s\n' "  only tries the addresses it got. Land on a resolution holding none of the answering ones and D8"
    printf '%s\n' "  admission fails, so the node refuses to start - at random. Prefer a domain where every address answers."
    printf '%s\n' "  (Mixed results only show that some addresses stay silent. The cause may be a second CDN, a canary"
    printf '%s\n' "  rollout, rate limiting or plain packet loss - this script cannot tell which.)"
  fi
else
  printf '%s\n' "${R}READY: none.${N}"
fi

if [[ -n $UNSURE ]]; then
  printf '\n%s\n' "${Y}UNSURE${N}  ${D}(QUIC answers but there is no h3 evidence: another QUIC protocol, or curl is missing)${N}"
  printf '%s\n' "  The node handshakes with ALPN h3, so D8 admission may still reject these. Confirm before using one."
  while IFS='|' read -r rtt dom fam alt cert _ _; do
    printf '  %-26s %-9s %-5s %-5s %s\n' "$dom" "${rtt}ms" "$fam" "$cert" "$alt"
  done <<< "$UNSURE"
fi

if [[ -n $BLOCKED ]]; then
  printf '\n%s\n' "${Y}BLOCKED-CN${N}  ${D}(reachable from this VPS, but blocked inside mainland China)${N}"
  printf '%s\n' "  The camouflage domain is also the SNI clients use to reach this node. A domain the GFW blocks"
  printf '%s\n' "  means Chinese users are cut off at the SNI and never reach the node at all, while the node's own"
  printf '%s\n' "  logs stay clean. Do not use these unless this node does not serve mainland users (-a skips the check)."
  while IFS='|' read -r rtt dom fam alt cert _ _; do
    [[ $rtt -ge 0 ]] && r="${rtt}ms" || r="-"
    printf '  %-26s %-9s %-5s %-5s %s\n' "$dom" "$r" "${fam:--}" "$cert" "$alt"
  done <<< "$BLOCKED"
fi

if [[ -n $NOGO ]]; then
  printf '\n%s\n' "${R}NO${N}"
  while IFS='|' read -r _ dom _ alt _ cn _; do
    if [[ $cn == blocked ]]; then
      why="unreachable from here, and blocked inside mainland China anyway"
    elif [[ $alt != yes ]]; then
      why="the site does not offer h3 at all"
    elif [[ $CONTROL_OK -eq 1 ]]; then
      # 对照组通了 ⇒ 不是本机的问题。Akamai 这类 CDN 常见：HTTP 头里宣称 h3，
      # 但分给你的那个边缘 IP 上并没有开 QUIC。换个域名，别在这上面较劲。
      why="advertises h3, but the edge addresses handed to us run no QUIC (seen on Akamai, and on some CloudFront edges)"
    else
      why="advertises h3 but is unreachable; outbound UDP is blocked on this host (see control)"
    fi
    printf '  %-26s %s\n' "$dom" "$why"
  done <<< "$NOGO"
fi

cat <<TXT

Put the winner on the PANEL, not in the node's server.json:
  node sni            = <chosen domain>
  node cover_upstream = <chosen domain>:$PORT   (leave empty and the node derives sni:443)

The client's SNI comes from that same sni field via the subscription, so the two must match byte for byte.

Beyond "does it work", also weigh:
  * reachability  - the domain is ALSO the SNI clients use; it must not be blocked where the users are
  * plausibility  - would this node's users normally reach that site? an obscure domain is itself a signal
  * dual stack    - v6 is the primary path, prefer a domain with both AAAA and A
  * latency       - every failed authentication pays one round trip to the camouflage site, and so does boot

Which addresses a domain resolves to can change between runs: www.amazon.com came back entirely CloudFront
(QUIC works) on one run and entirely Akamai (no QUIC at all) on the next, from the same host minutes apart.
A single run only sees one resolution, so run this a few times, spread out, before committing to a domain.
A domain that ever comes back NO is a domain the node may randomly refuse to boot on.

After changing the panel, restart the node and look for these two lines:
  [boot]  using the camouflage site the panel hands out server_name=... upstream=...
  [relay] camouflage upstream passed admission reachable=... dual_stack=...
If the second line is missing, admission failed and the node will not start. That is the final word.
TXT
