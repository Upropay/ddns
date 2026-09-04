# Cloudflare DDNS 高级版 (aws-ddns-adv.sh)

> 纯 Bash 实现的 Cloudflare 动态 DNS (DDNS) 更新脚本，无需 jq 等额外依赖，支持 API 令牌与 Global API Key 双模式；支持**单域名解析到多个 IP（DNS Round Robin 负载均衡）**，自带重复记录清理与 cron 定时任务安装；**支持「一键管道安装」**，无需先保存脚本文件。

---

## 功能特性

### 核心功能
- **自动获取公网 IPv4**：通过 `https://ipv4.icanhazip.com` 自动检测当前外网 IP
- **手动指定 IP**：支持传入固定 IP，适用于静态 IP 场景
- **智能记录管理**：
  - 记录不存在 → 自动创建
  - 记录已存在且 IP 一致 → 跳过，无冗余 API 调用
  - 记录已存在但 IP 变更 → 更新记录
  - 多条同名记录 → 自动清理冗余（可按服务器归属精细化处理）
- **保留 Proxy 状态**：更新时保留原记录的 `proxied`（橙色云朵）开关，不会强制关闭
- **多机负载均衡（DNS Round Robin）** ✨
  - 通过 `--origin-id <服务器唯一标识>` 让每台服务器只管理属于自己的那条 A 记录
  - 利用 Cloudflare DNS 记录的 `comment` 字段标记归属（格式 `origin:<origin-id>`）
  - 多台服务器并发操作安全，互不覆盖；最终形成「一个二级域名 → 多个公网 IP」的轮询解析
- **一键管道安装** ✨：`bash <(curl -sSL 发布URL) --install-cron ...` 即可完成下载 + 安装到 `/root/aws-ddns-adv.sh` + 注册 cron + 立即执行；脚本默认的 `SCRIPT_URL` 已指向发布地址，不会下错版本

### 鉴权双模式
| 模式 | 安全性 | 推荐度 | 说明 |
|------|--------|--------|------|
| **API 令牌 (Bearer Token)** | ⭐⭐⭐⭐⭐ | ✅ 推荐 | 细粒度权限控制，可限制仅操作特定 Zone 和 DNS |
| **Global API Key** | ⭐⭐ | ⚠️ 兼容 | 全账户权限，仅用于旧场景兼容 |

### 部署与运维
- **一键安装 cron**：`--install-cron` 参数自动安装脚本、注册每小时整点定时任务、并立即执行一次；`--origin-id` 会自动通过 `ORIGIN_ID` 环境变量注入 crontab
- **标准路径**：
  - 脚本安装位置：`/root/aws-ddns-adv.sh`
  - 定时任务日志：`/root/aws-ddns-adv.log`
- **完整错误提示**：针对 HTTP 401/403/429 等常见错误给出针对性排查建议
- **轻量依赖**：仅依赖系统自带 `curl`、`sed`、`awk`，JSON 解析由 Bash + Awk 原生实现

---

## 环境要求

- 操作系统：Linux / macOS / BSD 等类 Unix 系统
- Shell：Bash 4.0+
- 必需命令：`curl`、`sed`、`awk`、`crontab`（仅安装定时任务时需要）

```bash
# Debian/Ubuntu
apt update && apt install -y curl cron gawk

# CentOS/RHEL
yum install -y curl cronie gawk
```

---

## 快速开始

### 发布地址
- 最新发布版（管道安装用）：`https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh`
- 脚本内默认 `SCRIPT_URL` 已指向该地址，`bash <(curl ...) --install-cron` 安全可用

### 方式一：推荐 — API 令牌模式

#### 1. 在 Cloudflare 创建 API 令牌

登录 Cloudflare Dashboard → **My Profile** → **API Tokens** → **Create Token**

选择 **Edit zone DNS** 模板（或自定义），确保包含以下权限：

| 权限类别 | 权限项 | 访问级别 |
|----------|--------|----------|
| Zone     | Zone   | Read     |
| Zone     | DNS    | Edit     |

在 **Zone Resources** 中选择目标域名（或 All zones），创建后复制令牌字符串（形如 `cfut_xxxxxx`）。

#### 2. 推荐用法 — 一键管道安装（无需先下文件）

