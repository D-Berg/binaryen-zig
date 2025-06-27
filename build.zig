const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Build and link as dynamic or static library") orelse .static;
    const strip = b.option(bool, "strip", "strip binaries") orelse false;

    const binaryen_dep = b.dependency("binaryen", .{});

    const binaryen_mod = b.addModule("binaryen", .{
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .strip = strip,
    });

    binaryen_mod.addIncludePath(binaryen_dep.path("src"));
    binaryen_mod.addIncludePath(binaryen_dep.path("src/emscripten-optimizer"));
    binaryen_mod.addIncludePath(binaryen_dep.path("third_party/FP16/include"));
    binaryen_mod.addIncludePath(binaryen_dep.path("third_party/llvm-project/include"));
    binaryen_mod.addIncludePath(binaryen_dep.path("."));

    const flags = &.{
        "-std=c++17",
        "-fno-rtti",
        "-Wno-unused-parameter",
        "-DPROJECT_VERSION=123",
    };

    binaryen_mod.addCSourceFiles(.{
        .root = binaryen_dep.path("src"),
        .files = src_source_files,
        .flags = flags,
    });

    binaryen_mod.addCSourceFiles(.{
        .root = binaryen_dep.path("third_party"),
        .files = third_party_source_files,
        .flags = flags,
    });

    binaryen_mod.addCSourceFile(.{
        .file = try WasmIntrinsics(b, binaryen_dep),
        .flags = flags,
        .language = .cpp,
    });

    const lib_binaryen = b.addLibrary(.{
        .name = "binaryen",
        .root_module = binaryen_mod,
        .linkage = linkage,
    });

    lib_binaryen.installHeader(binaryen_dep.path("src/binaryen-c.h"), "binaryen-c.h");
    lib_binaryen.installHeader(binaryen_dep.path("src/wasm-delegations.def"), "wasm-delegations.def");
    lib_binaryen.addConfigHeader(Config(b, binaryen_dep));

    lib_binaryen.linkSystemLibrary("pthread");

    const translate_c = b.addTranslateC(.{
        .root_source_file = binaryen_dep.path("src/binaryen-c.h"),
        .optimize = optimize,
        .target = target,
        .link_libc = true,
    });

    const binaryen_c = translate_c.addModule("binaryen-c");
    binaryen_c.linkLibrary(lib_binaryen);

    b.addNamedLazyPath("binaryen-c.h", binaryen_dep.path("src"));

    b.installArtifact(lib_binaryen);

    buildTools(b, target, optimize, strip, binaryen_dep, lib_binaryen);
}

