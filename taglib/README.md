SWIG wrapper for TagLib 2.x, generated against the TagLib headers in
`/usr/include` (Debian 13 ships TagLib 2.0.2 as `libtag-dev`; it also builds
against 2.3.x).

To regenerate the wrapper after editing `taglib.i` (needs `swig` and the TagLib
dev headers):

```
make
```

The cgo build flags live in `cgo.go`, not in the generated `taglib.go`, so the
generated files need no manual edits.

Notes for callers:

- Read binary data with `ByteVector.Bytes()`, not `Data()`: SWIG converts the
  `char*` returned by `data()` with `strlen`, which truncates at the first NUL.
- Use `String.ToCString(true)` for UTF-8; `ToCString()` returns Latin-1.
- Objects returned by value (e.g. `Tag().Title()`) are allocated by the
  wrapper and must be freed (`DeleteString`, `DeleteVariant`, ...). There
  are no finalizers: whatever is not deleted leaks.
- `ReadTags(ref)` and `Pictures(ref)` read a file's tags and embedded pictures
  with every intermediate object freed; prefer them over hand-written reads.
- Delete a `FileRef` before the `WebdavFileStream` it reads from: the
  `FileRef` does not own the stream. `stream.Delete()` also closes the file.
- `FileRef.AudioProperties()` is null (`Swigcptr() == 0`) for a file without
  audio properties.
