# deploy-reality-tunnel

**SS 业务层 + VLESS+Reality 双端隧道**一键部署/管理脚本。

在 落地机(海外 VPS,装 3x-ui 面板)与 家中转机 之间用 VLESS+Reality 隧道取代 realm-wss 双端隧道,解决"裸 SS/SOCKS 出境被识别/被封"的问题。业务层(x-ui 的 SS)**一个字节不用动**,隧道自动接管加密与伪装。

```
dae(SS节点) ──内网──> 家中转机 [xray: ss-in → Reality出站] ──VLESS+Reality隧道──>
            落地机 [xray: Reality入站 → SS outbound] ──> 127.0.0.1:x-ui SS ──> 出口
```

> ⚠️ 头号原则:**中转机必须放在国内/内网**(如家里 Debian/NAS)。否则 dae→中转机的裸 SS 段照样出境,隧道白搭。

## 业务协议:Shadowsocks(默认)/ SOCKS5 / 双业务 both

`server` 第2参数选协议(默认 `ss`,`socks` 或 `both`),`relay` 为**条目级协议**(每条可混):

```bash
bash deploy.sh server ss|socks|both   # 落地: ss(默认)/ socks / both=SS+SOCKS 双隧道
bash deploy.sh relay                  # 中转: 条目级,每条末尾标 ss/socks(默认 ss),可混合
```

- **server both(一台落地两个隧道)**:自动生成两个 Reality 入站——`443 → SS 业务`、`8443(可改)→ SOCKS5 业务`,同一套 UUID/私钥,relay 端加对应两条条目
- **relay 条目级协议**:交互里每条问"本条协议(回车=SS/输入socks=SOCKS5)",行尾标 `ss`/`socks`;SS 条目给 daed, SOCKS 条目给应用(直接填 SOCKS5 代理)
- SOCKS5 认证(落地业务/中转入站)可选,存 `server.creds` / `relay.socksauth`
- 老条目无行尾标记 = 默认 SS,完全向后兼容

## 功能一览

| 命令 | 在哪台跑 | 干什么 |
|---|---|---|
| `server` | 每台落地机 | Reality 入站(默认 443)→ 转发本机 x-ui SS;自动生成 UUID/x25519/shortId;dest 可选菜单 + 自动验证 TLS1.3 |
| `relay` | 家中转机 | 多条 SS 入站(本地端口可手改,每条对应一台落地)→ 各自 Reality 出站;条目可追加/删除 |
| `del` | 中转机 | 删除落地条目(relay 交互里输 `d` 也能删) |
| `status` | 任意 | 看服务/监听端口/配置文件 |
| `remove` | 任意 | 完全卸载(停服务+删配置,可选删凭据) |

### 内置细节

- **幂等**:重跑不换凭据(落地 key 存 `/usr/local/etc/xray/server.creds`,条目存 `relay.entries`),客户端不用改
- **复用 x-ui 自带 xray**:优先调用 `/usr/local/x-ui/bin/xray`,不重复安装(落地机甚至不用装新东西)
- **dest 1-8 菜单**:cloudflare / apple / google / dl.google / nvidia / tesla / amazon / 自定义,选中自动 openssl 验证 TLS1.3+X25519
- **删除内嵌**:server 检测到已部署可输 `d` 删除重置;relay 条目菜单 `y`=追加 / `d`=删除 / 回车=沿用并重新生成配置
- **每台独立 systemd 服务** `xray-tunnel`,日志 `journalctl -u xray-tunnel`

## 安装(三种拉取方式)

> 国内直连 raw.githubusercontent 经常卡死,对应方式按需选。

