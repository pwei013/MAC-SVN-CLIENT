import Foundation
import SVNCore

struct SVNClientIntegrationTests {
    func testBrowseCheckoutSelectiveCommitDirectoryCommitAndUpdate() async throws {
        let fixture = try LocalSVNFixture()
        defer { fixture.remove() }
        try fixture.prepareRepository()

        let client = SVNClient(executablePath: fixture.svn.path)
        let rootEntries = try await client.list(url: fixture.repository.absoluteString)
        try expect(Set(rootEntries.map(\.name)) == ["branches", "trunk"])
        try expect(rootEntries.allSatisfy { $0.kind == "dir" })

        let trunk = fixture.repository.appendingPathComponent("trunk")
        let unusualDirectory = "中文 空格@目录"
        let unusualFile = "\(unusualDirectory)/文件 @v1.txt"
        let nestedEntries = try await client.list(
            url: trunk.appendingPathComponent(unusualDirectory).absoluteString
        )
        try expect(nestedEntries.map(\.name) == ["文件 @v1.txt"])

        let workingCopy = fixture.root.appendingPathComponent("检出 空格@work")
        _ = try await client.checkout(url: trunk.absoluteString, destination: workingCopy)
        let info = try await client.info(at: workingCopy)
        try expect(URL(string: info.url)?.standardized == trunk.standardized)
        try expect(URL(fileURLWithPath: info.rootPath).resolvingSymlinksInPath().path == workingCopy.resolvingSymlinksInPath().path)
        try expect(!(info.revision.isEmpty))
        let initialChanges = try await client.status(at: workingCopy)
        try expect(initialChanges.isEmpty)

        try fixture.write("changed unicode content\n", to: workingCopy.appendingPathComponent(unusualFile))
        try fixture.write("selected change\n", to: workingCopy.appendingPathComponent("parent/selected.txt"))
        try fixture.write("leave this local\n", to: workingCopy.appendingPathComponent("parent/unselected.txt"))
        let newFile = "待添加 @空格.txt"
        try fixture.write("new content\n", to: workingCopy.appendingPathComponent(newFile))

        let changes = try await client.status(at: workingCopy)
        try expect(changes.first(where: { $0.path == unusualFile })?.item == "modified")
        try expect(changes.first(where: { $0.path == newFile })?.item == "unversioned")
        try expect(changes.first(where: { $0.path == unusualFile })?.canCommit == true)
        let diff = try await client.diff(at: workingCopy, paths: [unusualFile])
        try expect(diff.contains("+changed unicode content"))

        _ = try await client.add(at: workingCopy, paths: [newFile])
        let afterAdd = try await client.status(at: workingCopy)
        try expect(afterAdd.first(where: { $0.path == newFile })?.item == "added")
        _ = try await client.commit(
            at: workingCopy,
            paths: [unusualFile, newFile, "parent/selected.txt"],
            message: "提交已勾选的文件"
        )
        let afterCommit = try await client.status(at: workingCopy)
        try expect(afterCommit.map(\.path) == ["parent/unselected.txt"])
        try expect(try fixture.cat(trunk.appendingPathComponent(unusualFile)) == "changed unicode content\n")
        try expect(try fixture.cat(trunk.appendingPathComponent(newFile)) == "new content\n")
        try expect(try fixture.cat(trunk.appendingPathComponent("parent/unselected.txt")) == "original unselected\n")

        _ = try await client.update(at: workingCopy)
        let afterDirectoryRevisionUpdate = try await client.status(at: workingCopy)
        try expect(afterDirectoryRevisionUpdate.map(\.path) == ["parent/unselected.txt"])
        try expect(try String(contentsOf: workingCopy.appendingPathComponent("parent/unselected.txt"), encoding: .utf8) == "leave this local\n")
        try fixture.runSVN(["propset", "reviewed", "yes", "--", "parent@"], at: workingCopy)
        try fixture.write("another local change\n", to: workingCopy.appendingPathComponent("parent/selected.txt"))
        let withPropertyChange = try await client.status(at: workingCopy)
        try expect(withPropertyChange.first(where: { $0.path == "parent" })?.properties == "modified")
        _ = try await client.commit(at: workingCopy, paths: ["parent"], message: "仅提交目录属性")
        let afterDirectoryCommit = try await client.status(at: workingCopy)
        try expect(Set(afterDirectoryCommit.map(\.path)) == ["parent/selected.txt", "parent/unselected.txt"])
        try expect(try fixture.cat(trunk.appendingPathComponent("parent/selected.txt")) == "selected change\n")

        let remoteWriter = fixture.root.appendingPathComponent("remote-writer")
        try fixture.runSVN(["checkout", "--", trunk.absoluteString + "@", remoteWriter.path])
        try fixture.write("remote update\n", to: remoteWriter.appendingPathComponent("README.md"))
        try fixture.runSVN(["commit", "-m", "remote update", "--", "README.md@"], at: remoteWriter)
        _ = try await client.update(at: workingCopy)
        try expect(try String(contentsOf: workingCopy.appendingPathComponent("README.md"), encoding: .utf8) == "remote update\n")
        try expect(try String(contentsOf: workingCopy.appendingPathComponent("parent/unselected.txt"), encoding: .utf8) == "leave this local\n")
    }

