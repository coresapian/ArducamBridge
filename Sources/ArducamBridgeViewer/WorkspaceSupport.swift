import Foundation

struct WorkspacePaths {
    let repositoryRoot: URL

    var detectorConfig: URL {
        repositoryRoot.appendingPathComponent("configs/vending.generated.yaml")
    }

    var datasetRoot: URL {
        repositoryRoot.appendingPathComponent("datasets/vending", isDirectory: true)
    }

    var trainingProjectRoot: URL {
        repositoryRoot.appendingPathComponent("runs/vending-training", isDirectory: true)
    }

    var detectorScript: URL {
        repositoryRoot.appendingPathComponent("scripts/run-vending-detector.sh")
    }

    var trainingScript: URL {
        repositoryRoot.appendingPathComponent("scripts/train-vending-model.sh")
    }
}

enum WorkspaceLocatorError: LocalizedError {
    case repositoryRootNotFound

    var errorDescription: String? {
        switch self {
        case .repositoryRootNotFound:
            return "Unable to locate the ArducamBridge workspace. Launch the app from inside the repository or keep the .app under dist/."
        }
    }
}

enum WorkspaceLocator {
    static func resolve() throws -> WorkspacePaths {
        for candidate in candidateRoots() {
            if let root = searchUpward(from: candidate) {
                return WorkspacePaths(repositoryRoot: root)
            }
        }
        throw WorkspaceLocatorError.repositoryRootNotFound
    }

    private static func candidateRoots() -> [URL] {
        var urls: [URL] = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        ]

        if let executableURL = Bundle.main.executableURL {
            urls.append(executableURL)
            urls.append(executableURL.deletingLastPathComponent())
        }

        return urls.map { $0.standardizedFileURL }
    }

    private static func searchUpward(from start: URL) -> URL? {
        var current = start
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
            current = current.deletingLastPathComponent()
        } else if !isDirectory.boolValue {
            current = current.deletingLastPathComponent()
        }

        while true {
            let packageURL = current.appendingPathComponent("Package.swift")
            let sourcesURL = current.appendingPathComponent("Sources/ArducamBridgeViewer", isDirectory: true)
            if FileManager.default.fileExists(atPath: packageURL.path), FileManager.default.fileExists(atPath: sourcesURL.path) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                return nil
            }
            current = parent
        }
    }
}

enum ProcessEnvironment {
    static func defaultShellEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPATH = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let currentPATH = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let mergedPATH = requiredPATH + currentPATH.filter { !requiredPATH.contains($0) }
        environment["PATH"] = mergedPATH.joined(separator: ":")
        return environment
    }
}

extension FileManager {
    func createDirectoryIfNeeded(at url: URL) throws {
        try createDirectory(at: url, withIntermediateDirectories: true)
    }
}
