import SwiftUI
import UniformTypeIdentifiers
import AppKit
import MyCompressCore

struct CompressView: View {
    @StateObject private var appState = AppState()
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var algorithm: MCZCompressionAlgorithm = .zstd
    @State private var level: MCZCompressionLevel = .default
    @State private var password = ""
    @State private var showPassword = false
    @State private var showAdvanced = false
    @State private var blockSize = 1024 * 1024 // 1MB
    @State private var isDragging = false
    @State private var hoveredAlgorithm: MCZCompressionAlgorithm? = nil
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 拖拽区域
                    dropZone
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    
                    // 文件信息
                    if let inputURL = inputURL {
                        fileInfoView(url: inputURL)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    
                    // 选项区域
                    optionsSection
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                    
                    // 压缩按钮
                    compressButton
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .alert("错误", isPresented: $appState.showError) {
                Button("确定") {}
            } message: {
                Text(appState.errorMessage ?? "未知错误")
            }
            .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                handleDrop(providers: providers)
            }
            
            if appState.isProcessing {
                ProcessingOverlay()
                    .environmentObject(appState)
            }
        }
    }
    
    // MARK: - 拖拽区域
    private var dropZone: some View {
        Button(action: selectFile) {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                Text("拖拽文件或文件夹到这里")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("或点击选择")
                    .font(.system(size: 11))
                    .foregroundColor(Color(nsColor: .tertiaryLabelColor))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 140)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isDragging ? Color.accentColor.opacity(0.08) : Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isDragging ? Color.accentColor : Color(nsColor: .separatorColor),
                                style: StrokeStyle(lineWidth: isDragging ? 2 : 1, dash: isDragging ? [] : [4, 4])
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - 文件信息
    @ViewBuilder
    private func fileInfoView(url: URL) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(formatFileSize(getFileSize(url: url)))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: { inputURL = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 选项区域
    private var optionsSection: some View {
        VStack(spacing: 0) {
            // 算法选择
            VStack(spacing: 0) {
                optionRow(icon: "bolt.fill", iconColor: .orange, title: "压缩算法") {
                    HStack(spacing: 4) {
                        // LZ4 按钮
                        algorithmButton(algo: .lz4, title: "LZ4")
                        // Zstandard 按钮（推荐）
                        algorithmButton(algo: .zstd, title: "Zstandard", showRecommended: true)
                        // LZMA 按钮
                        algorithmButton(algo: .lzma, title: "LZMA")
                    }
                }
                
                // 悬停时显示算法说明卡片
                if let hovered = hoveredAlgorithm {
                    algorithmInfoCard(for: hovered)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                
                // 加密选项
                optionRow(icon: "lock.fill", iconColor: .blue, title: "加密") {
                    HStack(spacing: 8) {
                        if showPassword {
                            TextField("密码", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                        } else {
                            SecureField("密码 (可选)", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 140)
                        }
                        Button(action: { showPassword.toggle() }) {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            
            Divider()
                .padding(.horizontal, 16)
            
            // 高级选项按钮
            Button(action: { withAnimation(.easeInOut(duration: 0.2)) { showAdvanced.toggle() } }) {
                HStack {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("高级选项")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: showAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if showAdvanced {
                VStack(spacing: 0) {
                    Divider()
                    
                    optionRow(icon: "slider.horizontal.3", iconColor: .purple, title: "压缩级别") {
                        Picker("", selection: $level) {
                            Text("最快").tag(MCZCompressionLevel.fastest)
                            Text("快速").tag(MCZCompressionLevel.fast)
                            Text("默认").tag(MCZCompressionLevel.default)
                            Text("最佳").tag(MCZCompressionLevel.best)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                    }
                    
                    optionRow(icon: "square.split.2x2", iconColor: .teal, title: "块大小") {
                        Picker("", selection: $blockSize) {
                            Text("256 KB").tag(256 * 1024)
                            Text("512 KB").tag(512 * 1024)
                            Text("1 MB").tag(1024 * 1024)
                            Text("2 MB").tag(2 * 1024 * 1024)
                            Text("4 MB").tag(4 * 1024 * 1024)
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 算法按钮（带悬停检测）
    @ViewBuilder
    private func algorithmButton(algo: MCZCompressionAlgorithm, title: String, showRecommended: Bool = false) -> some View {
        let isSelected = algorithm == algo
        
        Button(action: {
            algorithm = algo
            switch algo {
            case .lz4: level = .fastest
            case .zstd: level = .default
            case .lzma: level = .best
            }
        }) {
            HStack(spacing: showRecommended ? 3 : 0) {
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if showRecommended {
                    Text("推荐")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.3) : Color.accentColor)
                        )
                        .foregroundColor(.white)
                }
            }
            .padding(.horizontal, showRecommended ? 10 : 14)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor : Color(nsColor: .controlColor))
            )
            .foregroundColor(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredAlgorithm = hovering ? algo : nil
            }
        }
    }
    
    // MARK: - 算法说明卡片
    @ViewBuilder
    private func algorithmInfoCard(for algo: MCZCompressionAlgorithm) -> some View {
        let info = algorithmDescription(for: algo)
        
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(info.title)
                        .font(.system(size: 12, weight: .semibold))
                    if info.recommended {
                        Text("推荐")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(2)
                    }
                }
                
                HStack(spacing: 16) {
                    labelMetric(icon: "arrow.down.circle.fill", color: .green, label: "压缩", value: info.speed)
                    labelMetric(icon: "arrow.up.circle.fill", color: .blue, label: "解压", value: info.decompressionSpeed)
                    labelMetric(icon: "archivebox.circle.fill", color: .orange, label: "压缩率", value: info.ratio)
                }
                
                Text(info.scenario)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private func labelMetric(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
    
    private func algorithmDescription(for algo: MCZCompressionAlgorithm) -> (title: String, speed: String, decompressionSpeed: String, ratio: String, scenario: String, recommended: Bool) {
        switch algo {
        case .lz4:
            return ("LZ4 - 极速压缩", "极快", "极快", "较低",
                    "适合临时备份、快速传输等对速度要求极高的场景，不适合长期归档。", false)
        case .zstd:
            return ("Zstandard - 均衡", "快", "很快", "优秀",
                    "日常使用的最佳选择，速度与压缩率完美平衡，适合大多数压缩需求。", true)
        case .lzma:
            return ("LZMA - 高压缩率", "较慢", "较快", "最高",
                    "适合长期归档存储、分发大文件等对压缩率要求极高的场景，压缩耗时较长。", false)
        }
    }
    
    // MARK: - 压缩按钮
    private var compressButton: some View {
        Button(action: startCompression) {
            HStack(spacing: 8) {
                if appState.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(appState.isProcessing ? appState.statusMessage : "压缩")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(inputURL == nil || appState.isProcessing ? Color.gray.opacity(0.3) : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(inputURL == nil || appState.isProcessing)
    }
    
    // MARK: - 选项行辅助
    @ViewBuilder
    private func optionRow<Content: View>(icon: String, iconColor: Color, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundColor(iconColor)
                .frame(width: 16)
            
            Text(title)
                .font(.system(size: 12))
                .foregroundColor(.primary)
            
            Spacer()
            
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    // MARK: - 操作方法
    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择要压缩的文件或文件夹"
        
        if panel.runModal() == .OK {
            inputURL = panel.url
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    self.inputURL = url
                } else if let url = item as? URL {
                    self.inputURL = url
                }
            }
        }
        return true
    }
    
    private func startCompression() {
        guard let inputURL = inputURL else { return }
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = inputURL.lastPathComponent + ".mcz"
        panel.allowedContentTypes = [UTType(filenameExtension: "mcz") ?? .data]
        panel.message = "选择保存位置"
        
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }
        outputURL = saveURL
        
        Task {
            appState.startProcessing(message: "正在压缩...")
            
            do {
                let options = MCZCompressionOptions(
                    algorithm: algorithm,
                    level: level,
                    blockSize: blockSize,
                    maxConcurrency: ProcessInfo.processInfo.activeProcessorCount,
                    password: password.isEmpty ? nil : password,
                    preservePermissions: true
                )
                
                let compressor = ParallelCompressor(
                    options: options,
                    progressHandler: { @Sendable prog in
                        Task { @MainActor in
                            self.appState.updateProgress(
                                prog.fractionCompleted,
                                message: "正在压缩... \(Int(prog.fractionCompleted * 100))%"
                            )
                        }
                    }
                )
                
                try await compressor.compressDirectory(source: inputURL, destination: saveURL)
                
                appState.finishProcessing(message: "压缩完成！")
                
            } catch {
                appState.showError(error.localizedDescription)
            }
        }
    }
    
    // MARK: - 工具方法
    private func getFileSize(url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
