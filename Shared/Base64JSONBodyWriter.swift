import Foundation

enum Base64JSONBodyWriter {
    static func write(
        fileURL: URL,
        mimeType: String,
        metadata: EagleUploadMetadata
    ) throws -> URL {
        try Task.checkCancellation()

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("eagle-upload-\(UUID().uuidString)")
            .appendingPathExtension("json")

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw EagleClientError.cannotCreateUploadBody
        }

        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }

            var prefix = try JSONSerialization.data(
                withJSONObject: metadata.jsonObject(),
                options: []
            )
            guard prefix.last == Character("}").asciiValue else {
                throw EagleClientError.cannotCreateUploadBody
            }
            prefix.removeLast()
            prefix.append(contentsOf: Data(#","base64":"data:"#.utf8))
            prefix.append(contentsOf: Data(mimeType.utf8))
            prefix.append(contentsOf: Data(";base64,".utf8))
            try output.write(contentsOf: prefix)

            let input = InputStream(url: fileURL)
            guard let input else {
                throw EagleClientError.cannotCreateUploadBody
            }
            input.open()
            defer { input.close() }

            // A multiple of three keeps every non-final Base64 block padding-free.
            let chunkSize = 3 * 16_384
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
            defer { buffer.deallocate() }

            while true {
                try Task.checkCancellation()
                let count = input.read(buffer, maxLength: chunkSize)
                if count < 0 {
                    throw input.streamError ?? EagleClientError.cannotCreateUploadBody
                }
                if count == 0 {
                    if let streamError = input.streamError {
                        throw streamError
                    }
                    break
                }
                let chunk = Data(bytes: buffer, count: count)
                try output.write(contentsOf: Data(chunk.base64EncodedString().utf8))
            }

            try Task.checkCancellation()
            try output.write(contentsOf: Data(#""}"#.utf8))
            return destination
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
