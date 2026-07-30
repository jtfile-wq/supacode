import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeFileTreeManagerTests {
  private func makeTempTree() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("filetree-\(UUID().uuidString)")
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try "one".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    try "two".write(to: root.appendingPathComponent("nested/b.txt"), atomically: true, encoding: .utf8)
    try "hidden".write(to: root.appendingPathComponent(".secret"), atomically: true, encoding: .utf8)
    return root
  }

  @Test func folderSourceReadsOnlyTheRootUntilExpanded() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()

    await state.loadFolder(at: root)

    #expect(state.nodes.map(\.name) == ["nested", "a.txt"])
    // The directory is present but its children have not been read yet.
    #expect(state.nodes[0].children.isEmpty)
  }

  @Test func expandingADirectoryReadsItsChildren() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()
    await state.loadFolder(at: root)

    await state.expandFolder(state.nodes[0], root: root)

    #expect(state.expanded.contains("nested"))
    #expect(state.nodes[0].children.map(\.name) == ["b.txt"])
  }

  @Test func folderSourceHidesDotfiles() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()

    await state.loadFolder(at: root)

    #expect(!state.nodes.contains { $0.name == ".secret" })
  }

  @Test func unreadableDirectoryStaysCollapsedAndRetriesOnTheNextClick() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()
    await state.loadFolder(at: root)
    let missing = FileTreeNode(
      relativePath: "gone", name: "gone", isDirectory: true, status: .unchanged, children: []
    )

    await state.expandFolder(missing, root: root)

    #expect(state.nodes.map(\.name) == ["nested", "a.txt"])
    #expect(!state.expanded.contains("gone"))
    #expect(state.didFailToRead(missing))

    // Second attempt must retry rather than take an "already loaded" fast path
    // that would mark the row expanded with no children.
    await state.expandFolder(missing, root: root)

    #expect(!state.expanded.contains("gone"))
    #expect(state.didFailToRead(missing))
  }

  @Test func refreshRestoresPreviouslyExpandedDirectories() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()
    await state.loadFolder(at: root)
    await state.expandFolder(state.nodes[0], root: root)

    // A refresh rebuilds from the root; the open directory must come back
    // populated, not open-and-empty.
    await state.loadFolder(at: root)

    #expect(state.expanded.contains("nested"))
    #expect(state.nodes[0].children.map(\.name) == ["b.txt"])
  }

  @Test func refreshPicksUpAFileAddedInsideAnExpandedDirectory() async throws {
    let root = try makeTempTree()
    defer { try? FileManager.default.removeItem(at: root) }
    let state = WorktreeFileTreeState()
    await state.loadFolder(at: root)
    await state.expandFolder(state.nodes[0], root: root)
    try "three".write(
      to: root.appendingPathComponent("nested/c.txt"), atomically: true, encoding: .utf8
    )

    await state.loadFolder(at: root)

    #expect(state.nodes[0].children.map(\.name) == ["b.txt", "c.txt"])
  }
}
