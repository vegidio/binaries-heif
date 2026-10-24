#!/usr/bin/env bash
#
# bundle.sh: build the self-contained "bundle" release asset.
#
# The static_* zips ship libheif plus its dependencies (libde265, x265) as separate archives. Programs that also
# statically link another copy of any of those dependencies (e.g. a full FFmpeg build, which bundles its own x265)
# end up with two definitions of the same symbols: either a duplicate-symbol error or, worse, the linker silently
# mixing code from two different versions.
#
# This script merges libheif and the dependencies it actually needs into ONE static library in which every symbol
# that is not libheif's public C API (heif_*) is renamed with a unique prefix, so it can never collide with another
# copy of the same library, whatever its version. It then verifies the result and zips it:
#
#   bundle_<os>_<arch>.zip
#   ├── include/libheif/...   only the public headers of libheif
#   └── lib/libheif.a         (heif.lib with MSVC) libheif + its private dependencies, private symbols prefixed
#
# It runs under bash on every platform: macOS, Linux, MSYS2 (MinGW) and Git Bash (MSVC). Only LLVM tools are used to
# read and rewrite objects, so the logic is the same everywhere; the platform only picks the archiver and the
# compiler used for the link tests:
#
#   os       objects  merge                    link tests
#   osx      Mach-O   libtool -static          cc / c++ (Apple clang)
#   linux    ELF      llvm-ar -M (MRI script)  cc / c++
#   mingw    COFF     llvm-ar -M (MRI script)  gcc / g++ of the MSYS2 environment
#   windows  COFF     llvm-lib                 clang-cl + lld-link (system libs from the MSVC developer environment)
#
# Usage:
#   scripts/bundle.sh --os <osx|linux|mingw|windows> --arch <x64|arm64> --static-dir <dir> --output <zip>
#
#   --static-dir  the static_<arch> directory the static zip is made from (include/ + stripped lib/); it is only read
#   --output      path of the zip to create
#   --skip-link-tests  skip the smoke and collision link tests (local debugging only, CI never passes it)
#
# Environment:
#   LLVM_BIN  directory with llvm-nm, llvm-objcopy, llvm-readobj and llvm-ar/llvm-ranlib or llvm-lib, clang-cl, lld-link
#             (default: look them up on PATH)
#   CC, CXX   C compiler and C++ link driver for the link tests (default: cc/c++, gcc/g++ on MinGW)
#   LIBTOOL   Apple's libtool (default: /usr/bin/libtool)
#
# Every step is fatal on failure: a bundle that is not verified is never produced.

set -euo pipefail

# ---------------------------------------------------------------------------------------------------------------------
# Per-repo configuration
# ---------------------------------------------------------------------------------------------------------------------

# Main library; it names the output archive (lib<name>.a / <name>.lib).
MAIN_LIB=heif

# Libraries that must end up in the bundle; the closure of their undefined symbols decides what else is merged in.
ROOT_LIBS=(heif)

# Prefix given to every private symbol.
PREFIX=heifrs_

# Symbols that keep their name: the main library's public C API. Extended regex, matched against the C-level name (the
# leading "_" of Mach-O removed). Empty means "nothing is public, rename everything".
PUBLIC_REGEX='^heif_'

# Extra safety net for the undefined-symbol check: references to these (C-level names) must never stay unprefixed.
PRIVATE_API_REGEX='^(x265_|de265_)'

# Entries of include/ shipped in the bundle.
PUBLIC_HEADERS=(libheif)

