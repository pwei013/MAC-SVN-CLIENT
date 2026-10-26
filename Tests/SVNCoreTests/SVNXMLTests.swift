import Foundation
import SVNCore

struct SVNXMLTests {
    func testListDecodesNamesAndOptionalCommitMetadata() throws {
        let entries = try SVNXML.parseList(Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <lists><list path="file:///fixture">
          <entry kind="file"><name>中文 &amp; 空格@文件.txt</name><size>42</size>
            <commit revision="17"><author>测试用户</author><date>2026-10-23T00:00:00Z</date></commit>
          </entry>
          <entry kind="dir"><name>目录</name><commit revision="3"/></entry>
        </list></lists>
        """.utf8))

        try expect(entries.count == 2)
        try expect(entries.first?.name == "目录")
        try expect(entries.first?.kind == "dir")
        try expect(entries.first?.author == "")
        let file = try require(entries.first(where: { $0.kind == "file" }))
        try expect(file.name == "中文 & 空格@文件.txt")
        try expect(file.revision == "17")
        try expect(file.author == "测试用户")
        try expect(file.size == 42)
    }

    func testInfoRequiresALocalWorkingCopyRoot() throws {
        let info = try SVNXML.parseInfo(Data("""
        <info><entry kind="dir" path="." revision="9">
          <url>file:///fixture/trunk</url>
          <wc-info><wcroot-abspath>/tmp/中文 空格@工作副本</wcroot-abspath></wc-info>
        </entry></info>
        """.utf8))
        try expect(info.url == "file:///fixture/trunk")
        try expect(info.rootPath == "/tmp/中文 空格@工作副本")
        try expect(info.revision == "9")
        try expectThrows(SVNError.self) { try SVNXML.parseInfo(Data("<info><entry><url>file:///fixture</url></entry></info>".utf8)) }
    }

    func testStatusKeepsPropertyChangesAndRejectsConflictsForCommit() throws {
        let changes = try SVNXML.parseStatus(Data("""
        <status><target path=".">
          <entry path="modified &amp; @file"><wc-status item="modified" props="none"/></entry>
          <entry path="properties"><wc-status item="normal" props="modified"/></entry>
          <entry path="untracked"><wc-status item="unversioned" props="none"/></entry>
          <entry path="missing"><wc-status item="missing" props="none"/></entry>
          <entry path="text-conflict"><wc-status item="conflicted" props="none"/></entry>
          <entry path="property-conflict"><wc-status item="modified" props="conflicted"/></entry>
          <entry path="tree-conflict"><wc-status item="normal" props="none" tree-conflicted="true"/></entry>
          <entry path="clean"><wc-status item="normal" props="none"/></entry>
        </target><changelist name="review">
          <entry path="changelist-file"><wc-status item="added" props="none"/></entry>
        </changelist></status>
        """.utf8))
        let byPath = Dictionary(uniqueKeysWithValues: changes.map { ($0.path, $0) })
        try expect(byPath["clean"] == nil)
        try expect(byPath["modified & @file"]?.canCommit == true)
        try expect(byPath["properties"]?.canCommit == true)
        try expect(byPath["changelist-file"]?.canCommit == true)
        for path in ["untracked", "missing", "text-conflict", "property-conflict", "tree-conflict"] {
            try expect(byPath[path]?.canCommit == false, "Path: \(path)")
        }
        try expect(byPath["tree-conflict"]?.treeConflicted == true)
    }

    func testMalformedOrUnexpectedXMLIsRejected() throws {
        try expectThrows(SVNError.self) { try SVNXML.parseList(Data("<lists><list>".utf8)) }
        try expectThrows(SVNError.self) { try SVNXML.parseList(Data("<html>error page</html>".utf8)) }
        try expectThrows(SVNError.self) { try SVNXML.parseStatus(Data("<info/>".utf8)) }
        try expectThrows(SVNError.self) { try SVNXML.parseInfo(Data()) }
    }

    func testRepositoryLocationRejectsEmbeddedCredentialsAndNonRepositoryParts() throws {
        for value in ["https://user:password@example.invalid/repo", "https://example.invalid/repo?token=value",
                      "https://example.invalid/repo#fragment", "ssh://example.invalid/repo", "relative/repo"] {
            try expectThrows(SVNError.self, "Location: \(value)") { try SVNLocation.validated(value) }
        }
        let directory = "中文 目录@name"
        let child = try SVNLocation.child(directory, of: "https://example.invalid/repository")
        try expect(URL(string: child)?.lastPathComponent == directory)
    }
}
