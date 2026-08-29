import Foundation

// MARK: - Photo Verifier (FR-D04a through FR-D04e)

enum PhotoCaptureResult {
    case captured(imageData: Data)
    case cameraUnavailable(reason: String)
    case captureFailed(reason: String)
}

enum PhotoDeliveryResult {
    case delivered(deliveredAt: Date)
    case deliveryFailed(reason: String)
}

protocol PhotoCaptureSession {
    func captureStillImage() async -> PhotoCaptureResult
}

protocol PhotoDeliveryChannel {
    func deliver(photo: VerificationPhoto, to targetDeviceId: String) async -> PhotoDeliveryResult
}

final class PhotoVerifier {
    private let captureSession: PhotoCaptureSession
    private let deliveryChannel: PhotoDeliveryChannel
    private let maxImageSizeBytes: Int = 200 * 1024   // 200 KB per FR-D04b

    init(captureSession: PhotoCaptureSession, deliveryChannel: PhotoDeliveryChannel) {
        self.captureSession = captureSession
        self.deliveryChannel = deliveryChannel
    }

    /// Capture a verification photo and deliver it to the companion app.
    /// Returns nil if camera is unavailable (graceful degradation per FR-D04d).
    func verify(
        adherenceLogId: UUID,
        targetDeviceId: String
    ) async -> PhotoVerificationStatus {
        let captureResult = await captureSession.captureStillImage()

        switch captureResult {
        case .cameraUnavailable(let reason):
            print("[PhotoVerifier] Camera unavailable: \(reason)")
            return .unavailable

        case .captureFailed(let reason):
            print("[PhotoVerifier] Capture failed: \(reason)")
            return .unavailable

        case .captured(let imageData):
            return await processAndDeliver(
                imageData: imageData,
                adherenceLogId: adherenceLogId,
                targetDeviceId: targetDeviceId
            )
        }
    }

    // MARK: - Private

    private func processAndDeliver(
        imageData: Data,
        adherenceLogId: UUID,
        targetDeviceId: String
    ) async -> PhotoVerificationStatus {
        // Compress to max 200 KB if needed
        let compressed = compressIfNeeded(imageData)

        let photo = VerificationPhoto(
            id: UUID(),
            adherenceLogId: adherenceLogId,
            capturedAt: Date(),
            deliveredAt: nil,
            deletedFromDeviceAt: nil,
            imageData: compressed
        )

        let deliveryResult = await deliveryChannel.deliver(photo: photo, to: targetDeviceId)

        switch deliveryResult {
        case .delivered:
            // Photo will be deleted from primary device within 1 hour (FR-D04b)
            // The deletion is handled by a separate cleanup task
            return .delivered

        case .deliveryFailed:
            // Retain photo on device for retry
            return .captured
        }
    }

    private func compressIfNeeded(_ imageData: Data) -> Data {
        if imageData.count <= maxImageSizeBytes {
            return imageData
        }

        // Simple compression: reduce quality iteratively
        // In production: use platform image APIs (UIImage JPEG compression on iOS,
        // Bitmap compress on Android)
        var quality: CGFloat = 0.9
        var compressed = imageData

        while compressed.count > maxImageSizeBytes && quality > 0.1 {
            quality -= 0.1
            // Placeholder: in production, call UIImage(data:)?.jpegData(compressionQuality: quality)
            compressed = Data(imageData.prefix(Int(Double(imageData.count) * quality)))
        }

        return Data(compressed.prefix(maxImageSizeBytes))
    }
}
