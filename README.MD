***
# Phocus2Importer

Phocus2Importer 是一个 macOS 命令行工具，用于将 Hasselblad `.3FR` RAW 文件离线导入到 **Phocus Mobile 2**（iPadOS 版，运行于 macOS）的数据库中。

它主要解决了官方应用不支持的机型（如 X1D I代 / H6D）无法在 Phocus Mobile 2 中导入的问题，并通过修改 RAW 头部标识，为 X1D 系列额外启用了 HNNR（AI 降噪）处理流程。

> **适用环境**：macOS (Apple Silicon)
> **适配版本**：Phocus Mobile 2 v3.6.1

---

## ✨ 功能特性

*   **支持旧款机型**：强制导入不受官方正式支持的 `.3FR` 文件（如 X1D 50C / H6D 等）到 Phocus Mobile 2 相册。
*   **启用 AI 降噪 (HNNR)**：通过对 RAW 头部进行轻量级 Patch（修改标识位），触发应用内部针对 X1D 系列的 HNNR 处理路径。
*   **离线导入**：无需连接相机，直接从 Mac 磁盘批量导入素材。
*   **自动沙盒定位**：自动侦测 `com.hasselblad.mobile2` 的沙盒容器路径，无需手动查找。
    *   RAW 存储至 `Data/Documents/Images/`
    *   数据库写入 `Data/Library/RealmDB/Album.realm`
    *   生成占位预览图至 `Data/Library/PreviewCache/`（注：工具生成的是黑色占位图，仅用于确保数据库记录有效）。
*   **EXIF 解析**：优先使用系统框架 (`ImageIO`) 自动提取 EXIF 信息，亦支持手动指定 JSON 覆盖关键元数据。

---

## 📥 获取方式

