# binaries-heif

A repository with static and dynamic binaries for libheif with HEVC support.

It offers x64 & arm64 versions for macOS, Linux, MinGW and Windows.

## 📦 Release assets

| Asset                       | Contents                                                                              |
|-----------------------------|---------------------------------------------------------------------------------------|
| `static_<os>_<arch>.zip`    | libheif, libde265 and x265 as separate static libraries, with all their headers       |
| `dynamic_<os>_<arch>.zip`   | the same libraries as shared libraries (`.dylib`, `.so`, `.dll`)                       |
| `bundle_<os>_<arch>.zip`    | ONE self-contained static library with private symbols prefixed (see below)           |

`<os>` is `osx`, `linux`, `mingw` or `windows` (MSVC); `<arch>` is `x64` or `arm64`.

### Bundle

The bundle is meant for programs that statically link libheif **and** another copy of one of its dependencies, typically
a full FFmpeg build, which bundles its own x265. With the separate static libraries, two copies of x265 end up in the
same link: either the linker fails with duplicate symbols, or it silently mixes code from two different versions (e.g.
x265 build 217 from this repo and build 216 from FFmpeg).

`bundle_<os>_<arch>.zip` contains:

- `include/libheif/`: libheif's public headers only.
- `lib/libheif.a` (`lib/heif.lib` on Windows/MSVC): libheif merged with the dependencies it needs (libde265 and x265).

Every symbol in that library except libheif's public C API (`heif_*`) is renamed with the prefix `heifrs_`: libde265,
x265, libheif's own internals, and C++ template instantiations (`x265_cleanup` → `heifrs_x265_cleanup`). The bundle
therefore can't clash with any other copy of libde265 or x265, whatever its version. The `heif_*` API is unchanged, so
code using libheif's headers needs no change. Link it alone, plus the system and C++ runtime libraries (e.g.
`-lc++` on macOS, `-lstdc++ -lpthread -ldl -lm` on Linux, `-lstdc++ -lpthread` on MinGW). On MSVC the runtime comes
from the library's `/DEFAULTLIB` directives (`/MD`), plus `kernel32.lib` and `advapi32.lib`.

The bundle is produced by [scripts/bundle.sh](scripts/bundle.sh) from the same stripped libraries as the static zip.
Each build verifies it: no unprefixed private symbol is defined or referenced, a small program encodes and decodes an
HEVC image with it, and the same program links cleanly with the bundle **and** the original unprefixed libde265 and x265
forced in together.

## 👨🏾‍💻 Author

Vinicius Egidio ([vinicius.io](http://vinicius.io))
