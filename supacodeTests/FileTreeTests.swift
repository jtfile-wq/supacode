import Testing

@testable import supacode

struct FileTreeTests {
  @Test func nestsPathsIntoDirectories() {
    let nodes = FileTree.build(from: ["a/b/c.swift", "a/d.swift"])

    #expect(nodes.count == 1)
    #expect(nodes[0].name == "a")
    #expect(nodes[0].isDirectory)
    #expect(nodes[0].children.map(\.name) == ["b", "d.swift"])
    #expect(nodes[0].children[0].children.map(\.name) == ["c.swift"])
  }

  @Test func sortsDirectoriesBeforeFilesThenCaseInsensitively() {
    let nodes = FileTree.build(from: ["zebra.swift", "Apple.swift", "src/main.swift", "Beta/x.swift"])

    #expect(nodes.map(\.name) == ["Beta", "src", "Apple.swift", "zebra.swift"])
  }

  @Test func relativePathIsRootRelativeAndSlashJoined() {
    let nodes = FileTree.build(from: ["a/b/c.swift"])

    #expect(nodes[0].relativePath == "a")
    #expect(nodes[0].children[0].relativePath == "a/b")
    #expect(nodes[0].children[0].children[0].relativePath == "a/b/c.swift")
  }

  @Test func statusLandsOnTheLeafNotTheDirectory() {
    let nodes = FileTree.build(
      from: ["a/b.swift"],
      statuses: ["a/b.swift": .modified]
    )

    #expect(nodes[0].status == .unchanged)
    #expect(nodes[0].children[0].status == .modified)
  }

  @Test func mergesPathsSharingAPrefix() {
    let nodes = FileTree.build(from: ["src/a.swift", "src/b.swift", "src/deep/c.swift"])

    #expect(nodes.count == 1)
    #expect(nodes[0].children.map(\.name) == ["deep", "a.swift", "b.swift"])
  }

  @Test func handlesEmptyInputAndStrayEmptyPaths() {
    #expect(FileTree.build(from: []).isEmpty)
    #expect(FileTree.build(from: [""]).isEmpty)
    #expect(FileTree.build(from: ["/"]).isEmpty)
  }
}
