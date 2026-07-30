# File Tree Inspector Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third inspector pane to Supacode that lists the selected worktree's files, and open any file as a new tab rendered by a pager.

**Architecture:** A new `.files` case on the existing `WorktreeInspectorPane` enum drives a new toolbar toggle and a new inspector view. Git worktrees populate the tree from one `git ls-files` call with a status overlay; non-git folder rows read one directory per expansion. Clicking a file calls a new method on `WorktreeTerminalState` that creates an ordinary terminal tab whose command is `bat` (or `less`), so no non-terminal tab type is introduced.

**Tech Stack:** Swift 6, SwiftUI, The Composable Architecture, Ghostty (embedded terminal), Tuist (project generation), swift-testing, swift-format and SwiftLint.

## Global Constraints

- Design spec: `docs/superpowers/specs/2026-07-29-file-tree-inspector-pane-design.md`. Read it before starting.
- **Read the repo's own `CLAUDE.md` before writing code.** Two of its rules bind directly on this work: ":31 Prefer Swift-native APIs over Foundation where they exist (e.g. `replacing()` not `replacingOccurrences()`)" and ":29 When a new logic changes in the Reducer, always add tests."
- Branch: `file-tree-inspector-pane`, based on `upstream/main` @ `3ec6fb80`.
- **No commit may list an AI as author or co-author.** `CONTRIBUTING.md` forbids it. Never add a `Co-Authored-By` trailer in this repo.
- **Prefer additive edits.** This patch is rebased onto upstream on every release. A new enum case or a new file rebases cleanly; a rewritten function does not. Where an existing function must change, keep the hunk as small as possible.
- Run `make check` (swift-format plus SwiftLint) before every commit. It is required by the repo.
- Run `make test` to run tests. New test files are picked up because `TUIST_GENERATION_INPUTS` in the `Makefile` globs `supacodeTests/*.swift`, which invalidates the Tuist generation stamp. Do not hand-edit `Project.swift` to register a test file.
- Scope: local worktrees only. Remote (ssh) worktrees get an unavailable state, not an implementation.
- Dotfiles are filtered out of the tree. Ignored files and empty directories are excluded.

---

### Task 1: FileTree domain model and builder

The only real logic in the feature: folding a flat path list into nested nodes. Pure, no filesystem, no git, no SwiftUI, so it carries the test coverage for the whole feature.

**Files:**
- Create: `supacode/Domain/FileTree.swift`
- Test: `supacodeTests/FileTreeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FileTreeNode` (`relativePath: String`, `name: String`, `isDirectory: Bool`, `status: FileTreeNode.Status`, `children: [FileTreeNode]`, `id: String`), `FileTreeNode.Status` (`.unchanged`, `.modified`, `.untracked`), and `FileTree.build(from: [String], statuses: [String: FileTreeNode.Status]) -> [FileTreeNode]`.

- [ ] **Step 1: Write the failing test**

Create `supacodeTests/FileTreeTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL to compile with "cannot find 'FileTree' in scope".

- [ ] **Step 3: Write the implementation**

Create `supacode/Domain/FileTree.swift`:

```swift
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

