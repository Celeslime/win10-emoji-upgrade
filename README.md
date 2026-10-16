# Win10Emoji — 在 Windows 10 上安装 Windows 11 官方 Segoe UI Emoji 字体

Windows 10 的 emoji 字体永远停在 2019 年的 **1.29 版（Emoji 12.0）**，微软不再为 Win10 更新；  
而 Windows 11 已经迭代到 **1.70 版（Emoji 17.0）**。本仓库提供一套带安全护栏的自动化工具，  
把 Win11 的官方字体安全地装到 Win10 上，全程可校验、可回滚。

> 原理：Win11 的 `seguiemj.ttf` 采用 COLR v1，但保留了完整的 COLR v0 兼容记录，  
> Win10 的渲染器可以直接使用——实测在记事本、Edge、Chrome 中彩色渲染正常。

## 效果对比

| Emoji 版本   | 覆盖率（旧 1.29） | 覆盖率（新 1.70） |
| ---------- | ----------- | ----------- |
| Emoji 13.0 | 44%         | **100%**    |
| Emoji 14.0 | 4%          | **100%**    |
| Emoji 15.0 | 3%          | **100%**    |
| Emoji 16.0 | 12%         | **100%**    |
| Emoji 17.0 | 58%         | **100%**    |
| 全版本合计      | 92%         | **99%**     |

（按 Unicode 官方 `emoji-test.txt` 3963 条 fully-qualified 序列逐条比对）

## 获取字体（本仓库不分发）

字体是微软版权文件，**请自行获取**，按可信度排序：

1. 找一台 Windows 11 电脑，拷贝 `C:\Windows\Fonts\seguiemj.ttf`（约 12MB）；
2. 下载微软官网 Win11 ISO，从 `sources\install.wim` 中提取；
3. ⚠️ 不要使用论坛/网盘来源的字体文件——系统字体被篡改的后果很严重。

把文件放到本仓库目录下（与脚本同目录），命名为 `seguiemj.ttf`，或稍后用 `-SourceFont` 指定路径。

## 快速开始

所有脚本需要 PowerShell 5.1+，改动系统文件的步骤需**管理员权限**。

```powershell
# 1) 预览（只读，不改任何东西）
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1

# 2) 备份 + 导出注册表 + 接管文件所有权（管理员）
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Prepare

# 3) 解除字体注册（管理员），然后完整重启一次
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Unregister

# 4) 写入新字体 + 恢复注册（管理员），然后再完整重启一次
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Commit

# 5) 校验
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Phase Verify

# 不满意？一键回滚（管理员），之后重启
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Apply -Phase Rollback
```

## Commit 失败？走开机任务通道

如果 Commit 反复报「文件被占用 / 访问被拒绝」，且你的系统开启了**快速启动**  
（Win10 默认开启），「重启时替换」登记（PendingFileRenameOperations）会被  
快速启动的内核休眠恢复**静默跳过**——这是最常见的失败原因。

改用 SYSTEM 权限的一次性开机任务，在会话创建前完成替换：

```powershell
# 注册开机任务（管理员）
powershell -ExecutionPolicy Bypass -File .\Register-BootTask.ps1 -SourceFont .\seguiemj.ttf

# 真重启（不要关机再开机——快速启动下那不是真重启）
shutdown /r /t 5

# 重启回来后校验
powershell -ExecutionPolicy Bypass -File .\Set-EmojiFont.ps1 -Phase Verify
```

任务执行内容：停字体缓存 → 接管所有权 → 删旧字体 → 拷新字体 → 恢复注册表 →  
清缓存 → 自删任务。日志写入 `<系统盘>:\EmojiFontBackup\boot-replace.log`。

> 注意：内核字体表只在会话创建时加载。开机任务完成替换后，如果 Verify  
> 显示的仍是旧版本，再普通重启一次即可。

## 工具集（tools/）

需要 Python 3.8+，无需第三方库：

| 脚本                  | 用途                                       |
| ------------------- | ---------------------------------------- |
| `inspect_font.py`   | 解析任意 TTF 的 name/cmap 表，输出版本号 + 指定码位覆盖    |
| `emoji_coverage.py` | 按 Unicode 官方 `emoji-test.txt` 逐版本统计字体覆盖率 |
| `gdi_glyph_test.py` | 用 GDI 查询系统当前实际加载的 emoji 字体字形覆盖           |

浏览器端验证页 `emoji-check.html` 可在替换前后对比渲染效果。

## 已知限制

- **`Win + .` 表情面板的候选列表不会更新**——面板的 emoji 清单固化在系统里，  
  新表情可以粘贴显示、可以搜索，但面板里选不到。设计如此，无解。
- **国旗类 emoji（🇨🇳 等）在 Windows 上永远显示为字母对**——系统行为，换字体无解。
- **系统更新或 `sfc /scannow` 可能把字体还原为 1.29**——重跑开机任务通道即可。
- 少数自带 emoji 渲染的应用（部分 Electron 应用、老版 Office）可能不走系统字体。

## 风险声明

本工具会替换 Windows 系统字体文件（`C:\Windows\Fonts\seguiemj.ttf`）并修改注册表。  
虽然每一步都有备份和回滚路径，仍请理解：

- 操作前 `seguiemj.ttf.original` 等备份会写入备份目录，回滚靠它；
- 极端情况下系统更新可能覆盖替换，需重跑一次脚本；
- 使用本工具的一切后果自负。

## License

代码以 MIT 协议发布。`seguiemj.ttf` 字体文件版权归 Microsoft Corporation 所有，  
本仓库不分发该字体，请用户自行从合法渠道获取。