/// Only ran if doing zig build tools
fn buildTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    binaryen_dep: *std.Build.Dependency,
    lib_binaryen: *std.Build.Step.Compile,
) void {
    const tools = b.step("tools", "Build wasm tools");

    const wasm_opt_mod = b.addModule("wasm-opt", .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    wasm_opt_mod.addIncludePath(binaryen_dep.path("src/tools"));
    wasm_opt_mod.addIncludePath(binaryen_dep.path("src"));
    wasm_opt_mod.addIncludePath(binaryen_dep.path("third_party/FP16/include"));
    wasm_opt_mod.addIncludePath(binaryen_dep.path("src/tools/fuzzing"));
    wasm_opt_mod.addCSourceFiles(.{
        .root = binaryen_dep.path("src"),
        .files = &.{
            "tools/wasm-opt.cpp",

            "tools/fuzzing/fuzzing.cpp",
            "tools/fuzzing/heap-types.cpp",
            "tools/fuzzing/parameters.cpp",
            "tools/fuzzing/random.cpp",
        },
        .language = .cpp,
    });

    wasm_opt_mod.linkLibrary(lib_binaryen);

    const wasm_opt_exe = b.addExecutable(.{
        .name = "wasm-opt",
        .root_module = wasm_opt_mod,
    });

    const wasm_opt_install = b.addInstallArtifact(wasm_opt_exe, .{});
    tools.dependOn(&wasm_opt_install.step);

    const wasm_merge_mod = b.addModule("wasm-merge", .{
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    wasm_merge_mod.addIncludePath(binaryen_dep.path("src/tools"));
    wasm_merge_mod.addIncludePath(binaryen_dep.path("src"));
    wasm_merge_mod.addCSourceFiles(.{
        .root = binaryen_dep.path("src"),
        .files = &.{
            "tools/wasm-merge.cpp",
        },
        .language = .cpp,
    });

    wasm_merge_mod.linkLibrary(lib_binaryen);

    const wasm_merge_exe = b.addExecutable(.{
        .name = "wasm-merge",
        .root_module = wasm_merge_mod,
    });

    const install_wasm_merge = b.addInstallArtifact(wasm_merge_exe, .{});
    tools.dependOn(&install_wasm_merge.step);
}

fn WasmIntrinsics(b: *std.Build, binaryen_dep: *std.Build.Dependency) !std.Build.LazyPath {
    const file_lazy_path = binaryen_dep.path("src/passes/wasm-intrinsics.wat");
    const file_path = file_lazy_path.getPath(b);

    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    const wat = try file.readToEndAlloc(b.allocator, 1024 * 2048);

    var wat_hex: std.ArrayListUnmanaged(u8) = .empty;

    const writer = wat_hex.writer(b.allocator);

    for (wat) |c| {
        try writer.print("0x{x},", .{c});
    }
    const wasm_intrinsics = b.addConfigHeader(
        .{
            .style = .{ .cmake = binaryen_dep.path("src/passes/WasmIntrinsics.cpp.in") },
            .include_path = "WasmIntrinsics.cpp",
        },
        .{ .WASM_INTRINSICS_EMBED = try wat_hex.toOwnedSlice(b.allocator) },
    );

    return wasm_intrinsics.getOutput();
}

fn Config(b: *std.Build, binaryen_dep: *std.Build.Dependency) *std.Build.Step.ConfigHeader {
    const config_h = b.addConfigHeader(
        .{ .style = .{ .cmake = binaryen_dep.path("config.h.in") }, .include_path = "config.h" },
        .{ .PROJECT_VERSION = "123" },
    );
    return config_h;
}

const third_party_source_files = &[_][]const u8{
    "llvm-project/Binary.cpp",
    "llvm-project/ConvertUTF.cpp",
    "llvm-project/DJB.cpp",
    "llvm-project/DWARFAbbreviationDeclaration.cpp",
    "llvm-project/DWARFAcceleratorTable.cpp",
    "llvm-project/DWARFAddressRange.cpp",
    "llvm-project/DWARFCompileUnit.cpp",
    "llvm-project/DWARFContext.cpp",
    "llvm-project/DWARFDataExtractor.cpp",
    "llvm-project/DWARFDebugAbbrev.cpp",
    "llvm-project/DWARFDebugAddr.cpp",
    "llvm-project/DWARFDebugArangeSet.cpp",
    "llvm-project/DWARFDebugAranges.cpp",
    "llvm-project/DWARFDebugFrame.cpp",
    "llvm-project/DWARFDebugInfoEntry.cpp",
    "llvm-project/DWARFDebugLine.cpp",
    "llvm-project/DWARFDebugLoc.cpp",
    "llvm-project/DWARFDebugMacro.cpp",
    "llvm-project/DWARFDebugPubTable.cpp",
    "llvm-project/DWARFDebugRangeList.cpp",
    "llvm-project/DWARFDebugRnglists.cpp",
    "llvm-project/DWARFDie.cpp",
    "llvm-project/DWARFEmitter.cpp",
    "llvm-project/DWARFExpression.cpp",
    "llvm-project/DWARFFormValue.cpp",
    "llvm-project/DWARFGdbIndex.cpp",
    "llvm-project/DWARFListTable.cpp",
    "llvm-project/DWARFTypeUnit.cpp",
    "llvm-project/DWARFUnit.cpp",
    "llvm-project/DWARFUnitIndex.cpp",
    "llvm-project/DWARFVerifier.cpp",
    "llvm-project/DWARFVisitor.cpp",
    "llvm-project/DWARFYAML.cpp",
    "llvm-project/DataExtractor.cpp",
    "llvm-project/Debug.cpp",
    "llvm-project/Dwarf.cpp",
    "llvm-project/Error.cpp",
    "llvm-project/ErrorHandling.cpp",
    "llvm-project/FormatVariadic.cpp",
    "llvm-project/Hashing.cpp",
    "llvm-project/LEB128.cpp",
    "llvm-project/LineIterator.cpp",
    "llvm-project/MCRegisterInfo.cpp",
    "llvm-project/MD5.cpp",
    "llvm-project/MemoryBuffer.cpp",
    "llvm-project/NativeFormatting.cpp",
    "llvm-project/ObjectFile.cpp",
    "llvm-project/Optional.cpp",
    "llvm-project/Path.cpp",
    "llvm-project/ScopedPrinter.cpp",
    "llvm-project/SmallVector.cpp",
    "llvm-project/SourceMgr.cpp",
    "llvm-project/StringMap.cpp",
    "llvm-project/StringRef.cpp",
    "llvm-project/SymbolicFile.cpp",
    "llvm-project/Twine.cpp",
    "llvm-project/UnicodeCaseFold.cpp",
    "llvm-project/WithColor.cpp",
    "llvm-project/YAMLParser.cpp",
    "llvm-project/YAMLTraits.cpp",
    "llvm-project/dwarf2yaml.cpp",
    "llvm-project/obj2yaml_Error.cpp",
    "llvm-project/raw_ostream.cpp",
};

const src_source_files = &[_][]const u8{
    "binaryen-c.cpp",

    "ir/ExpressionAnalyzer.cpp",
    "ir/ExpressionManipulator.cpp",
    "ir/debuginfo.cpp",
    "ir/drop.cpp",
    "ir/effects.cpp",
    "ir/eh-utils.cpp",
    "ir/export-utils.cpp",
    "ir/intrinsics.cpp",
    "ir/lubs.cpp",
    "ir/memory-utils.cpp",
    "ir/module-utils.cpp",
    "ir/names.cpp",
    "ir/possible-contents.cpp",
    "ir/properties.cpp",
    "ir/LocalGraph.cpp",
    "ir/LocalStructuralDominance.cpp",
    "ir/public-type-validator.cpp",
    "ir/ReFinalize.cpp",
    "ir/return-utils.cpp",
    "ir/stack-utils.cpp",
    "ir/table-utils.cpp",
    "ir/type-updating.cpp",
    "ir/module-splitting.cpp",

    "asmjs/asmangle.cpp",
    "asmjs/asm_v_wasm.cpp",
    "asmjs/shared-constants.cpp",

    "cfg/Relooper.cpp",

    "emscripten-optimizer/optimizer-shared.cpp",
    "emscripten-optimizer/simple_ast.cpp",
    "emscripten-optimizer/parser.cpp",

    "parser/context-decls.cpp",
    "parser/context-defs.cpp",
    "parser/lexer.cpp",
    "parser/parse-1-decls.cpp",
    "parser/parse-2-typedefs.cpp",
    "parser/parse-3-implicit-types.cpp",
    "parser/parse-4-module-types.cpp",
    "parser/parse-5-defs.cpp",
    "parser/wast-parser.cpp",
    "parser/wat-parser.cpp",

    "support/archive.cpp",
    "support/bits.cpp",
    "support/colors.cpp",
    "support/command-line.cpp",
    "support/debug.cpp",
    "support/dfa_minimization.cpp",
    "support/file.cpp",
    "support/intervals.cpp",
    "support/istring.cpp",
    "support/json.cpp",
    "support/name.cpp",
    "support/path.cpp",
    "support/safe_integer.cpp",
    "support/string.cpp",
    "support/suffix_tree.cpp",
    "support/suffix_tree_node.cpp",
    "support/threads.cpp",
    "support/utilities.cpp",

    "wasm/literal.cpp",
    "wasm/parsing.cpp",
    "wasm/source-map.cpp",
    "wasm/wasm.cpp",
    "wasm/wasm-binary.cpp",
    "wasm/wasm-debug.cpp",
    "wasm/wasm-emscripten.cpp",
    "wasm/wasm-interpreter.cpp",
    "wasm/wasm-io.cpp",
    "wasm/wasm-ir-builder.cpp",
    "wasm/wasm-stack.cpp",
    "wasm/wasm-stack-opts.cpp",
    "wasm/wasm-type.cpp",
    "wasm/wasm-type-shape.cpp",
    "wasm/wasm-validator.cpp",

    "analysis/cfg.cpp",

    "passes/pass.cpp",
    "passes/AbstractTypeRefining.cpp",
    "passes/AlignmentLowering.cpp",
    "passes/Asyncify.cpp",
    "passes/AvoidReinterprets.cpp",
    "passes/CoalesceLocals.cpp",
    "passes/CodeFolding.cpp",
    "passes/CodePushing.cpp",
    "passes/ConstantFieldPropagation.cpp",
    "passes/ConstHoisting.cpp",
    "passes/DataFlowOpts.cpp",
    "passes/DeadArgumentElimination.cpp",
    "passes/DeadCodeElimination.cpp",
    "passes/DeAlign.cpp",
    "passes/DebugLocationPropagation.cpp",
    "passes/DeNaN.cpp",
    "passes/Directize.cpp",
    "passes/DuplicateFunctionElimination.cpp",
    "passes/DuplicateImportElimination.cpp",
    "passes/DWARF.cpp",
    "passes/EncloseWorld.cpp",
    "passes/ExtractFunction.cpp",
    "passes/Flatten.cpp",
    "passes/FuncCastEmulation.cpp",
    "passes/GenerateDynCalls.cpp",
    "passes/GlobalEffects.cpp",
    "passes/GlobalRefining.cpp",
    "passes/GlobalStructInference.cpp",
    "passes/GlobalTypeOptimization.cpp",
    "passes/GUFA.cpp",
    "passes/hash-stringify-walker.cpp",
    "passes/Heap2Local.cpp",
    "passes/HeapStoreOptimization.cpp",
    "passes/I64ToI32Lowering.cpp",
    "passes/Inlining.cpp",
    "passes/InstrumentLocals.cpp",
    "passes/InstrumentMemory.cpp",
    "passes/Intrinsics.cpp",
    "passes/J2CLItableMerging.cpp",
    "passes/J2CLOpts.cpp",
    "passes/JSPI.cpp",
    "passes/LegalizeJSInterface.cpp",
    "passes/LimitSegments.cpp",
    "passes/LLVMMemoryCopyFillLowering.cpp",
    "passes/LLVMNontrappingFPToIntLowering.cpp",
    "passes/LocalCSE.cpp",
    "passes/LocalSubtyping.cpp",
    "passes/LogExecution.cpp",
    "passes/LoopInvariantCodeMotion.cpp",
    "passes/Memory64Lowering.cpp",
    "passes/MemoryPacking.cpp",
    "passes/MergeBlocks.cpp",
    "passes/MergeLocals.cpp",
    "passes/MergeSimilarFunctions.cpp",
    "passes/Metrics.cpp",
    "passes/MinifyImportsAndExports.cpp",
    "passes/MinimizeRecGroups.cpp",
    "passes/Monomorphize.cpp",
    "passes/MultiMemoryLowering.cpp",
    "passes/NameList.cpp",
    "passes/NameTypes.cpp",
    "passes/NoInline.cpp",
    "passes/OnceReduction.cpp",
    "passes/OptimizeAddedConstants.cpp",
    "passes/OptimizeCasts.cpp",
    "passes/OptimizeForJS.cpp",
    "passes/OptimizeInstructions.cpp",
    "passes/Outlining.cpp",
    "passes/param-utils.cpp",
    "passes/PickLoadSigns.cpp",
    "passes/Poppify.cpp",
    "passes/PostEmscripten.cpp",
    "passes/Precompute.cpp",
    "passes/Print.cpp",
    "passes/PrintCallGraph.cpp",
    "passes/PrintFeatures.cpp",
    "passes/PrintFunctionMap.cpp",
    "passes/RedundantSetElimination.cpp",
    "passes/RemoveImports.cpp",
    "passes/RemoveMemoryInit.cpp",
    "passes/RemoveNonJSOps.cpp",
    "passes/RemoveUnusedBrs.cpp",
    "passes/RemoveUnusedModuleElements.cpp",
    "passes/RemoveUnusedNames.cpp",
    "passes/RemoveUnusedTypes.cpp",
    "passes/ReorderFunctions.cpp",
    "passes/ReorderGlobals.cpp",
    "passes/ReorderLocals.cpp",
    "passes/ReReloop.cpp",
    "passes/RoundTrip.cpp",
    "passes/SafeHeap.cpp",
    "passes/SeparateDataSegments.cpp",
    "passes/SetGlobals.cpp",
    "passes/SignaturePruning.cpp",
    "passes/SignatureRefining.cpp",
    "passes/SignExtLowering.cpp",
    "passes/SimplifyGlobals.cpp",
    "passes/SimplifyLocals.cpp",
    "passes/Souperify.cpp",
    "passes/SpillPointers.cpp",
    "passes/SSAify.cpp",
    "passes/StackCheck.cpp",
    "passes/string-utils.cpp",
    "passes/StringLifting.cpp",
    "passes/StringLowering.cpp",
    "passes/Strip.cpp",
    "passes/StripEH.cpp",
    "passes/StripTargetFeatures.cpp",
    "passes/test_passes.cpp",
    "passes/TraceCalls.cpp",
    "passes/TranslateEH.cpp",
    "passes/TrapMode.cpp",
    "passes/TupleOptimization.cpp",
    "passes/TypeFinalizing.cpp",
    "passes/TypeGeneralizing.cpp",
    "passes/TypeMerging.cpp",
    "passes/TypeRefining.cpp",
    "passes/TypeSSA.cpp",
    "passes/Unsubtyping.cpp",
    "passes/Untee.cpp",
    "passes/Vacuum.cpp",
};
