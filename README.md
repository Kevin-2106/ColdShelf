# ColdShelf

[![CI](https://github.com/Kevin-2106/ColdShelf/actions/workflows/ci.yml/badge.svg)](https://github.com/Kevin-2106/ColdShelf/actions/workflows/ci.yml)

ColdShelf 是一个面向 **Windows + PowerShell 7.4+** 的本地命令行归档工具。它把暂时不用的目录保存为未压缩 TAR，验证内容后可删除原目录，并在需要时恢复到原路径。

## 预期使用场景

在当前市场环境下，大容量 SSD 的价格仍然较高；HDD 更适合提供低成本的大容量存储，但随机读写性能通常无法满足编程环境、虚拟机、SDK、工具链和大型软件目录的日常使用需求。

ColdShelf 面向这类“平时不常用、使用时又依赖 SSD 随机读写性能”的目录：暂时不用时，通过 `cold` 将其归档到大容量 HDD，释放昂贵的 SSD 空间；再次需要时，通过 `hot` 恢复到原 SSD 路径，使软件继续获得应有的随机读写性能。它提供的是由用户显式控制的冷热迁移流程，不是自动分层存储，也不替代备份。

核心原则：

- 归档及内容校验完成前不删除源目录；
- 恢复目标只要已经存在，就拒绝覆盖；
- 每个归档保存逐文件 SHA-256 manifest；
- 删除冷归档前，逐项验证恢复目录与 manifest 一致；
- `meta.json` 和 `manifest.json` 随归档保存，`index.json` 可重建；
- 正常运行使用 Windows `%SystemRoot%\System32\tar.exe`。

> ColdShelf 不是备份系统。单份本地 TAR 不能替代异地、多副本备份和定期恢复演练。

## 安装为直接命令

在仓库目录中执行：

```powershell
pwsh -NoProfile -File .\install.ps1
```

默认安装到 `%LOCALAPPDATA%\Programs\ColdShelf`，并将该目录追加到当前用户的 `PATH`。安装不需要管理员权限，也不使用可能截断长 PATH 的 `setx`。自定义 `InstallRoot` 必须为空目录，或包含属于同一路径的有效 ColdShelf ownership state 且没有额外文件；安装器不会接管非空用户目录。安装或更新完成后，关闭并重新打开终端：

```powershell
coldshelf --help
```

再次运行 `install.ps1` 会更新已安装脚本，不会重复添加 PATH。卸载命令：

```powershell
pwsh -NoProfile -File "$env:LOCALAPPDATA\Programs\ColdShelf\uninstall.ps1"
```

卸载只移除 ownership state 中固定列出的 ColdShelf 命令文件及其拥有的用户 PATH 条目，不递归删除安装目录；安装目录出现未受 ColdShelf 管理的文件时会拒绝卸载。它不会删除 `%USERPROFILE%\.coldshelf`、archiveRoot、TAR 或恢复数据。若不想安装，也可以在仓库中使用 portable 形式：

```powershell
pwsh -NoProfile -File .\coldshelf.ps1 --help
```

## 命令

```text
init / cold / hot / list / info / verify / remove / doctor / stats
```

```powershell
# 初始化
coldshelf init 'E:\ColdShelfStore'

# 冷藏；校验后询问是否删除源目录
coldshelf cold 'D:\Projects\OldGame'

# 自动删除或明确保留源目录
coldshelf cold 'D:\Projects\OldGame' --remove
coldshelf cold 'D:\Projects\OldGame' --keep

# 查看
coldshelf list
coldshelf info OldGame

# 校验
coldshelf verify OldGame
coldshelf verify OldGame --full

# 恢复
coldshelf hot OldGame

# 恢复时临时添加 Microsoft Defender 排除项
coldshelf hot OldGame -d
coldshelf hot OldGame --defender-exclusion

# 验证恢复副本后删除冷归档
coldshelf remove OldGame
coldshelf remove OldGame --yes

# 诊断与统计
coldshelf doctor
coldshelf stats
coldshelf stats OldGame
```

目标参数可使用完整 ID、唯一 ID 前缀或唯一目录名。匹配不唯一时返回冲突，不会自动猜测。

## 运行要求

- Windows 10/11；
- PowerShell 7.4 或更高版本；
- Windows 自带 `%SystemRoot%\System32\tar.exe`；
- 对源目录、归档目录和恢复目标父目录有相应权限；
- ColdShelf state 与 `archiveRoot` 必须互不包含，且不能是文件系统根、用户根、Windows、ProgramData 或 Program Files 根；
- 使用 `hot -d` 或 `hot --defender-exclusion` 时，需要接受 UAC 提权，并且系统须提供 `Get-MpPreference`、`Add-MpPreference` 和 `Remove-MpPreference`。

正常运行固定调用 System32 中的 `tar.exe`，不使用 `PATH` 中的同名程序。`COLDSHELF_TAR_PATH` 是供受控测试使用的可执行文件覆盖项。

## 测试

测试全部使用随机临时目录和隔离状态。Defender 流程使用测试 helper，不会执行真实 UAC 或修改 Microsoft Defender 配置；安装测试使用随机 HKCU 测试子键，不会修改真实用户 `PATH`。

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
pwsh -NoProfile -File .\tests\run-install-tests.ps1
```

GitHub Actions 在 `windows-latest` 上执行 PowerShell AST 解析、核心回归和安装回归。

ColdShelf 不提供 VSS。冷藏期间仍在写入的目录可能无法得到一致快照；使用前应停止相关应用。

## 状态与归档布局

默认状态目录：

```text
%USERPROFILE%\.coldshelf
├─ config.json
├─ history.json
└─ defender-sessions\
```

可用 `COLDSHELF_HOME` 覆盖状态目录：

```powershell
$env:COLDSHELF_HOME = 'D:\Temp\coldshelf-state'
```

归档根目录布局：

```text
E:\ColdShelfStore\
├─ archives\
│  ├─ <id>\
│  │  ├─ archive.tar
│  │  ├─ manifest.json
│  │  └─ meta.json
│  ├─ <id>.tmp\
│  │  ├─ archive.tar
│  │  ├─ manifest.json
│  │  └─ meta.json
│  └─ .coldshelf-remove-archive-<id>-<random>\
└─ index.json
```

- `archive.tar`：未压缩 TAR；
- `manifest.json`：目录项以及每个文件的相对路径、长度和 SHA-256；
- `meta.json`：归档 ID、源路径、大小、状态、`archiveSha256` 等事实；
- `<id>.tmp`：创建中或失败后留下的临时归档，不会作为正式归档列出；
- `.coldshelf-remove-archive-<id>-<random>`：`remove` 被中断时可能留下的归档 quarantine，不会作为正式归档列出；
- `index.json`：从正式归档 metadata 重建的派生索引。

## `cold <path> [--remove|--keep]`

选项：

| 方式 | 校验成功后的行为 |
|---|---|
| 无选项 | 交互询问是否删除源目录；输入重定向时保留 |
| `--remove` | 自动删除源目录 |
| `--keep` | 不询问，保留源目录 |

`cold` 的实际顺序：

1. 解析源目录，拒绝文件系统根、受保护路径、与归档根互相包含的路径、reparse point 和含换行符的名称；
2. 统计文件数、目录数和逻辑字节数；
3. 读取每个文件并建立内容 manifest，其中包含逐文件 SHA-256；
4. 在 `archives/<id>.tmp` 写入 `manifest.json` 和状态为 `creating` 的 `meta.json`；
5. 创建 `archive.tar`；
6. 要求 System32 `tar.exe -tf` 成功解析归档，同时严格读取 TAR/USTAR/PAX 原始 512-byte header，以无损路径检查绝对路径、盘符、`..` 逃逸、重复项和顶层目录；
7. 将原始 header 的完整路径与 .NET `TarReader` 条目按顺序一一配对，由 `TarReader` 读取类型、长度和内容并重新计算每个文件的 SHA-256，再与 `manifest.json` 逐项比较；
8. 再次扫描源目录并生成 manifest，与归档前基准逐项比较，检测归档期间的内容变化；
9. 计算整个 `archive.tar` 的 SHA-256，写入 `meta.json.archiveSha256`；
10. 将 metadata 标记为 `cold`，再把 `<id>.tmp` 发布为正式 `<id>`；
11. 只有以上步骤全部成功后，才询问或执行源目录删除；
12. 删除提交前对正式 `archive.tar` 和 `manifest.json` 持有拒绝写入/删除的读取句柄，并再次执行 `verify --full`；
13. 在同一父目录用 `Directory.Move` 将源目录原子冻结为带 128-bit 随机 nonce 的 `.coldshelf-delete-<id>-<nonce>`，通过 `CreateNew` 创建随机 ownership token sidecar，并以独占 `DeleteOnClose` handle 持有到事务结束，再对冻结内容做逐文件 manifest 校验；
14. 校验成功后先写入 `sourceRemovalPending` metadata；递归删除紧前再次核对 exact path、ownership token、reparse 状态和完整 manifest，然后只删除 ColdShelf 自有 quarantine。若冻结校验或 pending metadata 写入失败，目录会原子移回原名。

因此，`cold` 不只是比较文件数量和总大小，而是进行内容级逐文件校验。归档发布前的任何 TAR、manifest、完整性或 metadata 错误都会保留源目录；失败的 `<id>.tmp` 可能保留供 `doctor` 和人工检查。若进程在 quarantine 删除阶段被强制中断，metadata 会保留 `sourceRemovalPending` 与 `sourceQuarantine`，不会错误声称源目录仍在原路径。

## `hot <id-or-name> [-d|--defender-exclusion]`

恢复目标固定为 `meta.json.sourcePath`。

恢复过程：

1. 先执行快速归档结构校验并读取 `manifest.json` 基准，确定安全恢复目标；
2. 检查目标路径；文件、空目录或非空目录只要存在，都以退出码 `4` 拒绝；
3. 在目标的**同一父目录**创建 `.coldshelf-restore-<id>-<random>` staging 目录；
4. 锁定 `archive.tar`，执行 `verify --full`，确认容器 SHA-256、所有条目类型、长度和逐文件内容哈希均有效；链接、设备或其他 v1 不支持的条目会在调用 native extraction 前被拒绝；
5. 解包到 staging，确认只有预期顶层目录；
6. 对恢复结果重新建立逐文件 manifest，并与归档基准逐项比较；
7. 再次检查目标不存在；
8. 使用 `[System.IO.Directory]::Move` 将 staging 中的顶层目录移动为最终目标；
9. 更新 metadata、清理 staging，并记录历史；冷归档仍然保留。

staging 和 target 位于同一父目录，因此在同父目录的 NTFS 场景下，最后的 `Directory.Move` 是目录重命名/发布，不是把已解包内容再逐文件复制一遍。若目标在解包期间出现，ColdShelf 仍会拒绝覆盖。

### 临时 Microsoft Defender 排除

`-d` 与 `--defender-exclusion` 等价，只作用于本次 `hot`：

- ColdShelf 通过 UAC 启动提权 helper；拒绝 UAC、Defender cmdlet 不可用或排除添加失败时，返回退出码 `9`；
- 只请求两个**精确路径**的临时排除：本次 staging 路径和最终 target 路径，不排除它们的父目录；
- helper 先读取现有排除项。某个精确路径若原本已经存在，会记录为 pre-existing，结束时不会移除；
- helper 只清理由本次会话实际添加、即 owned 的精确排除项；添加后会重新读取 Defender 配置，只有 exact path 状态唯一且一致时才声明 ownership；
- helper 每 250 ms 检查父进程 PID 和启动时间，并同时监视显式 stop 文件；父进程正常退出或消失时，它会尝试清理 owned 排除项；
- 正常恢复结束后，主进程要求 helper 清理并最多等待 30 秒。

这不是断电保证。整机断电、系统崩溃，或 helper 被强制终止时，helper 的 `finally` 可能没有机会执行，临时排除项可能残留。主进程被强杀但 helper 仍存活时，helper 通常可通过父进程监视发现并清理；如果 helper 也被强杀，则不能保证清理。Microsoft Defender 没有提供“检查不存在并由本调用原子创建且带所有权 token”的 API；外部管理员工具若恰好在 ColdShelf 添加同一 exact path 的极窄时间窗口内并发修改排除列表，所有权判断无法做到数学意义上的绝对无竞态。ColdShelf 通过随机 staging、同目标 mutex、Add 后重读和只清理 owned paths 将该窗口降到最低。

恢复数据已经发布、但 Defender 清理或后处理失败时，命令返回退出码 `10`，表示数据可能已经位于目标路径，但状态处于 degraded，不能把该退出码当作“什么都没发生”。

## `verify <id-or-name> [--full]`

普通 `verify` 检查：

- `meta.json` 版本、ID 和名称；
- `archive.tar` 存在且非空；
- System32 `tar.exe` 可成功列出归档；
- 原始 TAR/USTAR/PAX header 校验和、数值字段、终止块和成员路径安全，且只有预期顶层目录；
- `manifest.json` 存在且版本有效。

普通 `verify` 不读取整个归档内容，适合快速结构检查。

`verify --full` 包含以上检查，并进一步：

- 顺序读取 TAR 内每个目录项和文件内容，计算逐文件 SHA-256，与 `manifest.json` 基准逐项比较；
- 计算**整个 `archive.tar` 文件**的 SHA-256，与冷藏时写入 `meta.json.archiveSha256` 的基准比较。

Windows `tar.exe -tf` 的 stdout 会经过当前系统代码页，无法无损表示某些 Unicode 文件名，因此 ColdShelf 不把该文本作为路径真值；完整路径来自归档内原始 UTF-8 USTAR `name/prefix`、PAX `path` 或 GNU long-name header。Windows bsdtar 对超过经典 TAR size 字段边界的大文件可能同时写入 PAX `size`；ColdShelf 只接受规范的非负十进制 Int64，且该值必须与普通 header size 完全相同，不允许 PAX 属性改变 parser 的数据边界。原始 header 与 `TarReader` 的条目数量、顺序、类型或已知兼容形态之外的路径若不一致，验证会 fail closed。

缺少基准、内容 manifest 不同或容器哈希不同都会返回完整性错误。大型归档的 `--full` 需要完整读取 TAR，耗时接近一次顺序读盘；`cold` 在允许删除源目录前始终执行同等级的内容验证。

## `remove <id-or-name> [--yes]`

`remove` 删除 `archives/<id>`，不会删除恢复目录。

删除前必须：

1. 普通验证冷归档结构及其 `manifest.json`；
2. 确认 `meta.json.sourcePath` 当前是安全且存在的目录；
3. 重新读取恢复目录中的每个文件并计算 SHA-256；
4. 按 `manifest.json` 逐项比较路径、类型、长度和哈希；
5. 确认归档目录是 `archiveRoot/archives` 的直接子目录、目录名与 metadata ID 一致，且不是 reparse point。

删除流程使用双冻结事务：确认后先把恢复目录原子重命名为带随机 nonce 的 ColdShelf source quarantine，并用独占 `CreateNew`/`DeleteOnClose` handle 持有 ownership token；随后再次验证逐文件 manifest，对冷归档执行 `verify --full`，再以同样方式冻结并持有 archive quarantine，并在 quarantine 内再次执行完整容器哈希与内容 manifest 校验。递归删除 archive quarantine 紧前还会再次核对 exact path、held token、reparse 状态、metadata ID、容器哈希和内容 manifest。只有两份冻结数据仍匹配时，才先把 hot source 原子移回原路径，再删除 ColdShelf 自有的 archive quarantine。

任一文件新增、缺失、改名、长度变化或内容哈希变化都会拒绝删除。任一冻结或验证步骤失败都会尽力原子移回原名，且不会删除最后一份正确副本。实现不是只比较文件数和总字节数。`--yes` 只跳过最终交互确认，不跳过任何校验；非交互环境不带 `--yes` 时返回用法错误。

## `doctor`

`doctor`：

- 检查配置的归档根和 System32 `tar.exe`；
- 对正式归档执行普通内容校验；
- 报告遗留的 `<id>.tmp`；
- 报告中断的 archive quarantine 和 `sourceRemovalPending` metadata；
- 重建 `index.json`；
- 检查 `defender-sessions` 中的 orphan/未完成会话和清理失败记录。

对于可能残留的 Defender 排除项，`doctor` 会打印应在**管理员 PowerShell**中手工执行的命令，例如：

```powershell
Remove-MpPreference -ExclusionPath 'D:\Exact\ColdShelf\Path'
```

执行前应先用 `Get-MpPreference` 核对该精确路径确实应删除，尤其不要误删用户原先配置的排除项。`doctor` 只报告和给出命令，不会自动删除 Defender 排除项、失败暂存目录、quarantine 或用户数据。发现无效正式归档或中断状态时返回 degraded (`10`)。

## `manifest.json` 与 `meta.json`

`manifest.json` 示例：

```json
{
  "version": 1,
  "entries": [
    {
      "path": "bin",
      "type": "directory",
      "length": 0,
      "sha256": null
    },
    {
      "path": "bin/app.exe",
      "type": "file",
      "length": 123456,
      "sha256": "0123456789abcdef..."
    }
  ]
}
```

路径使用相对于源目录根的 `/` 分隔形式。源根本身不作为 manifest entry；空目录通过目录 entry 保留。

`meta.json` 的主要字段：

| 字段 | 含义 |
|---|---|
| `version` | metadata 版本，当前为 `1` |
| `id` | 归档 ID，也是正式归档目录名 |
| `name` | 源目录叶名称和 TAR 顶层目录名 |
| `sourcePath` | 原始绝对路径，也是恢复目标 |
| `archiveFile` | 当前为 `archive.tar` |
| `manifestFile` | 当前为 `manifest.json` |
| `createdAt` | 创建时间 |
| `originalSize` | 普通文件逻辑字节数合计 |
| `fileCount` | 文件数 |
| `directoryCount` | 目录数，包含源根 |
| `archiveSize` | TAR 文件大小 |
| `archiveSha256` | 整个 TAR 的 SHA-256 基准 |
| `status` | `creating`、`failed`、`cold` 或 `hot` |
| `sourceRemoved` / `sourceRemovedAt` | 源目录删除状态和时间 |
| `sourceRemovalPending` | 已提交源目录删除，但 quarantine 清理或最终 metadata 更新尚未确认完成 |
| `sourceQuarantine` | pending 状态下记录的 ColdShelf source quarantine 绝对路径 |
| `restoredAt` | 最近恢复时间 |

JSON 通过同目录临时文件写入，再用文件移动替换目标，降低半写文件的概率。

## 统计与 ETA

`cold` 和 `hot` 分开记录成功操作，`stats` 可显示全部记录或指定归档的记录。

- **Average**：所有样本的加权吞吐，即 `总字节数 / 总时长`，不是每次速度的算术平均；
- **Recent**：最近最多 5 个同类样本的加权吞吐，同样按 `这些样本总字节数 / 总时长` 计算；
- **EMA**：第一个样本直接作为初值，之后使用 `新 EMA = 旧 EMA × 0.7 + 最新样本速度 × 0.3`。

ETA 优先使用同类操作的 EMA；没有历史时，`cold` 默认 110 MB/s，`hot` 默认 130 MB/s。冷藏和恢复不共享 EMA。统计历史损坏或写入失败只产生警告，不会回滚已经完成的数据操作。

## 退出码

退出码与 `coldshelf.ps1` 中的定义一致：

| 退出码 | 名称 | 含义 |
|---:|---|---|
| `0` | success | 成功 |
| `1` | general | 未分类或未预期的一般错误 |
| `2` | usage | 命令、参数、选项或交互用法错误 |
| `3` | not found | 源目录、归档或必要目标未找到 |
| `4` | conflict | 匹配歧义、恢复目标已存在或目标冲突 |
| `5` | safety | 危险路径、reparse point、删除前置条件或其他安全策略拒绝 |
| `6` | tar | TAR 可执行文件、启动、创建或解包失败 |
| `7` | integrity | metadata、manifest、TAR 结构、哈希或内容完整性失败 |
| `8` | state | 未初始化、配置、归档根、空间或持久状态错误 |
| `9` | defender/UAC | UAC、Defender helper 或临时排除项操作失败 |
| `10` | degraded | 数据可能已发布但后处理不完整，或 `doctor` 发现无效归档 |

调用方必须检查 `$LASTEXITCODE`。尤其是 `10`：它可能表示恢复目标已经成功发布，但 Defender 排除清理、metadata/history/index 等后处理没有完整完成。

```powershell
coldshelf hot OldGame --defender-exclusion
switch ($LASTEXITCODE) {
    0  { 'Restore completed.' }
    9  { throw 'UAC or Defender exclusion setup failed.' }
    10 { throw 'Data may be restored, but cleanup/state is degraded; inspect output and run doctor.' }
    default { throw "ColdShelf failed with exit code $LASTEXITCODE." }
}
```

## 已知限制

- 无 VSS，不能为持续变化的数据提供一致性快照；
- TAR 未压缩，所需空间接近源数据大小并包含 TAR 开销；
- 不支持 reparse point；state、archiveRoot、source、restore parent 和 quarantine 的现存祖先链也会检查 reparse point；
- quarantine 使用不可预测 nonce、独占 `CreateNew`/`DeleteOnClose` ownership handle 和删除紧前内容复核，但普通用户态文件系统 API 无法对抗有权限的并发本地管理员在最后一个检查与递归删除之间主动替换目录；
- 权限不足、独占锁、磁盘断开和断电仍可能中断操作；
- 同父目录 `Directory.Move` 的重命名发布依赖目标文件系统支持，本文所述行为针对 NTFS；
- Defender 临时排除依赖 helper 获得清理执行机会，无法覆盖断电或 helper 强杀；
- 单机单份归档不是完整备份方案。

首次使用建议先执行 `cold --keep`，再运行 `verify --full`，并用非关键数据完成一次 `hot` 与 `remove` 演练。

## 许可证

本仓库当前未附带开源许可证。代码可公开查看，但未经版权所有者明确许可，不授予复制、修改、分发或再许可的权利。

安全问题请按 [SECURITY.md](SECURITY.md) 通过 GitHub private vulnerability reporting 报告，不要在公开 issue 中披露可能导致数据删除、路径逃逸或权限滥用的细节。
