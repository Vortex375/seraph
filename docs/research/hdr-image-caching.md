# HDR photo viewer: restoring image caching for the native photo path

Research into re-adding caching for full-resolution photos now that the gallery
viewer / file viewer feed raw bytes to a native Android `ImageView` platform
view (`HdrPhotoView`) instead of rendering them through Flutter `Image` widgets.
Written 2026-09-20.

## Summary recommendation

| Option | What it reuses | Cache layer | Invalidation story | New deps | Risk |
|---|---|---|---|---|---|
| **A. `dio_cache_interceptor` on the existing dio instances** (recommended first step) | Existing `Dio` stack, auth headers, `_withTokenRecovery`; the library implements the HTTP cache semantics and stores (memory + disk) | Memory (`MemCacheStore`, LRU) now; disk (`FileCacheStore`/Hive/Drift etc.) as an upgrade | Pure RFC 7234 semantics driven by our server's `ETag` + `Last-Modified`; 304 revalidation built in | 1 package (`dio_cache_interceptor`, already dio-5-compatible) | Low. Must raise `MemCacheStore.maxEntrySize` above the default 500 KB or full-res photos are silently not cached |
| **B. `native_dio_adapter` → Cronet** (upgrade path) | `dio` unchanged; Android's own Chromium network stack (HTTP/3, proxies, native HTTP cache) | Cronet disk cache (`CacheMode.disk`) | Cronet honors `Cache-Control`/ETag natively (Chromium semantics) | 1 package (`native_dio_adapter`; pulls `cronet_http`) | Medium: changes the HTTP stack for **all** dio traffic; devices without Play Services need the documented `createFallbackAdapter`; default engine has no cache — must pass `createCronetEngine` |
| **C. `flutter_cache_manager`** (`getSingleFile(url, headers:…)`) | A mature file cache (temp dir + sqflite metadata, `If-None-Match` revalidation) | File (disk) + manager-side metadata | 7-day TTL when no `Cache-Control` (no Last-Modified heuristic); `If-None-Match` when `ETag` stored; stale files refreshed in background | 1 package, but it brings its own `package:http` stack | Medium: full-res fetches leave dio entirely — the 401/403 token-refresh-retry logic would need to be rebuilt on the second client; header-passing API exists but is a parallel fetch path |
| **D. Coil/Glide in the native view** (URL as creation params) | A battle-tested native image pipeline (memory + disk cache, EXIF, downsampling) | Native memory + disk | Native-managed; Glide keys by URL+signature (invalidation is manual); Coil by default always writes to disk cache, `Cache-Control` support is opt-in | Kotlin deps in `android/` | High for this app: auth token lives in Dart; 401/403 mid-session handling requires Dart↔native round trips; inverts the current bytes-as-creation-params architecture |

