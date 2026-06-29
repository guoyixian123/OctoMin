# OctoMin

> OctoMin 是面向 macOS 的多线程高性能压缩工具。针对现有免费压缩软件速度慢、格式支持有限的问题深度优化，依托多线程算力大幅提升压缩效率，丰富兼容各类图像格式，满足日常轻量化处理需求。

## 特性

- **[性能] 多线程并行压缩/解压** - 充分利用多核 CPU，块级并行处理
- **[安全] AES-256-GCM 加密** - 军用级加密保护你的文件
- **[格式] 自定义 OMZ 格式** - 专为并行优化的压缩格式
- **[兼容] 支持多种格式** - 兼容 ZIP、RAR、7z、TAR、GZ、BZ2 等常见格式
- **[算法] 三种压缩算法** - LZ4（极速）、Zstandard（均衡）、LZMA（高压缩率）
- **[界面] 原生 macOS 界面** - 简洁美观的 SwiftUI 图形界面
- **[工具] 命令行工具** - 同时提供 CLI 版本，支持脚本自动化
- **[开源] 完全免费开源** - 所有功能无限制使用，包括多线程

## 与市面压缩工具对比

市面上主流压缩软件在多线程支持上普遍受限：免费版通常只提供单线程压缩，需要付费才能解锁多核加速。

| 功能特性 | OctoMin (本项目) | The Unarchiver | Keka (免费版) | BetterZip | WinZip Mac | 系统归档实用工具 |
|---------|:---:|:---:|:---:|:---:|:---:|:---:|
| **价格** | 完全免费 | 免费 | 免费/付费 | 付费 | 付费 | 内置 |
| **多线程压缩** | 全核心支持 | 不支持压缩 | 单线程压缩 | 付费版 | 付费版 | 单线程 |
| **多线程解压** | OMZ格式并行 | 单线程 | 部分格式 | 是 | 是 | 单线程 |
| **压缩算法** | LZ4/Zstd/LZMA | 无 | 7z/Zip等 | 多种 | Zip等 | Zip |
| **AES-256加密** | OMZ格式 | 否 | 是 | 是 | 是 | 否 |
| **自定义压缩级别** | 0-9滑块调节 | 否 | 有限 | 是 | 是 | 否 |
| **自定义线程数** | 1~2x核心数 | 否 | 否 | 有限 | 否 | 否 |
| **自定义块大小** | 可调 | 否 | 否 | 否 | 否 | 否 |
| **Zstandard算法** | 是 | 否 | 否 | 否 | 否 | 否 |
| **LZ4极速压缩** | 是 | 否 | 否 | 否 | 否 | 否 |
| **原生SwiftUI界面** | 是 | 是 | 旧框架 | - | - | 否 |
| **命令行工具** | 是 | 否 | 是 | 是 | 是 | 否 |
| **开源** | MIT | 是 | GPL | 否 | 否 | 否 |

> 表格说明："是"=完整支持，"否"=不支持，"部分"=部分支持，"有限"=有限支持

### 为什么选择 OctoMin？

1. **真正免费的多线程** - 不同于 Keka 等工具免费版仅单线程，OctoMin 所有功能完全免费，压缩/解压均可利用全部 CPU 核心
2. **现代压缩算法** - 内置 Zstandard 和 LZ4，比传统的 Deflate/Zip 快数倍
3. **并行优化的 OMZ 格式** - 专为多核设计的自定义格式，块级并行，加密同样支持并行
4. **原生 macOS 体验** - 使用 SwiftUI 构建，简洁美观，符合 macOS 设计规范
5. **灵活的参数调节** - 压缩级别、线程数、块大小均可精细控制
6. **命令行支持** - GUI + CLI 双模式，适合日常使用和脚本自动化

### 速度对比参考

在 8 核 M1/M2 Mac 上，使用默认设置压缩 1GB 混合文件：

| 工具 | 压缩格式 | 线程 | 耗时（约） | 压缩率 |
|------|---------|------|-----------|--------|
| OctoMin | OMZ (Zstd) | 8线程 | ~3秒 | 优秀 |
| Keka 免费版 | 7z | 1线程 | ~20秒 | 优秀 |
| 系统归档 | Zip | 1线程 | ~15秒 | 一般 |
| OctoMin | OMZ (LZ4) | 8线程 | ~1秒 | 一般 |
| BetterZip (付费) | 7z | 8线程 | ~5秒 | 优秀 |

