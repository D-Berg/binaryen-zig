# Binaryen

[Binaryen](https://github.com/WebAssembly/binaryen) using the zig build system.

# Usage

```sh
zig fetch --save=binaryen git+https://github.com/D-Berg/binaryen-zig.git

```

```zig
const binaryen_dep = b.dependency("binaryen", .{
    .target = target,
    .optimize = optimize,
    // optional
    .strip = true, // or false
    .linkage = .static // or .dynamic
});

```

## Option 1: TranslateC of binaryen-c.h and automatic linking of libbinaryen

build.zig:

```zig
exe_mod.addImport("c", binaryen_dep.module("binaryen-c"));
```

## Option 2: manually doing TranslateC

If you want all c includes all in one namespace.

c.h:

```c
#include "binaryen-c.h"
#include <stdio.h> // just an example of another c include
```

build.zig:

```zig

const translate_c = b.addTranslateC(.{
    .root_source_file = b.path("c.h"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
});
translate_c.addIncludePath(binaryen_dep.namedLazyPath("binaryen-c.h"));
exe_mod.addImport("c", translate_c.createModule());
exe_mod.linkLibrary(binaryen_dep.artifact("binaryen"));

```




