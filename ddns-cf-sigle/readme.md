# Cloudflare DDNS

> 纯 Bash 实现的 Cloudflare 动态 DNS (DDNS) 更新脚本，无需 jq 等额外依赖，支持 API 令牌与 Global API Key 双模式，自带重复记录清理与 cron 定时任务安装。

---

## 功能特性

### 核心功能
- **自动获取公网 IPv4**：通过 `https://ipv4.icanhazip.com` 自动检测当前外网 IP
- **手动指定 IP**：支持传入固定 IP，适用于静态 IP 场景
- **智能记录管理**：
  - 记录不存在 → 自动创建
  - 记录已存在且 IP 一致 → 跳过，无冗余 API 调用
  - 记录已存在但 IP 变更 → 更新记录
  - 多条同名 A 记录 → 自动保留第一条，删除其余重复项
- **保留 Proxy 状态**：更新时保留原记录的 `proxied`（橙色云朵）开关，不会强制关闭

### 鉴权双模式
| 模式 | 安全性 | 推荐度 | 说明 |
|------|--------|--------|------|
| **API 令牌 (Bearer Token)** | ⭐⭐⭐⭐⭐ | ✅ 推荐 | 细粒度权限控制，可限制仅操作特定 Zone 和 DNS |
| **Global API Key** | ⭐⭐ | ⚠️ 兼容 | 全账户权限，仅用于旧场景兼容 |

### 部署与运维
- **一键安装 cron**：`--install-cron` 参数自动复制脚本、注册每分钟定时任务、并立即执行一次
- **日志落盘**：定时任务输出自动追加至 `/root/setDomainRecorder.log`
- **完整错误提示**：针对 HTTP 401/403/429 等常见错误给出针对性排查建议
- **零额外依赖**：仅依赖系统自带 `curl` 与 `sed`，JSON 解析由 Bash 原生实现

---

## 环境要求

- 操作系统：Linux / macOS / BSD 等类 Unix 系统
- Shell：Bash 4.0+
- 必需命令：`curl`、`sed`、`crontab`（仅安装定时任务时需要）

```bash
# Debian/Ubuntu
apt update && apt install -y curl cron

# CentOS/RHEL
yum install -y curl cronie
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

#### 2. 单次执行 — 更新一次 DNS

```bash
# 通过命令行参数传入令牌
chmod +x aws-ddns-adv.sh
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com

# 或通过环境变量传入（更安全，避免令牌出现在进程列表中）
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh example.com home.example.com

# 手动指定 IP（不走自动检测）
./aws-ddns-adv.sh --token YOUR_API_TOKEN example.com home.example.com 203.0.113.5
```

#### 3. 安装定时任务 — 每分钟自动更新

```bash
# 推荐：令牌通过环境变量注入，不写入 crontab
export CF_API_TOKEN=YOUR_API_TOKEN
./aws-ddns-adv.sh --install-cron example.com home.example.com

# 或通过 --token 参数（令牌会明文写入 crontab，注意安全）
./aws-ddns-adv.sh --install-cron --token YOUR_API_TOKEN example.com home.example.com
```

安装完成后会：
1. 将脚本复制到 `/root/setDomainRecorder.sh`
2. 写入 crontab：`* * * * * CF_API_TOKEN='...' /bin/bash /root/setDomainRecorder.sh example.com home.example.com >> /root/setDomainRecorder.log 2>&1`
3. 立即执行一次更新，验证配置是否正确

---

### 方式二：兼容 — Global API Key 模式

#### 1. 获取 Global API Key

Cloudflare Dashboard → **My Profile** → **API Tokens** → **Global API Key** → View

需要同时使用注册邮箱 + Global API Key。

#### 2. 使用方式

```bash
# 单次执行
./aws-ddns-adv.sh your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com

# 安装定时任务
./aws-ddns-adv.sh --install-cron your@email.com YOUR_GLOBAL_API_KEY example.com home.example.com
```

---

## 完整用法参考

```
用法:
  推荐使用 API 令牌（Bearer Token）:
    单次执行:  aws-ddns-adv.sh --token <api_token> <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron --token <api_token> <zone_name> <record_name> [ip]

  兼容旧版 Global API Key:
    单次执行:  aws-ddns-adv.sh <auth_email> <auth_key> <zone_name> <record_name> [ip]
    安装定时:  aws-ddns-adv.sh --install-cron <auth_email> <auth_key> <zone_name> <record_name> [ip]
```

### 参数说明

| 参数 | 必填 | 说明 |
|------|------|------|
| `--install-cron` | ❌ | 启用定时任务安装模式 |
| `--token <token>` | ❌ | Cloudflare API 令牌，等价于环境变量 `CF_API_TOKEN` |
| `--token=<token>` | ❌ | 等号写法，同上 |
| `CF_API_TOKEN` | ❌ | 环境变量方式传入 API 令牌（优先级低于 `--token`） |
| `SCRIPT_URL` | ❌ | 环境变量，自定义定时任务模式下脚本的下载地址（默认 `https://ddns.8245454.xyz/aws4.sh`） |
| `<auth_email>` | ⚠️ | Global API Key 模式：Cloudflare 登录邮箱 |
| `<auth_key>` | ⚠️ | Global API Key 模式：Global API Key 字符串 |
| `<zone_name>` | ✅ | Cloudflare 中的根域名，如 `example.com` |
| `<record_name>` | ✅ | 要操作的完整 DNS 记录名，如 `home.example.com` |
| `[ip]` | ❌ | 手动指定 IPv4；省略时自动检测公网 IP |
| `-h`, `--help` | ❌ | 显示帮助并退出 |