> 用 `bash <(curl -sSL <发布URL>)` 直接远程执行安装，管道执行时 cron 分支会**从 `SCRIPT_URL` 再下载同一份新版脚本**到 `/root/aws-ddns-adv.sh`，两边版本完全一致。

#### 场景 A — 单机：一个二级域名 → 单个 IP（传统用法）

```bash
# 一键安装 cron（推荐）
bash <(curl -sSL https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh) \
  --install-cron --token YOUR_API_TOKEN example.com home.example.com

# 本地有脚本时的等价写法
chmod +x aws-ddns-adv.sh
./aws-ddns-adv.sh --install-cron --token YOUR_API_TOKEN example.com home.example.com

# 单次运行（不装 cron，先验证效果）
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com

# 单次运行（更安全：令牌放环境变量，不进进程列表）
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh example.com home.example.com

# 手动指定 IP（不走自动检测）
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com 203.0.113.5
```

#### 场景 B — 多机负载均衡：一个二级域名 → 多个公网 IP ✨

> 核心：每台服务器指定**唯一**的 `--origin-id`（如 `server-a`、`server-b`），脚本会自动写入 `comment=origin:<id>` 作为归属标签，多台服务器的记录**互不干扰**。

假设你有两台公网服务器，想让 `home.example.com` 同时解析到这两个 IP，做 DNS Round Robin 负载均衡：

**服务器 A（身份 `yc-hk`，一键管道安装 cron）：**
```bash
bash <(curl -sSL https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh) \
  --install-cron \
  --origin-id yc-hk \
  --token YOUR_API_TOKEN \
  example.com home.example.com
```

**服务器 B（身份 `sh`，一键管道安装 cron）：**
```bash
bash <(curl -sSL https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh) \
  --install-cron \
  --origin-id sh \
  --token YOUR_API_TOKEN \
  example.com home.example.com
```

**本地脚本等价写法（先跑一次看效果，再装 cron）：**
```bash
# 服务器 A
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh --origin-id yc-hk example.com home.example.com
./aws-ddns-adv.sh --install-cron --origin-id yc-hk example.com home.example.com

# 服务器 B
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh --origin-id sh example.com home.example.com
./aws-ddns-adv.sh --install-cron --origin-id sh example.com home.example.com
```

两台安装完成后，Cloudflare DNS 面板最终会看到：

```
home.example.com  A  203.0.113.10   TTL Auto  Comment: origin:yc-hk
home.example.com  A  198.51.100.23  TTL Auto  Comment: origin:sh
```

客户端多次 `dig home.example.com` 会轮询返回两个 IP，DNS 层面实现负载均衡。

> **origin-id 命名建议**：用主机名、MAC 后 4 位、地域简称、内网 IP 末段均可，只要两台不一样就行。比如 `--origin-id $(hostname -s)` 自动取主机名。

---

### 方式二：兼容 — Global API Key 模式

#### 1. 获取 Global API Key

Cloudflare Dashboard → **My Profile** → **API Tokens** → **Global API Key** → View

需要同时使用注册邮箱 + Global API Key。

#### 2. 使用方式

```bash
# 一键管道安装（单机）
bash <(curl -sSL https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh) \
  --install-cron your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com

# 一键管道安装（多机负载均衡，示例 server-a）
bash <(curl -sSL https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh) \
  --install-cron --origin-id server-a your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com

# 本地脚本单次执行
./aws-ddns-adv.sh your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com
```

---

## 完整用法参考

```
用法:
  推荐使用 API 令牌（Bearer Token）:
    单次执行:  aws-ddns-adv.sh --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]
    一键管道:  bash <(curl -sSL <发布URL>) --install-cron --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]

  兼容旧版 Global API Key:
    单次执行:  aws-ddns-adv.sh <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
    一键管道:  bash <(curl -sSL <发布URL>) --install-cron <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
```

### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `--install-cron` | ❌ | 启用定时任务安装模式 |
| `--origin-id <id>` | ⚠️ | **多机负载均衡必填**。当前服务器的唯一身份标识；等价于环境变量 `ORIGIN_ID`。脚本只管理 `comment == origin:<id>` 的那条 A 记录 |
| `--origin-id=<id>` | ⚠️ | 等号写法，同上 |
| `--token <token>` | ❌ | Cloudflare API 令牌，等价于环境变量 `CF_API_TOKEN` |
| `--token=<token>` | ❌ | 等号写法，同上 |
| `CF_API_TOKEN` | ❌ | 环境变量方式传入 API 令牌（优先级低于 `--token`） |
| `ORIGIN_ID` | ❌ | 环境变量方式传入 origin-id（优先级低于 `--origin-id`） |
| `SCRIPT_URL` | ❌ | 环境变量，覆盖定时任务模式下脚本的下载地址（默认 `https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh`） |
| `<auth_email>` | ⚠️ | Global API Key 模式：Cloudflare 登录邮箱 |
| `<auth_key>` | ⚠️ | Global API Key 模式：Global API Key 字符串 |
| `<zone_name>` | ✅ | Cloudflare 中的根域名，如 `example.com` |
| `<record_name>` | ✅ | 要操作的完整 DNS 记录名，如 `home.example.com` |
| `[ip]` | ❌ | 手动指定 IPv4；省略时自动检测公网 IP |
| `-h`, `--help` | ❌ | 显示帮助并退出 |

> 「⚠️ 必填」表示在对应场景下必填；单机传统用法可不传 `--origin-id`。

> 关于「一键管道」语法注意：`<发布URL>` 用普通引号包裹即可，**不要用反引号** `` ` ``（反引号在 Bash 里是命令替换，会把 URL 当命令执行）。

---

## 脚本执行流程

### 传统模式（未传 --origin-id）

```
run_once 主流程（兼容逻辑，100% 保留旧行为）
    │
    ├─ 获取当前 IP → 校验 IPv4
    ├─ 查询 Zone ID
    ├─ 查询同名 A 记录列表
    │
    └─ 分支处理：
        ├─ 0 条  → POST 创建（TTL=1，proxied=false，无 comment）
        ├─ N>1 条 → DELETE 后 N-1 条，保留第 1 条
        └─ 1 条  → IP 相同则跳过，否则 PUT 更新（保留 proxied）
```

### 负载均衡模式（传 --origin-id=xxx）

```
run_once 主流程（按归属精细化管理）
    │
    ├─ 获取当前 IP → 校验 IPv4
    ├─ 查询 Zone ID
    ├─ 查询同名 A 记录列表
    ├─ 遍历每条记录的 comment，按「comment==origin:xxx」分桶：
    │     ├─ all_ids[]        = 所有同名记录（不操作其他服务器的）
    │     └─ my_ids[]         = 归属自己的记录（comment 匹配）
    │
    └─ 分支处理：
        ├─ my_ids.length == 0
        │      → POST 创建新记录（写入 comment=origin:xxx）
        │
        ├─ my_ids.length > 1
        │      → DELETE 自己的后 N-1 条，保留第 1 条
        │        （只清理自己的重复，不会动 server-b 的记录）
        │
        └─ my_ids.length == 1
               ├─ IP 相同 → 跳过
               └─ IP 不同 → PUT 更新（保留原 proxied，重写 comment）
```

### install_cron 脚本来源判断

```
--install-cron 模式脚本来源判定
    │
    ├─ $0 是普通本地文件
    │     └─ 和 /root/aws-ddns-adv.sh 不同 → cp 本地文件过去
    │     └─ 相同 → 不重复拷贝
    │
    └─ $0 不是普通文件（典型：bash <(curl ...) 管道执行）
          └─ curl -fsSLo /root/aws-ddns-adv.sh $SCRIPT_URL
             （默认 SCRIPT_URL = GitHub Release 同版本脚本，版本一致）
          └─ chmod +x，写入 crontab，立即执行一次