# Smoke test: encodes a small image with x265 and decodes it back with libde265, so the renamed code of every bundled
# library actually runs (plugin registration, function pointer tables, assembly). With BUNDLE_COLLIDE it also uses the
# original, unprefixed libde265 and x265 linked into the same program (collision test).
write_smoke_source() {
  cat > "$1" <<'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libheif/heif.h>
#ifdef BUNDLE_COLLIDE
#include <x265.h>
#include <libde265/de265.h>
#endif

#define CHECK(expr, what)                                                       \
  do {                                                                          \
    heif_error err_ = (expr);                                                   \
    if (err_.code != heif_error_Ok) {                                           \
      fprintf(stderr, "%s failed: %s\n", what, err_.message);                   \
      return 1;                                                                 \
    }                                                                           \
  } while (0)

typedef struct { unsigned char* data; size_t size; } buffer;

static heif_error write_to_buffer(heif_context* ctx, const void* data, size_t size, void* userdata) {
  buffer* buf = (buffer*) userdata;
  heif_error ok = {heif_error_Ok, heif_suberror_Unspecified, "Success"};
  heif_error fail = {heif_error_Encoding_error, heif_suberror_Unspecified, "out of memory"};
  unsigned char* grown = (unsigned char*) realloc(buf->data, buf->size + size);
  (void) ctx;
  if (!grown) return fail;
  memcpy(grown + buf->size, data, size);
  buf->data = grown;
  buf->size += size;
  return ok;
}

int main(void) {
  const int w = 64, h = 64;
  heif_context* ctx;
  heif_context* ctx2;
  heif_encoder* encoder;
  heif_image* image;
  heif_image* decoded;
  heif_image_handle* handle;
  heif_writer writer;
  buffer buf = {NULL, 0};
  int c, x, y;

  printf("libheif %s\n", heif_get_version());
#ifdef BUNDLE_COLLIDE
  printf("unprefixed copies linked alongside: libde265 %s, x265 %s\n", de265_get_version(), x265_version_str);
#endif
  CHECK(heif_init(NULL), "heif_init");
  if (!heif_have_encoder_for_format(heif_compression_HEVC) || !heif_have_decoder_for_format(heif_compression_HEVC)) {
    fprintf(stderr, "HEVC encoder/decoder plugin missing\n");
    return 1;
  }

  /* Encode a 64x64 4:2:0 gradient with x265. */
  ctx = heif_context_alloc();
  CHECK(heif_context_get_encoder_for_format(ctx, heif_compression_HEVC, &encoder), "get HEVC encoder");
  CHECK(heif_encoder_set_lossy_quality(encoder, 50), "set quality");
  CHECK(heif_image_create(w, h, heif_colorspace_YCbCr, heif_chroma_420, &image), "heif_image_create");
  for (c = 0; c < 3; c++) {
    heif_channel channel = c == 0 ? heif_channel_Y : c == 1 ? heif_channel_Cb : heif_channel_Cr;
    int pw = c == 0 ? w : w / 2, ph = c == 0 ? h : h / 2;
    size_t stride;
    uint8_t* plane;
    CHECK(heif_image_add_plane(image, channel, pw, ph, 8), "heif_image_add_plane");
    plane = heif_image_get_plane2(image, channel, &stride);
    for (y = 0; y < ph; y++)
      for (x = 0; x < pw; x++) plane[y * stride + x] = (uint8_t) (c == 0 ? (x + y) * 2 : 128);
  }
  CHECK(heif_context_encode_image(ctx, image, encoder, NULL, NULL), "heif_context_encode_image");
  writer.writer_api_version = 1;
  writer.write = write_to_buffer;
  CHECK(heif_context_write(ctx, &writer, &buf), "heif_context_write");
  heif_encoder_release(encoder);
  heif_image_release(image);
  heif_context_free(ctx);

  /* Decode it back with libde265. */
  ctx2 = heif_context_alloc();
  CHECK(heif_context_read_from_memory_without_copy(ctx2, buf.data, buf.size, NULL), "read");
  CHECK(heif_context_get_primary_image_handle(ctx2, &handle), "get primary image");
  CHECK(heif_decode_image(handle, &decoded, heif_colorspace_undefined, heif_chroma_undefined, NULL), "decode");
  if (heif_image_get_width(decoded, heif_channel_Y) != w || heif_image_get_height(decoded, heif_channel_Y) != h) {
    fprintf(stderr, "decoded image has the wrong size\n");
    return 1;
  }
  heif_image_release(decoded);
  heif_image_handle_release(handle);
  heif_context_free(ctx2);
  heif_deinit();

  printf("OK: HEVC round trip through x265 and libde265 (%u bytes)\n", (unsigned) buf.size);
  free(buf.data);
  return 0;
}
EOF
}

