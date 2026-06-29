import SwiftUI
import UniformTypeIdentifiers
import AppKit
import OctoMinCore

struct CompressView: View {
    @StateObject private var appState = AppState()
    @State private var inputURL: URL?
    @State private var outputURL: URL?
    @State private var outputFormat: OutputCompressionFormat = .omz
    @State private var algorithm: OMZCompressionAlgorithm = .zstd
    @State private var levelValue: Int = 5 // 0-9 滑块值
    @State private var zipLevel: Int = 6
    @State private var threadCount: Int = ProcessInfo.processInfo.activeProcessorCount
    @State private var password = ""
    @State private var showPassword = false
    @State private var showAdvanced = false
    @State private var blockSize = 1024 * 1024 // 1MB
    @State private var isDragging = false
    
    private let maxThreads = ProcessInfo.processInfo.activeProcessorCount * 2
    private let minThreads = 1
    
    // 将滑块值(0-9)映射到压缩级别
    private var level: OMZCompressionLevel {
        switch levelValue {
        case 0...1: return .fastest
        case 2...4: return .fast
        case 5...7: return .default
        default: return .best
        }
    }
    
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
            VStack(spacing: 0) {
                // 输出格式选择
                optionRow(icon: "doc.zipper", iconColor: .accentColor, title: "输出格式") {
                    Picker("", selection: $outputFormat) {
                        Text("OMZ").tag(OutputCompressionFormat.omz)
                        Text("ZIP").tag(OutputCompressionFormat.zip)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 120)
                    .onChange(of: outputFormat) { _ in
                        showAdvanced = false
                    }
                }
                
                // 格式说明（固定显示，不做动画）
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: 20)
                    Text(outputFormat.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
                .padding(.top, -4)
                
                // OMZ 专属选项
                if outputFormat == .omz {
                    // 压缩算法
                    optionRow(icon: "bolt.fill", iconColor: .orange, title: "压缩算法") {
                        Picker("", selection: $algorithm) {
                            Text("LZ4").tag(OMZCompressionAlgorithm.lz4)
                            Text("Zstandard").tag(OMZCompressionAlgorithm.zstd)
                            Text("LZMA").tag(OMZCompressionAlgorithm.lzma)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 200)
                        .onChange(of: algorithm) { newAlgo in
                            switch newAlgo {
                            case .lz4: levelValue = 0
                            case .zstd: levelValue = 5
                            case .lzma: levelValue = 9
                            }
                        }
                    }
                    
                    // 当前算法说明（固定显示当前选中算法的介绍，不使用悬停）
                    algorithmInfoFixed
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }
                
                // 加密选项
                if outputFormat.supportsEncryption {
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
            }
            
            Divider()
                .padding(.horizontal, 16)
            
            // 高级选项按钮
            Button(action: { withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() } }) {
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
                    
                    if outputFormat == .omz {
                        // OMZ 高级选项
                        
                        // 压缩级别（滑块方式）
                        optionRow(icon: "slider.horizontal.3", iconColor: .purple, title: "压缩级别") {
                            levelSlider
                        }
                        
                        // 压缩级别说明
                        HStack {
                            Spacer()
                            Text(levelDescription)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .padding(.top, -6)
                        
                        // 线程数
                        optionRow(icon: "cpu", iconColor: .blue, title: "线程数") {
                            threadPicker
                        }
                        
                        // 块大小
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
                        
                        // 块大小说明
                        HStack {
                            Spacer()
                            Text("文件被切成此大小的块并行压缩。默认1MB适合大多数场景。")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .padding(.top, -6)
                    } else if outputFormat == .zip {
                        // ZIP 高级选项
                        optionRow(icon: "slider.horizontal.3", iconColor: .purple, title: "压缩级别") {
                            zipLevelSlider
                        }
                        
                        HStack {
                            Spacer()
                            Text(zipLevelDescription)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .padding(.top, -6)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 固定算法介绍（不使用悬停动画，避免卡顿）
    private var algorithmInfoFixed: some View {
        let info = algorithmDescription(for: algorithm)
        
        return HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(info.title)
                        .font(.system(size: 11, weight: .semibold))
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
                
                HStack(spacing: 14) {
                    smallMetric(icon: "arrow.down.circle.fill", color: .green, label: "压缩", value: info.speed)
                    smallMetric(icon: "arrow.up.circle.fill", color: .blue, label: "解压", value: info.decompressionSpeed)
                    smallMetric(icon: "archivebox.circle.fill", color: .orange, label: "压缩率", value: info.ratio)
                }
                
                Text(info.scenario)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(2)
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
    private func smallMetric(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 9, weight: .semibold))
        }
    }
    
    // MARK: - 统一滑块组件
    private func standardSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        leftLabel: String,
        leftColor: Color,
        rightLabel: String,
        rightColor: Color,
        numberValue: Int,
        resetAction: @escaping () -> Void,
        resetHelp: String
    ) -> some View {
        HStack(spacing: 4) {
            Text(leftLabel)
                .font(.system(size: 10))
                .foregroundColor(leftColor)
                .frame(width: 32, alignment: .center)
            Slider(value: value, in: range, step: step)
                .frame(width: 124)
            Text(rightLabel)
                .font(.system(size: 10))
                .foregroundColor(rightColor)
                .frame(width: 32, alignment: .center)
            Text("\(numberValue)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
                .frame(width: 28, alignment: .trailing)
                .monospacedDigit()
            Button(action: resetAction) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .frame(width: 18, height: 16)
            }
            .buttonStyle(.plain)
            .help(resetHelp)
            .frame(width: 18, height: 16)
        }
        .frame(width: 250, alignment: .trailing)
    }
    
    // MARK: - 压缩级别滑块（OMZ）
    private var levelSlider: some View {
        standardSlider(
            value: Binding(
                get: { Double(levelValue) },
                set: { levelValue = max(0, min(9, Int($0))) }
            ),
            range: 0...9,
            step: 1,
            leftLabel: "最快",
            leftColor: .green,
            rightLabel: "最佳",
            rightColor: .orange,
            numberValue: levelValue,
            resetAction: {
                switch algorithm {
                case .lz4: levelValue = 0
                case .zstd: levelValue = 5
                case .lzma: levelValue = 6
                }
            },
            resetHelp: "重置为推荐级别"
        )
    }
    
    // MARK: - ZIP压缩级别滑块
    private var zipLevelSlider: some View {
        standardSlider(
            value: Binding(
                get: { Double(zipLevel) },
                set: { zipLevel = max(0, min(9, Int($0))) }
            ),
            range: 0...9,
            step: 1,
            leftLabel: "存储",
            leftColor: .gray,
            rightLabel: "最佳",
            rightColor: .orange,
            numberValue: zipLevel,
            resetAction: { zipLevel = 6 },
            resetHelp: "重置为默认级别"
        )
    }
    
    private var levelDescription: String {
        switch levelValue {
        case 0: return "0: 极速压缩，压缩率最低"
        case 1: return "1: 极快，压缩率较低"
        case 2: return "2: 很快，压缩率偏低"
        case 3: return "3: 快速压缩"
        case 4: return "4: 较快，压缩率较好"
        case 5: return "5: 默认，速度与压缩率平衡"
        case 6: return "6: 均衡偏压缩率"
        case 7: return "7: 较高压缩率"
        case 8: return "8: 高压缩率，速度较慢"
        case 9: return "9: 最高压缩率，速度最慢"
        default: return ""
        }
    }
    
    // MARK: - 线程数选择器
    private var threadPicker: some View {
        standardSlider(
            value: Binding(
                get: { Double(threadCount) },
                set: { threadCount = max(minThreads, min(maxThreads, Int($0))) }
            ),
            range: Double(minThreads)...Double(maxThreads),
            step: 1,
            leftLabel: "少",
            leftColor: .blue,
            rightLabel: "多",
            rightColor: .blue,
            numberValue: threadCount,
            resetAction: { threadCount = ProcessInfo.processInfo.activeProcessorCount },
            resetHelp: "重置为CPU核心数"
        )
    }
    
    private var zipLevelDescription: String {
        switch zipLevel {
        case 0: return "0: 仅存储，不压缩"
        case 1: return "1: 最快速度，压缩率最低"
        case 2...3: return "\(zipLevel): 快速压缩"
        case 4...6: return "\(zipLevel): 平衡速度与压缩率（默认）"
        case 7...8: return "\(zipLevel): 高压缩率"
        case 9: return "9: 最高压缩率，速度最慢"
        default: return ""
        }
    }
    
    private func algorithmDescription(for algo: OMZCompressionAlgorithm) -> (title: String, speed: String, decompressionSpeed: String, ratio: String, scenario: String, recommended: Bool) {
        switch algo {
        case .lz4:
            return ("LZ4 极速压缩", "极快", "极快", "较低",
                    "适合临时备份、快速传输等对速度要求极高的场景。", false)
        case .zstd:
            return ("Zstandard 均衡压缩", "快", "很快", "优秀",
                    "日常使用的最佳选择，速度与压缩率完美平衡。", true)
        case .lzma:
            return ("LZMA 高压缩率", "较慢", "较快", "最高",
                    "适合长期归档、分发大文件，压缩耗时较长。", false)
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
                Text(appState.isProcessing ? appState.statusMessage : "压缩为 \(outputFormat.displayName)")
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
        
        let ext = outputFormat.fileExtension
        let defaultName = inputURL.lastPathComponent + "." + ext
        
        let panel = NSSavePanel()
        panel.nameFieldStringValue = defaultName
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .data]
        panel.message = "选择保存位置"
        
        guard panel.runModal() == .OK, let saveURL = panel.url else { return }
        outputURL = saveURL
        
        Task {
            appState.startProcessing(message: "正在压缩...")
            
            do {
                let files = [inputURL]
                
                let uOptions = UniversalCompressor.Options(
                    password: password.isEmpty ? nil : password,
                    overwriteExisting: true,
                    maxConcurrency: threadCount,
                    omzAlgorithm: algorithm,
                    omzLevel: level,
                    omzBlockSize: blockSize,
                    zipCompressionLevel: zipLevel
                )
                
                let compressor = UniversalCompressor { prog in
                    Task { @MainActor in
                        self.appState.updateProgress(
                            prog.fractionCompleted,
                            message: prog.statusMessage
                        )
                    }
                }
                
                try await compressor.compress(files: files, to: saveURL, format: outputFormat, options: uOptions)
                
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