    func testCommitFailureIsNotAutomaticallyReplayed() async throws {
        let root = try LocalSVNFixture.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("calls.txt")
        let executable = root.appendingPathComponent("failing svn")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$1" >> \(shellQuote(marker.path))
        if [ "$1" = status ]; then
            printf '%s\\n' '<status><target path="."><entry path="file.txt"><wc-status item="modified" props="none"/></entry></target></status>'
            exit 0
        fi
        for argument in "$@"; do
            if [ "$argument" = temporary-fixture-password ]; then
                printf '%s\\n' password-in-arguments >> \(shellQuote(marker.path))
            fi
        done
        IFS= read -r entered_password
        if [ "$entered_password" = temporary-fixture-password ]; then
            printf '%s\\n' password-from-stdin >> \(shellQuote(marker.path))
        fi
        printf '%s\\n' "svn: E170013: simulated connection failure $entered_password" >&2
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let password = "temporary-fixture-password"
        let client = SVNClient(
            executablePath: executable.path,
            credentials: SVNCredentials(username: "fixture-user", password: password)
        )

        do {
            _ = try await client.commit(at: root, paths: ["file.txt"], message: "one attempt")
            throw CheckFailure.failed("A failed svn commit must report an error")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(!(error.localizedDescription.isEmpty))
            try expect(!(error.localizedDescription.contains(password)))
            try expect(error.localizedDescription.contains("[已隐藏]"))
        }
        let calls = try String(contentsOf: marker, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        try expect(calls == ["status", "commit", "password-from-stdin"], "A write failure must not trigger an automatic retry, and passwords must use stdin")
    }

    func testAddedDirectoryCommitsOnlySelectedChildren() async throws {
        let fixture = try LocalSVNFixture()
        defer { fixture.remove() }
        try fixture.prepareRepository()
        let client = SVNClient(executablePath: fixture.svn.path)
        let trunk = fixture.repository.appendingPathComponent("trunk")
        let workingCopy = fixture.root.appendingPathComponent("new-directory-work")
        _ = try await client.checkout(url: trunk.absoluteString, destination: workingCopy)

        let directory = "新建 中文 空格@名称"
        let selectedFile = directory + "/selected.txt"
        let unselectedFile = directory + "/unselected.txt"
        try fixture.write("selected new file\n", to: workingCopy.appendingPathComponent(selectedFile))
        try fixture.write("unselected new file\n", to: workingCopy.appendingPathComponent(unselectedFile))
        _ = try await client.add(at: workingCopy, paths: [directory])
        let afterAdd = try await client.status(at: workingCopy)
        try expect(Set(afterAdd.map(\.path)) == [directory, selectedFile, unselectedFile])
        try expect(afterAdd.allSatisfy { $0.item == "added" && $0.canCommit })
        let addedFileDiff = try await client.diff(at: workingCopy, paths: [selectedFile])
        try expect(addedFileDiff.contains("+selected new file"))
        try expect(!addedFileDiff.contains("+unselected new file"))

        _ = try await client.commit(at: workingCopy, paths: [directory, selectedFile], message: "新增目录和已勾选文件")

        let entries = try await client.list(url: trunk.appendingPathComponent(directory).absoluteString)
        try expect(entries.map(\.name) == ["selected.txt"])
        try expect(try fixture.cat(trunk.appendingPathComponent(selectedFile)) == "selected new file\n")
        let remaining = try await client.status(at: workingCopy)
        try expect(remaining.map(\.path) == [unselectedFile])
        try expect(remaining.first?.item == "added")
        try expect(try String(contentsOf: workingCopy.appendingPathComponent(unselectedFile), encoding: .utf8) == "unselected new file\n")
    }

    func testMissingFileCanBeScheduledAndCommittedAsDeletion() async throws {
        let fixture = try LocalSVNFixture()
        defer { fixture.remove() }
        try fixture.prepareRepository()
        let client = SVNClient(executablePath: fixture.svn.path)
        let trunk = fixture.repository.appendingPathComponent("trunk")
        let workingCopy = fixture.root.appendingPathComponent("missing-file-work")
        _ = try await client.checkout(url: trunk.absoluteString, destination: workingCopy)
        try FileManager.default.removeItem(at: workingCopy.appendingPathComponent("README.md"))

        let missing = try await client.status(at: workingCopy)
        try expect(missing.first(where: { $0.path == "README.md" })?.item == "missing")
        try expect(missing.first(where: { $0.path == "README.md" })?.canCommit == false)
        _ = try await client.scheduleMissing(at: workingCopy, paths: ["README.md"])
        let scheduled = try await client.status(at: workingCopy)
        try expect(scheduled.first(where: { $0.path == "README.md" })?.item == "deleted")
        try expect(scheduled.first(where: { $0.path == "README.md" })?.canCommit == true)

        _ = try await client.commit(at: workingCopy, paths: ["README.md"], message: "提交缺失文件的删除")

        let serverEntries = try await client.list(url: trunk.absoluteString)
        try expect(!(serverEntries.contains { $0.name == "README.md" }))
        let remaining = try await client.status(at: workingCopy)
        try expect(remaining.isEmpty)
        try expect(!(FileManager.default.fileExists(atPath: workingCopy.appendingPathComponent("README.md").path)))
    }

    func testCheckoutRejectsNonemptyDestinationWithoutChangingItsContents() async throws {
        let fixture = try LocalSVNFixture()
        defer { fixture.remove() }
        try fixture.prepareRepository()
        let client = SVNClient(executablePath: fixture.svn.path)
        let destination = fixture.root.appendingPathComponent("existing destination")
        let existingFile = destination.appendingPathComponent("keep.txt")
        try fixture.write("preserve existing content\n", to: existingFile)

        do {
            _ = try await client.checkout(
                url: fixture.repository.appendingPathComponent("trunk").absoluteString,
                destination: destination
            )
            throw CheckFailure.failed("Checkout must reject a nonempty destination")
        } catch let error as CheckFailure {
            throw error
        } catch {
            try expect(!(error.localizedDescription.isEmpty))
        }

        try expect(try FileManager.default.contentsOfDirectory(atPath: destination.path) == ["keep.txt"])
        try expect(try String(contentsOf: existingFile, encoding: .utf8) == "preserve existing content\n")
    }
}

private struct LocalSVNFixture {
    let root: URL
    let repository: URL
    let svn: URL
    let svnadmin: URL