# ---------------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------------

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Prints the first lines of a symbol list, for error messages and logs.
show() { sed -n "1,${2:-50}p" "$1" | sed 's/^/    /'; local n; n=$(wc -l < "$1"); [ "$n" -le "${2:-50}" ] || echo "    ... ($n total)"; }

# Path of an LLVM tool: from $LLVM_BIN when set, otherwise from PATH.
find_tool() {
  if [ -n "${LLVM_BIN:-}" ]; then
    if [ -f "$LLVM_BIN/$1.exe" ]; then echo "$LLVM_BIN/$1.exe"; return; fi
    if [ -x "$LLVM_BIN/$1" ]; then echo "$LLVM_BIN/$1"; return; fi
    die "$1 not found in LLVM_BIN=$LLVM_BIN"
  fi
  command -v "$1" || die "$1 not found on PATH (set LLVM_BIN)"
}

# MSYS2 / Git Bash may hand us Windows paths (D:\a\...); turn them into paths bash is happy with.
unix_path() { if command -v cygpath > /dev/null; then cygpath -u "$1"; else printf '%s\n' "$1"; fi; }

# Sorted, unique symbol names of an archive. llvm-nm prints an empty line and "<member>:" before each member's
# symbols, and native Windows builds print CRLF; all of that is dropped. Extra arguments are llvm-nm flags.
symbols() {
  "$NM" -j "$@" 2> nm.err | tr -d '\r' | awk 'NF && !/:$/' | LC_ALL=C sort -u \
    || { cat nm.err >&2; die "llvm-nm failed on ${*: -1}"; }
}

# Names that COFF linker directives (.drectve) refer to: /alternatename:A=B and /include:X. Section contents are not
# rewritten by llvm-objcopy, so these names must keep their spelling or the directives would point to nothing. They
# are MSVC STL/CRT plumbing (e.g. _Avx2WmemEnabledWeakValue), not library code. Prints nothing for ELF/Mach-O.
directive_symbols() {
  [ "$FORMAT" = coff ] || return 0
  "$READOBJ" --coff-directives "$@" 2> /dev/null | tr -d '\r"' | tr ' ' '\n' \
    | awk 'tolower($0) ~ /^[-\/]alternatename:/ { sub(/^[^:]*:/, ""); n = split($0, p, "="); for (i = 1; i <= n; i++) print p[i] }
           tolower($0) ~ /^[-\/]include:/ { sub(/^[^:]*:/, ""); print }' \
    | LC_ALL=C sort -u
}

# COFF weak externals, as "<alias> <target>" pairs. A weak external is an alias that resolves to <target> unless
# something else defines <alias>; recent MSVC emits every vector deleting destructor (??_E...) this way, aliased to
# the scalar one (??_G...). llvm-nm lists them as undefined, but they are definitions in all but name: an alias must
# be renamed together with its target, or the bundle would still define the unprefixed ??_E... of every class.
# Prints nothing for ELF/Mach-O.
weak_externals() {
  [ "$FORMAT" = coff ] || return 0
  "$READOBJ" --symbols "$@" 2> /dev/null | tr -d '\r' | awk '
    $1 == "Symbol" && $2 == "{" { name = ""; weak = 0 }
    $1 == "Name:" { name = $2 }
    $1 == "StorageClass:" && $2 == "WeakExternal" { weak = 1 }
    $1 == "Linked:" && weak { print name, $2 }' | LC_ALL=C sort -u
}

