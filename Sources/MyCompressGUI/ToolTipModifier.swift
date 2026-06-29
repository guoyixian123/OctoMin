import SwiftUI
import AppKit

// MARK: - 算法说明卡片 (鼠标悬停显示)
/// 鼠标悬停在按钮上时，在按钮下方显示一个详细的算法说明卡片
struct AlgorithmInfoCard: View {
    let algorithm: String
    let speed: String
    let decompressionSpeed: String
    let ratio: String
    let scenario: String
    let recommended: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.accentColor)
                Text(algorithm)
                    .font(.system(size: 13, weight: .semibold))
                if recommended {
                    Text("推荐")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(3)
                }
                Spacer()
            }
            .padding(.bottom, 10)
            
            // 性能指标
            VStack(spacing: 5) {
                metricRow(icon: "arrow.down.circle.fill", color: .green, label: "压缩速度", value: speed)
                metricRow(icon: "arrow.up.circle.fill", color: .blue, label: "解压速度", value: decompressionSpeed)
                metricRow(icon: "archivebox.circle.fill", color: .orange, label: "压缩率", value: ratio)
            }
            .padding(.bottom, 10)
            
            // 分隔线
            Divider()
                .padding(.bottom, 10)
            
            // 适用场景
            HStack(alignment: .top, spacing: 5) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
                    .padding(.top, 1)
                Text(scenario)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(3)
            }
        }
        .padding(12)
        .frame(width: 250)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 16, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }
    
    @ViewBuilder
    private func metricRow(icon: String, color: Color, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(color)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.primary)
        }
    }
}

// MARK: - 悬停触发修饰符
struct AlgorithmTipModifier: ViewModifier {
    let algorithm: String
    let speed: String
    let decompressionSpeed: String
    let ratio: String
    let scenario: String
    let recommended: Bool
    
    @State private var isHovering = false
    @State private var showCard = false
    
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovering = hovering
                }
                if hovering {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if isHovering {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showCard = true
                            }
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) {
                        showCard = false
                    }
                }
            }
            .overlay(alignment: .top) {
                if showCard {
                    VStack(spacing: 0) {
                        // 小三角
                        Triangle()
                            .fill(Color(nsColor: .windowBackgroundColor))
                            .frame(width: 12, height: 6)
                            .overlay(
                                Triangle()
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                            )
                            .offset(y: -0.5)
                        
                        AlgorithmInfoCard(
                            algorithm: algorithm,
                            speed: speed,
                            decompressionSpeed: decompressionSpeed,
                            ratio: ratio,
                            scenario: scenario,
                            recommended: recommended
                        )
                    }
                    .fixedSize()
                    .offset(y: -8) // 向上偏移
                    .zIndex(1000)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95)).combined(with: .offset(y: 5)),
                            removal: .opacity.combined(with: .scale(scale: 0.98))
                        )
                    )
                }
            }
    }
}

// 小三角形状
struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

extension View {
    func algorithmTip(
        name: String,
        speed: String,
        decompressionSpeed: String,
        ratio: String,
        scenario: String,
        recommended: Bool = false
    ) -> some View {
        self.modifier(AlgorithmTipModifier(
            algorithm: name,
            speed: speed,
            decompressionSpeed: decompressionSpeed,
            ratio: ratio,
            scenario: scenario,
            recommended: recommended
        ))
    }
}
