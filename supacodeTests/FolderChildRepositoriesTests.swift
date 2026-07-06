import ComposableArchitecture
import Foundation
import IdentifiedCollections
import Testing

@testable import supacode

/// Coverage for folder → child-repository nesting: `Repository.childGitRepositoryURLs`
/// discovery, the `orderedRepositoryIDs()` grouping that seats children right after
/// their parent folder, and the `nestedRepositoryIDs` projection the sidebar uses to
/// indent child sections.
@MainActor
struct FolderChildRepositoriesTests {
  // MARK: - Fixtures.

  private func makeFolderRepository(root: URL) -> Repository {
    let worktree = Worktree(
      id: Repository.folderWorktreeID(for: root),
      kind: .folder,
      name: Repository.name(for: root),
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(
      id: RepositoryID(root.standardizedFileURL.path(percentEncoded: false)),
      rootURL: root,
      name: Repository.name(for: root),
      worktrees: [worktree],
      isGitRepository: false
    )
  }

  private func makeGitRepository(root: URL) -> Repository {
    let main = Worktree(
      id: WorktreeID(root.standardizedFileURL.path(percentEncoded: false)),
      name: "main",
      detail: "",
      workingDirectory: root,
      repositoryRootURL: root
    )
    return Repository(
      id: RepositoryID(root.standardizedFileURL.path(percentEncoded: false)),
      rootURL: root,
      name: Repository.name(for: root),
      worktrees: [main]
    )
  }

  private func makeState(repositories: [Repository], roots: [URL]) -> RepositoriesFeature.State {
    var state = RepositoriesFeature.State()
    state.repositories = IdentifiedArray(uniqueElements: repositories)
    state.repositoryRoots = roots
    state.isInitialLoadComplete = true
    return state
  }

  // MARK: - Discovery.

  @Test func childGitRepositoryURLsFindsOnlyDirectGitChildren() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appending(path: "folder-child-discovery-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }

    // Two git repos (dir-form and file-form `.git`), one plain directory, one
    // plain file, and one git repo hidden a level deeper that must NOT match.
    let repoB = root.appending(path: "b-repo", directoryHint: .isDirectory)
    let repoA = root.appending(path: "a-repo", directoryHint: .isDirectory)
    let plain = root.appending(path: "plain", directoryHint: .isDirectory)
    let deep = plain.appending(path: "deep-repo", directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: repoB.appending(path: ".git", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(at: repoA, withIntermediateDirectories: true)
    try Data("gitdir: /elsewhere".utf8)
      .write(to: repoA.appending(path: ".git", directoryHint: .notDirectory))
    try fileManager.createDirectory(
      at: deep.appending(path: ".git", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try Data().write(to: root.appending(path: "loose-file", directoryHint: .notDirectory))

    let children = Repository.childGitRepositoryURLs(in: root)

    #expect(children.map(\.lastPathComponent) == ["a-repo", "b-repo"])
  }

  @Test func childGitRepositoryURLsReturnsEmptyForMissingDirectory() {
    let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString)")
    #expect(Repository.childGitRepositoryURLs(in: missing).isEmpty)
  }

  // MARK: - Ordering.

  @Test func orderedRepositoryIDsSeatsChildrenAfterParentFolder() throws {
    let folderURL = URL(fileURLWithPath: "/tmp/unify")
    let childA = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-api"))
    let childB = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-app"))
    let folder = makeFolderRepository(root: folderURL)
    let other = makeGitRepository(root: URL(fileURLWithPath: "/tmp/other"))
    // Children deliberately placed away from the folder in load order.
    let state = makeState(
      repositories: [childA, other, folder, childB],
      roots: [folderURL, other.rootURL]
    )

    let ordered = state.orderedRepositoryIDs()

    let folderIndex = try #require(ordered.firstIndex(of: folder.id))
    #expect(ordered[folderIndex + 1] == childA.id)
    #expect(ordered[folderIndex + 2] == childB.id)
    #expect(ordered.contains(other.id))
  }

  @Test func parentFolderRepositoryIDIsNilForTopLevelAndFolderRepos() {
    let folderURL = URL(fileURLWithPath: "/tmp/unify")
    let folder = makeFolderRepository(root: folderURL)
    let child = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-api"))
    let topLevel = makeGitRepository(root: URL(fileURLWithPath: "/tmp/other"))
    let state = makeState(repositories: [folder, child, topLevel], roots: [folderURL])

    #expect(state.parentFolderRepositoryID(of: child) == folder.id)
    #expect(state.parentFolderRepositoryID(of: topLevel) == nil)
    #expect(state.parentFolderRepositoryID(of: folder) == nil)
  }

  // MARK: - Sidebar structure.

  @Test func structureNestsChildSectionsBeneathFolder() {
    let folderURL = URL(fileURLWithPath: "/tmp/unify")
    let folder = makeFolderRepository(root: folderURL)
    let childA = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-api"))
    let childB = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-app"))
    let state = makeState(repositories: [childB, folder, childA], roots: [folderURL])

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let sectionIDs = structure.sections.map(\.id)
    let expected: [SidebarStructure.Section.SectionID] = [
      .folder(folder.id),
      .repository(childB.id),
      .repository(childA.id),
    ]
    #expect(sectionIDs == expected)
    #expect(structure.nestedRepositoryIDs == [childA.id, childB.id])
    // Children stay in the reorderable mirror so `.repositoriesMoved` offsets
    // keep translating 1:1 against `orderedRepositoryIDs()`.
    #expect(structure.reorderableRepositoryIDs == [folder.id, childB.id, childA.id])
  }

  @Test func topLevelReposAreNeverMarkedNested() {
    let repo = makeGitRepository(root: URL(fileURLWithPath: "/tmp/solo"))
    let state = makeState(repositories: [repo], roots: [repo.rootURL])

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    #expect(structure.nestedRepositoryIDs.isEmpty)
  }

  // MARK: - Removal cascade.

  @Test func removingFolderPrunesDerivedChildrenButKeepsExplicitRoots() async {
    let folderURL = URL(fileURLWithPath: "/tmp/unify")
    let folder = makeFolderRepository(root: folderURL)
    // Derived: discovered inside the folder, not a persisted root.
    let derived = makeGitRepository(root: URL(fileURLWithPath: "/tmp/unify/unify-api"))
    // Explicit: also inside the folder, but the user added it directly.
    let explicitURL = URL(fileURLWithPath: "/tmp/unify/unify-app")
    let explicit = makeGitRepository(root: explicitURL)
    var state = makeState(
      repositories: [folder, derived, explicit],
      roots: [folderURL, explicitURL]
    )
    state.reconcileSidebarForTesting()

    let store = TestStore(initialState: state) {
      RepositoriesFeature()
    } withDependencies: {
      $0.repositoryPersistence.saveRoots = { _ in }
      $0.repositoryPersistence.pruneRepositoryConfigs = { _ in }
      $0.analyticsClient.capture = { _, _ in }
      $0.gitClient.isGitRepository = { _ in false }
      $0.gitClient.worktrees = { _ in [] }
      $0.uuid = .incrementing
    }
    store.exhaustivity = .off(showSkippedAssertions: false)

    await store.send(.repositoriesRemoved([folder.id], selectionWasRemoved: false))
    await store.skipReceivedActions()

    // The derived child lived only through its parent folder; the explicit
    // root survives the folder's removal.
    #expect(store.state.repositories[id: folder.id] == nil)
    #expect(store.state.repositories[id: derived.id] == nil)
    #expect(store.state.repositories[id: explicit.id] != nil)
    #expect(store.state.repositoryRoots == [explicitURL])
  }

  // MARK: - Failure visibility.

  @Test func failedChildRepositoryStillRendersFailureRow() {
    let folderURL = URL(fileURLWithPath: "/tmp/unify")
    let folder = makeFolderRepository(root: folderURL)
    // A discovered child that failed to load: present only as a LoadFailure —
    // no repositories entry, no persisted root.
    let failedChildID = RepositoryID("/tmp/unify/corrupt-repo")
    var state = makeState(repositories: [folder], roots: [folderURL])
    state.loadFailuresByID = [failedChildID: "fatal: not a git repository"]

    let structure = state.computeSidebarStructure(groupPinned: true, groupActive: true)

    let failedSection = structure.sections.compactMap { section -> URL? in
      if case .failedRepository(let id, let rootURL, _, _, _) = section, id == failedChildID {
        return rootURL
      }
      return nil
    }.first
    #expect(failedSection?.path(percentEncoded: false) == "/tmp/unify/corrupt-repo")
  }
}