# Classifies symbol names (stdin, one per line) for the rename map and the verification. $1 is the output of
# directive_symbols, $2 a list of names that were renamed already (empty before renaming). Output: "<class> <name>",
# class being one of
#   public   the main library's C API, keeps its name
#   special  COFF/linker machinery that must keep its name: @feat.00, @comp.id, @vol.md, __real@/__xmm@/__ymm@ constants
#            (named by their content), __imp_ import thunks, names used by .drectve directives and other names
#            starting with "." (e.g. MinGW's .weak.__cxa_pure_virtual.* aliases)
#   prefixed carries the prefix
#   refptr   MinGW .refptr.<target>, a COMDAT keyed by its name that holds the address of <target>. It must follow
#            its target: if the target is renamed and the .refptr kept its name, the linker would fold the bundle's
#            .refptr with the one of another copy and one of them would point to the wrong copy. A .refptr to a symbol
#            the bundle doesn't own (C++ runtime, public API) is "special".
#   private  everything else: gets the prefix
classify() {
  awk -v fmt="$FORMAT" -v pub="$PUBLIC_REGEX" -v prefix="$PREFIX" -v dfile="$1" -v ofile="$2" '
    BEGIN {
      while ((getline l < dfile) > 0) directive[l] = 1
      while ((getline l < ofile) > 0) old[l] = 1
    }
    function cls(name,   c) {
      c = name
      if (fmt == "macho" && substr(c, 1, 1) == "_") c = substr(c, 2)
      if (pub != "" && c ~ pub) return "public"
      if (fmt == "coff" && (name == "@feat.00" || name == "@comp.id" || name == "@vol.md" || name ~ /^\./ ||
                            name ~ /^__(real|xmm|ymm)@/ || name ~ /^__imp_/ || (name in directive))) return "special"
      if (substr(c, 1, length(prefix)) == prefix) return "prefixed"
      return "private"
    }
    { names[++n] = $0; defined[$0] = 1 }
    END {
      for (i = 1; i <= n; i++) {
        name = names[i]
        if (fmt == "coff" && name ~ /^\.refptr\./) {
          t = substr(name, 9)
          k = (t in defined) ? cls(t) : "external"
          if (k == "prefixed") print "prefixed", name
          else if (k == "private" || (t in old)) print "refptr", name
          else print "special", name
        } else print cls(name), name
      }
    }'
}

# ---------------------------------------------------------------------------------------------------------------------
# Arguments and tools
# ---------------------------------------------------------------------------------------------------------------------

OS='' ARCH='' STATIC_DIR='' OUTPUT='' SKIP_LINK_TESTS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --os) OS=$2; shift 2 ;;
    --arch) ARCH=$2; shift 2 ;;
    --static-dir) STATIC_DIR=$2; shift 2 ;;
    --output) OUTPUT=$2; shift 2 ;;
    --skip-link-tests) SKIP_LINK_TESTS=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$OS" ] && [ -n "$ARCH" ] && [ -n "$STATIC_DIR" ] && [ -n "$OUTPUT" ] \
  || die "usage: $0 --os <osx|linux|mingw|windows> --arch <x64|arm64> --static-dir <dir> --output <zip>"
case "$ARCH" in x64 | arm64) ;; *) die "unknown arch: $ARCH" ;; esac

