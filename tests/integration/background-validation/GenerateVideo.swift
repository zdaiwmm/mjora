import Foundation

@main
struct GenerateValidationVideo {
    static func main() async throws {
        guard CommandLine.arguments.count == 4, let size = Int64(CommandLine.arguments[2]) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }
        try await SyntheticValidationVideo.make(url, size: size, marker: CommandLine.arguments[3])
        try await SyntheticValidationVideo.verifyDecodes(url)
        print("Synthetic MP4 generated and first frame decoded")
    }
}
