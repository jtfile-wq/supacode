# File tree inspector pane

**Date:** 2026-07-29
**Branch:** `file-tree-inspector-pane` (off `upstream/main` @ `3ec6fb80`)
**Status:** approved, ready for implementation planning

## Problem

Supacode has no way to see what files are in a worktree. You can launch an agent at a
worktree root and watch it work, but to answer "what is actually in here" or "what did it just
touch" you leave the app. The trailing toolbar already hosts two inspector toggles, git and
notifications, so there is an established place for a third.

## Decisions

These were settled during design and are not open for re-litigation during implementation.

| Decision | Choice | Why |
| --- | --- | --- |
| Distribution | Local-only fork, no upstream issue or PR | Upstream requires an issue labeled `ready` before any PR, and a prior sidebar PR was declined under policy #419. Accepting a rebase per release instead. |
| File viewer | New tab running `bat`, falling back to `less` | The tab bar is hard-wired to Ghostty surfaces. A pager tab needs no new tab infrastructure, no syntax highlighter, and no binary or large-file handling of our own. |
| Tab behavior | One new tab per file, stacking | Matches how the user reads: open several files, compare, close them. |
| Tree contents | Tracked plus untracked, `.gitignore` respected | One git call, and it keeps `node_modules` and build output out of the tree. |
| Git status | Modified and untracked files tinted | Makes the tree answer "what did the agent just change", which is the point in an agent runner. |
| Dotfiles | Hidden | Explicit choice. One-line change to reverse if it proves annoying. |
| Ignored files, empty directories | Excluded | Both require a filesystem walk that the git listing avoids. |
| Non-git folder rows | Lazy per-directory listing | Half the user's sidebar rows are folders, including the one this feature was requested from. A pane that is dead there is a pane that is dead where it is wanted. |
| Remote worktrees | Out of scope for v1 | Both the listing and the pager need remote command building. Deferred, not designed out. |

## Scope

**In:** the pane, the toolbar toggle, the menu item and shortcut, both data sources, git status
tint, click-to-open as a pager tab, refresh on file change.

**Out:** editing files, renaming, deleting, drag and drop, multi-select, reveal in Finder from the
tree, remote worktrees, a search or filter field.

## Architecture

Ten existing files change and five are added. Keeping that surface small is a design goal, not an
accident: every line here is rebased against upstream on each release.

### Existing files

| File | Change |
| --- | --- |
| `SupacodeSettingsShared/App/AppShortcuts.swift` | Add `toggleFilesInspector` to the id enum (:21), its stable string key (:73), display name (:164), lookup map entry (:109), the default binding `key: "f", modifiers: [.command, .option]` next to the other two (:447), and the group listing (:516). `⌘⌥F` is unbound today; git is `⌘⌥G` and notifications is `⌘⌥N`, so it fits the existing pattern. |
| `supacode/Features/Repositories/Reducer/RepositoriesFeature.swift` | Add `case files` to `WorktreeInspectorPane` (:83). Extend the `.filesChanged` handler (:2975) to invalidate the cached tree for that worktree. |
| `supacode/Features/Repositories/Views/WorktreeStatusToolbarItems.swift` | Add `WorktreeFilesButton`, mirroring `WorktreeGitStatusButton` (:24) and the notifications button (:121): same `isSelected` / `tint` / `foreground` / `onActivate` signature and the same shortcut-in-help-text treatment. |
| `supacode/Features/Repositories/Views/WorktreeDetailView.swift` | Add the button to `TrailingStatusToolbarContent` (:757), between git and notifications. |
| `supacode/Features/Repositories/Views/WorktreeStatusInspector.swift` | Add `case .files:` to the switch (:19), passing the worktree and the tree state. |
| `supacode/Commands/SidebarCommands.swift` | Add "Toggle Files Inspector" beside the existing two inspector menu items (:109 to :119), same `toggleInspectorPaneAction?(.files)` and `.disabled` treatment. |
| `supacode/Clients/Git/GitClient.swift` | Add `listFiles(for:)` and `fileStatuses(for:)`. Existing `ls-files` invocations live at :564 and :573, so this follows established form. |
| `supacode/Clients/Repositories/GitClientDependency.swift` | Expose both as closure properties (:29), wire them in `make(shell:)` (:105), and stub them in `testValue` (:152). Nothing in the app calls `GitClient` directly; every consumer goes through this struct of explicit closures, and it has no forwarding, so a method added only to `GitClient` is invisible to `@Dependency(\.gitClient)`. |
| `supacodeTests/RepositoriesFeatureTests.swift` | Extend with a `.files` pane case and the token bump. `CLAUDE.md:29` requires tests for reducer changes, and `toggleInspectorPaneOpensSwapsAndCloses` (:16) already covers this exact path for the other two panes. |
| `supacode/Features/Terminal/Models/WorktreeTerminalState.swift` | Add `openFileViewerTab(url:)`. `TabCreation` and `createTab(_:)` are both `private` to this type (:670, :693), so a caller outside the file cannot construct one. The method has to live here, and it should be the only addition to this file. |

### New files

**`supacode/Domain/FileTree.swift`** holds `FileTreeNode` (name, relative path, `isDirectory`,
children, `status`) and a pure `FileTree.build(from paths: [String]) -> [FileTreeNode]` that folds a
flat path list into nested nodes. Sort order is directories first, then case-insensitive name. This
is the only real logic in the feature and it is deliberately isolated so it can be tested without a
repo, a filesystem, or a view.

**`supacode/Features/Repositories/BusinessLogic/WorktreeFileTreeManager.swift`** owns the two
sources and the cache. Git worktrees load eagerly in one shot; folder rows load one directory per
expansion and memoize the result. It exposes `state(for:)` keyed by worktree, mirroring
`WorktreeTerminalManager`.

