const std = @import("std");
const instTree = @import("decoder_tree.zig");
const print = std.debug.print;
const Emulator = @import("emulator.zig").Emulator;

pub fn main() !void {
    if (std.os.argv.len < 2) {
        std.debug.print("Need to specify data filepath", .{});
        return;
    }
    if (std.os.argv.len == 3) {
        try decodeFile(std.os.argv[1], true);
    } else {
        try decodeFile(std.os.argv[1], false);
    }
}

fn decodeFile(filename: [*:0]const u8, emulate: bool) !void {
    const file = try std.fs.cwd().openFileZ(filename, .{});
    defer file.close();

    var buf_reader = std.io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var array_list = std.ArrayList(u8).init(allocator);
    defer array_list.deinit();

    try reader.readAllArrayList(&array_list, 4098);

    try decodeInstructionStream(&array_list, emulate);
}

fn decodeInstructionStream(array_list: *std.ArrayList(u8), emulate: bool) !void {
    print("Emulation: {any}\n", .{emulate});
    var instruction = instTree.Instruction{
        .mod = null,
        .d = false,
        .w = false,
        .s = false,
        .reg = null,
        .rm = null,
    };
    print("Input byte length: {d}\n", .{array_list.items.len});
    var current_index: u16 = 0;
    var prev_index: u16 = 0;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const gpa_allocator = gpa.allocator();
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    const allocator = arena.allocator();
    defer arena.deinit();
    const stdOut = std.io.getStdOut().writer();

    var instructionTree = try instTree.getDecoderTree(allocator);
    var emulator = Emulator{};

    while (current_index < array_list.items.len) {
        instruction.reset();
        prev_index = current_index;
        current_index = instructionTree.decode(array_list, current_index, &instruction) catch |err| {
            print("Failed to match: {any}\n", .{err});
            return;
        };
        try instruction.printInstruction(stdOut);
        if (emulate) {
            try stdOut.writeAll(" ; ");
            try emulator.emulateInstruction(stdOut, &instruction, prev_index, &current_index);
        }
        try stdOut.writeAll("\n");
    }
    if (emulate) {
        try emulator.printRegisters(stdOut);
        try emulator.printFlags(stdOut);
    }
}

// ---------------- Tests ----------------
test "listing 37" {
    const filename = "./data/listing_0037_single_register_mov";
    try decodeFile(filename, false);
}

test "listing 38" {
    const filename = "./data/listing_0038_many_register_mov";
    try decodeFile(filename, false);
}

test "listing 39" {
    const filename = "./data/listing_0039_more_movs";
    try decodeFile(filename, false);
}

test "listing 40" {
    const filename = "./data/listing_0040_challenge_movs";
    try decodeFile(filename, false);
}

test "listing 41" {
    const filename = "./data/listing_0041_add_sub_cmp_jnz";
    try decodeFile(filename, false);
}

test "listing 43 decode" {
    const filename = "./data/listing_0043_immediate_movs";
    try decodeFile(filename, false);
}

test "listing 43 emulate" {
    const filename = "./data/listing_0043_immediate_movs";
    try decodeFile(filename, true);
}

test "listing 44 decode" {
    const filename = "./data/listing_0044_register_movs";
    try decodeFile(filename, false);
}

test "listing 44 emulate" {
    const filename = "./data/listing_0044_register_movs";
    try decodeFile(filename, true);
}

test "listing 46 decode" {
    const filename = "./data/listing_0046_add_sub_cmp";
    try decodeFile(filename, false);
}

test "listing 46 emulate" {
    const filename = "./data/listing_0046_add_sub_cmp";
    try decodeFile(filename, true);
}

test "listing 48 emulate" {
    const filename = "./data/listing_0048_ip_register";
    try decodeFile(filename, true);
}

test "listing 49 emulate" {
    const filename = "./data/listing_0049_conditional_jumps";
    try decodeFile(filename, true);
}

test "listing 51 emulate" {
    const filename = "./data/listing_0051_memory_mov";
    try decodeFile(filename, true);
}

test "listing 52 emulate" {
    const filename = "./data/listing_0052_memory_add_loop";
    try decodeFile(filename, true);
}

test "listing 54 emulate" {
    const filename = "./data/listing_0054_draw_rectangle";
    try decodeFile(filename, true);
}