```

---

## 输出示例

### 传统模式 · 场景 1：首次创建记录
```
已创建记录: home.example.com -> 203.0.113.5
```

### 传统模式 · 场景 2：IP 未变化
```
记录已是目标 IPv4，无需更新: home.example.com -> 203.0.113.5
```

### 传统模式 · 场景 3：清理重复记录
```
检测到 3 条同名 A 记录，清理多余 2 条
已删除重复记录: a1b2c3d4e5f6...
已删除重复记录: g7h8i9j0k1l2...
已更新记录: home.example.com 203.0.113.5 -> 198.51.100.23
```

### 传统模式 · 场景 4：管道安装 cron 成功
```
已从 https://github.com/Upropay/ddns/releases/download/1.0.0/aws-ddns-adv.sh 下载脚本到: /root/aws-ddns-adv.sh
已安装脚本到: /root/aws-ddns-adv.sh
已写入定时任务: 每小时整点执行一次
已创建记录: home.example.com -> 203.0.113.5
```

---

### 负载均衡模式 · 场景 1：服务器 A 首次创建
```
[origin:yc-hk] 检测到 0 条归属自己的记录（总 1 条同名 A 记录）
[origin:yc-hk] 已创建记录: home.example.com -> 203.0.113.10
```

### 负载均衡模式 · 场景 2：服务器 B 首次创建（A 的记录不受影响）
```
[origin:sh] 检测到 0 条归属自己的记录（总 1 条同名 A 记录）
[origin:sh] 已创建记录: home.example.com -> 198.51.100.23
```

### 负载均衡模式 · 场景 3：服务器 A IP 变更
```
[origin:yc-hk] 检测到 1 条归属自己的记录（总 2 条同名 A 记录）
[origin:yc-hk] 已更新记录: home.example.com 203.0.113.10 -> 203.0.113.99
```
> 此时 `origin:sh` 的 198.51.100.23 记录完好无损，DNS 仍保留两条。

### 负载均衡模式 · 场景 4：A 机发现自己有重复记录
```
[origin:yc-hk] 检测到 2 条归属自己的记录（总 3 条同名 A 记录）
[origin:yc-hk] 自己的记录重复 1 条，保留第一条，清理其余
[origin:yc-hk] 已删除自己的重复记录: xyz...
```

---

### 鉴权失败（两种模式通用）
```
请求失败: GET https://api.cloudflare.com/...
响应: {...}
API 说明: Invalid access token
Cloudflare API 返回 HTTP 401。
API 令牌鉴权失败。请确认:
  1) 令牌未过期、未撤销
  2) 拥有 Zone:Zone:Read 与 Zone:DNS:Edit 权限
  3) 权限的 Zone Resources 覆盖目标 zone（或选择 All zones）
```

---

## 常用运维操作

### 查看定时任务
```bash
crontab -l
# 示例（单机令牌模式）：
# 0 * * * * CF_API_TOKEN='xxx' /bin/bash /root/aws-ddns-adv.sh example.com home.example.com >> /root/aws-ddns-adv.log 2>&1
#
# 示例（负载均衡模式）：
# 0 * * * * CF_API_TOKEN='xxx' ORIGIN_ID='yc-hk' /bin/bash /root/aws-ddns-adv.sh example.com home.example.com >> /root/aws-ddns-adv.log 2>&1
```

### 查看执行日志
```bash
tail -f /root/aws-ddns-adv.log
```

### 卸载定时任务
```bash
# 移除对应 crontab 行
crontab -l | grep -v '/root/aws-ddns-adv.sh' | crontab -

# 可选：清理残留文件
rm -f /root/aws-ddns-adv.sh /root/aws-ddns-adv.log
```

### 手动运行已安装脚本
```bash
# 单机
export CF_API_TOKEN=YOUR_API_TOKEN
/root/aws-ddns-adv.sh example.com home.example.com

# 负载均衡（yc-hk）
export CF_API_TOKEN=YOUR_API_TOKEN
export ORIGIN_ID=yc-hk
/root/aws-ddns-adv.sh example.com home.example.com
```

### 验证 Round Robin 效果
```bash
# 多次查询看返回 IP 是否轮询
for i in {1..10}; do dig +short home.example.com @1.1.1.1; echo "---"; done
```

### 检查当前 DNS 记录的 comment 归属
```bash
# 方法 1：浏览器打开 Cloudflare DNS 面板直接看 Comment 列
# 方法 2：用 API 查看（<zone_id> 替换为实际值）
curl -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone_id>/dns_records?type=A&name=home.example.com" \
  | python3 -m json.tool