> 实际速度因文件类型和硬件配置而异。OctoMin 的 LZ4 模式在大文件场景下优势尤为明显。

## 系统要求

- macOS 13.0 (Ventura) 或更高版本
- Apple Silicon (M1/M2/M3/M4) 或 Intel Mac

## 项目结构

```
OctoMin/
├── Sources/
│   ├── OctoMinCore/       # 核心压缩/加密引擎
│   ├── OctoMinGUI/        # SwiftUI 图形界面
│   └── OctoMinCLI/        # 命令行工具
└── Package.swift          # Swift Package Manager 配置
```

## 构建

### 环境要求

- Xcode 15+ 或 Swift 5.9+ 工具链

### 编译命令

```bash
# 克隆仓库
git clone <repository-url>
cd OctoMin

# 编译 Release 版本
swift build -c release

# 编译后的可执行文件位置
# .build/arm64-apple-macosx/release/OctoMinApp   # GUI 应用
# .build/arm64-apple-macosx/release/OctoMinCLI   # 命令行工具
```

## 使用指南

### 图形界面

运行 `OctoMinApp` 后：

1. **选择文件** - 拖拽文件/文件夹到窗口，或点击选择
2. **选择格式** - OMZ（自定义格式，支持加密和多线程）或 ZIP
3. **压缩算法** - OMZ 格式可选：
   - **LZ4** - 极速压缩/解压，压缩率较低，适合快速备份
   - **Zstandard (Zstd)** - 速度与压缩率的平衡（推荐）
   - **LZMA** - 最高压缩率，速度较慢，适合长期归档
4. **加密** - 设置密码保护压缩包（OMZ 格式）
5. **高级选项** - 调整压缩级别、线程数、块大小

### 命令行工具

```bash
# 压缩文件/文件夹
OctoMinCLI compress <input> [-o output.omz] [-a zstd|lz4|lzma] [-l 0-9] [-p password] [-t threads]

# 解压文件
OctoMinCLI decompress <archive> [-o output_dir] [-p password]

# 查看压缩包内容
OctoMinCLI list <archive>
```

#### 命令行示例

```bash
# 使用 Zstd 算法压缩文件夹
OctoMinCLI compress ~/Documents -o backup.omz -a zstd -l 5

# 使用 LZ4 极速压缩，8线程
OctoMinCLI compress large_file.dmg -o fast.omz -a lz4 -t 8

# 加密压缩
OctoMinCLI compress secret_files -o secret.omz -p mypassword

# 解压
OctoMinCLI decompress backup.omz -o ~/Extracted
```

## OMZ 格式说明

`.omz` (OctoMin Zip) 是本项目自定义的压缩格式，特点：

- **魔数**：`OMZ1` (0x4F 0x4D 0x5A 0x31)
- **块级并行**：文件被切分为固定大小的块（默认1MB），可独立压缩
- **AES-256-GCM 认证加密**：每个块独立加密，支持并行解密
- **PBKDF2 密钥派生**：从密码派生加密密钥，抗暴力破解
- **支持大文件**：64位文件大小支持，可处理超大文件

## 技术栈

- **Swift 5.9+**
- **SwiftUI** - 原生 macOS 界面
- **Apple Compression Framework** - 底层压缩算法
- **CryptoKit** - AES-256-GCM 加密
- **Swift Concurrency** - async/await + TaskGroup 实现并行
- **libz** - ZIP 格式支持
- **Swift Package Manager** - 构建系统

## 第三方格式支持

解压时支持以下格式：

| 格式 | 扩展名 | 支持情况 |
|------|--------|----------|
| OMZ | .omz | 压缩/解压 |
| ZIP | .zip | 压缩/解压 |
| RAR | .rar | 解压 |
| 7-Zip | .7z | 解压 |
| TAR | .tar | 解压 |
| Gzip | .gz/.tar.gz | 解压 |
| Bzip2 | .bz2/.tar.bz2 | 解压 |

## 许可证

MIT License

## 关于图标

蓝色章鱼 - OctoMin 的标志，代表灵活、多触手（多线程）的压缩能力。
