# Cloudflare DDNS 高级版 (aws-ddns-adv.sh)

> 纯 Bash 实现的 Cloudflare 动态 DNS (DDNS) 更新脚本，无需 jq 等额外依赖，支持 API 令牌与 Global API Key 双模式；支持**单域名解析到多个 IP（DNS Round Robin 负载均衡）**，自带重复记录清理与 cron 定时任务安装。

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
- **多机负载均衡（DNS Round Robin）** ✨ 新增
  - 通过 `--origin-id <服务器唯一标识>` 让每台服务器只管理属于自己的那条 A 记录
  - 利用 Cloudflare DNS 记录的 `comment` 字段标记归属（格式 `origin:<origin-id>`）
  - 多台服务器并发操作安全，互不覆盖；最终形成「一个二级域名 → 多个公网 IP」的轮询解析

### 鉴权双模式
| 模式 | 安全性 | 推荐度 | 说明 |
|------|--------|--------|------|
| **API 令牌 (Bearer Token)** | ⭐⭐⭐⭐⭐ | ✅ 推荐 | 细粒度权限控制，可限制仅操作特定 Zone 和 DNS |
| **Global API Key** | ⭐⭐ | ⚠️ 兼容 | 全账户权限，仅用于旧场景兼容 |

### 部署与运维
- **一键安装 cron**：`--install-cron` 参数自动复制脚本、注册每分钟定时任务、并立即执行一次；**origin-id 会自动注入 crontab**
- **日志落盘**：定时任务输出自动追加至 `/root/setDomainRecorder.log`
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

### 方式一：推荐 — API 令牌模式

#### 1. 在 Cloudflare 创建 API 令牌

登录 Cloudflare Dashboard → **My Profile** → **API Tokens** → **Create Token**

选择 **Edit zone DNS** 模板（或自定义），确保包含以下权限：

| 权限类别 | 权限项 | 访问级别 |
|----------|--------|----------|
| Zone     | Zone   | Read     |
| Zone     | DNS    | Edit     |

在 **Zone Resources** 中选择目标域名（或 All zones），创建后复制令牌字符串（形如 `xxxxxx-xxxxxxxxxxxxxxxxxx`）。

#### 2. 场景 A — 单机：一个二级域名 → 单个 IP（传统用法）

```bash
# 单次执行（令牌参数）
chmod +x aws-ddns-adv.sh
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com

# 单次执行（令牌环境变量，更安全）
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh example.com home.example.com

# 手动指定 IP（不走自动检测）
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com 203.0.113.5

# 安装定时任务
./aws-ddns-adv.sh --install-cron --token YOUR_API_TOKEN example.com home.example.com
```

#### 3. 场景 B — 多机负载均衡：一个二级域名 → 多个公网 IP ✨

> 核心：每台服务器指定**唯一**的 `--origin-id`（如 `server-a`、`server-b`），脚本会自动写入 `comment=origin:<id>` 作为归属标签，多台服务器的记录**互不干扰**。

假设你有两台公网服务器，想让 `home.example.com` 同时解析到这两个 IP，做 DNS Round Robin 负载均衡：

**服务器 A（公网 IP 会变，身份是 server-a）：**
```bash
export CF_API_TOKEN=YOUR_API_TOKEN

# 先跑一次看效果
./aws-ddns-adv.sh --origin-id server-a example.com home.example.com

# 没问题后装定时任务（每分钟自动同步）
./aws-ddns-adv.sh --install-cron --origin-id server-a example.com home.example.com
```

**服务器 B（公网 IP 会变，身份是 server-b）：**
```bash
export CF_API_TOKEN=YOUR_API_TOKEN

./aws-ddns-adv.sh --origin-id server-b example.com home.example.com
./aws-ddns-adv.sh --install-cron --origin-id server-b example.com home.example.com
```

两台安装完成后，Cloudflare DNS 面板最终会看到：

```
home.example.com  A  203.0.113.10   TTL Auto  Comment: origin:server-a
home.example.com  A  198.51.100.23  TTL Auto  Comment: origin:server-b
```

客户端 `dig home.example.com` 会在多次请求中轮询返回两个 IP，DNS 层面实现负载均衡。