### 推荐：直接下载
请前往本项目的 [**Releases**](#) 页面下载最新编译好的二进制文件。解压后即可在终端中使用。

### 自行构建
如果你需要自定义功能或在特定架构上运行，请参阅下方的 [构建指南](#-构建指南)。

---

## 🚀 使用方法

### 前置要求
1.  **安装 App**：你的 Mac 必须已安装 Phocus Mobile 2。
    *   *方式 A (推荐)*：通过 PlayCover 安装未签名的 IPA（适合大屏体验）。
        *   IPA 下载链接：
            *   谷歌Drive：https://drive.google.com/file/d/1KqttQ-i5-FZkuOOglQE8Oj8-U_bEXeBK/view?usp=sharing
            *   百度网盘：https://pan.baidu.com/s/1PyMwO_dc1Xn7IAClTNr4pg?pwd=czwc 提取码: czwc
        *   感谢脱壳者 https://decrypt.day/
    *   *方式 B*：直接从 Mac App Store 下载官方 iPad 版本（如适用）。
2.  **初始化**：首次运行本工具前，请务必**至少打开过一次 Phocus Mobile 2 App**，以确保系统已生成沙盒容器和数据库文件。

### 1. 批量导入（推荐）

这是最高效的模式。将指定目录下的**所有 .3FR 文件**（不包含子文件夹）导入。

```bash
# 语法：Phocus2Importer <文件夹路径>
Phocus2Importer /Volumes/SSD/100HASBL
```

> **注意**：批量模式会自动为每个文件生成唯一的时间戳以避免主键冲突，不支持自定义参数。

### 2. 单文件导入

适用于测试或精准控制导入参数。

```bash
# 基础用法
Phocus2Importer --3fr /path/to/B0001118.3FR

# 高级用法：指定 EXIF 并自定义导入时间戳
Phocus2Importer --3fr /path/to/B0001118.3FR --exifbin /path/to/exif.json --ts 1765115750
```

**参数说明：**
*   `--3fr <file>`: 指定单个 `.3FR` 文件路径。
*   `--exifbin <file>`: （可选）手动指定 EXIF JSON 文件。
*   `--ts <unix_seconds>`: （可选）手动指定导入时间戳，不指定则默认使用当前时间。

---

## 🛠 构建指南

如果你选择自行从源码编译，请确保已安装 Xcode 或 Xcode Command Line Tools。

### 1. 获取源码
```bash
git clone https://github.com/yuhaoyua/Phocus2Importer.git
cd Phocus2Importer
```

### 2. 编译项目
由于依赖 RealmSwift，第一次编译可能需要几分钟来拉取依赖。

```bash
# 以 Release 模式编译
swift build -c release
```

### 3. 安装或运行
编译完成后，二进制文件位于 `.build/release/` 目录下。

```bash
# 直接运行
.build/release/Phocus2Importer --help

# (可选) 瘦身二进制文件，减小体积
strip -x .build/release/Phocus2Importer

```

---

## ⚙️ 高级配置

### EXIF JSON 模板
如果不满意系统自动抓取的 EXIF 信息，你可以通过 `--exifbin` 传入一个 JSON 文件来强制覆盖。

⚠️ **重要提示：**
为了确保数据库解析正确，**JSON 内容必须保持为单行（严禁换行）**，且字段顺序建议保持一致。请直接复制以下模板进行修改：

```json
{"Shot":"XCD 45P","Device":"Hasselblad X1D 50C","Dimensions":"8272 * 6200","DateTimeOriginal":"2025:12:07 21:55:50","ApertureValue":"4.0","OffsetTimeOriginal":"+08:00","Rating":"Optional(0)","ShutterSpeedValue":"1/50s","ISO":"100","Orientation":"0"}
```

*   **Shot**: 镜头名称
*   **Device**: 相机型号
*   **DateTimeOriginal**: 拍摄时间 (格式 YYYY:MM:DD HH:MM:SS)

---

## ⚠️ 常见问题与注意事项

### Gatekeeper 拦截 ("应用已损坏" 或 "无法打开")
如果下载的二进制文件无法运行，通常是因为 macOS 的安全机制。
**推荐解决方法**（移除隔离属性）：
```bash
xattr -cr /path/to/Phocus2Importer
```
或者，你可以临时允许任何来源：
```bash
sudo spctl --master-disable
```
然后前往 系统设置 → 隐私与安全性，在“允许从以下位置下载的 App”选择 任何来源。

### 兼容性
*   **HNNR 支持**：目前针对 X1D 系列的标识位修改已验证有效。如果你持有 **H6D** 或其他机型并希望获得更好支持，欢迎提交 Issue 并提供样片。
*   **预览图全黑**：工具生成的 `Thumbnail` 和 `Middle` 预览图默认为全黑 JPEG。这是为了保证导入速度和数据库完整性。通常在 App 内打开大图后，App 会重新渲染。

### 工作原理（概要）
*   自动定位 com.hasselblad.mobile2 的沙盒容器；
*   将 .3FR 复制到 Data/Documents/Images/，并对 RAW 头部执行一次首个匹配项的安全替换（仅前 4KB 头部，0x40 → 0x42），以触发兼容路径；
*   生成两张黑色预览图（400×300、1378×1033）至 Data/Library/PreviewCache/；
*   向 Data/Library/RealmDB/Album.realm 写入一条记录，主键格式为：<原始文件名>3FR<UnixTime>；
*   EXIF 采用系统框架 ImageIO 读取，或由用户提供 EXIF 文件覆盖关键显示字段。

---

## ⚖️ 免责声明

1.  **数据安全**：本工具涉及对 App 沙盒数据 (`Realm` 数据库) 和 RAW 文件头部的直接修改。尽管已做测试，但仍存在损坏数据库的风险。**强烈建议在操作前备份 `~/Library/Containers/com.hasselblad.mobile2` 目录。**
2.  **非官方工具**：本项目与 Hasselblad (哈苏) 官方无关，仅供学习和研究使用。
3.  **版权声明**：请确保你对导入的 `.3FR` 文件拥有合法的使用权。

---

## License

MIT License