**`supacode/Features/Repositories/Views/WorktreeFilesInspectorView.swift`** renders the tree with
disclosure rows, applies the status tint, and calls back on file activation.

**`supacodeTests/FileTreeTests.swift`** and **`supacodeTests/WorktreeFileTreeManagerTests.swift`**
cover the builder and the folder source respectively, using `swift-testing` (`import Testing`,
`@Test`, `#expect`) to match the existing suite.

## Data flow

**Git worktree.** One `git ls-files --cached --others --exclude-standard -z`, then
`git status --porcelain -z` for the tint. NUL separation on both so paths containing spaces,
newlines, or non-UTF8 bytes survive. Filter out any path with a component beginning `.`, fold the
remainder into nodes, and mark each node from the status map. The whole tree is in memory, so
expanding a directory is free.

**Folder row.** `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` with
`.skipsHiddenFiles`, on the root at open and on each directory as it is expanded. Never recursive:
pointing at `/Users/jtfile` must not enumerate a home directory. No status tint, because there is no
repo to ask.

**Refresh.** Subscribe to the existing `.filesChanged(worktreeID:)` event, already emitted on a
5 second debounce (`WorktreeInfoWatcherManager.swift:278`). No new watcher, no polling, no manual
refresh button.

Expansion state survives a refresh, keyed by relative path rather than node identity. For the folder
source that means the refresh re-reads every open directory, not just the root: folder nodes always
come back with no children, so preserving expansion without re-reading would render open, empty
rows. The cost is one directory read per directory the user actually opened.

The reload is keyed on worktree id *and* the change token together. Keying on the token alone would
skip the load when switching between two worktrees that both still sit at zero, which is every pair
of worktrees nothing has written to yet.

Both the directory reads and the tree fold run off the main actor. Enumerating a large directory
blocks, and a big repo's file list is a real recursive fold plus a localized sort at every level.

## Opening a file

`WorktreeTerminalState.openFileViewerTab(url:)` builds the creation internally:

```swift
createTab(TabCreation(
  title: url.lastPathComponent,
  icon: "doc.text",            // TabCreation.icon is an SF Symbol name (String?)
  isTitleLocked: true,
  command: pagerCommand(for: url),
  initialInput: nil,
  activation: .focused,
  inheritingFromSurfaceId: currentFocusedSurfaceId(),
  context: GHOSTTY_SURFACE_CONTEXT_TAB,
  tabID: nil,
  bypassZmx: true
))
```

`resolveLaunch` documents that an explicit `command` is wrapped directly, without shell resolution
or integration, which is exactly the semantics a pager tab wants. `bypassZmx: true` because a
viewer tab has no reason to survive app quit, and per-file zmx sessions would be churn for nothing.
Note that `isBlockingScript` stays `false`: the blocking-script guardrails include readonly-after-
completion and no-split behavior that a viewer tab should not inherit.

The pager is resolved once and cached: `bat --style=numbers,header --paging=always --color=always --`
when `bat` is on `PATH`, otherwise `less -R --`. The file path is shell-quoted. The title is locked
so the pager cannot rewrite the tab name out from under the filename.

## Error handling

- **Git listing fails** for any reason, including the `GitEnvironmentError` the app already models
  for an unaccepted Xcode license: fall back to the lazy `FileManager` listing rather than showing
  an empty pane. A tree without tint beats no tree.
- **Git status fails but the listing succeeded:** keep the listing and drop the tint. The two calls
  get separate error handling precisely so a transient status failure, a concurrent agent holding
  `index.lock` being the obvious one in this app, cannot discard a good file list and drop the pane
  to a listing that ignores `.gitignore`.
- **Directory unreadable** on expand: the row stays collapsed and carries a warning affordance. It is
  recorded as failed, deliberately not as loaded, so the next click retries rather than expanding to
  nothing. One bad directory does not fail the pane.
- **File is gone** by the time it is clicked, which is likely when an agent is mid-refactor: refresh
  the tree instead of spawning a pager that immediately errors into a dead tab.
- **Binary or huge file**: the pager's problem. Both `bat` and `less` handle it, and neither blocks
  the UI, since the work happens in the tab's own process.
- **Remote worktree**: pane shows an unavailable state, consistent with how the git pane handles a
  folder row today (`WorktreeStatusInspector.swift:73`).

## Testing

`FileTree.build` is a pure function over a flat path list and gets real coverage: nesting depth,
directories-before-files ordering, case-insensitive sort, a single deeply nested path, paths sharing
a prefix, and status propagation onto the right leaf. Everything else in this feature is wiring
between existing systems, and the honest check on wiring is running the app.

Before committing, `make check` (swift-format plus swiftlint), which the repo requires.

## Maintenance

This is carried as a local patch indefinitely. Two consequences to keep in view while implementing:

1. **Prefer additive edits.** A new `case` in an enum and a new file conflict far less on rebase than
   a rewritten function. Where something has to change in an existing function, keep the edit to the
   smallest possible hunk.
2. **No AI-authored commits.** `CONTRIBUTING.md` forbids an AI as author or co-author. Even though
   nothing here is going upstream today, keeping commits clean preserves the option, so no
   `Co-Authored-By` trailer on any commit in this repo.
3. **Follow the repo's `CLAUDE.md`.** Two rules bind directly on this work: prefer Swift-native APIs
   over Foundation where they exist (:31), and always add tests when reducer logic changes (:29).

Builds are unsigned local builds, so Sparkle auto-updates do not apply to them. Upstream releases
are pulled by rebasing this branch onto `upstream/main` and rebuilding.