```

### SCRIPT_URL 覆盖（私有部署 / 自托管）
```bash
# 用自己的镜像地址下载安装脚本，cron 分支下载也走这个地址
SCRIPT_URL=https://your-internal-server.com/aws-ddns-adv.sh \
bash <(curl -sSL https://your-internal-server.com/aws-ddns-adv.sh) \
  --install-cron --origin-id yc-hk --token YOUR_TOKEN example.com home.example.com
```

---

## 常见问题

### Q1: 为什么脚本名里有 "aws"，实际操作的是 Cloudflare？
本脚本从 AWS Route 53 版本演进而来，保留了历史文件名以兼容旧有下载链路，内部 API 调用全部指向 Cloudflare。

### Q2: 两台服务器同时跑，会不会删错对方的记录？
不会。只要 `--origin-id` **不一样**，每台服务器只会匹配 `comment==origin:<自己id>` 的记录进行操作；其他服务器（以及历史遗留无 comment）的记录完全不触碰。

### Q3: 旧数据迁移：已有不带 origin-id 的记录，怎么接入负载均衡模式？
两种方式：
1. **推荐**：到 Cloudflare 面板手动给那条记录的 **Comment** 字段写上 `origin:yc-hk`，再在对应机器上用 `--origin-id yc-hk` 运行脚本即可自动接管。
2. **省事**：直接用 `--origin-id yc-hk` 运行脚本，会自动新建一条带 comment 的记录，形成两条；旧的那条手动删掉即可。

### Q4: 管道安装用 `bash <(curl ...)` 安全吗？
是当前社区通用做法（和 `curl | bash` 相比，`<(...)` 是进程替换，参数能正常透传，不会被 `sh` 吞掉）。
- 安全前提：发布 URL 走 HTTPS，且来自可信源（这里是你自己的 GitHub Release）
- 如果你更谨慎：先 `curl -fsSLo /tmp/ddns.sh <URL>` 下载，`cat /tmp/ddns.sh | head -n 20` 目测代码，再 `bash /tmp/ddns.sh --install-cron ...` 安装

### Q5: 支持 IPv6 (AAAA 记录) 吗？
当前版本仅支持 IPv4 A 记录。如需 IPv6 可修改：将 IP 检测换为 `https://ipv6.icanhazip.com`，并将脚本中 `type=A` 全部替换为 `type=AAAA`，同时把 IPv4 正则换成 IPv6 匹配。

### Q6: TTL 固定为 1（Auto）可以改吗？
脚本中 `ttl:1` 表示使用 Cloudflare 自动 TTL。如需自定义，修改以下四处：
- 传统模式创建：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L325-L325)
- 传统模式更新：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L351-L351)
- 负载均衡模式创建：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L374-L374)
- 负载均衡模式更新：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L398-L398)

合法值：`1`（Auto）或 60-86400 之间的整数秒。

### Q7: proxied（橙色云朵）默认关闭，可以默认开启吗？
创建新记录时脚本使用 `proxied:false`，位置同上 Q6 中四处 `ttl` 相邻的 `proxied` 字段，改为 `true` 即可。
**注意**：已有记录的 proxied 状态在更新时会被原样保留，不会被脚本覆盖。

### Q8: 负载均衡模式下，某台服务器长期离线，它的旧 IP 记录会一直在 DNS 里吗？
是的——这是 DNS Round Robin 本身的局限（无健康检查）。那台机器的记录只能由它自己上线时更新，或你手动到 Cloudflare 删掉。对可用性要求高的生产场景，建议升级到 **Cloudflare Load Balancing**（带健康检查 + 故障转移）。

### Q9: 如何调试 API 请求？
在脚本对应 `curl` 调用处（如 [cf_http_get](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L168-L190)）的参数里加 `-v`，查看详细请求与响应头。

### Q10: cron 不执行怎么办？
1. 确认 cron 服务运行：`systemctl status cron` 或 `service crond status`
2. 查看系统日志：`grep CRON /var/log/syslog` 或 `journalctl -u cron`
3. 确保 `/root/aws-ddns-adv.sh` 有执行权限：`chmod +x /root/aws-ddns-adv.sh`
4. 手动执行一次脚本，确认无交互性错误：`/root/aws-ddns-adv.sh --token xxx zone record`
5. crontab 环境变量极少，若用自定义路径，建议在 cron 行首加 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`
6. 管道安装后检查 `$SCRIPT_URL` 是否可访问（若默认值指向内网地址会下载失败）

---

## 返回码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功（创建 / 更新 / 无需更新 / 清理重复） |
| `1` | 通用错误（参数错误、缺少依赖、IP 非法、API 失败等） |