enum FileTree {
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `make test`
Expected: PASS, all six `FileTreeTests` cases.

- [ ] **Step 5: Commit**

```bash
make check
git add supacode/Domain/FileTree.swift supacodeTests/FileTreeTests.swift
git commit -m "feat: add FileTree node model and path folding"
```

---

### Task 2: Git file listing and status

**Files:**
- Modify: `supacode/Clients/Git/GitClient.swift` (add two `GitOperation` cases near :21, two methods near :575 beside `untrackedFileCount`)
- Modify: `supacode/Clients/Repositories/GitClientDependency.swift` (two closure properties near :29, two `make(shell:)` entries near :105, two `testValue` stubs near :152)

**Interfaces:**
- Consumes: `FileTreeNode.Status` from Task 1.
- Produces: `GitClient.listFiles(for: URL) async throws -> [String]` and `GitClient.fileStatuses(for: URL) async throws -> [String: FileTreeNode.Status]`, both exposed on `GitClientDependency` under the same names.

**Critical:** nothing in the app calls `GitClient` directly. Every consumer goes through `GitClientDependency`, a struct of explicit `@Sendable` closures registered as the `DependencyKey`. It has no forwarding or dynamic dispatch, so a method added only to `GitClient` is invisible to `@Dependency(\.gitClient)`. Both layers must be edited or Task 3 will not compile.

- [ ] **Step 1: Add the operation cases**

In `supacode/Clients/Git/GitClient.swift`, in the `GitOperation` enum, after `case untrackedFileCount = "untracked_file_count"` (:22):

```swift
  case fileList = "file_list"
  case fileStatus = "file_status"
```

- [ ] **Step 2: Add the two methods**

In the same file, immediately after `untrackedFileCount(for:)` (ends :575):

```swift
  /// Tracked plus untracked files, honoring `.gitignore`. NUL separated so
  /// paths containing spaces or newlines survive the round trip.
  nonisolated func listFiles(for worktreeRoot: URL) async throws -> [String] {
    let path = worktreeRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .fileList,
      arguments: ["-C", path, "ls-files", "--cached", "--others", "--exclude-standard", "-z"]
    )
    return output.split(separator: "\0").map(String.init).filter { !$0.isEmpty }
  }

  /// Modified / untracked status per root-relative path, for the tree tint.
  nonisolated func fileStatuses(for worktreeRoot: URL) async throws -> [String: FileTreeNode.Status] {
    let path = worktreeRoot.path(percentEncoded: false)
    let output = try await runGit(
      operation: .fileStatus,
      arguments: ["-C", path, "status", "--porcelain", "-z"]
    )
    let fields = output.split(separator: "\0").map(String.init)
    var statuses: [String: FileTreeNode.Status] = [:]
    var index = 0
    while index < fields.count {
      let entry = fields[index]
      index += 1
      // "XY <path>": two status columns, a space, then the path.
      guard entry.count > 3 else { continue }
      let code = String(entry.prefix(2))
      let file = String(entry.dropFirst(3))
      // Rename and copy entries put the *source* path in the next NUL field.
      // Skipping it keeps that path from being read as a status entry.
      if code.hasPrefix("R") || code.hasPrefix("C") { index += 1 }
      statuses[file] = code.contains("?") ? .untracked : .modified
    }
    return statuses
  }
```

- [ ] **Step 3: Expose both methods on the dependency**

In `supacode/Clients/Repositories/GitClientDependency.swift`, three edits.

Closure properties, after `var untrackedFileCount` (:29):

```swift
  var listFiles: @Sendable (URL) async throws -> [String]
  var fileStatuses: @Sendable (URL) async throws -> [String: FileTreeNode.Status]
```

Live wiring in `make(shell:)`, after the `untrackedFileCount` entry (:105), matching the one-line style used there:

```swift
      listFiles: { try await GitClient(shell: shell).listFiles(for: $0) },
      fileStatuses: { try await GitClient(shell: shell).fileStatuses(for: $0) },
```

Test stubs in `testValue` (:152), which starts from `liveValue` and overrides only what would otherwise shell out:

```swift
    // `liveValue` shells out to real git; fixtures use fake paths, so default
    // to an empty tree rather than a thrown error.
    value.listFiles = { _ in [] }
    value.fileStatuses = { _ in [:] }
```

Property order in the struct, the `make(shell:)` argument order, and the memberwise initializer must all stay in sync. Add both entries in the same relative position in each.

- [ ] **Step 4: Verify it builds**

Run: `make build-app`
Expected: build succeeds.

- [ ] **Step 5: Sanity check the git invocations by hand**

Run: `git -C ~/dev/supacode ls-files --cached --others --exclude-standard -z | tr '\0' '\n' | head`
Expected: a list of repo-relative paths with no `.build/` or `ThirdParty/ghostty` contents in it.

Run: `git -C ~/dev/supacode status --porcelain -z | tr '\0' '\n' | head`
Expected: status lines, or empty output on a clean tree.

- [ ] **Step 6: Commit**

```bash
make check
git add supacode/Clients/Git/GitClient.swift supacode/Clients/Repositories/GitClientDependency.swift
git commit -m "feat: add git file listing and per-file status to GitClient"
```

---

### Task 3: File tree loader

Owns the two data sources and the per-worktree cache. Mirrors the existing `WorktreeTerminalManager.state(for:)` shape so the view code reads like its neighbors.

**Files:**
- Create: `supacode/Features/Repositories/BusinessLogic/WorktreeFileTreeManager.swift`
- Test: `supacodeTests/WorktreeFileTreeManagerTests.swift`

**Interfaces:**
- Consumes: `FileTree`, `FileTreeNode` (Task 1); `GitClient.listFiles(for:)`, `GitClient.fileStatuses(for:)` (Task 2).
- Produces: `WorktreeFileTreeManager` with `state(for: Worktree) -> WorktreeFileTreeState`, and `WorktreeFileTreeState` with `nodes: [FileTreeNode]`, `loadFailure: String?`, `isLoading: Bool`, `expanded: Set<String>`, `func load(worktree: Worktree) async`, `func toggle(_ node: FileTreeNode, worktree: Worktree) async`.

- [ ] **Step 1: Write the failing test**

Create `supacodeTests/WorktreeFileTreeManagerTests.swift`. This covers the folder-row source against a real temp directory, which is the part with branching behavior. The git source is covered by `FileTreeTests` plus the manual check in Task 2.

```swift
import Foundation
import Testing

@testable import supacode

@MainActor
struct WorktreeFileTreeManagerTests {
  private func makeTempTree() throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("filetree-\(UUID().uuidString)")
    let fm = FileManager.default
    try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `make test`
Expected: FAIL to compile with "cannot find 'WorktreeFileTreeState' in scope".

- [ ] **Step 3: Write the implementation**

Create `supacode/Features/Repositories/BusinessLogic/WorktreeFileTreeManager.swift`:

```swift
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

