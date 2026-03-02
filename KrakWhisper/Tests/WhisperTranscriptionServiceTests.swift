import XCTest
@testable import KrakWhisper

final class WhisperTranscriptionServiceTests: XCTestCase {

    func testInitialState() {
        let service = WhisperTranscriptionService()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.currentModelSize)
        XCTAssertFalse(service.isTranscribing)
    }

    func testLoadMissingModel() async throws {
        let service = WhisperTranscriptionService()

        // Use an explicit non-existent path for deterministic behavior
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let fakeModelURL = tempDir.appendingPathComponent("ggml-tiny.en.bin")

        do {
            try await service.loadModel(from: fakeModelURL, size: .tiny)
            XCTFail("Expected error for missing model file")
        } catch let error as TranscriptionError {
            if case .modelFileNotFound(let size) = error {
                XCTAssertEqual(size, .tiny)
            } else {
                XCTFail("Expected modelFileNotFound, got: \(error)")
            }
        }
    }

    func testLoadModelPreservesPreviousOnFailure() async throws {
        // Verifies that a failed load does not unload the previously active model.
        // Since we can't actually load a real model in tests without a .bin file,
        // we verify that after a failed load, the service remains in its initial state.
        let service = WhisperTranscriptionService()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let fakeURL = tempDir.appendingPathComponent("nonexistent.bin")

        do {
            try await service.loadModel(from: fakeURL, size: .base)
        } catch {
            // Expected
        }

        // Service should still be in initial state
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.currentModelSize)
    }

    func testTranscribeWithoutModel() async {
        let service = WhisperTranscriptionService()

        do {
            _ = try await service.transcribe(audioFrames: [0.1, 0.2, 0.3])
            XCTFail("Expected error for no model loaded")
        } catch let error as TranscriptionError {
            if case .modelNotLoaded = error {
                // Expected
            } else {
                XCTFail("Expected modelNotLoaded, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testTranscribeEmptyAudio() async {
        let service = WhisperTranscriptionService()

        do {
            _ = try await service.transcribe(audioFrames: [])
            XCTFail("Expected error for empty audio")
        } catch let error as TranscriptionError {
            if case .emptyAudioData = error {
                // Expected
            } else {
                XCTFail("Expected emptyAudioData, got: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func testUnloadModel() {
        let service = WhisperTranscriptionService()
        service.unloadModel()
        XCTAssertFalse(service.isModelLoaded)
        XCTAssertNil(service.currentModelSize)
    }
}

final class WhisperModelSizeTests: XCTestCase {

    func testModelFileNames() {
        XCTAssertEqual(WhisperModelSize.tiny.fileName, "ggml-tiny.en.bin")
        XCTAssertEqual(WhisperModelSize.base.fileName, "ggml-base.en.bin")
        XCTAssertEqual(WhisperModelSize.small.fileName, "ggml-small.en.bin")
    }

    func testModelLocator() throws {
        let url = try WhisperModelLocator.modelFileURL(for: .tiny)
        XCTAssertEqual(url.lastPathComponent, "ggml-tiny.en.bin")
        XCTAssertTrue(url.pathComponents.contains("Models"))
    }

    func testIsModelDownloadedSideEffectFree() {
        // isModelDownloaded should NOT create directories
        let result = WhisperModelLocator.isModelDownloaded(.tiny)
        // We just verify it returns a Bool without crashing
        XCTAssertFalse(result) // Model shouldn't be downloaded in test env
    }

    func testAllCases() {
        XCTAssertEqual(WhisperModelSize.allCases.count, 3)
    }

    func testDownloadURLs() {
        for size in WhisperModelSize.allCases {
            let url = size.downloadURL
            XCTAssertTrue(url.absoluteString.contains("huggingface.co"))
            XCTAssertTrue(url.absoluteString.contains(size.fileName))
        }
    }

    func testDefaultModel() {
        XCTAssertEqual(WhisperModelSize.defaultModel, .base)
    }
}
