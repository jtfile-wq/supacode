import ComposableArchitecture
import Foundation
import Observation

/// Per-worktree file tree, cached so switching panes does not re-shell git.
///
/// Two sources, picked per worktree kind. A git worktree lists in one shot, so
/// expanding a directory is free. A folder row has no repo to ask, so it reads
/// one directory per expansion: pointing at a home directory must never
/// enumerate the whole thing.
@MainActor
@Observable
final class WorktreeFileTreeState {
  enum Source {
    case git
    case folder
  }

  private(set) var nodes: [FileTreeNode] = []
  private(set) var loadFailure: String?
  private(set) var isLoading = false
  private(set) var source: Source = .folder
  /// Keyed by `relativePath`, so expansion survives a refresh that rebuilds nodes.
  var expanded: Set<String> = []
  /// Folder rows only: directories already read, so re-expanding is free.
  private var loadedDirectories: Set<String> = []
  /// Directories whose last read failed. Kept apart from `loadedDirectories` so
  /// a retry actually retries instead of taking the already-loaded fast path.
  private var failedDirectories: Set<String> = []

  // Resolved by type rather than key path, matching `RepositoriesFeature`: the
  // module defaults to MainActor isolation, which makes `\.gitClient` a
  // non-Sendable key path.
  @ObservationIgnored @Dependency(GitClientDependency.self) private var gitClient

  func load(worktree: Worktree) async {
    // `localWorkingDirectory` is `URL?`, nil for remote worktrees. Remote needs
    // remote command building on both the listing and the pager, which is out
    // of scope, so both conditions collapse into one guard.
    guard worktree.host == nil, let root = worktree.localWorkingDirectory else {
      nodes = []
      loadFailure = "Remote worktrees aren't supported yet."
      return
    }
    isLoading = true
    defer { isLoading = false }

    if worktree.kind == .git, await loadGit(root: root) { return }
    await loadFolder(at: root)
  }

  /// Returns false when the *listing* failed, so the caller falls back to the
  /// folder source. A broken git environment (an unaccepted Xcode license is
  /// the one the app already models) should still give a browsable tree.
  private func loadGit(root: URL) async -> Bool {
    let paths: [String]
    do {
      paths = try await gitClient.listFiles(root)
    } catch {
      return false
    }
    // Status is only the tint, so it gets its own failure handling. A transient
    // error here (a concurrent agent holding index.lock is routine in this app)
    // must not discard a good file list and drop the pane to a listing that
    // ignores .gitignore.
    let statuses = (try? await gitClient.fileStatuses(root)) ?? [:]
    let visible = paths.filter { path in
      !path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
    nodes = await Self.build(from: visible, statuses: statuses)
    source = .git
    loadedDirectories = []
    failedDirectories = []
    loadFailure = nil
    return true
  }

  /// Folder source: read the root, then re-read every directory the user had
  /// open. Without the second pass a refresh leaves expanded rows rendering
  /// open and empty, since folder nodes always come back with no children.
  func loadFolder(at root: URL) async {
    do {
      var tree = try await Self.readDirectory(root, prefix: "")
      source = .folder
      loadedDirectories = []
      failedDirectories = []
      // Shallowest first, so a parent's children exist before a child splices in.
      let byDepth = expanded.sorted {
        $0.filter { $0 == "/" }.count < $1.filter { $0 == "/" }.count
      }
      for path in byDepth {
        let url = root.appending(path: path, directoryHint: .isDirectory)
        guard let children = try? await Self.readDirectory(url, prefix: path) else {
          failedDirectories.insert(path)
          continue
        }
        tree = Self.replacingChildren(in: tree, at: path, with: children)
        loadedDirectories.insert(path)
      }
      nodes = tree
      loadFailure = nil
    } catch {
      nodes = []
      loadFailure = "Can't read this folder."
    }
  }

  func toggle(_ node: FileTreeNode, worktree: Worktree) async {
    guard node.isDirectory else { return }
    if expanded.contains(node.relativePath) {
      expanded.remove(node.relativePath)
      return
    }
    // The git source lists in one shot, so children are already in memory.
    guard source == .folder, let root = worktree.localWorkingDirectory else {
      expanded.insert(node.relativePath)
      return
    }
    await expandFolder(node, root: root)
  }

  /// Folder source: read `node`'s children and splice them in.
  func expandFolder(_ node: FileTreeNode, root: URL) async {
    if loadedDirectories.contains(node.relativePath) {
      expanded.insert(node.relativePath)
      return
    }
    let url = root.appending(path: node.relativePath, directoryHint: .isDirectory)
    do {
      let children = try await Self.readDirectory(url, prefix: node.relativePath)
      nodes = Self.replacingChildren(in: nodes, at: node.relativePath, with: children)
      loadedDirectories.insert(node.relativePath)
      failedDirectories.remove(node.relativePath)
      expanded.insert(node.relativePath)
    } catch {
      // Record the failure but do NOT mark it loaded. Marking it would send the
      // next click down the already-loaded fast path, expanding the row to
      // nothing and never retrying. One bad directory must not empty the pane.
      failedDirectories.insert(node.relativePath)
    }
  }

  /// Drives the row's warning affordance.
  func didFailToRead(_ node: FileTreeNode) -> Bool {
    failedDirectories.contains(node.relativePath)
  }

  /// `nonisolated` and hopped off the main actor: enumerating a large directory
  /// blocks, and this runs while the pane is on screen.
  private nonisolated static func readDirectory(
    _ url: URL,
    prefix: String
  ) async throws -> [FileTreeNode] {
    try await Task.detached(priority: .userInitiated) {
      let entries = try FileManager.default.contentsOfDirectory(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
      let nodes = try entries.map { entry -> FileTreeNode in
        let isDirectory = try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
        let name = entry.lastPathComponent
        return FileTreeNode(
          relativePath: prefix.isEmpty ? name : prefix + "/" + name,
          name: name,
          isDirectory: isDirectory,
          status: .unchanged,
          children: []
        )
      }
      return nodes.sorted { lhs, rhs in
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
      }
    }.value
  }

  /// Same reason: a big repo's file list is a real recursive fold plus a
  /// localized sort at every level, and the main thread shouldn't wear it.
  private nonisolated static func build(
    from paths: [String],
    statuses: [String: FileTreeNode.Status]
  ) async -> [FileTreeNode] {
    await Task.detached(priority: .userInitiated) {
      FileTree.build(from: paths, statuses: statuses)
    }.value
  }

  nonisolated static func replacingChildren(
    in nodes: [FileTreeNode],
    at path: String,
    with children: [FileTreeNode]
  ) -> [FileTreeNode] {
    nodes.map { node in
      var copy = node
      if node.relativePath == path {
        copy.children = children
      } else if path.hasPrefix(node.relativePath + "/") {
        copy.children = replacingChildren(in: node.children, at: path, with: children)
      }
      return copy
    }
  }
}

/// Caches one `WorktreeFileTreeState` per worktree, mirroring
/// `WorktreeTerminalManager.state(for:)`.
@MainActor
@Observable
final class WorktreeFileTreeManager {
  private var states: [Worktree.ID: WorktreeFileTreeState] = [:]

  func state(for worktree: Worktree) -> WorktreeFileTreeState {
    if let existing = states[worktree.id] { return existing }
    let created = WorktreeFileTreeState()
    states[worktree.id] = created
    return created
  }
}
