# Releasing

One version for every package, a `CHANGELOG.md` entry per package, and a `v<version>` tag
(DESIGN D8). Before 1.0 a minor version is a breaking change, and every other release is a
patch. A released tag is never moved: a fix is the next patch.

## Every release

1. Set `version:` in each package's `pubspec.yaml`, and the tag in the README's and the
   adopting snippets' `ref:`.
2. Add each package's `CHANGELOG.md` entry. A package with no change says so, and names the
   release it came with.
3. Run the checks in `CLAUDE.md`, and `flutter test` in `packages/galley_web`.
4. Commit, tag `v<version>`, push the commit and the tag.

## A release that changes the canvas

The canvas ships built, as an asset of its release (DESIGN D14). Before step 4:

1. Build it into a new, empty directory, so nothing from an earlier build is in it:

   ```sh
   cd packages/galley_web
   flutter build web --release --no-web-resources-cdn --no-wasm-dry-run -o <empty dir>/web
   ```

   `--no-web-resources-cdn` puts CanvasKit in the build. Without it the canvas fetches it from
   Google's CDN, which D14 rejects.

2. Archive it, ustar, with the build's files at the archive's root:

   ```sh
   cd <empty dir>
   COPYFILE_DISABLE=1 tar --format ustar -czf galley_web-<version>.tar.gz -C web .
   ```

   `COPYFILE_DISABLE=1` keeps macOS tar from adding `._` files for extended attributes. The
   unpacker in `galley_cli` reads only files and directories, so an archive with a link in it
   is refused when `galley serve` fetches it, not here.

3. Pin it: `shasum -a 256 galley_web-<version>.tar.gz`, and set `pinnedCanvas` in
   `packages/galley_cli/lib/src/canvas.dart` to the version and that hash.

4. After the tag is pushed, create the release `v<version>` and attach the archive under that
   exact name. Then check it from the real address, in a new cache:

   ```sh
   GALLEY_CACHE=$(mktemp -d) dart run galley_cli:galley serve   # from an app's root
   ```

   It prints `Fetching the canvas` once, and `/` is the canvas. A wrong hash says so at start
   and serves no canvas.

A release that does not change the canvas keeps the old pin, and attaches nothing.