> **origin-id 命名建议**：用主机名、MAC 后 4 位、或内网 IP 末段均可，只要两台不一样就行。比如 `--origin-id $(hostname -s)` 自动取主机名。

---

### 方式二：兼容 — Global API Key 模式

#### 1. 获取 Global API Key

Cloudflare Dashboard → **My Profile** → **API Tokens** → **Global API Key** → View

需要同时使用注册邮箱 + Global API Key。

#### 2. 使用方式

```bash
# 单机单次执行
./aws-ddns-adv.sh your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com

# 多机负载均衡（server-a 示例）
./aws-ddns-adv.sh --origin-id server-a your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com

# 定时任务
./aws-ddns-adv.sh --install-cron --origin-id server-a your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com
```

---

## 完整用法参考

```
用法:
  推荐使用 API 令牌（Bearer Token）:
    单次执行:  aws-ddns-adv.sh --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron --token <api_token> [--origin-id <id>] <zone_name> <record_name> [ip]

  兼容旧版 Global API Key:
    单次执行:  aws-ddns-adv.sh <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron <auth_email> <auth_key> [--origin-id <id>] <zone_name> <record_name> [ip]
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
| `SCRIPT_URL` | ❌ | 环境变量，自定义定时任务模式下脚本的下载地址（默认 `https://ddns.8245454.xyz/aws4.sh`） |
| `<auth_email>` | ⚠️ | Global API Key 模式：Cloudflare 登录邮箱 |
| `<auth_key>` | ⚠️ | Global API Key 模式：Global API Key 字符串 |
| `<zone_name>` | ✅ | Cloudflare 中的根域名，如 `example.com` |
| `<record_name>` | ✅ | 要操作的完整 DNS 记录名，如 `home.example.com` |
| `[ip]` | ❌ | 手动指定 IPv4；省略时自动检测公网 IP |
| `-h`, `--help` | ❌ | 显示帮助并退出 |

> 「⚠️ 必填」表示在对应场景下必填；单机传统用法可不传 `--origin-id`。

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

---

### 负载均衡模式 · 场景 1：服务器 A 首次创建
```
[origin:server-a] 检测到 0 条归属自己的记录（总 1 条同名 A 记录）
[origin:server-a] 已创建记录: home.example.com -> 203.0.113.10
```

### 负载均衡模式 · 场景 2：服务器 B 首次创建（A 的记录不受影响）
```
[origin:server-b] 检测到 0 条归属自己的记录（总 1 条同名 A 记录）
[origin:server-b] 已创建记录: home.example.com -> 198.51.100.23
```

### 负载均衡模式 · 场景 3：服务器 A IP 变更
```
[origin:server-a] 检测到 1 条归属自己的记录（总 2 条同名 A 记录）
[origin:server-a] 已更新记录: home.example.com 203.0.113.10 -> 203.0.113.99
```
> 此时 server-b 的 198.51.100.23 记录完好无损，DNS 仍保留两条。

### 负载均衡模式 · 场景 4：A 机发现自己有重复记录
```
[origin:server-a] 检测到 2 条归属自己的记录（总 3 条同名 A 记录）
[origin:server-a] 自己的记录重复 1 条，保留第一条，清理其余
[origin:server-a] 已删除自己的重复记录: xyz...
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
# 负载均衡模式下的 crontab 示例：
# * * * * * CF_API_TOKEN='xxx' ORIGIN_ID='server-a' /bin/bash /root/setDomainRecorder.sh example.com home.example.com >> /root/setDomainRecorder.log 2>&1
```

### 查看执行日志
```bash
tail -f /root/setDomainRecorder.log
```

### 卸载定时任务
```bash
# 移除对应行
crontab -l | grep -v '/root/setDomainRecorder.sh' | crontab -

# 可选：清理残留文件
rm -f /root/setDomainRecorder.sh /root/setDomainRecorder.log
```

### 手动运行已安装脚本（带 origin-id）
```bash
export CF_API_TOKEN=YOUR_API_TOKEN
export ORIGIN_ID=server-a
/root/setDomainRecorder.sh example.com home.example.com
```

### 验证 Round Robin 效果
```bash
# 多次查询看返回 IP 是否轮询
for i in {1..10}; do dig +short home.example.com @1.1.1.1; echo "---"; done
```