    init() throws {
        let tools = try Self.findTools()
        root = try Self.makeTemporaryDirectory()
        repository = root.appendingPathComponent("repository")
        svn = tools.svn
        svnadmin = tools.svnadmin
    }

    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SVNManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func prepareRepository() throws {
        _ = try run(svnadmin, ["create", repository.path])
        let seed = root.appendingPathComponent("seed")
        try write("original readme\n", to: seed.appendingPathComponent("README.md"))
        try write("original unicode content\n", to: seed.appendingPathComponent("中文 空格@目录/文件 @v1.txt"))
        try write("original selected\n", to: seed.appendingPathComponent("parent/selected.txt"))
        try write("original unselected\n", to: seed.appendingPathComponent("parent/unselected.txt"))
        try runSVN(["import", "-m", "initial files", "--", seed.path, repository.appendingPathComponent("trunk").absoluteString])
        try runSVN(["mkdir", "-m", "branches", "--", repository.appendingPathComponent("branches").absoluteString + "@"])
    }

    func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    func runSVN(_ arguments: [String], at directory: URL? = nil) throws -> String {
        try run(svn, ["--non-interactive"] + arguments, at: directory)
    }

    func cat(_ url: URL) throws -> String {
        try runSVN(["cat", "--", url.absoluteString + "@"])
    }

    private func run(_ executable: URL, _ arguments: [String], at directory: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw FixtureError.commandFailed(
                executable.lastPathComponent,
                process.terminationStatus,
                String(decoding: errorData, as: UTF8.self)
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }

    private static func findTools() throws -> (svn: URL, svnadmin: URL) {
        let directories = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/svn-cli/bin").path,
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"
        ]
        for directory in directories {
            let svn = URL(fileURLWithPath: directory).appendingPathComponent("svn")
            let svnadmin = URL(fileURLWithPath: directory).appendingPathComponent("svnadmin")
            if FileManager.default.isExecutableFile(atPath: svn.path),
               FileManager.default.isExecutableFile(atPath: svnadmin.path) {
                return (svn, svnadmin)
            }
        }
        throw FixtureError.missingTools("Integration tests require svn and svnadmin in the same supported binary directory")
    }
}

private enum FixtureError: LocalizedError {
    case missingTools(String)
    case commandFailed(String, Int32, String)

    var errorDescription: String? {
        switch self {
        case let .missingTools(message):
            return message
        case let .commandFailed(command, status, error):
            return "Local fixture \(command) exited \(status): \(error)"
        }
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