**① 一行执行(海外机器 / 网络好时)**:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/welllam0806/deploy-reality-tunnel/main/deploy-reality-tunnel.sh) server
```

**② 下载到本地再跑(推荐,能看清下载进度和报错,避免"没反应"):**

```bash
curl -fsSL -o ~/deploy.sh https://raw.githubusercontent.com/welllam0806/deploy-reality-tunnel/main/deploy-reality-tunnel.sh
bash ~/deploy.sh server
```

**③ 绕 CDN 缓存,永远最新(GitHub API 直读)**:

```bash
bash <(curl -fsSL "https://api.github.com/repos/welllam0806/deploy-reality-tunnel/contents/deploy-reality-tunnel.sh" | python3 -c "import sys,json,base64;print(base64.b64decode(json.load(sys.stdin)['content']).decode())") server
```

> 脚本刚推送后 raw/jsdelivr 有 1~2 分钟缓存延迟,拿不到新功能时用 ③。同一脚本的三个后接参数:`server` / `relay` / `del` / `status` / `remove`。

## 部署流程

### 第一步:每台落地机跑 `server`(需 root)

```bash
sudo bash deploy.sh server
```

交互:

```
[i] 复用 x-ui 面板自带 xray: /usr/local/x-ui/bin/xray (Xray 26.x)
[i] 检测到本机已部署过          ← 第一次没有这行
    [y]=沿用凭据重新生成 [d]=删除部署重新开始 [回车]=沿用:   ← 想重装输 d
Reality 监听端口 [443]:
请选择 Reality 伪装目标 (dest/SNI):       ← 数字1-8,回车=1 cloudflare
    ✓ www.cloudflare.com 支持 TLS1.3 + X25519
本机 x-ui 的 SS 入站端口 [8388]:   ← 填 x-ui 面板里 SS 的端口
本机 x-ui 的 SS 入站密码 []:        ← 填 x-ui 面板里 SS 的密码
SS 加密方式(建议 aes-256-gcm) [aes-256-gcm]:
```

跑完打印交接参数:**落地IP / UUID / PublicKey / shortId / SNI / 业务SS端口**——抄下来给第二步。

### 第二步:家中转机跑 `relay`

```bash
sudo bash deploy.sh relay
```

交互(每台落地一条):

```
[i] 已有落地条目:                          ← 已有条目时的菜单
10007 203.0.113.1 443 ... awssgp
    [y]=追加条目 [d]=删除条目 [回车]=直接用现有:
----------------------------------------
  本地端口(daed 节点填这个端口) [8388]:    ← 可手改,回车自动+1
  落地IP(直接回车结束) []: 203.0.113.1
  落地 Reality 端口 [443]:
  UUID: ...
  PublicKey: ...
  shortId: ...
  请选择 Reality 伪装目标 (dest/SNI):       ← 选和落地端一样的数字
  备注(可选): awssgp
  ✓ 已添加 203.0.113.1:443
  继续添加下一台?(y/N):                    ← 回车=N 结束
```

结束自动生成配置、启动 `xray-tunnel`,并打印 **daed 节点链接**(`ss://...`,每落地一条,密码统一,密码也打印在输出里)。

### 第三步:daed 客户端

- 节点:**中转机IP:本地端口**,加密 `aes-256-gcm`,密码 = relay 输出里那个(或 `cat /usr/local/etc/xray/relay.sspass`)
- 验证:开 Google,或 `curl -x socks5h://127.0.0.1:10808 https://ipinfo.io`

## 卸载

| 目的 | 操作 |
|---|---|
| 删某条落地(中转机) | `relay` 交互输 `d`,或 `bash deploy.sh del` |
| 重置落地机部署 | `server` 检测到已部署时输 `d`(停服务删凭据,重新部署) |
| 完全卸载本机隧道 | `sudo bash deploy.sh remove`(停服务;询问是否连凭据/条目一起删) |

## 注意事项(血泪坑)

- **中转机必须国内/内网**;内网 SS 端口**千万别映射到公网**(否则裸 SS 出境,全盘皆输)
- **dest/SNI 别选微软系**(www.microsoft.com):Akamai 边缘拒绝 Reality 中继
- SS 加密只用 AEAD:`aes-256-gcm` / `chacha20-ietf-poly1305`
- 落地端与中转端 **SNI 必须一致**(relay 菜单选和 server 一样的数字)
- 落地换端口(443 被占用时)需两端同步
- 启动失败排查:看 `journalctl -u xray-tunnel -n 20`;配置检查 `xray run -test -c /usr/local/etc/xray/tunnel-relay.json`
- 下载脚本卡死且 ping 正常 → 先查 MTU(见 deploy-reality-tunnel skill:ping -M do 分级测 + TCPMSS 钳制)