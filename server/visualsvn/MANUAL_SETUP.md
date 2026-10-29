# 管理员人工接入与验收

交付的是 Windows PowerShell 4.0 兼容写法的源码。导入模块不会启动监听器；仅显式执行启动脚本才会监听 HTTPS。默认 `enableWrites:false`，完成下面的只读比对和隔离仓库测试前保持禁写。没有自动安装服务、计划任务、WinRM、SSH、防火墙规则或证书绑定。

## 人工配置

以下路径 `C:\Tools\SVNManager` 为示例，替换为实际本机工具目录；配置和状态必须使用本机绝对盘符路径，不使用 UNC 共享。

1. 把本目录源码复制到工具目录。不要放在 SVN 仓库、Web 站点、公共共享或普通用户可修改的目录。保护整个工具目录和父目录链的完整性；仅管理员、SYSTEM 和实际运行身份可修改脚本、模块、配置及回执。程序不能替代导入前对源码的保护。
2. 模板另存为 `bridge-config.json`，人工创建 `private-state`。配置及状态目录的所有者和允许访问项仅限运行身份、Administrators、SYSTEM；移除普通用户访问，核对父链不能被非受信任账号删除、替换、改权限，不经过 junction/符号链接。脚本会检查这些条件，不会代为放宽 ACL。仅用于子对象的 `InheritOnly` ACE 不作为祖先本身的授权。
3. 选择独立内网管理 DNS 名称及 HTTPS 端口。准备 Mac 信任、主机名匹配的正式或企业 CA 证书，由管理员按现有流程配置 HTTP.sys 证书绑定和运行身份的 URL 预留。不要使用 HTTP、通配主机、跳过 TLS 验证或开放公网。
4. 防火墙和 `allowedClientAddresses` 均限制到实际 Mac/VPN 出口 IP。模板仅 `127.0.0.1`，不是自动放行内网。应用的 IP 检查不能替代防火墙。
5. 通过公司秘密管理工具生成至少 **32 随机字节**的独立管理令牌，采用 Base64 或 Base64URL 字符串。配置 `tokenSha256` 保存该字符串 UTF-8 的 SHA256 小写十六进制值；原令牌只交给获准管理员，在 Mac 应用设置中输入并保存到钥匙串。不复用 SVN 或 Windows 密码，不把真实令牌发到对话、日志或 Git。
6. 配置 `repositories`：`name` 为 VisualSVN 中的真实仓库名，`uuid` 为同一仓库的实际 UUID，`url` 为该仓库根 URL（可沿用 SVN 的 HTTP 地址），`paths` 为允许管理的库内绝对路径。UUID 用于防止 URL 与仓库名误配而改错库。可在 VisualSVN PowerShell 中只读核对：

   ```powershell
   Get-WmiObject -Namespace 'root\VisualSVN' -Class 'VisualSVN_Repository' | Select-Object Name, URL, UUID
   ```

   例如根 URL `http://svn.example/Topone` 配路径 `/2026/MyProject`，只允许此项目及后代，不匹配 `/2026/MyProject2`。路径区分大小写。仅确实管理整个仓库时填写 `/`。
7. `enableWrites` 保持 JSON 布尔值 `false`，不要写字符串 `"false"`。服务拒绝错误类型布尔值和非数组白名单。
8. 用具备本机 VisualSVN 管理权限的 Windows PowerShell 4.0 窗口人工启动：

   ```powershell
   & "C:\Tools\SVNManager\Start-VisualSvnBridge.ps1" -ConfigPath "C:\Tools\SVNManager\bridge-config.json"
   ```

9. 在 Mac 仓库浏览页面点击地址右侧的“仓库权限”图标，或在本地工作副本的齿轮菜单选择“仓库权限…”。在弹出的“内网管理接口”中填写如 `https://svn-admin.example.internal:8443/` 的管理地址及独立令牌，点击“连接并读取”，先与 Manager 比对只读结果。Ctrl+C 停止前台服务。若需常驻，由管理员按既有服务管理规范托管；代码不自动部署。

策略或安全软件阻止运行时按现场策略处理，不修改执行策略或关闭安全机制绕过。启动失败只显示白名单状态码、异常类型和 HResult；请求错误不回显原始异常、请求、配置或凭据。配置、状态或父链 ACL 变化后先停止服务、核对后再启动。

## 隔离仓库验收后才能启用写入

只用管理员新建的临时仓库、测试账号和组完成一次核对，不在业务仓库试验。先只给隔离库白名单；业务路径保持禁写或移出白名单。

