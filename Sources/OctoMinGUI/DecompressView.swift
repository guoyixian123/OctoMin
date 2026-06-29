import SwiftUI
import UniformTypeIdentifiers
import AppKit
import OctoMinCore

struct DecompressView: View {
    @StateObject private var appState = AppState()
    @State private var archiveURL: URL?
    @State private var outputURL: URL?
    @State private var password = ""
    @State private var showPassword = false
    @State private var archiveInfo: ArchiveMetadata?
    @State private var omzInfo: OMZArchiveInfo?
    @State private var isDragging = false
    @State private var overwriteExisting = true
    
    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // 拖拽区域
                    dropZone
                        .padding(.horizontal, 20)
                        .padding(.top, 8)
                    
                    // 档案信息
                    if let archiveURL = archiveURL {
                        archiveInfoView(url: archiveURL)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    
                    // 密码选项（仅加密档案显示）
                    if archiveURL != nil && (archiveInfo?.isEncrypted == true || omzInfo?.header.isEncrypted == true) {
                        passwordSection
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                    }
                    
                    // 覆盖选项
                    if archiveURL != nil {
                        overwriteSection
                            .padding(.horizontal, 20)
                            .padding(.top, archiveInfo?.isEncrypted == true || omzInfo?.header.isEncrypted == true ? 0 : 12)
                    }
                    
                    // 解压按钮
                    decompressButton
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
        Button(action: selectArchive) {
            VStack(spacing: 8) {
                Image(systemName: "doc.zipper")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                Text("拖拽压缩文件到这里")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                Text("支持 .omz .zip .rar .7z .tar .gz .bz2 等")
                    .font(.system(size: 10))
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
    
    // MARK: - 档案信息
    @ViewBuilder
    private func archiveInfoView(url: URL) -> some View {
        let format = ArchiveFormat.from(url: url)
        
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 32, height: 32)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    Text(format?.displayName ?? "未知格式")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundColor(.accentColor)
                        .cornerRadius(3)
                    
                    Text(formatFileSize(getFileSize(url: url)))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    if UniversalExtractor.canHandle(url) {
                        // 支持
                    } else {
                        Text("需安装解压工具")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
                
                // OMZ格式详细信息
                if let info = omzInfo {
                    HStack(spacing: 16) {
                        metaLabel(label: "文件", value: "\(info.header.fileCount)")
                        metaLabel(label: "压缩率", value: String(format: "%.0f%%", info.compressionRatio * 100))
                    }
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Button(action: { archiveURL = nil; archiveInfo = nil; omzInfo = nil }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
        .onAppear {
            loadArchiveInfo()
        }
    }
    
    @ViewBuilder
    private func metaLabel(label: String, value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .medium))
        }
    }
    
    // MARK: - 密码区域
    private var passwordSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundColor(.blue)
                .frame(width: 16)
            
            Text("密码")
                .font(.system(size: 12))
            
            Spacer()
            
            HStack(spacing: 8) {
                if showPassword {
                    TextField("输入密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                } else {
                    SecureField("输入密码", text: $password)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 覆盖选项
    private var overwriteSection: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12))
                .foregroundColor(.orange)
                .frame(width: 16)
            
            Text("覆盖已存在文件")
                .font(.system(size: 12))
            
            Spacer()
            
            Toggle("", isOn: $overwriteExisting)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor))
        .cornerRadius(8)
    }
    
    // MARK: - 解压按钮
    private var decompressButton: some View {
        let canExtract = archiveURL != nil && (archiveURL.flatMap { UniversalExtractor.canHandle($0) } ?? false)
        
        return Button(action: startDecompression) {
            HStack(spacing: 8) {
                if appState.isProcessing {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(appState.isProcessing ? appState.statusMessage : "解压")
                    .font(.system(size: 13, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background((!canExtract || appState.isProcessing) ? Color.gray.opacity(0.3) : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!canExtract || appState.isProcessing)
    }
    
    // MARK: - 方法
    private func selectArchive() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        
        let supportedTypes = ArchiveFormat.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = supportedTypes
        panel.message = "选择压缩文件（支持 .omz .zip .rar .7z .tar .gz 等）"
        
        if panel.runModal() == .OK {
            archiveURL = panel.url
            archiveInfo = nil
            omzInfo = nil
        }
    }
    
    private func isSupportedArchive(_ url: URL) -> Bool {
        ArchiveFormat.from(url: url) != nil
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                var droppedURL: URL?
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURL = url
                } else if let url = item as? URL {
                    droppedURL = url
                }
                
                if let url = droppedURL, isSupportedArchive(url) {
                    self.archiveURL = url
                    self.archiveInfo = nil
                    self.omzInfo = nil
                }
            }
        }
        return true
    }
    
    private func loadArchiveInfo() {
        guard let url = archiveURL else { return }
        
        Task {
            do {
                if let format = ArchiveFormat.from(url: url), format == .omz {
                    omzInfo = try ParallelDecompressor.readArchiveInfo(archiveURL: url)
                }
                archiveInfo = try UniversalExtractor.readMetadata(for: url)
            } catch {
                // 加密文件需要密码
                archiveInfo = try? UniversalExtractor.readMetadata(for: url)
            }
        }
    }
    
    private func startDecompression() {
        guard let archiveURL = archiveURL else { return }
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择解压目标文件夹"
        panel.prompt = "解压到这里"
        
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        outputURL = destinationURL
        
        Task {
            appState.startProcessing(message: "正在解压...")
            
            do {
                let extractor = UniversalExtractor { [weak appState] prog in
                    Task { @MainActor in
                        appState?.updateProgress(
                            prog.fractionCompleted,
                            message: prog.statusMessage
                        )
                    }
                }
                
                try await extractor.extract(
                    archive: archiveURL,
                    to: destinationURL,
                    password: password.isEmpty ? nil : password,
                    overwrite: overwriteExisting
                )
                
                appState.finishProcessing(message: "解压完成！")
                NSWorkspace.shared.open(destinationURL)
                
            } catch {
                appState.showError(error.localizedDescription)
            }
        }
    }
    
    private func getFileSize(url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap(Int64.init) ?? 0
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
