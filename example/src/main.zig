//! based on https://github.com/WebAssembly/binaryen/blob/main/test/example/c-api-hello-world.c

const std = @import("std");
const c = @import("c");
const log = std.log;

pub fn main() !void {
    const c_allocator = std.heap.c_allocator;

    const module = c.BinaryenModuleCreate();
    defer c.BinaryenModuleDispose(module);

    c.BinaryenSetOptimizeLevel(2);
    c.BinaryenSetShrinkLevel(2);

    var ii = [2]c.BinaryenType{ c.BinaryenTypeInt32(), c.BinaryenTypeInt32() };

    const params = c.BinaryenTypeCreate(&ii, ii.len);
    const results = c.BinaryenTypeInt32();

    const x = c.BinaryenLocalGet(module, 0, c.BinaryenTypeInt32());
    const y = c.BinaryenLocalGet(module, 1, c.BinaryenTypeInt32());

    const add = c.BinaryenBinary(module, c.BinaryenAddInt32(), x, y);

    _ = c.BinaryenAddFunction(module, "adder", params, results, null, 0, add);
    _ = c.BinaryenAddExport(module, "adder", "adder");

    c.BinaryenModuleOptimize(module);
    c.BinaryenModulePrint(module); // prints wat

    const result = c.BinaryenModuleAllocateAndWrite(module, null);

    if (result.binary) |any_binary| {
        const out_file = try std.fs.cwd().createFile("add.wasm", .{});
        defer out_file.close();

        var binary: []const u8 = undefined;
        defer c_allocator.free(binary);

        binary.ptr = @ptrCast(any_binary);
        binary.len = result.binaryBytes;

        try out_file.writeAll(binary);
    }
}