STATIC_DIR=$(cd "$(unix_path "$STATIC_DIR")" && pwd)
OUTPUT=$(unix_path "$OUTPUT")
case "$OUTPUT" in /*) ;; *) OUTPUT="$PWD/$OUTPUT" ;; esac

case "$OS" in
  osx) FORMAT=macho EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  linux) FORMAT=elf EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  mingw) FORMAT=coff EXT=a OUT_LIB="lib$MAIN_LIB.a" ;;
  windows) FORMAT=coff EXT=lib OUT_LIB="$MAIN_LIB.lib" ;;
  *) die "unknown os: $OS" ;;
esac

NM=$(find_tool llvm-nm)
OBJCOPY=$(find_tool llvm-objcopy)
[ "$FORMAT" = coff ] && READOBJ=$(find_tool llvm-readobj)
case "$OS" in
  osx) LIBTOOL=${LIBTOOL:-/usr/bin/libtool} ;;
  linux | mingw) AR=$(find_tool llvm-ar); RANLIB=$(find_tool llvm-ranlib) ;;
  windows) LLVM_LIB=$(find_tool llvm-lib) ;;
esac
log "llvm-objcopy: $OBJCOPY ($("$OBJCOPY" --version | tr -d '\r' | grep -i version | head -1))"

# MSYS2 shells don't inherit the Windows PATH, so 7-Zip may only be reachable by its install location.
SEVENZIP=$(command -v 7z || true)
if [ -z "$SEVENZIP" ] && [ -f "/c/Program Files/7-Zip/7z.exe" ]; then SEVENZIP="/c/Program Files/7-Zip/7z.exe"; fi
[ -n "$SEVENZIP" ] || die "7z not found"

# Everything happens in a scratch directory, on copies; relative paths are used from here on, so native Windows tools
# never see MSYS paths.
WORK=$(mktemp -d "$(unix_path "${RUNNER_TEMP:-${TMPDIR:-/tmp}}")/bundle.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"
mkdir -p in syms bundle/include bundle/lib test

# ---------------------------------------------------------------------------------------------------------------------
# a. Closure: only the archives the root libraries actually need
# ---------------------------------------------------------------------------------------------------------------------

# lib<name>.a, or <name>.lib / lib<name>.lib with MSVC.
lib_file() {
  local f
  for f in "lib$1.$EXT" "$1.$EXT"; do [ -f "in/$f" ] && { echo "$f"; return; }; done
  die "library $1 not found in $STATIC_DIR/lib"
}

cp "$STATIC_DIR"/lib/*."$EXT" in/
ALL=()
for f in in/*."$EXT"; do
  f=${f#in/}
  ALL+=("$f")
  symbols --defined-only --extern-only "in/$f" > "syms/$f.def"
  symbols --undefined-only "in/$f" > "syms/$f.undef"
  [ -s "syms/$f.def" ] || die "no symbols read from $f"
done

CLOSURE=()
for name in "${ROOT_LIBS[@]}"; do CLOSURE+=("$(lib_file "$name")"); done

in_closure() { local f; for f in "${CLOSURE[@]}"; do [ "$f" = "$1" ] && return 0; done; return 1; }

# Repeatedly add the archive that resolves the most still-undefined symbols, until nothing more can be resolved. An
# archive whose symbols are all provided already (e.g. a subset library) is never added, so two archives defining the
# same objects are never merged.
while :; do
  (cd syms && for f in "${CLOSURE[@]}"; do cat "$f.def"; done) | LC_ALL=C sort -u > closure.def
  (cd syms && for f in "${CLOSURE[@]}"; do cat "$f.undef"; done) | LC_ALL=C sort -u \
    | LC_ALL=C comm -23 - closure.def > unresolved
  best='' best_n=0
  for f in "${ALL[@]}"; do
    in_closure "$f" && continue
    n=$(LC_ALL=C comm -12 unresolved "syms/$f.def" | wc -l | tr -d ' ')
    if [ "$n" -gt "$best_n" ]; then best=$f best_n=$n; fi
  done
  [ "$best_n" -gt 0 ] || break
  log "closure: + $best (resolves $best_n symbols)"
  CLOSURE+=("$best")
done
log "closure: ${CLOSURE[*]}"
for f in "${ALL[@]}"; do in_closure "$f" || log "closure: dropped $f (not needed)"; done
log "left to the system/C++ runtime: $(wc -l < unresolved | tr -d ' ') symbols"

# ---------------------------------------------------------------------------------------------------------------------
# b + c. Rename map
# ---------------------------------------------------------------------------------------------------------------------

(cd in && directive_symbols "${CLOSURE[@]}") > directives
(cd in && weak_externals "${CLOSURE[@]}") > weak.pairs
: > none
classify directives none < closure.def > closure.classes
grep -c . closure.classes > /dev/null || die "no symbols to classify"
for class in public special private refptr prefixed; do
  log "symbols: $(grep -c "^$class " closure.classes || true) $class"
done
grep -q "^prefixed " closure.classes && die "the input already contains prefixed symbols (${PREFIX}*)"
grep -q "^public " closure.classes || die "no public symbols found (PUBLIC_REGEX=$PUBLIC_REGEX)"

# OLD NEW, NEW being prefix + OLD, except on Mach-O where the prefix goes after the leading "_" (_x265_cleanup ->
# _heifrs_x265_cleanup) so the C-level name stays valid. A .refptr.<target> and a weak external follow their target.
awk -v fmt="$FORMAT" -v prefix="$PREFIX" '
  function renamed(n) { return (fmt == "macho" && substr(n, 1, 1) == "_") ? "_" prefix substr(n, 2) : prefix n }
  FNR == 1 { file++ }
  file == 1 && $1 == "private" { new[$2] = renamed($2) }
  file == 1 && $1 == "refptr" { refptr[$2] = substr($2, 9) }
  file == 1 { defined[$2] = 1 }
  file == 2 { alias[$1] = $2 }
  END {
    for (r in refptr) if (refptr[r] in new) new[r] = ".refptr." new[refptr[r]]
    for (a in alias) if (!(a in defined) && (alias[a] in new)) new[a] = renamed(a)
    for (n in new) print n, new[n]
  }' closure.classes weak.pairs | LC_ALL=C sort > rename.map
[ "$FORMAT" != coff ] || log "weak externals: $(wc -l < weak.pairs | tr -d ' '), renamed with their target: $(awk 'FNR == NR { w[$1] = 1; next } $1 in w' weak.pairs rename.map | wc -l | tr -d ' ')"
awk 'NF != 2 { bad = 1 } END { exit bad }' rename.map || die "symbol names with whitespace can't be renamed"
cut -d' ' -f1 rename.map > renamed.old
log "rename map: $(wc -l < rename.map | tr -d ' ') symbols"

# ---------------------------------------------------------------------------------------------------------------------
# d. Rename, in every archive of the closure (the main library too, so its references follow)
# ---------------------------------------------------------------------------------------------------------------------

for f in "${CLOSURE[@]}"; do
  log "renaming symbols in $f"
  "$OBJCOPY" --redefine-syms=rename.map "in/$f" "in/$f.renamed" || die "llvm-objcopy failed on $f"
  mv "in/$f.renamed" "in/$f"
done

# ---------------------------------------------------------------------------------------------------------------------
# e. Merge into the single output archive
# ---------------------------------------------------------------------------------------------------------------------

BUNDLE="bundle/lib/$OUT_LIB"
CLOSURE_PATHS=()
for f in "${CLOSURE[@]}"; do CLOSURE_PATHS+=("in/$f"); done
case "$OS" in
  osx)
    "$LIBTOOL" -static -no_warning_for_no_symbols -o "$BUNDLE" "${CLOSURE_PATHS[@]}"
    ;;
  linux | mingw)
    { echo "CREATE $BUNDLE"; for f in "${CLOSURE[@]}"; do echo "ADDLIB in/$f"; done; echo "SAVE"; echo "END"; } > merge.mri
    "$AR" -M < merge.mri
    "$RANLIB" "$BUNDLE"
    ;;
  windows)
    "$LLVM_LIB" -nologo -out:"$BUNDLE" "${CLOSURE_PATHS[@]}"
    ;;
esac
[ -s "$BUNDLE" ] || die "merge produced no $BUNDLE"
log "merged $BUNDLE ($(wc -c < "$BUNDLE" | tr -d ' ') bytes)"

for h in "${PUBLIC_HEADERS[@]}"; do cp -R "$STATIC_DIR/include/$h" bundle/include/; done

# ---------------------------------------------------------------------------------------------------------------------
# f. Verification
# ---------------------------------------------------------------------------------------------------------------------

# 1. Every defined symbol is public API, prefixed or linker machinery.
symbols --defined-only --extern-only "$BUNDLE" > bundle.def
directive_symbols "$BUNDLE" > bundle.directives
classify bundle.directives renamed.old < bundle.def > bundle.classes
grep -E '^(private|refptr) ' bundle.classes | cut -d' ' -f2 > offenders || true
if [ -s offenders ]; then
  echo "Defined symbols that are neither public nor prefixed:"; show offenders
  die "verification 1 failed"
fi
weak_externals "$BUNDLE" | awk -v prefix="$PREFIX" '
  substr($2, 1, length(prefix)) == prefix && substr($1, 1, length(prefix)) != prefix { print $1 " -> " $2 }' > offenders
[ ! -s offenders ] || { echo "Unprefixed weak externals aliasing prefixed symbols:"; show offenders; die "verification 1 failed"; }
grep '^public ' bundle.classes | cut -d' ' -f2 | LC_ALL=C sort > bundle.public
grep '^public ' closure.classes | cut -d' ' -f2 | LC_ALL=C sort | LC_ALL=C comm -23 - bundle.public > offenders
[ ! -s offenders ] || { echo "Public symbols missing from the bundle:"; show offenders; die "verification 1 failed"; }
log "verify 1 OK: $(wc -l < bundle.def | tr -d ' ') defined symbols, all public ($(grep -c '^public ' bundle.classes)), prefixed ($(grep -c '^prefixed ' bundle.classes)) or linker machinery ($(grep -c '^special ' bundle.classes || true))"

# 2. No reference to an unprefixed private symbol is left.
symbols --undefined-only "$BUNDLE" > bundle.undef
LC_ALL=C comm -12 bundle.undef renamed.old > offenders
[ ! -s offenders ] || { echo "References to renamed symbols under their old name:"; show offenders; die "verification 2 failed"; }
LC_ALL=C comm -23 bundle.undef bundle.def \
  | awk -v fmt="$FORMAT" -v re="$PRIVATE_API_REGEX" '
      { c = $0; sub(/^__imp_/, "", c); if (fmt == "macho") sub(/^_/, "", c); if (c ~ re) print }' > offenders
[ ! -s offenders ] || { echo "Unresolved references to private APIs:"; show offenders; die "verification 2 failed"; }
log "verify 2 OK: no reference to an unprefixed private symbol ($(LC_ALL=C comm -23 bundle.undef bundle.def | wc -l | tr -d ' ') left to the system)"

# 3 + 4. Smoke and collision tests.
#
#   smoke:     the test program against the bundle alone (plus system/C++ runtime libs), then run.
#   collision: the same program, built with BUNDLE_COLLIDE so it also calls the original libraries, against the
#              bundle AND the original unprefixed private archives from the static zip, every object of each forced
#              in (whole-archive), duplicate symbols fatal. A clean link proves the bundle can't clash with another
#              copy of its dependencies; running it proves both copies work side by side.
ORIGINALS=()
for f in "${CLOSURE[@]}"; do
  is_root=0
  for name in "${ROOT_LIBS[@]}"; do [ "$f" = "$(lib_file "$name")" ] && is_root=1; done
  [ "$is_root" = 1 ] || ORIGINALS+=("orig/$f")
done

if [ "$SKIP_LINK_TESTS" = 1 ]; then
  log "skipping smoke and collision tests (--skip-link-tests)"
else
  mkdir -p orig
  # The original archives and headers (x265.h, libde265/) the collision test is built against.
  for f in "${CLOSURE[@]}"; do cp "$STATIC_DIR/lib/$f" orig/; done
  cp -R "$STATIC_DIR/include" orig/include
  write_smoke_source test/smoke.c
  RUN=1

  case "$OS" in
    osx)
      CC=${CC:-cc} CXX=${CXX:-c++}
      [ "$ARCH" = x64 ] && ARCH_FLAGS=(-arch x86_64) || ARCH_FLAGS=(-arch arm64)
      if [ "$ARCH" = x64 ] && [ "$(uname -m)" = arm64 ] && ! /usr/bin/arch -x86_64 /usr/bin/true 2> /dev/null; then
        RUN=0; log "Rosetta unavailable: the x64 test programs are linked but not run"
      fi
      compile() { "$CC" "${ARCH_FLAGS[@]}" -O1 -Ibundle/include -Iorig/include "$@"; }
      link_smoke() { "$CXX" "${ARCH_FLAGS[@]}" -o "$1" "$2" "$BUNDLE"; }
      # Duplicate symbols are errors for ld64; on top of that every linker warning is fatal, like -Wl,-fatal_warnings,
      # except "no platform load command found": x265's NASM-assembled x64 objects carry no LC_BUILD_VERSION, in the
      # original static archives too, so ld warns about them in any link.
      # shellcheck disable=SC2054 # -Wl,-force_load,<lib> is one argument
      link_collide() {
        local out=$1 obj=$2 f; shift 2
        local args=(-Wl,-force_load,"$BUNDLE")
        for f in "$@"; do args+=(-Wl,-force_load,"$f"); done
        "$CXX" "${ARCH_FLAGS[@]}" -o "$out" "$obj" "${args[@]}" > link.log 2>&1 || { cat link.log; return 1; }
        grep -v "no platform load command found" link.log || true
        if grep -i "warning" link.log | grep -v -q "no platform load command found"; then
          echo "linker warnings are fatal in the collision test"; return 1
        fi
      }
      ;;
    linux | mingw)
      if [ "$OS" = linux ]; then CC=${CC:-cc} CXX=${CXX:-c++} SYSLIBS=(-lpthread -ldl -lm)
      else CC=${CC:-gcc} CXX=${CXX:-g++} SYSLIBS=(-lpthread); fi
      compile() { "$CC" -O1 -Ibundle/include -Iorig/include "$@"; }
      link_smoke() { "$CXX" -o "$1" "$2" "$BUNDLE" "${SYSLIBS[@]}"; }
      link_collide() {
        local out=$1 obj=$2; shift 2
        "$CXX" -o "$out" "$obj" -Wl,--whole-archive "$BUNDLE" "$@" -Wl,--no-whole-archive "${SYSLIBS[@]}"
      }
      ;;
    windows)
      CLANG_CL=$(find_tool clang-cl)
      LLD_LINK=$(find_tool lld-link)
      if [ "$ARCH" = x64 ]; then TARGET=x86_64-pc-windows-msvc MACHINE=x64; else TARGET=aarch64-pc-windows-msvc MACHINE=arm64; fi
      [ -n "${LIB:-}" ] || die "LIB is not set: run inside the MSVC developer environment (ilammy/msvc-dev-cmd)"
      # Options are spelled -opt instead of /opt so MSYS doesn't take them for paths. The C runtime and C++ library
      # come from the objects' /DEFAULTLIB directives (/MD: msvcrt, msvcprt); Win32 import libs are added explicitly.
      SYSLIBS=(kernel32.lib advapi32.lib)
      compile() {
        "$CLANG_CL" --target="$TARGET" -nologo -MD -O1 -D_CRT_SECURE_NO_WARNINGS -Ibundle/include -Iorig/include "$@"
      }
      link_smoke() { "$LLD_LINK" -nologo -machine:"$MACHINE" -subsystem:console -out:"$1" "$2" "$BUNDLE" "${SYSLIBS[@]}"; }
      link_collide() {
        local out=$1 obj=$2 f; shift 2
        local args=(-wholearchive:"$BUNDLE")
        for f in "$@"; do args+=(-wholearchive:"$f"); done
        "$LLD_LINK" -nologo -machine:"$MACHINE" -subsystem:console -out:"$out" "$obj" "${args[@]}" "${SYSLIBS[@]}"
      }
      ;;
  esac

  if [ "$OS" = windows ]; then
    compile -c test/smoke.c -Fotest/smoke.obj
    compile -DBUNDLE_COLLIDE -c test/smoke.c -Fotest/collide.obj
    OBJ=obj EXE=.exe
  else
    compile -c test/smoke.c -o test/smoke.o
    compile -DBUNDLE_COLLIDE -c test/smoke.c -o test/collide.o
    OBJ=o EXE=
  fi
  [ "$OS" = mingw ] && EXE=.exe

  run() {
    if [ "$RUN" = 1 ]; then
      if [ "$OS" = osx ] && [ "$ARCH" = x64 ]; then /usr/bin/arch -x86_64 "$1"; else "$1"; fi || die "$1 failed"
    fi
  }

  log "smoke test: linking against the bundle only"
  link_smoke "test/smoke$EXE" "test/smoke.$OBJ" || die "verification 3 failed: smoke test does not link"
  run "test/smoke$EXE"
  log "verify 3 OK"

  log "collision test: bundle + original ${ORIGINALS[*]}, whole archives"
  link_collide "test/collide$EXE" "test/collide.$OBJ" ${ORIGINALS[@]+"${ORIGINALS[@]}"} \
    || die "verification 4 failed: the bundle clashes with the original libraries"
  run "test/collide$EXE"
  log "verify 4 OK"
fi

# ---------------------------------------------------------------------------------------------------------------------
# g. Zip
# ---------------------------------------------------------------------------------------------------------------------

(cd bundle && "$SEVENZIP" a -tzip -mx=9 -snl ../bundle.zip include lib > /dev/null)
mkdir -p "$(dirname "$OUTPUT")"
mv bundle.zip "$OUTPUT"
log "created $OUTPUT"