### 检查当前 DNS 记录的 comment 归属
```bash
# 浏览器打开 Cloudflare DNS 面板即可看到 Comment 列
# 或用 API 查看：
curl -H "Authorization: Bearer $CF_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone_id>/dns_records?type=A&name=home.example.com" \
  | python3 -m json.tool
```

---

## 自定义下载源（离线/私有部署）

定时任务模式下，若脚本不是从本地文件运行（如 `curl ... | bash`），会从 `SCRIPT_URL` 下载脚本到目标路径。可通过环境变量指向私有地址：

```bash
export SCRIPT_URL=https://your-internal-server.com/aws-ddns-adv.sh
./aws-ddns-adv.sh --install-cron --origin-id server-a --token YOUR_TOKEN example.com home.example.com
```

---

## 常见问题

### Q1: 为什么脚本名里有 "aws"，实际操作的是 Cloudflare？
本脚本从 AWS Route 53 版本演进而来，保留了历史文件名以兼容已有的 `SCRIPT_URL` 下载链路，内部 API 调用全部指向 Cloudflare。

### Q2: 两台服务器同时跑，会不会删错对方的记录？
不会。只要 `--origin-id` **不一样**，每台服务器只会匹配 `comment==origin:<自己id>` 的记录进行操作；其他服务器（以及历史遗留无 comment）的记录完全不触碰。

### Q3: 旧数据迁移：已有不带 origin-id 的记录，怎么接入负载均衡模式？
两种方式：
1. **推荐**：到 Cloudflare 面板手动给那条记录的 **Comment** 字段写上 `origin:server-a`，再在 A 机上用 `--origin-id server-a` 运行脚本即可自动接管。
2. **省事**：直接在 A 机用 `--origin-id server-a` 运行脚本，会自动新建一条带 comment 的记录，形成两条；旧的那条手动删掉即可。

### Q4: 支持 IPv6 (AAAA 记录) 吗？
当前版本仅支持 IPv4 A 记录。如需 IPv6 可修改：将 IP 检测换为 `https://ipv6.icanhazip.com`，并将脚本中 `type=A` 全部替换为 `type=AAAA`，同时把 IPv4 正则换成 IPv6 匹配。

### Q5: TTL 固定为 1（Auto）可以改吗？
脚本中 `ttl:1` 表示使用 Cloudflare 自动 TTL。如需自定义，修改以下两处：
- 传统模式创建：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L325-L325)
- 传统模式更新：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L351-L351)
- 负载均衡模式创建：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L374-L374)
- 负载均衡模式更新：[aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L398-L398)

合法值：`1`（Auto）或 60-86400 之间的整数秒。

### Q6: proxied（橙色云朵）默认关闭，可以默认开启吗？
创建新记录时脚本使用 `proxied:false`，位置同上 Q5 中四处 `ttl` 相邻的 `proxied` 字段，改为 `true` 即可。
**注意**：已有记录的 proxied 状态在更新时会被原样保留，不会被脚本覆盖。

### Q7: 负载均衡模式下，某台服务器长期离线，它的旧 IP 记录会一直在 DNS 里吗？
是的——这是 DNS Round Robin 本身的局限（无健康检查）。那台机器的记录只能由它自己上线时更新，或你手动到 Cloudflare 删掉。对可用性要求高的生产场景，建议升级到 **Cloudflare Load Balancing（方案二，带健康检查 + 故障转移）**。

### Q8: 如何调试 API 请求？
在脚本对应 `curl` 调用处（如 [cf_http_get](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L168-L190)）的参数里加 `-v`，查看详细请求与响应头。

### Q9: cron 不执行怎么办？
1. 确认 cron 服务运行：`systemctl status cron` 或 `service crond status`
2. 查看系统日志：`grep CRON /var/log/syslog` 或 `journalctl -u cron`
3. 确保 `/root/setDomainRecorder.sh` 有执行权限：`chmod +x /root/setDomainRecorder.sh`
4. 手动执行一次脚本，确认无交互性错误
5. crontab 环境变量极少，若用自定义路径，建议在 cron 行首加 `PATH=/usr/bin:/bin:/usr/sbin:/sbin`

---

## 返回码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功（创建 / 更新 / 无需更新 / 清理重复） |
| `1` | 通用错误（参数错误、缺少依赖、IP 非法、API 失败等） |
