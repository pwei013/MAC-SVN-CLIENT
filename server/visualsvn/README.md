# VisualSVN 权限管理接入前检查

目标环境已确认：VisualSVN Server Manager 4.0.1，Subversion 本地用户认证。计划采用 Mac 客户端加内网 HTTPS 管理接口，服务器端由管理员人工配置。

## 当前兼容性边界

VisualSVN 的官方版本记录明确说明：4.2 才为权限管理 PowerShell 命令增加 Subversion 认证支持，并新增本地用户、组管理命令。`Get/Add/Set/Remove-SvnAccessRule` 从 3.4 就存在，不代表它们在 4.0.1 支持本地用户认证。

- [官方 4.2 发布说明](https://www.visualsvn.com/company/news/visualsvn-server-4.2-released)
- [官方版本记录：4.2.0 的 PowerShell enhancements](https://www.visualsvn.com/server/changes/)
- [官方 PowerShell 命令说明](https://www.visualsvn.com/support/topic/00088/)

旧版本存在 WMI 管理接口，但其类和方法不能根据其他版本的网上示例推断。下一步先读取本机实际接口元数据，再决定 4.0.1 兼容适配，或在用户另行决定并确认 Windows 兼容性后采用升级方案。目前尚未实现或部署权限管理 HTTPS 服务，也未更改任何真实仓库授权。

## 在 Windows 服务器上执行只读检查

1. 把 `Test-VisualSvnManagement.ps1` 复制到 SVN 所在的 Windows 服务器上的一个新工具目录。
2. 打开 **VisualSVN Server Manager → Action（操作）→ All Tasks（所有任务）→ Start PowerShell**。此入口用于加载服务器自己的官方模块及管理环境。
3. 在这个 PowerShell 窗口执行脚本。下面假设你把脚本放到 `C:\Tools\SVNManager`；如果放在其他目录，请替换为实际位置：

   ```powershell
   & "C:\Tools\SVNManager\Test-VisualSvnManagement.ps1" -OutputPath "C:\Tools\SVNManager\visualsvn-management.json"
   ```

4. 把生成的 `visualsvn-management.json` 提供给开发者。输出文件必须尚不存在；重复检查时改用新文件名。

脚本要求 Windows PowerShell 3.0 或更高版本。若执行策略或安全软件阻止脚本运行，保留提示并联系管理员按现有策略处理，不通过修改执行策略来绕过限制。

## 检查内容和副作用

- 读取已安装 VisualSVN 产品版本、PowerShell 和 Windows 版本。
- 查看指定管理命令是否存在及其参数名称，不执行这些管理命令。
- 使用 `Get-CimClass` 读取本机 `root/VisualSVN` 的类、属性和方法声明，不读取用户实例、密码或仓库权限数据，不调用 WMI 方法。
- 不启用 WinRM、SSH、HTTPS 监听器，不改变防火墙、服务或服务器配置。
- 仅在传入 `-OutputPath` 时新建该 JSON 文件；不传此参数时只在控制台输出 JSON。不会覆盖已有文件。异常只输出状态代码、异常类型和 HResult，不输出原始异常正文。
- `diagnostics` 有内容或 `truncated` 为 `true` 时，不能认定接口检查完整成功。元数据可读也不代表具有写权限或读写方法已经验证。

脚本源码以 Windows PowerShell 3.0/5.1 兼容写法编写，已通过 PowerShell 7.6 语法解析及命令调用白名单检查，并完成旧版语法和只读边界审阅；这些检查不等于 Windows 或 VisualSVN 4.0.1 实机验证。真实仓库写入和服务器部署需在完成接口核对后单独设计并由管理员执行。