1. 在 Manager 手工准备：根路径用户 A 只读，子目录没有 A 的显式规则，子目录另给 B 读写；孙目录和兄弟目录保留不同覆盖规则。
2. 禁写模式读取根、子、孙路径。确认每层 `GetSecurity` 只返回**该层显式条目**，与 Manager 红星标记一致，没有把已合并的继承条目当显式规则。若不符，停止反馈，不能打开写入。
3. 核对用户/组类型、名称、无访问/只读/读写映射及活动本地授权集。未知账号类型、权限值和重复目标条目应阻止操作。
4. 只读核对通过后，管理员只为隔离库把 `enableWrites` 改为布尔值 `true`，重启。通过应用准备、审阅并确认：对子目录 A 新增只读、改读写、设无访问、删除显式恢复继承。每步在 Manager 独立读回，并核对 B、兄弟及孙目录规则保留。
5. 确认删除最后一条显式规则时的空数组确实恢复继承，`SetSecurity(...,ResetChildren=false)` 保留后代覆盖。任何行为不符都停止，不自动回滚。
6. 准备审阅后先在 Manager 修改另一条规则，再确认，必须拒绝漂移。结果不明只查询状态并读回，不自动重试。重启服务后同一操作 ID 的回执仍可查询。
7. Windows PowerShell 4.0 / VisualSVN 4.0.1 实机均通过后，管理员才能按维护安排将明确业务路径加入白名单启用。管理期间避免其他管理员同时编辑同一路径权限。

`SetSecurity` 替换目标路径整组显式规则。实现保留其他原始嵌入实例，固定 `ResetChildren=false`，写前重读目标、祖先和账号清单，写后独立读取完整目标规则。WMI 没有原生 compare-and-swap，外部 Manager 在最后一次读和写之间变更仍有竞态，不能声称绝对原子防覆盖。

## 范围与状态

- 规则作用于当前路径和后代，后代显式覆盖保留；删除显式条目后根据 SVN 继承决定访问。
- `No Access` 不是 Windows 强制拒绝；组或 Everyone 的更宽规则仍可能授予访问。不把一条规则等同某用户的最终有效权限。
- 用户/组名称清单为服务器范围。为显示继承，读取仓库根到目标的祖先 ACL；写入受路径白名单约束。
- 4.0.1 本地认证没有 5.1 后恢复的全库级规则，本版不调用 `GetGlobalSecurity`。Everyone 只显示保留，不能在第一版编辑。
- 请求最多 64 KiB、响应 2 MiB、账号 5000 个、路径 64 层；超限拒绝，不给可写的截断清单。
- 服务串行处理，数据目录以本机互斥锁防止两个桥接进程并发。原始 pending 和 result 回执均以 CreateNew 和明确受限 ACL 保存，保留回执，不为重试而删除。
- `confirmed`：方法成功且新 WMI 查询核对目标完整规则一致；`unknown`：已尝试写入但结果未核实；`pending`：缺少持久终态，可能写前或写后中断；`rejected`：写前检查拒绝。后三种不能当“没发生”自动重试。
- 单个审阅有效 5 分钟，绑定目标、身份、操作和快照，一次使用。未知结果刷新、在 Manager 核对，不自动重放、回滚或提交 SVN。

## HTTPS JSON 契约

所有接口均 `POST` JSON，`Authorization: Bearer <独立令牌>`；无 CORS，拒绝浏览器 Origin，不在 URL 中放凭据。

| 接口 | 请求 | 成功返回 |
| --- | --- | --- |
| `/v1/inspect` | `repositoryURL` | `schemaVersion:1, repositoryURL, repositoryName, path, serverVersion, version, writesEnabled, writeDisabledReason, accounts, rules, scopeDescription` |
| `/v1/prepare` | `repositoryURL, accountKind, accountName, access, expectedVersion` | `schemaVersion:1, reviewId, expiresAt, repositoryURL, repositoryName, path, accountKind, accountName, oldAccess, newAccess, scopeDescription, version` |
| `/v1/apply` | `reviewId, operationId`（UUID） | `schemaVersion:1, operationId, status, code` |
| `/v1/status` | `operationId` | 同上；不存在为 HTTP404 `OPERATION_NOT_FOUND` |

`accounts` 元素为 `{kind:"user"或"group",name}`；规则为 `{accountKind,accountName,access,sourcePath,isInherited}`。访问值 `none/read/write`，准备请求额外接受 `removeExplicit`。`oldAccess:null` 表示当前路径没有该身份的显式条目。错误含 `schemaVersion:1,code`，意外错误可附仅类型/HResult 的安全诊断。

## 本地离线检查

`Test-VisualSvnBridge.ps1` 在模块私有作用域用模拟快照验证 URL 白名单、Unicode、注入拒绝、Values/ValueMap、单条规则修改、禁写、审阅漂移/过期和操作查询。无需监听器、WMI 或真实权限数据。Windows 上可人工执行：

```powershell
& "C:\Tools\SVNManager\Test-VisualSvnBridge.ps1"
```

本机使用 PowerShell 7.6.6 runspace 实际执行 47 项通过；这不覆盖 Windows ACL、HTTP.sys、VisualSVN WMI 行为。旧服务器实机检查仍按上一节完成。

## 主源依据

- [VisualSVN 4.2 本地用户和权限 PowerShell 支持](https://www.visualsvn.com/company/news/visualsvn-server-4.2-released)
- [VisualSVN 5.1 恢复本地认证全库规则](https://www.visualsvn.com/company/news/visualsvn-server-5.1-released)
- [权限继承、优先级和 No Access](https://www.visualsvn.com/support/topic/00033/)
- [WMI Values / ValueMap 映射](https://learn.microsoft.com/en-us/windows/win32/wmisdk/value-map)

旧 WMI 方法及参数取自本次实际检测报告；显式规则、空数组和 ResetChildren 的具体行为仍需上述隔离实机验收。
