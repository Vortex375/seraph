# Flutter Search Enhancement Design

**Date:** 2026-05-01

**Status:** Approved in brainstorming session

**Approach:** A — Enhanced ListTile (Material-Native, Minimal)

## Goal

Improve the Flutter app's search results screen so each result clearly shows both the file name and its containing folder, and so the user can interactively open either the file itself or the folder that contains it.

## Scope

- Modify `lib/src/search/search_controller.dart` to parse and expose a parent folder path and name for every search result.
- Add `openResultFile(File)` and `openResultFolder(String)` methods to `MySearchController`.
- Modify `lib/src/search/search_view.dart` to render each result as a `ListTile` with:
  - `title` — file name (tapping the row opens the file viewer)
  - `subtitle` — immediate parent folder name
  - `trailing` — a folder icon button that opens the containing folder in the file browser
- Ensure that opening a search result file directly works even when the user did not navigate through the file browser first (the file viewer's fallback `stat` path must be supported).

## Non-Goals

- Changing the search backend API or SSE protocol.
- Adding true two-column table layout (per selected Approach A).
- Adding file-type icons, previews, or thumbnails to search results.
- Adding selection, multi-select, or share actions to search results.
- Adding sorting or filtering of search results.

## Affected Components

| File | Change |
|------|--------|
| `lib/src/search/search_controller.dart` | Add folder path/name extraction; add navigation helpers |
| `lib/src/search/search_view.dart` | Replace bare `ListTile(title: Text(...))` with enriched `ListTile` |

## Data Flow / Changes

### Folder Path Extraction

The search service returns a stream of JSON objects. Each file hit contains `providerId` and `path` (the full file path on that provider). The controller currently constructs a `File` object as:

```dart
File(
  path: "${reply["providerId"]}/${reply["path"].toString()}",
  name: p.basename(reply["path"].toString())
)
```

We will compute alongside it:

- `folderPath` — the directory portion of the full path (`providerId/dirname(reply["path"])`)
- `folderName` — `p.basename(dirname(reply["path"]))`, or the `providerId` when the file sits at the provider root

### Navigation Helpers

Two new methods on `MySearchController`:

1. **`void openResultFile(File file)`**
   - Calls `Get.toNamed('/view?path=${file.path}')`.
   - The existing `FileViewerController.onInit` already handles the case where `initialIndex == -1` (i.e. the user navigated directly rather than from the file browser) by reading `Get.parameters['path']`, calling `fileService.stat(path)`, overriding `file.path`, and adding the single file to `files`. No changes to `FileViewerController` are required.

2. **`void openResultFolder(String folderPath)`**
   - Calls `Get.toNamed('/files?path=$folderPath')`.
   - The existing `FileBrowserView` page factory resets `FileBrowserController.path` from `Get.parameters['path']` and reloads the directory. No changes to `FileBrowserController` or `FileBrowserView` are required.

Both methods must gracefully handle possible null or empty strings.

## UI Changes

### SearchView Result ListTile

Each item becomes:

```dart
ListTile(
  title: Text(item.name ?? '', overflow: TextOverflow.ellipsis),
  subtitle: Text(folderName, overflow: TextOverflow.ellipsis, style: TextStyle(...)),
  onTap: () => controller.openResultFile(item),
  trailing: IconButton(
    icon: const Icon(Icons.folder_open),
    tooltip: 'Open folder',
    onPressed: () => controller.openResultFolder(folderPath),
  ),
)
```

- The entire row is tappable and opens the file viewer.
- The folder icon button is the dedicated action for opening the parent folder.
- Long folder names are truncated with ellipsis so the row stays single-line.

## Error Handling

- If a search result has an empty or null `path`, the `ListTile` is rendered without `onTap` and the folder button is disabled.
- If `stat` fails when opening a file directly, the file viewer already shows its generic error state.
- If the folder path is invalid or the user lacks access, the file browser already shows its generic error state.

## Testing

- `flutter analyze` must pass.
- `flutter test` must continue to pass (the project currently has no search-specific tests).
- No new test files are added for this minimal UI enhancement (keeping scope focused), but the existing tests must not regress.

## Implementation Notes

- Keep changes localized strictly to the two search files.
- Follow existing GetX navigation patterns and existing `FileBrowserController`/`FileViewerController` conventions.
- Do not introduce new packages.
- The `path` package is already imported in `search_controller.dart` (`import 'package:path/path.dart' as p;`).
