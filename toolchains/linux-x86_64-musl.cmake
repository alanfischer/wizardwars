# CMake toolchain for cross-compiling to Linux x86_64 from macOS using musl-cross.
# Install: brew install FiloSottile/musl-cross/musl-cross
#
# The resulting .so is statically linked against libstdc++, libgcc, and musl's
# libc, and all internal symbols are hidden via --exclude-libs,ALL.  This makes
# it self-contained and compatible with glibc-based Linux hosts (Ubuntu, Debian,
# etc.) even though it was built with musl-cross.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR x86_64)

set(CMAKE_C_COMPILER   x86_64-linux-musl-gcc)
set(CMAKE_CXX_COMPILER x86_64-linux-musl-g++)
set(CMAKE_AR           x86_64-linux-musl-ar)
set(CMAKE_RANLIB       x86_64-linux-musl-ranlib)
set(CMAKE_STRIP        x86_64-linux-musl-strip)

# Resolve musl's static libc archive at configure time (runs on the macOS host).
execute_process(
    COMMAND x86_64-linux-musl-gcc -print-file-name=libc.a
    OUTPUT_VARIABLE MUSL_LIBC_A
    OUTPUT_STRIP_TRAILING_WHITESPACE
)

# Bake everything in so the .so has no external runtime dependencies:
#   -static-libstdc++  : link libstdc++ from a static archive
#   -static-libgcc     : link libgcc from a static archive
#   ${MUSL_LIBC_A}     : link musl's libc.a (avoids NEEDED libmusl.so.1)
#   --exclude-libs,ALL : hide all statically-linked symbols from the .so's
#                        export table to prevent conflicts with glibc in the
#                        host Godot process
set(CMAKE_SHARED_LINKER_FLAGS
    "${CMAKE_SHARED_LINKER_FLAGS} -static-libstdc++ -static-libgcc ${MUSL_LIBC_A} -Wl,--exclude-libs,ALL"
)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