**Recommendation (short):** Option A restores in-session parity with the old
`ImageCache` behavior with the smallest diff — one interceptor added to the two
dio instances in `GalleryImageLoader` and `FileService` — because our server
already sends `ETag` + `Last-Modified` on every `/dav/p/*` GET, which
`dio_cache_interceptor` uses both to decide cacheability and (via the RFC
7234 §4.2.2 heuristic, 10 % of age-since-Last-Modified) to give a long fresh
window, and to revalidate with `If-None-Match` afterwards. Option B is the
upgrade path to transparent disk caching without any cache-management code in
our repo. Option D is a bigger architectural change and should only be picked
if native downsampling/EXIF handling becomes a requirement. Options A and B are
composable: A for memory now, B later (A's interceptor would need to be removed
from the image Dio when B lands, so they don't double-cache).

---

## Q1. What Flutter's ImageCache actually caches, and why platform-view bytes can't use it

`ImageCache` is an in-memory LRU cache — "up to 1000 images, and up to 100 MB"
(`maximumSize` / `maximumSizeBytes` defaults of `_kDefaultSize = 1000` and
`_kDefaultSizeBytes = 100 << 20`) — whose entries are `ImageStreamCompleter`s
holding **decoded** `ui.Image` data, keyed by `Object` keys produced by
`ImageProvider`s ([flutter/flutter `packages/flutter/lib/src/painting/image_cache.dart`](https://github.com/flutter/flutter/blob/main/packages/flutter/lib/src/painting/image_cache.dart)):

```dart
const int _kDefaultSize = 1000;
const int _kDefaultSizeBytes = 100 << 20; // 100 MiB
...
/// Implements a least-recently-used cache of up to 1000 images, and up to 100
/// MB.
class ImageCache {
  final Map<Object, _PendingImage> _pendingImages = <Object, _PendingImage>{};
  final Map<Object, _CachedImage> _cache = <Object, _CachedImage>{};
```

The entry point is `ImageCache.putIfAbsent(key, loader)`, called from
`ImageProvider.resolve`; a completed entry stores the `ImageStreamCompleter`
with its decoded-image byte size (`sizeBytes = info.sizeBytes`). Nothing in the
cache ever stores raw response bytes; the unit of caching is the decoded image
and the entry point is an `ImageProvider`.

Raw `Uint8List` bytes handed to a platform view via `creationParams` bypass
`ImageProvider` entirely: the platform-view docs show `creationParams` as a
`Map<String, dynamic>` serialized to the native side with
`StandardMessageCodec` at view construction
([flutter.dev, Hosting native Android views](https://docs.flutter.dev/platform-integration/android/platform-views) —
"`creationParams` / `creationParamsCodec` in
`PlatformViewsService.initSurfaceAndroidView` / `AndroidView`"). There is no
`ImageProvider` involved in that flow, so nothing ever enters `ImageCache` —
confirmed in this repo: `HdrPhotoView` takes `bytes` and passes them as
creation params (`lib/src/gallery/hdr_photo_view.dart:36-58`), and the bytes
come from fresh dio GETs with no cache
(`lib/src/gallery/gallery_image_loader.dart:103-110` — `fullResolution`, whose
class doc states "Full-resolution images are deliberately NOT cached";
`lib/src/file_browser/file_service.dart:161-188` — `fetchFileBytes`).

Consequence: the old Flutter-path behavior "page back and the decoded photo is
still in `ImageCache`, no re-download" cannot be had for free under the
platform-view path; caching must happen on the HTTP layer (or in the native
view).

## Q2. `dio_cache_interceptor`

Package: [pub.dev/packages/dio_cache_interceptor](https://pub.dev/packages/dio_cache_interceptor),
v4.0.7, published 2026-06-26 by verified publisher `cow-level.ovh`, Apache-2.0,
Dart SDK (runs on all platforms incl. web), ~230k weekly downloads, depends on
`dio ^5.2.0+1` and `http_cache_core ^1.1.4`. **Compatible with dio 5.x** (the
constraint is `^5.2.0+1`; our app pins `dio: ^5.7.0`,
`app/seraph_app/pubspec.yaml:13`). Null-safe, Dart 3-era, actively maintained
(released 2 months ago; upstream repo
[llfbandit/dart_http_cache](https://github.com/llfbandit/dart_http_cache) has
~156 stars and 1 open issue).

**RFC 7234 behavior.** The README lists implemented HTTP directives: cache
triggers `ETag` / `Last-Modified` / `Date`; freshness `Age`, `Date`, `Expires`,
`max-age`, `max-stale`, `min-fresh`, `must-revalidate`; commutators `no-cache`
/ `no-store`
([README, pub.dev](https://pub.dev/packages/dio_cache_interceptor)). The
strategy code ([`http_cache_core/lib/src/model/cache/cache_strategy.dart`](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/model/cache/cache_strategy.dart))
implements conditional revalidation: "If-None-Match takes precedence over
If-Modified-Since (RFC 7232 §6)"; on a stale-but-cached response it sends
`If-None-Match: <etag>` if an ETag was stored, else `If-Modified-Since` from
`Last-Modified`, else from `Date`. The README example shows exactly the
integrated behavior: "Requesting with global options => status(304 => 200) =>
Content is read from cache store." (304s are transparently turned into cached
200s by the interceptor.)

**What happens with NO cache headers** (the important question for us): a
response is only stored if it carries at least one cache directive —
[`_hasCacheDirectives`](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/model/cache/cache_strategy.dart)
returns true only if the response has `ETag`, `Last-Modified`, `Expires`, or
`max-age`. **A response with none of those is not cached at all** (no
time-based fallback beyond that). But if `Last-Modified` *is* present, it
implements RFC 7234 §4.2.2 heuristic freshness —
[`_computeFreshnessLifetime`](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/model/cache/cache_response.dart)
returns "10% of the document's age at the time it was served" (explicitly
citing the RFC, applied only to query-less URLs):

```dart
if (lastModified != null && Uri.parse(url).query.isEmpty) {
  // As recommended by the HTTP RFC, the max age of a document
  // should be defaulted to 10% of the document's age
  ...
  return ((delta > 0) ? delta / 10 : 0).round();
}
```

So: header-less → nothing cached; `Last-Modified` but no `Cache-Control` →
stored and served fresh for 10 % of (Date − Last-Modified), then revalidated
with `If-None-Match`/`If-Modified-Since`.

**Request options** ([`CacheOptions` source](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/model/cache/cache_options.dart),
[README](https://pub.dev/packages/dio_cache_interceptor)): `store` (required),
`policy` (default `CachePolicy.request`; also `refresh`, `forceCache`,
`refreshForceCache`, `noCache`), `hitCacheOnErrorCodes`,
`hitCacheOnNetworkFailure` (serve cache offline), `maxStale` (override TTL for
server-less-config, "Useful only when origin server has no cache config"),
`priority`, `cipher`, `keyBuilder`, `allowPostMethod`. The default
`keyBuilder` derives the cache key from the **URL only** (`_uuid.v5(Namespace.url.value, url.toString())`
— [cache_options.dart](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/model/cache/cache_options.dart)),
so rotating bearer tokens do not fragment the cache.

**Stores** (README "Stores" section): `MemCacheStore` ("Volatile cache with LRU
strategy"), `BackupCacheStore` (primary+secondary), and separately-published
persistent stores — `FileCacheStore` ([`http_cache_file_store`](https://pub.dev/packages/http_cache_file_store)),
`HiveCacheStore` (`hive_ce`), `IsarCacheStore`, `ObjectBoxCacheStore`,
`SembastCacheStore`, `MMKVCacheStore` (Android/iOS), `DriftCacheStore`
([`http_cache_drift_store`](https://pub.dev/packages/http_cache_drift_store) —
notable because the app already uses Drift for the mirror DB).

**One trap for our use case:** `MemCacheStore` defaults are
`maxSize = 7340032` (7 MB) and `maxEntrySize = 512000` (500 KB), and entries
larger than `maxEntrySize` are **silently not stored** ([`mem_cache_store.dart`](https://github.com/llfbandit/dart_http_cache/blob/master/http_cache_core/lib/src/store/mem_cache_store.dart):
"Entry too heavy, skip it"). Full-resolution JPEGs are typically several MB, so
the store must be constructed with raised limits
(`MemCacheStore(maxSize: …, maxEntrySize: …)`), or with a persistent store for
the photo path. With the right sizes this is actually *cheaper* than the old
Flutter path: `ImageCache` held the **decoded** image (~width×height×4 bytes —
a 12 MP photo ≈ 48 MB), while the interceptor holds the **encoded** file bytes.

**With our server's headers:** every `/dav/p/*` GET response has `ETag` +
`Last-Modified` and no `Cache-Control` (see Q7), so `dio_cache_interceptor`
will cache it, serve it fresh for 10 % of the file's age (a photo modified 1
year ago ⇒ ~36 days of freshness; a file modified 10 minutes ago ⇒ 1 minute),
and after staleness revalidate with `If-None-Match` — which our
`golang.org/x/net/webdav` handler + `http.ServeContent` answers correctly with
304. Net effect: paging back to a photo within a session is a pure memory hit;
token-refresh-retry logic in `_get`/`_withTokenRecovery` keeps working because
the interceptor sits under it.

## Q3. `flutter_cache_manager`

Package: [pub.dev/packages/flutter_cache_manager](https://pub.dev/packages/flutter_cache_manager),
v3.4.5, published 2026-09-19 (yesterday at time of writing) by verified
publisher `baseflow.com`, 1.9k likes, 3.83M downloads. Actively maintained and
null-safe.

**How it caches** (README FAQ): files go into the app's temp directory (OS may
purge); metadata lives in **sqflite** on Android/iOS/macOS, a JSON file
elsewhere. Eviction by `maxNrOfCacheObjects` (LRU-by-last-use) and `stalePeriod`
(default **30 days** — [`_config_io.dart`](https://github.com/Baseflow/flutter_cache_manager/blob/main/flutter_cache_manager/lib/src/config/_config_io.dart):
`stalePeriod = stalePeriod ?? const Duration(days: 30)`).

**Revalidation / TTL** ([`lib/src/web/file_service.dart`](https://github.com/Baseflow/flutter_cache_manager/blob/main/flutter_cache_manager/lib/src/web/file_service.dart)):
"Without a cache-control header we keep the file for a week"
(`ageDuration = const Duration(days: 7)`); `max-age=…` honored, `no-cache` ⇒
`Duration.zero`. There is **no Last-Modified heuristic** and no
`If-Modified-Since`; the only validator used is `ETag` —
[`web_helper.dart`](https://github.com/Baseflow/flutter_cache_manager/blob/main/flutter_cache_manager/lib/src/web/web_helper.dart)
adds `if-none-match` with the stored ETag on background refreshes (skipped on
web for CORS): 

```dart
// Adding `if-none-match` header on web causes a CORS error.
if (etag != null && !kIsWeb) {
  headers[HttpHeaders.ifNoneMatchHeader] = etag;
}
```

`getSingleFile` / `getFileStream` **always return the cached file immediately**
and only then check validity and refresh in the background (README FAQ "When
are the cached files updated?"). Both accept arbitrary extra headers
(`getSingleFile(url, headers: …)`), so authenticated requests are possible —
but they ride `flutter_cache_manager`'s own `HttpFileService` on
`package:http ^1.6.0`, *not* dio. Using it for full-res photos would mean a
second, parallel HTTP stack where our 401/403 force-refresh-and-retry
(`file_service.dart:68-79`) does not exist and would have to be reimplemented
as a custom `FileService`.

**With our server's headers:** `/dav/p/*` sends `ETag` + `Last-Modified`, no
`Cache-Control` ⇒ validTill = 7 days, revalidation via stored `ETag` only. It
would work, but it duplicates fetch plumbing that `dio_cache_interceptor` (Q2)
gets by decoration of the dio instance we already use.

## Q4. True platform HTTP stacks from Dart

### cronet_http (Android)

[pub.dev/packages/cronet_http](https://pub.dev/packages/cronet_http) (v1.9.0,
2026-06-23, published by `dart.dev` — first-party): "An Android Flutter plugin
that provides access to the Cronet HTTP client." Its motivation lists, versus
"the socket-based `dart:io HttpClient`": platform features (proxies),
**"It supports configurable caching"**, and HTTP/3.

- Cache configuration: `CronetEngine.build(cacheMode: CacheMode.memory |
  CacheMode.disk | CacheMode.diskNoHttp | CacheMode.disabled, cacheMaxSize: …)`
  — [`CacheMode` API docs](https://pub.dev/documentation/cronet_http/latest/cronet_http/CacheMode.html),
  README example builds `CronetEngine.build(cacheMode: CacheMode.memory, cacheMaxSize: 2 * 1024 * 1024)`
  and wraps it in `CronetClient.fromCronetEngine(engine)`. Cronet *is* Chromium's
  network stack, so its HTTP cache implements standard `Cache-Control`/validator
  semantics natively ([Cronet reference](https://developer.android.com/guide/topics/connectivity/cronet/reference/org/chromium/net/package-summary)).
- **GMS vs embedded:** by default the package "depends on Google Play Services
  for its Cronet implementation"; devices without it can use embedded Cronet by
  setting `--dart-define=cronetHttpNoPlay=true` ("Use embedded Cronet", README) —
  at the cost of bundling the Cronet library (tens of MB in the APK).
- **dio integration:** `cronet_http` itself only exposes a `CronetClient`
  implementing `package:http` `Client` — there is no documented direct dio
  path in that package. The documented path is **`native_dio_adapter`**
  ([pub.dev/packages/native_dio_adapter](https://pub.dev/packages/native_dio_adapter),
  v1.8.0 2026-07-29, from the dio org): `dio.httpClientAdapter = NativeAdapter();`
  uses `cronet_http` on Android and `cupertino_http` on iOS/macOS, deps
  `dio ^5.4.0`, `cronet_http ^1.9.0`. Its `createCronetEngine` hook accepts a
  caller-built engine, so the cache is configurable:
  ([native_adapter.dart source](https://github.com/cfug/dio/blob/main/plugins/native_dio_adapter/lib/src/native_adapter.dart))

```dart
NativeAdapter(createCronetEngine: () => CronetEngine.build(
  cacheMode: CacheMode.disk, cacheMaxSize: 100 * 1024 * 1024))
```

- **Known sharp edges** (all documented in the package itself): devices
  without Play Services can have all Cronet providers disabled and
  `CronetEngine.build()` throws for *every* request — the opt-in
  `createFallbackAdapter: (…) => IOHttpClientAdapter()` exists for exactly
  this ([README](https://pub.dev/packages/native_dio_adapter),
  [dio#2444](https://github.com/cfug/dio/issues/2444)); the adapter lagged
  `cronet_http` 1.9.0 briefly ([dio#2581](https://github.com/cfug/dio/issues/2581)),
  resolved by the cfug/dio release that upgraded to `cronet_http 1.9.0`.
  Switching adapters changes TLS/proxy/HTTP2 behavior globally (README note).
  Since the Cronet cache applies to everything dio sends, API JSON responses
  would also enter the cache — harmless with a server that controls headers,
  but a behavioral change to be aware of.

### cupertino_http (iOS, optional)

[pub.dev/packages/cupertino_http](https://pub.dev/packages/cupertino_http) /
[README](https://github.com/dart-lang/http/blob/master/pkgs/cupertino_http/README.md):
wraps Apple's URL Loading System; `URLSessionConfiguration..cache = URLCache.withCapacity(…)`
configures `URLCache`. NativeAdapter wires it automatically on iOS/macOS.
iOS has no HDR path in this app (`hdr_photo_view.dart:21`), so this is only
relevant if the same cache should cover the Flutter-rendered path there.

### dart:io HttpClient vs Android's stock HTTP cache

**Confirmed.** The Android platform response cache,
`android.net.http.HttpResponseCache`, documents itself as a cache for
`HttpURLConnection`/`HttpsURLConnection` — "there is no platform-provided
cache for `DefaultHttpClient` or `AndroidHttpClient`"
([Android API reference](https://developer.android.com/reference/android/net/http/HttpResponseCache)).
Dart's `HttpClient` does not go through `java.net.HttpURLConnection` at all: it
is Dart's own socket-based implementation — the first-party `cronet_http`
readme makes exactly this point: advantages over "the socket-based
[dart:io HttpClient](https://api.dart.dev/stable/dart-io/HttpClient-class.html)
implementation" include caching, proxies, HTTP/3
([cronet_http README](https://pub.dev/packages/cronet_http), same wording in
the [`native_dio_adapter` README](https://pub.dev/packages/native_dio_adapter)).
The Dart team's own tracker shows `dart:io` HttpClient doing no client-side
caching of ETag responses — [dart-lang/sdk#34966](https://github.com/dart-lang/sdk/issues/34966)
("My Web Server returns an ETag, so a client might want to cache the response"
— closed as not planned, no caching feature added). The `package:http` choice
table confirms `IOClient` (the `dart:io` stack) has no Caching column check
([pub.dev/packages/http](https://pub.dev/packages/http) — "Caching ❌").
**Confirmed: Dart HTTP bypasses Android's `HttpResponseCache` entirely.**

## Q5. Native Android image loaders (Coil / Glide) instead of bytes-as-creation-params

The alternative architecture: pass `url` + auth headers as creation params and
let the native `ImageView` load via Coil/Glide, inheriting native memory+disk
caching, EXIF rotation and downsampling.

**Coil** ([docs](https://coil-kt.github.io/coil/)):
- Caching: memory cache + disk cache are core; `ImageLoader` "executes
  incoming ImageRequests by fetching, decoding, caching, and returning the
  result" ([Getting Started](https://coil-kt.github.io/coil/getting_started/)).
  Notable: "By default, Coil 3.x does not respect `Cache-Control` headers and
  always saves a response to its disk cache"; optional
  `coil-network-cache-control` adds `CacheControlCacheStrategy` for
  header-driven caching ([Network Images](https://coil-kt.github.io/coil/network/)).
- Per-request headers are a first-class API: `ImageRequest.Builder.httpHeaders(headers)`
  (`NetworkHeaders`), or an OkHttp `Interceptor` on the `callFactory` for every
  request ([Network Images → Headers](https://coil-kt.github.io/coil/network/)).
- Request rewriting / auth handling would go through a Coil `Interceptor`
  (`coil3.intercept.Interceptor`), documented for transforming requests
  ([Recipes → Transforming Requests](https://coil-kt.github.io/coil/recipes/)).
- Preload writes to "the disk and memory caches" ([FAQ](https://coil-kt.github.io/coil/faq/)).

**Assessment against our flow:**
- *Headers:* easy — headers are per-request (`httpHeaders()`), and the cache
  key is derived from the data (URL), not the auth header, so token rotation
  does not fragment the cache (same property as dio_cache_interceptor's URL-only
  default key).
- *Token expiry (401/403):* this is the real cost. The token and the
  refresh-retry logic live in Dart (`LoginController.refreshTokenIfNeeded(force: true)`
  driven by `_withTokenRecovery` in `gallery_image_loader.dart:148-159` and
  `file_service.dart:68-79`). Under Coil/Glide, a native fetch that 401s must
  reach back into Dart (MethodChannel round-trip) to force-refresh and retry,
  or Dart must push fresh tokens into the native view on every refresh. The
  current design avoids this precisely because bytes are fetched *in Dart*
  where token recovery is one `try/catch` away.
- *Lifecycle/architecture change:* the native side moves from "decode a byte
  array in `onCreate`" to "issue a network load with headers, handle
  errors/timeouts, handle token callbacks" — plus Coil 3 needs an
  artifact-specific networking engine (`coil-network-okhttp` etc.,
  [Getting Started → Artifacts](https://coil-kt.github.io/coil/getting_started/)).
  That's a substantially larger change than adding an HTTP-layer cache,
  touching the platform channel contract and `android/` code (which also means
  the APK build gate applies).

**Glide** ([caching docs](https://bumptech.github.io/glide/doc/caching.html)):
four cache layers (active resources, memory cache, resource disk cache, data
disk cache), all LRU; cache keys built from the model (URL) — and invalidation
is *deliberately keyed on the URL/`Signature`*, not HTTP validators: "In
practice, the best way to invalidate a cache file is to change your identifier
when the content changes". Dynamic request headers require a
`GlideUrl`+`LazyHeaders` `ModelLoader` setup. Glide's disk cache is a
content cache, not an RFC 7234 HTTP cache — stale photos would need manual
`signature()` invalidation. Same Dart-side token problem as Coil, so it does
not score better than Coil for our auth model.

## Q6. HTTP semantics primer (what makes a cache work with no client policy)

A cache needs (a) permission/ability to *store*, and (b) either a *freshness
lifetime* or a *validator* to *reuse*:

- **Store:** `Cache-Control: max-age=N` (explicit freshness), `Expires` (old
  style), or — in the absence of any — validators `ETag` / `Last-Modified`
  which at minimum allow conditional revalidation (client sends
  `If-None-Match` / `If-Modified-Since`, server answers `304 Not Modified` and
  the client reuses its copy). RFC 7234 §4.2.2 additionally *allows* caches to
  invent freshness from `Last-Modified` ("10% of the interval since the
  Last-Modified time") when no explicit lifetime is given
  ([RFC 7234 §4.2.2](https://datatracker.ietf.org/doc/html/rfc7234#section-4.2.2);
  background explainer: [Calvano, HTTP Heuristic Caching](https://paulcalvano.com/2018-03-14-http-heuristic-caching-missing-cache-control-and-expires-headers-explained/)).
  Chromium/Firefox implement exactly the 10 % heuristic.
- **`no-cache`** = store but always revalidate; **`no-store`** = never store.

**What Go servers emit:** [`http.ServeContent`](https://pkg.go.dev/net/http#ServeContent)
— used by our WebDAV path (Q7) — "handles Range requests properly, sets the
MIME type, and handles If-Match, If-Unmodified-Since, If-None-Match,
If-Modified-Since, and If-Range requests"; **"If modtime is not the zero time
or Unix epoch, ServeContent includes it in a Last-Modified header"**; and
"**If the caller has set w's ETag header** formatted per RFC 7232 §2.3,
ServeContent uses it to handle requests using If-Match, If-None-Match, or
If-Range." So: **Last-Modified is automatic; ETag only if the handler sets
it.** `ServeContent` never sets `Cache-Control` — without an explicit
`w.Header().Set("Cache-Control", …)` a Go handler serves validators only, and
clients fall back to heuristic freshness.

## Q7. What our server actually sends for full-res images

Full-res photos are served by the api-gateway's WebDAV module: the Flutter app
requests `GET /dav/p/<providerId><path>`
(`lib/src/gallery/gallery_media.dart:36-42`, `fullResolution()`;
`lib/src/file_browser/file_service.dart:149-154`, `getFileUrl()` →
`$serverUrl/dav/p$path`). Server side:

- The handler is `golang.org/x/net/webdav.Handler` with prefix `/dav`
  (`api-gateway/webdav/webdav.go:102-107`, module pins `golang.org/x/net v0.57.0`
  per `api-gateway/go.mod`).
- `GET/HEAD` goes through `handleGetHeadPost`
  ([x/net@v0.57.0 `webdav/webdav.go`, lines 222-240](https://cs.opensource.google/go/go/+/master:golang.org/x/net/webdav/webdav.go)):
  ```go
  etag, err := findETag(ctx, h.FileSystem, h.LockSystem, reqPath, fi)
  ...
  w.Header().Set("ETag", etag)
  // Let ServeContent determine the Content-Type header.
  http.ServeContent(w, r, reqPath, fi.ModTime(), f)
  ```
  i.e. **ETag is always set** — `findETag`
  ([`webdav/prop.go:450-458`](https://cs.opensource.google/go/go/+/master:golang.org/x/net/webdav/prop.go))
  falls back to `fmt.Sprintf(`"%x%x"`, fi.ModTime().UnixNano(), fi.Size())`
  (mtime+size, Apache-style) — and **Last-Modified is set automatically** by
  `http.ServeContent` from `fi.ModTime()` (Q6). Conditional requests are
  answered natively: `ServeContent` implements `If-None-Match`/`If-Modified-Since`.
- **No `Cache-Control` is sent on `/dav/*`**: repo-wide grep for
  `Cache-Control` in Go code finds only
  `api-gateway/preview/preview.go:223` (`"Cache-Control": "max-age=604800"` on
  the *thumbnail* `/preview` endpoint via `DataFromReader`),
  `api-gateway/search/search.go:84` and `api-gateway/gateway/gateway.go:126`
  (`no-cache` on `/search`, `/app/index.html`), and the
  `cachecontrol.NoCachePreset` middleware applied only to `/api` and
  `/public-api` groups (`gateway/gateway.go:116-119`). Nothing touches the
  `/dav` route (`webdav.go` installs only auth + request-scoped resolve caches,
  lines 108-132 — the "CacheMiddleware" there is a per-request space/share
  *resolve* cache, unrelated to HTTP caching).

**Net: our full-res responses are `ETag` + `Last-Modified` + no `Cache-Control`.**
That means: (a) they are cacheable by any RFC-7234-aware client (validator
present), (b) freshness must come from the heuristic (10 % of age since
Last-Modified — the file's mtime, so typically large for photos), (c) any
client can revalidate cheaply with 304s, and (d) a plain-TTL cache like
`flutter_cache_manager` uses its 7-day fallback. Setting
`Cache-Control: max-age=…` on the `/dav` GET path in the gateway (one line, e.g.
next to `preview.go:223`) would make *every* client (Cronet, Flutter web
browser, Coil) behave deterministically and is the cheapest server-side
complement to any option below.

## Recommendation

**Restore in-session caching (parity with old `ImageCache`) with least
own-code: Option A — `dio_cache_interceptor` on the existing dio instances.**

1. Add `dio_cache_interceptor` to `GalleryImageLoader.dio`
   (`gallery_image_loader.dart:51`) and `FileService.dio`
   (`file_service.dart:37`) with `MemCacheStore(maxSize: …, maxEntrySize: …)`
   sized above one full-res photo, and keep the default `CachePolicy.request`.
   Because the default cache key is the URL alone
   (`defaultCacheKeyBuilder`), and the server answers validators with 304s
   (Q6/Q7), paging back to a photo in a session is a zero-network hit, and a
   stale entry revalidates with `If-None-Match` → 304 — all semantics owned by
   the library, none hand-rolled. It also composes with the existing
   401/403-refresh-retry code instead of replacing it, and
   `hitCacheOnNetworkFailure: true` can even buy back the thumbnails-style
   offline behavior for full-res photos. Keep `fullResolution`'s documented
   "not cached" comment in sync when doing this.
   *Caveat to verify during implementation:* `MemCacheStore` silently drops
   entries over `maxEntrySize` (default 500 KB — Q2), so the defaults would be
   a no-op for photos; size the store explicitly.
2. **Server-side enabler (optional but high leverage):** add
   `Cache-Control: max-age=<n>` (e.g. 1 day) to `/dav` GET responses in the
   gateway so behavior no longer depends on the Last-Modified heuristic and
   matches what `/preview` already does (`preview.go:222-224`).
3. **Upgrade path to disk caching, in order of least own-code:**
   - A-persistent: swap `MemCacheStore` for `FileCacheStore`
     (`http_cache_file_store`) / `HiveCacheStore` / `DriftCacheStore`
     (drift is already an app dependency) — README "Stores" list (Q2). Same
     invalidation semantics, disk-backed.
   - Or B: `native_dio_adapter` with
     `createCronetEngine: () => CronetEngine.build(cacheMode: CacheMode.disk, …)`
     — Chromium's own disk cache handles freshness/revalidation for all dio
     traffic; requires handling the no-Play-Services fallback and accepting
     that it applies to all dio traffic (Q4).
4. **Skip for now:** Coil/Glide-in-the-native-view (Q5) — it brings native
   disk+memory caches "for free" but moves auth/retry across the Dart/native
   boundary and restructures the `HdrPhotoView` contract; reconsider only if
   native downsampling/EXIF handling for non-HDR photos becomes a goal.
   `flutter_cache_manager` (Q3) is also not preferred here: it drags in a
   second HTTP stack beside dio and its revalidation is ETag-only with a flat
   7-day TTL.

What was skipped: measuring actual `max-age` value choices and cache sizes —
pick from a profiling pass; add when numbers exist.