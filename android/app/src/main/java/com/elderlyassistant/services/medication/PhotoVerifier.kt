package com.elderlyassistant.services.medication

import java.util.UUID

// MARK: - Photo Verifier (FR-D04a through FR-D04e)

sealed class PhotoCaptureResult {
    data class Captured(val imageData: ByteArray) : PhotoCaptureResult()
    data class CameraUnavailable(val reason: String) : PhotoCaptureResult()
    data class CaptureFailed(val reason: String) : PhotoCaptureResult()
}

sealed class PhotoDeliveryResult {
    data class Delivered(val deliveredAt: Long) : PhotoDeliveryResult()
    data class DeliveryFailed(val reason: String) : PhotoDeliveryResult()
}

interface PhotoCaptureSession {
    suspend fun captureStillImage(): PhotoCaptureResult
}

interface PhotoDeliveryChannel {
    suspend fun deliver(photo: VerificationPhoto, targetDeviceId: String): PhotoDeliveryResult
}

class PhotoVerifier(
    private val captureSession: PhotoCaptureSession,
    private val deliveryChannel: PhotoDeliveryChannel
) {
    companion object {
        private const val MAX_IMAGE_SIZE_BYTES = 200 * 1024  // 200 KB per FR-D04b
    }

    suspend fun verify(
        adherenceLogId: UUID,
        targetDeviceId: String
    ): PhotoVerificationStatus {
        return when (val captureResult = captureSession.captureStillImage()) {
            is PhotoCaptureResult.CameraUnavailable -> {
                println("[PhotoVerifier] Camera unavailable: ${captureResult.reason}")
                PhotoVerificationStatus.UNAVAILABLE
            }
            is PhotoCaptureResult.CaptureFailed -> {
                println("[PhotoVerifier] Capture failed: ${captureResult.reason}")
                PhotoVerificationStatus.UNAVAILABLE
            }
            is PhotoCaptureResult.Captured ->
                processAndDeliver(captureResult.imageData, adherenceLogId, targetDeviceId)
        }
    }

    private suspend fun processAndDeliver(
        imageData: ByteArray,
        adherenceLogId: UUID,
        targetDeviceId: String
    ): PhotoVerificationStatus {
        val compressed = compressIfNeeded(imageData)

        val photo = VerificationPhoto(
            id = UUID.randomUUID(),
            adherenceLogId = adherenceLogId,
            capturedAt = System.currentTimeMillis(),
            deliveredAt = null,
            deletedFromDeviceAt = null,
            imageData = compressed
        )

        return when (val result = deliveryChannel.deliver(photo, targetDeviceId)) {
            is PhotoDeliveryResult.Delivered -> PhotoVerificationStatus.DELIVERED
            is PhotoDeliveryResult.DeliveryFailed -> PhotoVerificationStatus.CAPTURED
        }
    }

    private fun compressIfNeeded(imageData: ByteArray): ByteArray {
        if (imageData.size <= MAX_IMAGE_SIZE_BYTES) return imageData

        var quality = 90
        var compressed = imageData

        while (compressed.size > MAX_IMAGE_SIZE_BYTES && quality > 10) {
            quality -= 10
            // In production: use Bitmap.compress(Bitmap.CompressFormat.JPEG, quality, ...)
            compressed = compressed.take((imageData.size * quality) / 100).toByteArray()
        }

        return compressed.take(MAX_IMAGE_SIZE_BYTES).toByteArray()
    }
}