  @ObservationIgnored @Dependency(\.gitClient) private var gitClient

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

  private static func replacingChildren(
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
```

- [ ] **Step 4: Reconcile the implementation against the real `Worktree` API**

`load(worktree:)` references `worktree.kind`, `worktree.host`, and `worktree.localWorkingDirectory`. Confirm the `RepositoryKind` case for a git worktree before building. It lives in `RepositoryIdentity.swift`, not a file of its own:

Run: `grep -n "enum RepositoryKind" -A 6 supacode/Domain/RepositoryIdentity.swift`
Expected: the case list, with `.git` at :53. If the case is spelled differently, update the comparison in `load(worktree:)`.

Note that `localWorkingDirectory` is `URL?` (`Worktree.swift:38`), which is why `load` unwraps it in the same guard as the `host == nil` check. Both are driven by the same `.local` case of `WorktreeLocation`, so a local worktree always has one.

Also confirm how the app resolves `gitClient` for a worktree. `RepositoriesFeature` uses a `gitClient(for: worktree)` helper rather than the bare dependency:

Run: `grep -n "func gitClient(for" -A 8 supacode/Features/Repositories/Reducer/RepositoriesFeature.swift`
Expected: the helper. If it exists and does more than return `@Dependency(\.gitClient)` (for example picking a remote-aware client), use the same resolution here instead of the bare dependency.

Finally, note the call style: `GitClientDependency`'s members are closures, so they are called positionally as `gitClient.listFiles(root)`, with no argument label, unlike `GitClient.listFiles(for:)`.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: PASS, all four `WorktreeFileTreeManagerTests` cases and the six from Task 1.

- [ ] **Step 6: Commit**

```bash
make check
git add supacode/Features/Repositories/BusinessLogic/WorktreeFileTreeManager.swift supacodeTests/WorktreeFileTreeManagerTests.swift
git commit -m "feat: add per-worktree file tree loader with git and folder sources"
```

---

### Task 4: Pane plumbing, refresh signal, and keyboard shortcut

No visible change on its own. It makes `.files` a legal pane, gives the view a refresh trigger, and registers the shortcut.

**Files:**
- Modify: `SupacodeSettingsShared/App/AppShortcuts.swift` (six sites: :21, :73, :109, :164, :447, :516)
- Modify: `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` (:83, :166 area, :2975)

**Interfaces:**
- Consumes: nothing.
- Produces: `WorktreeInspectorPane.files`, `AppShortcuts.toggleFilesInspector`, and `RepositoriesFeature.State.filesChangedToken: [Worktree.ID: Int]`.

- [ ] **Step 1: Add the pane case**

In `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift`, at the enum (:83):

```swift
enum WorktreeInspectorPane: Hashable, Sendable {
  case git
  case files
  case notifications
}
```

- [ ] **Step 2: Add the refresh token to state**

In the same file, in `State` beside `inspectorPane` (:167):

```swift
    /// Bumped per worktree whenever the file watcher reports a change, so the
    /// files inspector can re-read the tree without its own watcher.
    var filesChangedToken: [Worktree.ID: Int] = [:]
```

- [ ] **Step 3: Bump the token from the existing watcher case**

In the same file, in `case .filesChanged(let worktreeID):` (:2975), add one line immediately after the `guard let worktree` block and before `let worktreeURL`:

```swift
          state.filesChangedToken[worktreeID, default: 0] += 1
```

Leave the rest of that case exactly as it is. The existing `lineChanges` effect must keep working.

- [ ] **Step 4: Register the shortcut**

In `SupacodeSettingsShared/App/AppShortcuts.swift`, six edits:

At :21, extend the case list:
```swift
  case togglePullRequestInspector, toggleFilesInspector, toggleNotificationsInspector
```

At :73, in the stable-key switch, after the pull request line:
```swift
    case .toggleFilesInspector: "toggleFilesInspector"
```

At :109, in the lookup dictionary, after the pull request entry:
```swift
    "toggleFilesInspector": .toggleFilesInspector,
```

At :164, in the display-name switch, after the pull request line:
```swift
    case .toggleFilesInspector: "Toggle Files Inspector"
```

At :447, after `togglePullRequestInspector`:
```swift
  public static let toggleFilesInspector = AppShortcut(
    id: .toggleFilesInspector, key: "f", modifiers: [.command, .option]
  )
```

At :516, in the group listing:
```swift
        togglePullRequestInspector, toggleFilesInspector, toggleNotificationsInspector,
```

`⌘⌥F` is unbound in this file today (verified: no other `key: "f"` entry), and it sits alongside `⌘⌥G` for git and `⌘⌥N` for notifications.

- [ ] **Step 5: Add the reducer test**

`CLAUDE.md:29` says "When a new logic changes in the Reducer, always add tests". This task changes reducer state, so it needs one. `supacodeTests/RepositoriesFeatureTests.swift:16` already has `toggleInspectorPaneOpensSwapsAndCloses` covering `.git` and `.notifications`; extend that file with a case for the new pane and the new token.

Add to `RepositoriesFeatureTests`:

```swift
  @Test func toggleInspectorPaneHandlesTheFilesPane() async {
    let store = TestStore(initialState: RepositoriesFeature.State()) {
      RepositoriesFeature()
    } withDependencies: {
      $0.sidebarStructureAutoRecompute = false
    }

    // Opens on `.files` from the default `.git` pane.
    await store.send(.toggleInspectorPane(.files)) {
      $0.inspectorPresented = true
      $0.inspectorPane = .files
    }
    // Swapping away and back keeps the same open/close semantics as the others.
    await store.send(.toggleInspectorPane(.git)) {
      $0.inspectorPane = .git
    }
    await store.send(.toggleInspectorPane(.files)) {
      $0.inspectorPane = .files
    }
    await store.send(.toggleInspectorPane(.files)) {
      $0.inspectorPresented = false
    }
  }
```

The token bump is exercised through the watcher event. Match how the existing suite drives `worktreeInfoWatcher` events (`grep -n "filesChanged\|worktreeInfoWatcher" supacodeTests/*.swift`) and assert that a `.filesChanged` for a known worktree increments `filesChangedToken[worktreeID]` from absent to 1, and again to 2 on a second event. If no existing test drives that watcher, assert the state transition directly through whatever action the reducer exposes for it rather than inventing new plumbing.

- [ ] **Step 6: Verify it builds and nothing regressed**

Run: `make build-app && make test`
Expected: build succeeds; the existing suite still passes plus the new case. Any switch over `WorktreeInspectorPane` that is now non-exhaustive will fail the build here and gets fixed in Task 6.

- [ ] **Step 7: Commit**

```bash
make check
git add SupacodeSettingsShared/App/AppShortcuts.swift supacode/Features/Repositories/Reducer/RepositoriesFeature.swift supacodeTests/RepositoriesFeatureTests.swift
git commit -m "feat: add files inspector pane case, refresh token, and shortcut"
```

---

### Task 5: Inspector view

**Files:**
- Create: `supacode/Features/Repositories/Views/WorktreeFilesInspectorView.swift`
- Modify: `supacode/Features/Repositories/Views/WorktreeStatusInspector.swift` (:19 switch, and the container's stored properties)

**Interfaces:**
- Consumes: `WorktreeFileTreeManager`, `WorktreeFileTreeState` (Task 3); `FileTreeNode` (Task 1); `filesChangedToken` (Task 4).
- Produces: `WorktreeFilesInspectorView(worktree:manager:refreshToken:onOpenFile:)`, where `onOpenFile` is `(URL) -> Void`.

- [ ] **Step 1: Write the view**

Create `supacode/Features/Repositories/Views/WorktreeFilesInspectorView.swift`:

```swift
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
            FileTreeRows(nodes: state.nodes, depth: 0, state: state, worktree: worktree, onOpenFile: onOpenFile)
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
          nodes: node.children, depth: depth + 1, state: state, worktree: worktree, onOpenFile: onOpenFile
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
```

- [ ] **Step 2: Wire it into the inspector switch**

In `supacode/Features/Repositories/Views/WorktreeStatusInspector.swift`, add stored properties to `WorktreeStatusInspectorContainer` beside the existing ones (:8-16):

```swift
  let worktree: Worktree?
  let fileTreeManager: WorktreeFileTreeManager
  let filesChangedToken: Int
  let onOpenFile: (URL) -> Void
```

and the new branch in the switch (:20), between `.git` and `.notifications`. `worktree` is optional here because the container's call site binds an optional selection:

```swift
      case .files:
        if let worktree {
          WorktreeFilesInspectorView(
            worktree: worktree,
            manager: fileTreeManager,
            refreshToken: filesChangedToken,
            onOpenFile: onOpenFile
          )
        } else {
          ContentUnavailableView(
            "No Worktree",
            systemImage: "folder",
            description: Text("Select a worktree to browse its files.")
          )
        }
```

which means the stored property added above is `let worktree: Worktree?`, not `Worktree`.

- [ ] **Step 3: Fix the call site**

`WorktreeStatusInspectorContainer` is constructed in `WorktreeDetailView.swift`. Find it and pass the four new arguments:

Run: `grep -n "WorktreeStatusInspectorContainer(" supacode/Features/Repositories/Views/WorktreeDetailView.swift`

Add the manager to the view that owns that call site, alongside its other view state. One manager per view, so the per-worktree caches survive switching rows:

```swift
  @State private var fileTreeManager = WorktreeFileTreeManager()
```

Then pass the four new arguments at the call site. `selectedWorktree` is bound at `WorktreeDetailView.swift:33` as `repositories.worktree(for: repositories.selectedWorktreeID)`, which is **optional**, so both the argument and the token subscript need optional handling:

```swift
        worktree: selectedWorktree,
        fileTreeManager: fileTreeManager,
        filesChangedToken: selectedWorktree.flatMap { store.filesChangedToken[$0.id] } ?? 0,
        onOpenFile: { _ in }
```

Task 7 replaces the inert `onOpenFile` closure. Leaving it inert here keeps this task independently reviewable.

- [ ] **Step 4: Build and look at it**

Run: `make run-app`
Expected: the app launches. The Files pane is not reachable from the toolbar yet (Task 6), but the build must be clean and the existing panes must still work.

- [ ] **Step 5: Commit**

```bash
make check
git add supacode/Features/Repositories/Views/WorktreeFilesInspectorView.swift supacode/Features/Repositories/Views/WorktreeStatusInspector.swift supacode/Features/Repositories/Views/WorktreeDetailView.swift
git commit -m "feat: add files inspector view"
```

---

### Task 6: Toolbar toggle and menu item

Makes the pane reachable. After this task the feature is usable except that clicking a file does nothing.

**Files:**
- Modify: `supacode/Features/Repositories/Views/WorktreeStatusToolbarItems.swift` (append a new view)
- Modify: `supacode/Features/Repositories/Views/WorktreeDetailView.swift` (:757 `TrailingStatusToolbarContent`)
- Modify: `supacode/Commands/SidebarCommands.swift` (:114 area)

**Interfaces:**
- Consumes: `AppShortcuts.toggleFilesInspector`, `WorktreeInspectorPane.files` (Task 4).
- Produces: `WorktreeFilesToolbarButton(isSelected:tint:foreground:onActivate:)`.

- [ ] **Step 1: Add the button**

Append to `supacode/Features/Repositories/Views/WorktreeStatusToolbarItems.swift`:

```swift
/// Trailing toolbar toggle for the file tree pane. Deliberately plainer than
/// the git and bell buttons: there is no badge state to convey.
struct WorktreeFilesToolbarButton: View {
  let isSelected: Bool
  // Selection highlight color, derived from the terminal background luminance
  // so the lit state tracks the chrome instead of the system accent.
  let tint: Color
  // Concrete chrome foreground (white on dark, black on light) so the glyph
  // doesn't change color when the toggle is selected.
  let foreground: Color
  let onActivate: () -> Void
  @Shared(.settingsFile) private var settingsFile

  var body: some View {
    let shortcut = WorktreeDetailView.resolveShortcutDisplay(
      for: AppShortcuts.toggleFilesInspector,
      overrides: settingsFile.global.shortcutOverrides
    )
    Toggle(isOn: Binding(get: { isSelected }, set: { _ in onActivate() })) {
      if isSelected {
        Label("Files", systemImage: "list.bullet.indent")
          .foregroundStyle(foreground)
      } else {
        // No foreground so the resting glyph matches the other toolbar buttons
        // exactly, including the fade when the window isn't key.
        Label("Files", systemImage: "list.bullet.indent")
      }
    }
    .tint(tint)
    .help("Toggle Files Inspector (\(shortcut))")
    .accessibilityLabel("Files")
  }
}
```

- [ ] **Step 2: Put it in the toolbar group**

In `supacode/Features/Repositories/Views/WorktreeDetailView.swift`, in `TrailingStatusToolbarContent.body` (:765), between `WorktreeGitStatusButton` and `ToolbarNotificationsButtonHost`:

```swift
        WorktreeFilesToolbarButton(
          isSelected: inspectorPresented && inspectorPane == .files,
          tint: chromeTint,
          foreground: chromeForeground,
          onActivate: { onActivateInspector(.files) }
        )
```

- [ ] **Step 3: Add the menu item**

In `supacode/Commands/SidebarCommands.swift`, read the shortcut beside the other two (:78-79):

```swift
    let toggleFilesInspector = AppShortcuts.toggleFilesInspector.effective(from: overrides)
```

and add the button between the pull request and notifications items (:113):

```swift
        Button("Toggle Files Inspector", systemImage: "list.bullet.indent") {
          toggleInspectorPaneAction?(.files)
        }
        .appKeyboardShortcut(toggleFilesInspector)
        .help("Toggle Files Inspector (\(toggleFilesInspector?.display ?? "none"))")
        .disabled(toggleInspectorPaneAction?.isEnabled != true)
```

- [ ] **Step 4: Verify by hand**

Run: `make run-app`

Check each of these:
1. A third icon appears in the trailing toolbar pill, between the branch icon and the bell.
2. Clicking it opens the pane; clicking it again closes it. Same for `⌘⌥F`.
3. On a git worktree row, the tree lists files, excludes `.build/` and other ignored paths, and excludes dotfiles.
4. Modified files are orange and untracked files are green. Make a change with `echo "" >> README.md` and confirm the tint appears within about 5 seconds without touching the pane.
5. On a folder row, the tree lists the directory; expanding reads one level.
6. "Toggle Files Inspector" appears in the menu with `⌘⌥F` next to it.
7. **Regression check for the refresh key.** With the pane open, click between two worktrees that have never been modified in this session. The tree must repopulate for each one. If it sticks on "No Files", `FileTreeLoadKey` is not wired in and the pane is keyed on the token alone.
8. **Regression check for expansion across refresh.** On a folder row, expand a couple of levels, then touch a file anywhere in that worktree and wait out the 5 second debounce. The expanded directories must still show their contents, not render open and empty.
9. Point a folder row at a large directory and confirm opening the pane does not visibly stall the window, which is what the detached reads are for.

- [ ] **Step 5: Commit**

```bash
make check
git add supacode/Features/Repositories/Views/WorktreeStatusToolbarItems.swift supacode/Features/Repositories/Views/WorktreeDetailView.swift supacode/Commands/SidebarCommands.swift
git commit -m "feat: add files inspector toolbar toggle and menu item"
```

---

### Task 7: Open a file as a pager tab

**Files:**
- Modify: `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` (add one method; `TabCreation` :670 and `createTab(_:)` :693 are both `private` to this type, so the method has to live in this file)
- Modify: `supacode/Features/Repositories/Views/WorktreeDetailView.swift` (replace the inert `onOpenFile` closure from Task 5)

**Interfaces:**
- Consumes: `TabCreation` and `createTab(_:)`, both private to `WorktreeTerminalState`.
- Produces: `WorktreeTerminalState.openFileViewerTab(url: URL)`.

- [ ] **Step 1: Add the method**

In `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`, after the blocking-script tab creation region (near :660, before `private struct TabCreation`):

```swift
  /// Opens `url` in a new tab running a pager. This is an ordinary terminal
  /// tab with an explicit command: `resolveLaunch` wraps an explicit command
  /// directly, with no shell resolution or integration, which is exactly what a
  /// read-only viewer wants. `bypassZmx` because a viewer has no reason to
  /// survive app quit, and a zmx session per opened file would be churn.
  ///
  /// Not a blocking-script tab: those carry no-split and readonly-after-
  /// completion guardrails a viewer shouldn't inherit.
  @discardableResult
  func openFileViewerTab(url: URL) -> TerminalTabID? {
    guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
      // The agent may have moved or deleted it since the tree was listed.
      // Opening a pager on a missing path would just produce a dead tab.
      return nil
    }
    return createTab(
      TabCreation(
        title: url.lastPathComponent,
        icon: "doc.text",
        isTitleLocked: true,
        command: Self.pagerCommand(for: url),
        initialInput: nil,
        activation: .focused,
        inheritingFromSurfaceId: currentFocusedSurfaceId(),
        context: GHOSTTY_SURFACE_CONTEXT_TAB,
        tabID: nil,
        bypassZmx: true
      )
    )
  }

  private static func pagerCommand(for url: URL) -> String {
    // Single-quote escaping matches the existing convention in this file
    // (`remoteDefaultShellCommand`, :2419). `replacing` rather than
    // `replacingOccurrences` per CLAUDE.md:31.
    let quoted = "'" + url.path(percentEncoded: false).replacing("'", with: "'\\''") + "'"
    if let bat = batExecutable {
      return "\(bat) --style=numbers,header --paging=always --color=always -- \(quoted)"
    }
    return "/usr/bin/less -R -- \(quoted)"
  }

  /// Resolved once per launch. Every tree click would otherwise re-walk PATH
  /// stat-ing candidates, on the main actor.
  private static let batExecutable: String? = resolveExecutable("bat")

  /// Looks `name` up on PATH without spawning a subprocess. The Homebrew
  /// directories are appended explicitly because an app launched from Finder
  /// does not inherit a login shell's PATH.
  private static func resolveExecutable(_ name: String) -> String? {
    let fileManager = FileManager.default
    let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let directories =
      inherited.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin"]
    for directory in directories {
      let candidate = directory + "/" + name
      if fileManager.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
  }
```

- [ ] **Step 2: Confirm the `TabCreation` argument list still matches**

The memberwise initializer above must match the declaration exactly, including argument order.

Run: `sed -n '670,692p' supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
Expected: `title`, `icon`, `isTitleLocked`, `customTitle`, `tintColor`, `command`, `initialInput`, `activation`, `inheritingFromSurfaceId`, `context`, `tabID`, `isBlockingScript`, `blockingScriptKind`, `bypassZmx`. `customTitle`, `tintColor`, `isBlockingScript`, and `blockingScriptKind` all have defaults and are omitted above. If the order or defaults have drifted, correct the call.

- [ ] **Step 3: Wire the click**

In `supacode/Features/Repositories/Views/WorktreeDetailView.swift`, replace the placeholder from Task 5:

```swift
        onOpenFile: { _ in }
```

with a call through the terminal manager, matching how the view already reaches terminal state (`terminalManager.state(for:)`, as in `WorktreeTerminalTabsView.swift:22`):

```swift
        onOpenFile: { url in
          guard let worktree = selectedWorktree else { return }
          let opened = terminalManager.state(for: worktree) { false }
            .openFileViewerTab(url: url)
          if opened == nil {
            // Listed but gone by the time it was clicked, which is likely while
            // an agent is mid-refactor. Re-read the tree rather than leaving a
            // row that silently does nothing.
            Task {
              await fileTreeManager.state(for: worktree).load(worktree: worktree)
            }
          }
        }
```

Confirm the trailing-closure argument of `state(for:)` before using it:

Run: `grep -n "func state(for" -A 4 supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
Expected: the signature. The closure supplies `shouldRunSetupScript`; passing `false` is correct here, since opening a file must never trigger a setup script.

- [ ] **Step 4: Verify by hand**

Run: `make run-app`

Check each of these:
1. Clicking a file opens a new tab named for that file, focused, with a document icon.
2. The pager renders with line numbers and syntax highlighting when `bat` is installed. Confirm with `which bat`; if it is missing, the tab should still open through `less`.
3. `q` closes the pager. Opening several files stacks tabs; `⌘W` closes them.
4. The tab title stays the filename and is not renamed by the pager.
5. Delete a file outside the app while its row is visible, then click that row. No tab should open.
6. Open a file whose name contains a space to confirm quoting.

- [ ] **Step 5: Commit**

```bash
make check
git add supacode/Features/Terminal/Models/WorktreeTerminalState.swift supacode/Features/Repositories/Views/WorktreeDetailView.swift
git commit -m "feat: open files from the tree as pager tabs"
```

---

## Verification

After Task 7, the whole feature is in place. Final pass:

- [ ] `make check` is clean.
- [ ] `make test` passes, including the thirteen new cases (six in `FileTreeTests`, six in `WorktreeFileTreeManagerTests`, one in `RepositoriesFeatureTests`).
- [ ] `git log --oneline upstream/main..HEAD` shows nine commits (seven from these tasks, plus the spec and plan docs) and no `Co-Authored-By` trailer on any of them.
- [ ] `git diff --stat upstream/main..HEAD` shows seventeen files: ten modified, five created, plus the two docs.
- [ ] The app builds and runs, and every manual check in Tasks 6 and 7 passes.
- [ ] `grep -rn "replacingOccurrences" supacode` still returns nothing, per CLAUDE.md:31.
