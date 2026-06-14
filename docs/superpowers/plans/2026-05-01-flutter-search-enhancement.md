# Flutter Search Enhancement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enhance the Flutter app's search results to show parent folder names and allow direct opening of either the file (via file viewer) or the containing folder (via file browser).

**Architecture:** Approach A (Enhanced ListTile) — keep `ListTile`, add `subtitle` for folder name, `trailing` icon button for folder navigation.

**Tech Stack:** Flutter, Dart, GetX, path package (already imported)

---

### Task 1: Create worktree

**Files:** N/A (git operation)

- [ ] **Step 1: Check .gitignore and create worktree**

Check the existing `.worktrees/` directory or create one, ensure it is ignored, then create a dedicated branch and worktree for this feature.

```bash
git worktree add .worktrees/feature/search-enhancement -b feature/search-enhancement
cd .worktrees/feature/search-enhancement
```

- [ ] **Step 2: Verify clean baseline**

Run: `flutter analyze`
Expected: no errors in project code (build artefacts may exist but no lint issues)

Run: `flutter test`
Expected: all existing tests pass

---

### Task 2: Extend SearchController with folder info and navigation helpers

**Files:**
- Modify: `lib/src/search/search_controller.dart`

The `webdav_client` `File` class is immutable for `name` and `path`; but `path` is actually mutable (it has a setter). We cannot easily add new fields. Instead we will maintain a parallel `RxMap<String, String>` from file path to folder name. However, a simpler approach: compute folder info on-the-fly in the view from the `File.path`.

Wait — a cleaner pattern for this minimal change: the view can compute folder path from `item.path` using `p.dirname()`. But we need `folderPath` and `folderName` derived from the API `reply["path"]` (the path *within* the provider).

The `File.path` currently stores `"providerId/replyPath"`. So:
- `folderPath` = `p.dirname(file.path!)`
- `folderName` = `p.basename(p.dirname(file.path!))`

But we need to be careful: `p.dirname("providerId/file.txt")` returns `"providerId"`, and `p.basename("providerId")` returns `"providerId"`. That is correct — the "folder" for a root-level file is the provider name.

So the view can derive everything from the existing `File` object. But we still need navigation helpers on the controller.

- [ ] **Step 1: Add `openResultFile` method**

In `lib/src/search/search_controller.dart`, add after `clearSearch()`:

```dart
  void openResultFile(File file) {
    if (file.path == null || file.path!.isEmpty) {
      return;
    }
    Get.toNamed('${FileViewerView.routeName}?path=${file.path}');
  }
```

Need to import `FileViewerView`:
```dart
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
```

- [ ] **Step 2: Add `openResultFolder` method**

Add after `openResultFile`:

```dart
  void openResultFolder(String folderPath) {
    if (folderPath.isEmpty) {
      return;
    }
    Get.toNamed('${FileBrowserView.routeName}?path=$folderPath');
  }
```

Need to import `FileBrowserView`:
```dart
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
```

- [ ] **Step 3: Verify imports and run flutter analyze**

Run: `flutter analyze lib/src/search/search_controller.dart`
Expected: no issues

---

### Task 3: Update SearchView with enriched ListTile

**Files:**
- Modify: `lib/src/search/search_view.dart`

- [ ] **Step 1: Replace the result item builder**

Current code in `search_view.dart` around lines 35-43:

```dart
      body: controller.empty.value ? const Center(child: Column(spacing: 8, children: [Icon(Icons.not_interested, size: 48), Text("no results")])) : ListView.builder(
        itemCount: controller.fileResults.length,
        itemBuilder: (BuildContext context, int index) {
          final item = controller.fileResults[index];

          return ListTile(
            title: Text(item.name ?? '')
          );
        }),
```

Replace with:

```dart
      body: controller.empty.value
          ? const Center(
              child: Column(
                spacing: 8,
                children: [
                  Icon(Icons.not_interested, size: 48),
                  Text('no results'),
                ],
              ),
            )
          : ListView.builder(
              itemCount: controller.fileResults.length,
              itemBuilder: (BuildContext context, int index) {
                final item = controller.fileResults[index];
                final filePath = item.path;
                final folderPath =
                    filePath != null ? p.dirname(filePath) : '';
                final folderName =
                    folderPath.isNotEmpty ? p.basename(folderPath) : '';
                final hasPath = filePath != null && filePath.isNotEmpty;

                return ListTile(
                  title: Text(
                    item.name ?? '',
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: folderName.isNotEmpty
                      ? Text(
                          folderName,
                          overflow: TextOverflow.ellipsis,
                        )
                      : null,
                  onTap: hasPath ? () => controller.openResultFile(item) : null,
                  trailing: hasPath && folderPath.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.folder_open),
                          tooltip: 'Open folder',
                          onPressed: () =>
                              controller.openResultFolder(folderPath),
                        )
                      : null,
                );
              },
            ),
```

Note: `p` was already imported in `search_view.dart`? No, it's not imported in `search_view.dart` — only in `search_controller.dart`. So we need to import it in `search_view.dart` as well. But actually, we might want to keep the path logic in the controller instead, so the view doesn't need the extra import.

Alternative: Add a helper method in the controller that returns folder info. But for simplicity, let's just import `path` in the view. It's a standard package already available.

Wait, looking at the pubspec.yaml, `path` is a transitive dependency via `webdav_client` and maybe Flutter itself. Let me check if it works. Actually `path` is very likely available since `search_controller.dart` already imports it.

So add to `search_view.dart` imports:
```dart
import 'package:path/path.dart' as p;
```

- [ ] **Step 2: Run flutter analyze**

Run: `flutter analyze lib/src/search/search_view.dart`
Expected: no issues

---

### Task 4: Run tests and commit

- [ ] **Step 1: Run flutter analyze**

Run: `flutter analyze`
Expected: no issues

- [ ] **Step 2: Run flutter test**

Run: `flutter test`
Expected: all existing tests pass

- [ ] **Step 3: Commit**

```bash
git add lib/src/search/search_controller.dart lib/src/search/search_view.dart
git commit -m "feat(search): show folder name and enable file/folder navigation from results"
```

---

## Spec Coverage Checklist

| Spec Requirement | Task |
|---|---|
| Parse and expose parent folder path/name | Task 2 (computed in view from existing File.path) |
| Add `openResultFile(File)` | Task 2, Step 1 |
| Add `openResultFolder(String)` | Task 2, Step 2 |
| ListTile title = file name | Task 3, Step 1 |
| ListTile subtitle = folder name | Task 3, Step 1 |
| ListTile onTap opens file viewer | Task 3, Step 1 |
| Trailing folder icon opens file browser | Task 3, Step 1 |
| Truncate long names with ellipsis | Task 3, Step 1 (TextOverflow.ellipsis) |
| Handle null/empty paths gracefully | Task 3, Step 1 (hasPath guards) |
| flutter analyze passes | Task 4, Step 1 |
| flutter test passes | Task 4, Step 2 |

## Self-Review

- **Placeholder scan:** No TBD/TODO placeholders found.
- **Type consistency:** `FileViewerView.routeName` and `FileBrowserView.routeName` are existing static constants (`/view` and `/files`).
- **No new packages:** Uses existing `path` package.
- **Scope focused:** Only two files modified.
