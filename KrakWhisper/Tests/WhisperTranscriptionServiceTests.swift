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

        do {
            try await service.loadModel(.tiny)
            XCTFail("Expected error for missing model file")
        } catch let error as TranscriptionError {
            if case .modelFileNotFound(let size) = error {
                XCTAssertEqual(size, .tiny)
            } else {
                XCTFail("Expected modelFileNotFound, got: \(error)")
            }
        }
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

    func testModelLocator() {
        let url = WhisperModelLocator.modelFileURL(for: .tiny)
        XCTAssertEqual(url.lastPathComponent, "ggml-tiny.en.bin")
        XCTAssertTrue(url.pathComponents.contains("Models"))
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
