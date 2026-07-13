import Foundation

enum ZipArchiveError: LocalizedError {
    case tooManyFiles
    case fileTooLarge(String)
    case invalidFileName

    var errorDescription: String? {
        switch self {
        case .tooManyFiles: "The corpus package contains too many files."
        case .fileTooLarge(let name): "\(name) is too large for the debug corpus package."
        case .invalidFileName: "A corpus file has an invalid name."
        }
    }
}

/// A minimal ZIP writer using the uncompressed STORE method.
///
/// Corpus source HEIFs are already compressed, so re-compressing them adds
/// memory and thermal cost without useful size reduction. Streaming each file
/// keeps the recorder from holding an entire multi-frame package in memory.
struct ZipArchiveWriter {
    private struct Entry {
        let name: Data
        let crc32: UInt32
        let size: UInt32
        let localHeaderOffset: UInt32
    }

    func write(files: [URL], to outputURL: URL) throws {
        guard files.count <= Int(UInt16.max) else { throw ZipArchiveError.tooManyFiles }

        let manager = FileManager.default
        try? manager.removeItem(at: outputURL)
        manager.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        var entries: [Entry] = []
        for file in files {
            let nameString = file.lastPathComponent
            guard let name = nameString.data(using: .utf8), !name.isEmpty,
                  name.count <= Int(UInt16.max) else {
                throw ZipArchiveError.invalidFileName
            }

            let values = try file.resourceValues(forKeys: [.fileSizeKey])
            let fileSize = values.fileSize ?? 0
            guard fileSize >= 0, fileSize <= Int(UInt32.max) else {
                throw ZipArchiveError.fileTooLarge(nameString)
            }
            let crc = try CRC32.checksum(fileURL: file)
            let offset = output.offsetInFile
            guard offset <= UInt64(UInt32.max) else { throw ZipArchiveError.fileTooLarge(nameString) }

            try output.write(contentsOf: localHeader(
                name: name,
                crc32: crc,
                size: UInt32(fileSize)
            ))
            try output.write(contentsOf: name)
            try stream(file: file, to: output)

            entries.append(
                Entry(
                    name: name,
                    crc32: crc,
                    size: UInt32(fileSize),
                    localHeaderOffset: UInt32(offset)
                )
            )
        }

        let centralDirectoryOffset = output.offsetInFile
        guard centralDirectoryOffset <= UInt64(UInt32.max) else {
            throw ZipArchiveError.fileTooLarge(outputURL.lastPathComponent)
        }

        for entry in entries {
            try output.write(contentsOf: centralDirectoryHeader(entry: entry))
            try output.write(contentsOf: entry.name)
        }

        let centralDirectorySize = output.offsetInFile - centralDirectoryOffset
        guard centralDirectorySize <= UInt64(UInt32.max) else {
            throw ZipArchiveError.fileTooLarge(outputURL.lastPathComponent)
        }
        try output.write(contentsOf: endOfCentralDirectory(
            entryCount: UInt16(entries.count),
            centralDirectorySize: UInt32(centralDirectorySize),
            centralDirectoryOffset: UInt32(centralDirectoryOffset)
        ))
        try output.synchronize()
    }

    private func stream(file: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            try output.write(contentsOf: chunk)
        }
    }

    private func localHeader(name: Data, crc32: UInt32, size: UInt32) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x04034B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(crc32)
        data.appendLittleEndian(size)
        data.appendLittleEndian(size)
        data.appendLittleEndian(UInt16(name.count))
        data.appendLittleEndian(UInt16(0))
        return data
    }

    private func centralDirectoryHeader(entry: Entry) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x02014B50))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(20))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entry.crc32)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(entry.size)
        data.appendLittleEndian(UInt16(entry.name.count))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(entry.localHeaderOffset)
        return data
    }

    private func endOfCentralDirectory(
        entryCount: UInt16,
        centralDirectorySize: UInt32,
        centralDirectoryOffset: UInt32
    ) -> Data {
        var data = Data()
        data.appendLittleEndian(UInt32(0x06054B50))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(UInt16(0))
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(entryCount)
        data.appendLittleEndian(centralDirectorySize)
        data.appendLittleEndian(centralDirectoryOffset)
        data.appendLittleEndian(UInt16(0))
        return data
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1
        }
        return crc
    }

    static func checksum(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = (crc >> 8) ^ table[index]
        }
        return crc ^ 0xFFFFFFFF
    }

    static func checksum(fileURL: URL) throws -> UInt32 {
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        var crc: UInt32 = 0xFFFFFFFF
        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
            for byte in chunk {
                let index = Int((crc ^ UInt32(byte)) & 0xFF)
                crc = (crc >> 8) ^ table[index]
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ input: T) {
        var value = input.littleEndian
        Swift.withUnsafeBytes(of: &value) { bytes in
            append(contentsOf: bytes)
        }
    }
}