---

## 脚本执行流程

```
run_once 主流程
    │
    ├─ 获取当前 IP（参数 or icanhazip.com）
    │     └─ 校验 IPv4 格式，不合法直接退出
    │
    ├─ 查询 Zone ID（通过 zone_name 匹配）
    │     └─ 未找到 → 退出报错
    │
    ├─ 查询目标 A 记录列表（type=A + name=record_name）
    │
    ├─ 分支处理：
    │     ├─ 0 条记录 → POST 创建（TTL=1，proxied=false）
    │     │
    │     ├─ N 条记录（N>1）→ 保留第 1 条，DELETE 其余 N-1 条
    │     │
    │     └─ 1 条记录 或 清理后剩余 1 条：
    │           ├─ IP 未变化 → 输出提示并退出（无 API 写入）
    │           └─ IP 已变化 → PUT 更新（保留原 proxied 状态）
    │
    └─ 输出执行结果，exit 0
```

---

## 输出示例

### 场景 1：首次创建记录
```
已创建记录: home.example.com -> 203.0.113.5
```

### 场景 2：IP 未变化
```
记录已是目标 IPv4，无需更新: home.example.com -> 203.0.113.5
```

### 场景 3：IP 变更
```
已更新记录: home.example.com 203.0.113.5 -> 198.51.100.23
```

### 场景 4：清理重复记录
```
检测到 3 条同名 A 记录，清理多余 2 条
已删除重复记录: a1b2c3d4e5f6...
已删除重复记录: g7h8i9j0k1l2...
已更新记录: home.example.com 203.0.113.5 -> 198.51.100.23
```

### 场景 5：鉴权失败
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

### 手动运行已安装脚本
```bash
export CF_API_TOKEN=YOUR_API_TOKEN
/root/setDomainRecorder.sh example.com home.example.com
```

---

## 自定义下载源（离线/私有部署）

定时任务模式下，若脚本不是从本地文件运行（如 `curl ... | bash`），会从 `SCRIPT_URL` 下载脚本到目标路径。可通过环境变量指向私有地址：

```bash
export SCRIPT_URL=https://your-internal-server.com/aws-ddns-adv.sh
./aws-ddns-adv.sh --install-cron --token YOUR_TOKEN example.com home.example.com
```

---

## 常见问题

### Q1: 为什么脚本名里有 "aws"，实际操作的是 Cloudflare？
本脚本从 AWS Route 53 版本演进而来，保留了历史文件名以兼容已有的 `SCRIPT_URL` 下载链路，内部 API 调用全部指向 Cloudflare。

### Q2: 支持 IPv6 (AAAA 记录) 吗？
当前版本仅支持 IPv4 A 记录。如需 IPv6 可修改：将 IP 检测换为 `https://ipv6.icanhazip.com`，并将 `type=A` 替换为 `type=AAAA`。

### Q3: TTL 固定为 1（Auto）可以改吗？
脚本中 `ttl:1` 表示使用 Cloudflare 自动 TTL。如需自定义，修改 [aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L243-L243) 与 [aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L271-L271) 两处的 `ttl` 值即可（合法值：1 或 60-86400 之间的秒数）。

### Q4: proxied（橙色云朵）默认关闭，可以默认开启吗？
创建新记录时脚本使用 `proxied:false`（见 [aws-ddns-adv.sh](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L243-L243)）。若希望开启，将该行改为 `proxied:true`。**注意**：已有记录的 proxied 状态在更新时会被保留，不会被脚本覆盖。

### Q5: 如何调试 API 请求？
在脚本 `curl` 调用处（如 [cf_http_get](file:///Volumes/cdata/Projects/tools/ddns.sh/ddns-cf-adv/aws-ddns-adv.sh#L108-L130)）增加 `-v` 参数查看详细请求与响应头。

### Q6: cron 不执行怎么办？
1. 确认 cron 服务运行：`systemctl status cron` 或 `service crond status`
2. 查看系统日志：`grep CRON /var/log/syslog` 或 `journalctl -u cron`
3. 确保 `/root/setDomainRecorder.sh` 有执行权限：`chmod +x /root/setDomainRecorder.sh`
4. 手动执行一次脚本，确认无交互性错误

---

## 返回码

| 退出码 | 含义 |
|--------|------|
| `0` | 成功（创建 / 更新 / 无需更新 / 清理重复） |
| `1` | 通用错误（参数错误、缺少依赖、IP 非法、API 失败等） |
