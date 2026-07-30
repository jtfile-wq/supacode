import SwiftUI

/// Inspector pane listing the worktree's files. Git worktrees show a
/// `.gitignore`-respecting tree with a status tint; folder rows show a plain
/// directory listing read one level at a time.
struct WorktreeFilesInspectorView: View {
  let worktree: Worktree
  let manager: WorktreeFileTreeManager
  /// Changes whenever the file watcher reports activity in this worktree.
  let refreshToken: Int
  let onOpenFile: (URL) -> Void

  var body: some View {
    let state = manager.state(for: worktree)
    Group {
      if let failure = state.loadFailure {
        ContentUnavailableView(
          "Files Unavailable",
          systemImage: "folder.badge.questionmark",
          description: Text(failure)
        )
      } else if state.nodes.isEmpty {
        if state.isLoading {
          ProgressView().controlSize(.small)
        } else {
          ContentUnavailableView(
            "No Files",
            systemImage: "folder",
            description: Text("Nothing to show in this worktree.")
          )
        }
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            FileTreeRows(
              nodes: state.nodes,
              depth: 0,
              state: state,
              worktree: worktree,
              onOpenFile: onOpenFile
            )
          }
          .padding(.vertical, 4)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .task(id: FileTreeLoadKey(worktreeID: worktree.id, token: refreshToken)) {
      await state.load(worktree: worktree)
    }
  }
}

/// `.task(id:)` restarts only when the id *value* changes. Keying on the token
/// alone would skip the load when switching between two worktrees that both sit
/// at token 0, which is every pair of worktrees nothing has written to yet: the
/// pane would stay on its empty state until a watcher event happened to arrive.
private struct FileTreeLoadKey: Hashable {
  let worktreeID: Worktree.ID
  let token: Int
}

/// Rows are emitted recursively rather than with `OutlineGroup` so expansion
/// state can live on the loader (folder rows read children on expand) instead
/// of inside SwiftUI.
private struct FileTreeRows: View {
  let nodes: [FileTreeNode]
  let depth: Int
  let state: WorktreeFileTreeState
  let worktree: Worktree
  let onOpenFile: (URL) -> Void

  var body: some View {
    ForEach(nodes) { node in
      FileTreeRow(
        node: node,
        depth: depth,
        isExpanded: state.expanded.contains(node.relativePath),
        didFail: state.didFailToRead(node)
      ) {
        if node.isDirectory {
          Task { await state.toggle(node, worktree: worktree) }
        } else if let root = worktree.localWorkingDirectory {
          // `localWorkingDirectory` is `URL?`; a nil root means remote, which
          // never renders rows because `load` bails to the unavailable state.
          onOpenFile(root.appending(path: node.relativePath))
        }
      }
      if node.isDirectory, state.expanded.contains(node.relativePath) {
        FileTreeRows(
          nodes: node.children,
          depth: depth + 1,
          state: state,
          worktree: worktree,
          onOpenFile: onOpenFile
        )
      }
    }
  }
}

private struct FileTreeRow: View {
  let node: FileTreeNode
  let depth: Int
  let isExpanded: Bool
  /// Last read of this directory failed. Surfaced so an unreadable folder reads
  /// as unreadable rather than as empty.
  let didFail: Bool
  let activate: () -> Void

  var body: some View {
    Button(action: activate) {
      HStack(spacing: 5) {
        Image(systemName: "chevron.right")
          .font(.system(size: 9, weight: .semibold))
          .rotationEffect(.degrees(isExpanded ? 90 : 0))
          .foregroundStyle(.tertiary)
          .opacity(node.isDirectory ? 1 : 0)
          .frame(width: 9)
        Image(systemName: node.isDirectory ? "folder" : "doc")
          .font(.system(size: 10))
          .foregroundStyle(.secondary)
        Text(node.name)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(tint)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if didFail {
          Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .help("Can't read this folder.")
        }
      }
      .padding(.leading, CGFloat(depth) * 11 + 8)
      .padding(.trailing, 8)
      .padding(.vertical, 2)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(accessibilityLabel)
  }

  private var tint: Color {
    switch node.status {
    case .unchanged: node.isDirectory ? .primary : .secondary
    case .modified: .orange
    case .untracked: .green
    }
  }

  private var accessibilityLabel: String {
    let kind = node.isDirectory ? "Folder" : "File"
    let suffix = didFail ? ", unreadable" : ""
    switch node.status {
    case .unchanged: return "\(kind), \(node.name)\(suffix)"
    case .modified: return "\(kind), \(node.name), modified\(suffix)"
    case .untracked: return "\(kind), \(node.name), untracked\(suffix)"
    }
  }
}
