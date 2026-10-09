# SSH 本地网关代理

让远程 Linux 服务器通过 SSH 反向隧道，使用你这台 Windows 电脑可访问的 HTTP/HTTPS 网关。适用于服务器不能直连公司内网 API，而本机可以访问的场景。

```text
远程程序 → 127.0.0.1:remotePort → SSH 反向隧道
         → Windows 本地代理 → 公司网关
```

代理和隧道都只监听 `127.0.0.1`。代理要求独立生成的密码；该密码不会随 ZIP 分发。HTTPS 内容以 CONNECT 隧道转发，代理不解密 TLS。

## 运行条件

- Windows 10/11 x64，内置 PowerShell 5.1、任务计划程序和 OpenSSH 客户端。
- 远程 Linux 账户可以通过 SSH 公钥免密登录，并使用 Bash。
- Windows 电脑能访问目标网关，且工作时保持登录和联网。

## 安装

1. 将 ZIP **完整解压到固定目录**，以后不要移动该目录。`bin/ssh-gateway-proxy.exe` 是已打包的代理程序，运行时不需要 Python。
2. 在本机 `~/.ssh/config` 中配置一个具体主机别名，并先确认 `ssh <别名>` 能免密登录。例如：

   ```sshconfig
   Host my-server
       HostName 203.0.113.10
       Port 22
       User myuser
       IdentityFile C:\Users\myuser\.ssh\id_ed25519
       IdentitiesOnly yes
   ```

3. 编辑 `config.json`：

   - `sshAlias`：上一步的主机别名。
   - `localPort` / `remotePort`：本机代理端口和服务器回环端口；默认都是 `18791`。如有端口冲突，改为未使用的端口。
   - `allowedPrivateHosts`：允许代理访问的内网域名，例如 `gateway.company.example`。目标网关若只解析到公网 IP，可以设为 `[]`。

4. 在解压目录打开 PowerShell，运行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GatewayProxy.ps1 -Action Install
   ```

安装脚本会生成本机专用代理密码，写入远程账户下权限为 `600` 的 `~/.config/ssh-gateway-proxy/proxy.env`，注册登录后自动启动的计划任务，并在桌面创建快捷方式。它还会让远程 Bash 登录环境加载该代理设置。安装时不需要将 API 密钥写入这个项目。

## 使用与检查

安装后代理会立即启动。之后可以双击桌面上的 **SSH 网关代理 (<别名>)**；如果已经运行，不会再启动一份。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GatewayProxy.ps1 -Action Status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GatewayProxy.ps1 -Action Start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\GatewayProxy.ps1 -Action Stop
```

检查远程网关连接时，在服务器上运行 `curl -I https://<网关域名>/`。若网关要求认证，返回 `401` 也表示代理和 TLS 连接已打通。日志在本机 `.logs/`；代理密码在 `.secrets/`。这些目录不在分发 ZIP 中。

## 给 Codex 使用

远程 Codex 会从 Bash 登录环境读取 `HTTPS_PROXY`。Codex 的模型网关和 API 密钥需由每位使用者另行配置。例如在远程账户的 `~/.codex/config.toml` 中：

```toml
model = "<网关支持的模型>"
model_provider = "company_gateway"

[model_providers.company_gateway]
name = "Company Gateway"
base_url = "https://gateway.company.example/v1"
env_key = "COMPANY_GATEWAY_API_KEY"
wire_api = "responses"
```

把自己的 API 密钥放在远程账户的私有环境文件中，并确保 `COMPANY_GATEWAY_API_KEY` 在启动 Codex 的 shell 中可用。不要把密钥写进 `config.json`、项目目录或 ZIP。

## 重新打包代理程序

项目包含代理源码 `local-http-connect-proxy.py`。如果需要重新构建 exe，在 Windows 上安装 Python 3.10+ 和 PyInstaller，然后运行：

```powershell
python -m pip install pyinstaller
python -m PyInstaller --onefile --console --noconfirm --name ssh-gateway-proxy --distpath bin local-http-connect-proxy.py
```

打包文件仅包含项目源码、配置模板、说明和已构建的 exe；本机 SSH 密钥、API 密钥、代理密码、日志及服务器账户文件均不在其中。
