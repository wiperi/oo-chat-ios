import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum AgentShareURL {
    static func url(for address: String) -> URL? {
        guard HostedAgentClient.isHostedAgentAddress(address) else {
            return nil
        }
        return URL(string: "https://chat.openonion.ai/\(address)")
    }
}

struct AgentQRCodeShareView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    private let context = CIContext()

    var body: some View {
        NavigationStack {
            Group {
                if let image = qrImage {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(24)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Agent QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(url.absoluteString.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let image = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: image)
    }
}
