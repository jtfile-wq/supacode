import Foundation

/// One entry in a worktree file tree. Directories carry children; files are leaves.
nonisolated struct FileTreeNode: Identifiable, Hashable, Sendable {
  enum Status: Hashable, Sendable {
    case unchanged
    case modified
    case untracked
  }

  /// Path relative to the tree root, "/" separated. Stable across refreshes, so
  /// the view also uses it as the expansion-state key.
  let relativePath: String
  let name: String
  let isDirectory: Bool
  var status: Status
  /// Empty for files, and also for a directory whose children have not been
  /// read yet (folder rows load one level at a time).
  var children: [FileTreeNode]

  var id: String { relativePath }
}

/// `nonisolated` because the module defaults to MainActor isolation and this is
/// a pure fold over paths: the loader runs it off the main actor for big repos.
nonisolated enum FileTree {
  /// Folds a flat list of root-relative paths into nested nodes. Directories
  /// sort before files, then case-insensitively by name, matching Finder.
  static func build(
    from paths: [String],
    statuses: [String: FileTreeNode.Status] = [:]
  ) -> [FileTreeNode] {
    let components =
      paths
      .map { $0.split(separator: "/").map(String.init) }
      .filter { !$0.isEmpty }
    return build(components: components, prefix: "", statuses: statuses)
  }

  private static func build(
    components: [[String]],
    prefix: String,
    statuses: [String: FileTreeNode.Status]
  ) -> [FileTreeNode] {
    // Preserve first-seen order while grouping, then sort once at the end.
    var order: [String] = []
    var groups: [String: [[String]]] = [:]
    for parts in components {
      let head = parts[0]
      if groups[head] == nil {
        order.append(head)
        groups[head] = []
      }
      if parts.count > 1 {
        groups[head]?.append(Array(parts.dropFirst()))
      }
    }

    let nodes = order.map { head -> FileTreeNode in
      let path = prefix.isEmpty ? head : prefix + "/" + head
      let rest = groups[head] ?? []
      let isDirectory = !rest.isEmpty
      return FileTreeNode(
        relativePath: path,
        name: head,
        isDirectory: isDirectory,
        status: isDirectory ? .unchanged : (statuses[path] ?? .unchanged),
        children: isDirectory ? build(components: rest, prefix: path, statuses: statuses) : []
      )
    }

    return nodes.sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}
