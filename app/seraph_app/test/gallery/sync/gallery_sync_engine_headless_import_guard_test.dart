import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard test for the headless sync engine's import graph.
///
/// [GallerySyncEngine] (`lib/src/gallery/sync/gallery_sync_engine.dart`) is
/// meant to run in a background isolate after the UI isolate is killed. That
/// means its transitive import graph must not reach the Flutter UI framework
/// (`package:flutter/material.dart`, `package:flutter/widgets.dart`,
/// `package:flutter/cupertino.dart`) or GetX (`package:get/`): those pull in
/// widget-tree bindings, `GetxController` lifecycle hooks and
/// `package:flutter/material.dart` itself, none of which exist in a bare
/// Dart isolate.
///
/// This used to be enforced by construction - ticket 22's engine had no path
/// to any of that - but a later refactor co-located the abstract
/// [GalleryUploadBackend] interface and the concrete
/// `WebDavGalleryUploadBackend` (which DOES reach `FileService` →
/// `LoginController` → GetX → material) in the SAME file
/// (`gallery_upload_backend.dart`). The engine imported that file for the
/// interface alone, so the constraint survived only at runtime: the isolate
/// entrypoint never instantiated the concrete class. A future edit could have
/// re-coupled the two and broken headlessness without any test or build
/// failing.
///
/// Ticket 25's follow-up split the file. THIS test is what makes the split
/// survive: it walks the engine's transitive `package:seraph_app/...` imports
/// (resolving conditional imports to their non-`dart:io` branch, matching the
/// web build - the build gate) and asserts none of them import the Flutter UI
/// framework or GetX.
///
/// `package:flutter/services.dart` (platform channels) and
/// `package:flutter_secure_storage/` are intentionally NOT flagged here: they
/// are supported in background isolates on Android and do not pull in the
/// widget tree. The vector this guard exists to catch is GetX and
/// `flutter/material.dart` - the things that actually break a headless run.

/// Import directives we treat as forbidden anywhere in the engine's
/// transitive closure. A file matching any of these breaks headlessness.
final _forbiddenImportPatterns = <RegExp>[
  RegExp(r"import\s+'package:get/"),
  RegExp(r"import\s+'package:flutter/material\.dart'"),
  RegExp(r"import\s+'package:flutter/widgets\.dart'"),
  RegExp(r"import\s+'package:flutter/cupertino\.dart'"),
];

/// The engine file whose transitive import graph we are guarding.
final _engineFile = File('lib/src/gallery/sync/gallery_sync_engine.dart');

/// Matches a single `import` or `export` directive and captures the URI.
///
/// Handles plain imports (`import 'foo.dart';`), aliased conditional imports
/// (`import 'a.dart' if (cond) 'b.dart' as impl;`) and exports. The first
/// capture group is the default URI; the second is the conditional URI (or
/// null).
final _importRegex = RegExp(
  r"""(?:import|export)\s+['"]([^'"]+)['"](?:\s+if\s*\([^)]+\)\s*['"]([^'"]+)['"])?""",
);

/// Resolves a `package:seraph_app/...` URI to a file path under `lib/`.
/// Returns null for any URI that is not a `package:seraph_app` import (those
/// are third-party packages - checked separately, not walked).
String? _resolveSeraphImport(String uri) {
  const prefix = 'package:seraph_app/';
  if (!uri.startsWith(prefix)) {
    return null;
  }
  return 'lib/${uri.substring(prefix.length)}';
}

/// For a conditional import `import 'a' if (dart.library.io) 'b'`, returns
/// the URI that the WEB build resolves to (the one that is actually compiled
/// when `dart:io` is unavailable): the default `a`, never the `dart.library.
/// io` branch `b`. For non-conditional imports, returns the single URI.
String _webBranch(String defaultUri, String? conditionalUri) {
  // The only conditional import in the engine's graph is
  // `local_source.dart`'s `if (dart.library.io) 'local_source_io.dart'`,
  // which selects `local_source_unsupported.dart` on the web. We always take
  // the default (non-io) branch: the web build is the build gate, and the
  // web build's closure is the one that must stay Flutter-UI-free.
  return defaultUri;
}

/// Walks the transitive import graph of [rootFile], collecting every
/// `package:seraph_app/...` file reachable via `import`/`export` directives.
/// Conditional imports are resolved to their web (non-`dart:io`) branch.
Set<File> _transitiveSeraphFiles(File rootFile) {
  final visited = <File>{};
  final queue = <File>[rootFile];

  while (queue.isNotEmpty) {
    final file = queue.removeLast();
    if (!visited.add(file)) {
      continue;
    }
    if (!file.existsSync()) {
      continue;
    }
    final source = file.readAsStringSync();
    for (final match in _importRegex.allMatches(source)) {
      final defaultUri = match.group(1)!;
      final conditionalUri = match.group(2);
      final resolvedUri = _webBranch(defaultUri, conditionalUri);
      final path = _resolveSeraphImport(resolvedUri);
      if (path != null) {
        queue.add(File(path));
      }
    }
  }
  return visited;
}

void main() {
  test(
    'GallerySyncEngine transitive imports contain no GetX or Flutter UI '
    'framework references (headless-isolate guard)',
    () {
      final files = _transitiveSeraphFiles(_engineFile);

      // Sanity: the walk actually reached the files we care about. If this
      // ever fails, the graph walker is broken and the guard is useless.
      expect(
        files.any((f) => f.path.endsWith('gallery_upload_backend.dart')),
        true,
        reason: 'import graph walker did not reach gallery_upload_backend.dart '
            '- the guard is not exercising the file the split was for',
      );
      expect(
        files.any((f) => f.path.endsWith('gallery_sync_engine.dart')),
        true,
        reason: 'import graph walker did not reach the engine file itself',
      );

      final violations = <String>[];
      for (final file in files) {
        final source = file.readAsStringSync();
        for (final pattern in _forbiddenImportPatterns) {
          if (pattern.hasMatch(source)) {
            violations.add(
              '${file.path}: matches ${pattern.pattern}',
            );
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'GallerySyncEngine (a headless, background-isolate class) must not '
            'transitively import GetX or the Flutter UI framework. The '
            'following files in its import graph violate that:\n'
            '${violations.join('\n')}\n\n'
            'This breaks headlessness: the engine runs in an isolate after the '
            'UI isolate is killed, and GetxControllers / widget-tree bindings '
            'do not exist there. If you added one of these imports, move the '
            'concrete (UI-coupled) type to a separate file that only the UI '
            'wiring imports - see webdav_gallery_upload_backend.dart for the '
            'pattern established by the ticket-25 follow-up split.',
      );

      // Belt-and-suspenders: the specific regression this guard was created
      //for - the abstract and concrete upload backends co-located in one file
      // that the engine imports - would show up as the engine's closure
      // reaching file_service.dart. Assert it does not.
      expect(
        files.any((f) => f.path.endsWith('file_browser/file_service.dart')),
        false,
        reason: 'GallerySyncEngine transitively imports FileService, which '
            'pulls in LoginController (a GetxController). This is the exact '
            'regression the abstract/concrete backend split exists to '
            'prevent - the concrete WebDavGalleryUploadBackend belongs in '
            'webdav_gallery_upload_backend.dart, imported only by '
            'initial_binding.dart.',
      );
    },
  );
}
