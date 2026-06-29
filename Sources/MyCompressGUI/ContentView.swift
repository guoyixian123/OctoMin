import SwiftUI
import AppKit

struct ProcessingOverlay: View {
    @EnvironmentObject var appState: AppState
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                
                Text(appState.statusMessage)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                
                ProgressView(value: appState.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 200)
                
                Text("\(Int(appState.progress * 100))%")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
            }
            .padding(24)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 4)
            )
        }
    }
}

struct ContentView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶部切换控件
            HStack {
                Spacer()
                Picker("", selection: $selectedTab) {
                    Text("压缩").tag(0)
                    Text("解压").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)
            
            // 内容区域
            if selectedTab == 0 {
                CompressView()
            } else {
                DecompressView()
            }
        }
        .frame(minWidth: 480, minHeight: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
