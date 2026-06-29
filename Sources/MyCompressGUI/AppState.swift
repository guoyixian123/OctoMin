import Foundation
import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var statusMessage = ""
    @Published var errorMessage: String?
    @Published var showError = false
    
    private var progressCancellable: AnyCancellable?
    
    func startProcessing(message: String) {
        isProcessing = true
        progress = 0
        statusMessage = message
        errorMessage = nil
        showError = false
    }
    
    func updateProgress(_ fraction: Double, message: String? = nil) {
        progress = fraction
        if let message = message {
            statusMessage = message
        }
    }
    
    func finishProcessing(message: String = "完成") {
        isProcessing = false
        progress = 1.0
        statusMessage = message
    }
    
    func showError(_ message: String) {
        errorMessage = message
        showError = true
        isProcessing = false
    }
}
