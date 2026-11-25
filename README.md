# Claude Desktop Shim for ClawGod

让 Windows 版 Claude Desktop 使用你已安装的 [ClawGod](https://github.com/0Chencc/clawgod) Claude Code CLI。

本项目是一个轻量级本地启动适配器：直接启动 Bun 和 ClawGod 的 `cli.cjs`，解决批处理启动层带来的长参数、引号和 stdio 兼容性问题。它不安装或升级 ClawGod，也不配置模型、API Key 或服务商。

## 功能

- **直接启动 EXE**：不经过 `cmd.exe`，避免其 8191 字符命令行限制及 shell 转义问题。
- **自动发现 Bun**：支持 ClawGod 启动器指定的路径、标准安装、npm 安装、`BUN_INSTALL` 和 PATH。
- **原样传递 stdio**：按字节转发 stdin / stdout / stderr，避免 UTF-8 BOM 干扰 stream-json 协议。
- **保留进程行为**：透传退出码，使用 Windows Job Object 管理子进程生命周期。
- **适配 Desktop 缓存**：从已安装的 `app.asar` 读取 CLI 版本与清单校验和，不写死版本号。
- **自动构建**：EXE 缺失或源码较新时自动编译；编译失败不会覆盖已有 EXE。
- **支持 `import`**：转发到 ClawGod 的导入工具，保留完整参数列表。

## 适用范围

- Windows x64；已在 Windows 11 验证。
- Claude Desktop 的 MSIX 安装布局。
- 部署脚本默认使用 `%LOCALAPPDATA%\Claude-3p` 用户数据目录。如果你的 Desktop 使用其他目录，需要先适配 `redeploy.ps1` 中的 `$UserDataSuffix`。
- 仅适配 **Windows 宿主 CLI**。Cowork 的隔离 Linux 工作区是独立组件，详见下文。

项目依赖 Desktop 的缓存布局与清单格式。Desktop 更新后需要重新部署；如果格式发生变化，部署脚本也可能需要更新。

## 前置条件

| 依赖 | 说明 |
| --- | --- |
| Claude Desktop | 已安装，并在部署前完全退出，包括托盘进程，且给安装目录（Windowsapp文件夹） 访问及修改权限|
| ClawGod | 已按上游说明安装，`claude.cmd --version` 能正常运行 |
| Bun | 可用的 `bun.exe`，由 shim 自动发现 |
| .NET Framework 4.x | 运行 shim；源码构建使用系统自带的 `csc.exe`，不需要 .NET SDK |
| PowerShell | 建议使用 Windows PowerShell 5.1 |
| Node.js / npm | 仅在下载可选的 Linux CLI 时需要 |

ClawGod 的默认文件布局：

```text
%USERPROFILE%\
├── .local\bin\
│   ├── claude.cmd
│   └── claude.orig.exe
└── .clawgod\
    ├── cli.cjs
    └── clawgod-import.exe    # 仅 import 命令需要
```

先检查已有的 ClawGod 安装：

```powershell
& "$env:USERPROFILE\.local\bin\claude.cmd" --version
```

## 快速开始

1. 下载发布包或完整源码，解压后在项目目录打开 PowerShell。
2. 完全退出 Claude Desktop。
3. 执行以下命令：

```powershell
.\install.ps1 -SkipLinuxCli
```

4. 重新启动 Claude Desktop，再创建或重试任务。

`-SkipLinuxCli` 仅跳过可选的 Linux CLI 下载，不影响 Windows 宿主 shim 的安装。

如果希望脚本自动关闭 Desktop：

```powershell
.\install.ps1 -CloseDesktop -SkipLinuxCli
```

`-CloseDesktop` 会强制关闭匹配的 `claude` 进程，请先保存正在进行的任务。默认不传此参数时，脚本发现 Desktop 正在运行会停止并提示。

安装过程会检查依赖、按需编译、验证 shim 的 `--version` 退出码，再部署到 Desktop 的 CLI 缓存。启动检查失败时不会显示安装成功。

## 常用命令

```powershell
# 安装 Windows 宿主 shim，不下载 Linux CLI
.\install.ps1 -SkipLinuxCli

# Desktop 更新后重新部署
.\redeploy.ps1

# 按需编译 / 强制重新编译
.\build.ps1
.\build.ps1 -Force

# 检查 shim 能否启动已有的 ClawGod CLI
.\ClaudeShim.exe --version

# 运行隔离回归测试
.\test.ps1
```

重新部署前也需要关闭 Desktop。重新部署只适配缓存位置，不会自动升级你的 ClawGod CLI。

## 工作原理

```text
Claude Desktop
    └── claude.exe（部署到 Desktop 缓存的 shim）
          └── bun.exe
                └── %USERPROFILE%\.clawgod\cli.cjs
```

shim 复刻 ClawGod 启动器的核心行为，而不是执行批处理文件：

```text
CLAUDE_CODE_EXECPATH=<claude.cmd 同目录的 claude.orig.exe>
bun.exe <用户目录>\.clawgod\cli.cjs <原始参数>
```

部署位置：

```text
%LOCALAPPDATA%\Claude-3p\claude-code\<version>\<checksum-prefix>\
    claude.exe
    .verified

%USERPROFILE%\.local\bin\claude-shim.exe
```

`<checksum-prefix>` 为 Desktop 清单校验和的前 12 位。`.verified` 写入的是 **Desktop 清单中的校验和**，不是 shim 自身的文件哈希。部署脚本只读取 `app.asar`，不修改应用包。

同时会设置用户环境变量 `CLAUDE_CODE_LOCAL_BINARY` 指向规范位置的 shim。不同 Desktop 构建对该变量的支持可能不同，因此脚本也会部署版本化缓存副本。

## 自定义路径与调试

| 环境变量 | 用途 |
| --- | --- |
| `CLAUDE_SHIM_TARGET` | 指定 ClawGod 的 `claude.cmd`；`claude.orig.exe` 应与其同目录 |
| `CLAUDE_SHIM_BUN` | 指定 `bun.exe` 的完整路径，优先于自动发现 |
| `CLAUDE_SHIM_DEBUG=1` | 将实际执行路径和参数写入 stderr |
| `BUN_INSTALL` | 自动发现 Bun 时检查此目录下的 `bin\bun.exe` |

例如，在当前 PowerShell 中验证自定义 Bun：

```powershell
$env:CLAUDE_SHIM_BUN = 'D:\tools\bun\bun.exe'
$env:CLAUDE_SHIM_DEBUG = '1'
.\ClaudeShim.exe --version
```

这些变量由 shim 进程读取。上述 `$env:` 设置仅作用于当前终端及其子进程，不会自动影响从开始菜单启动的 Desktop。

正常调试输出应指向 `bun.exe ...cli.cjs`，而不是 `cmd.exe`。调试日志包含完整启动参数，提交 issue 前请移除凭证和私有内容。

## 验证安装

安装脚本应输出成功的版本检查，例如：

```text
[ok] shim reports: <version> (Claude Code)
[ok] deployed shim reports: <version> (Claude Code)
```

重启 Desktop 后，可检查：

```text
%LOCALAPPDATA%\Claude-3p\logs\main.log
```

确认 CLI 可执行路径位于 `claude-code\<version>\<checksum-prefix>\claude.exe`。进程树中还应能看到该缓存副本启动 `bun.exe`。

实际 CLI 版本来自你的 ClawGod 安装，可能与 Desktop 用于命名缓存目录的清单版本不同。

## 常见问题

### `Claude Code couldn’t start` / `命令行太长。`

旧版启动器误走 `cmd.exe` 时，长参数会超过其 8191 字符上限；本地编码的错误消息还可能显示为乱码。

更新项目、关闭 Desktop 后执行：

```powershell
.\redeploy.ps1
```

当前 shim 不再回退到 `cmd.exe`，但仍受 Windows 原生进程命令行长度上限约束。

### `Bun not found` / `cli.cjs not found` / `original CLI not found`

检查 ClawGod 安装是否完整，或通过 `CLAUDE_SHIM_BUN` 指定正确的运行时路径。依赖缺失时 shim 返回退出码 `127`，不会尝试批处理回退。

### 文件被占用，无法替换 `claude.exe`

完全退出 Desktop，包括托盘进程，再重新部署。

### 找不到 `app.asar` 或无法解析清单

检查 Desktop 安装布局是否受支持。若问题出现在 Desktop 更新后，需要适配新的安装路径或清单格式。

## Cowork / Linux 工作区（可选）

Linux 工作区需要单独的 CLI、磁盘镜像、内核和 initrd。Windows shim 不提供这些 VM 镜像，也不会把 Linux CLI 改造成 ClawGod CLI。

安装 Desktop 清单对应的官方 Linux CLI：

```powershell
# 从 npm 下载，需要 Node.js / npm 和网络访问
.\redeploy.ps1 -FetchLinuxCli

# 或使用已有的 linux-x64 ELF 文件
.\redeploy.ps1 -LinuxCli 'D:\downloads\package\claude'
```

如果 Desktop 下载 VM 资源需要代理：

```powershell
.\redeploy.ps1 -ProxyUrl 'http://127.0.0.1:7890'
.\redeploy.ps1 -ClearProxy
```

代理选项修改当前生效的 Desktop `configLibrary` 条目中的 `egressProxyUrl`。Linux CLI 安装完成不代表 VM 镜像已准备就绪；工作区启动失败需要单独排查。

## 卸载

关闭 Desktop 后执行：

```powershell
.\redeploy.ps1 -Uninstall
```

脚本清理版本化缓存中的小型 shim 与 `.verified`、规范位置的 `claude-shim.exe`，并清除 `CLAUDE_CODE_LOCAL_BINARY`。

卸载不恢复此前被替换的缓存文件，也不删除 Linux CLI / VM 缓存或清除代理配置。代理配置需要单独通过 `-ClearProxy` 移除。重启后由 Desktop 重新解析或下载所需 CLI。

## 开发与测试

```powershell
.\build.ps1 -Force
.\test.ps1
```

回归测试覆盖 Bun 路径发现、长参数、特殊字符、原样 stdio、退出码、`import`、缺失依赖和自动构建。测试在独立临时目录中使用假的 Bun / ClawGod 文件，不修改用户安装、不调用模型 API，结束后清理临时文件。

## 项目结构

```text
claude-desktop-shim/
├── ClaudeShim.cs       # Windows 启动适配器源码
├── ClaudeShim.exe      # 本地构建产物 / Release 预编译文件
├── build.ps1           # 自动构建
├── install.ps1         # 安装入口
├── redeploy.ps1        # 部署、卸载及可选工作区配置
├── test.ps1            # 测试入口
├── tests/
│   └── ShimTests.cs    # 隔离回归测试
├── .gitignore
└── README.md
```

源码仓库保留构建脚本与测试；`ClaudeShim.exe` 作为构建产物由 `.gitignore` 排除，可随 GitHub Release 发布。发布包应包含 `ClaudeShim.exe`、`ClaudeShim.cs`、`build.ps1`、`install.ps1`、`redeploy.ps1` 和本 README。
