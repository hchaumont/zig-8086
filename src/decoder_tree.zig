const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expect = std.testing.expect;
const Allocator = std.mem.Allocator;

pub const Instruction = struct {
    pub const OpCode = enum {
        mov,
        add,
        sub,
        cmp,
        jnz,
        je,
        jl,
        jle,
        jb,
        jbe,
        jp,
        jo,
        js,
        jne,
        jnl,
        jg,
        jnb,
        ja,
        jnp,
        jno,
        jns,
        loop,
        loopz,
        loopnz,
        jcxz,
        none,
    };

    pub const Operand = union(enum) {
        immed: u16,
        reg: RegisterOperand,
        effectiveAddress: EffectiveAddressOperand,
        none,

        const RegisterOperand = struct {
            const RegWidth = enum {
                low,
                high,
                full,
            };
            width: RegWidth = .full,
            regIndex: u3 = 0,
        };

        const EffectiveAddressOperand = struct {
            regIndex1: ?u3 = null,
            regIndex2: ?u3 = null,
            displacement: u16 = 0,
        };
    };

    const Mod = enum(u2) {
        mem_mode = 0b00,
        mem_mode_8_bit = 0b01,
        mem_mode_16_bit = 0b10,
        reg_mode = 0b11,
    };

    const Type = enum {
        reg_rm,
        reg_mem,
        immed_reg,
        immed_rm_mov,
        immed_rm_multi_inst, // shared by add, sub, cmp
        jump,
        none,
    };

    opcode: OpCode = .none,
    type: Type = .none,
    mod: ?Mod,
    d: bool = false,
    w: bool = false,
    s: bool = false,
    reg: ?u3 = null,
    rm: ?u3 = null,
    displ: ?u8 = null,
    disph: ?u8 = null,
    datal: ?u8 = null,
    datah: ?u8 = null,

    pub fn reset(self: *Instruction) void {
        self.opcode = .none;
        self.type = .none;
        self.mod = null;
        self.d = false;
        self.w = false;
        self.s = false;
        self.reg = null;
        self.rm = null;
        self.displ = null;
        self.disph = null;
        self.datal = null;
        self.datah = null;
    }

    pub fn printInstruction(self: *Instruction, writer: anytype) !void {
        try std.fmt.format(writer, "{s}", .{@tagName(self.opcode)});
        try self.printOperandDest(writer);
        try self.printOperandSource(writer);
    }

    fn decodeRegister(w: bool, reg: u3) []const u8 {
        if (!w) {
            return switch (reg) {
                0b000 => "al",
                0b001 => "cl",
                0b010 => "dl",
                0b011 => "bl",
                0b100 => "ah",
                0b101 => "ch",
                0b110 => "dh",
                0b111 => "bh",
            };
        } else {
            return switch (reg) {
                0b000 => "ax",
                0b001 => "cx",
                0b010 => "dx",
                0b011 => "bx",
                0b100 => "sp",
                0b101 => "bp",
                0b110 => "si",
                0b111 => "di",
            };
        }
    }

    fn decodeEffectiveAddress(rm: u3) []const u8 {
        return switch (rm) {
            0b000 => "bx + si",
            0b001 => "bx + di",
            0b010 => "bp + si",
            0b011 => "bp + di",
            0b100 => "si",
            0b101 => "di",
            0b110 => "bp",
            0b111 => "bx",
        };
    }

    fn printOperandDest(self: *Instruction, writer: anytype) !void {
        switch (self.type) {
            Type.reg_rm => {
                assert(self.mod != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        const register = if (self.d) self.reg.? else self.rm.?;
                        try std.fmt.format(writer, " {s}", .{decodeRegister(self.w, register)});
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        if (self.d) {
                            try std.fmt.format(writer, " {s}", .{decodeRegister(self.w, self.reg.?)});
                        } else {
                            try printEffectiveAddress(self, writer);
                        }
                    },
                }
            },
            Type.immed_rm_mov => {
                try printEffectiveAddress(self, writer);
            },
            Type.immed_rm_multi_inst => {
                assert(self.mod != null);
                assert(self.rm != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        try std.fmt.format(writer, " {s}", .{decodeRegister(self.w, self.rm.?)});
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        try printEffectiveAddress(self, writer);
                    },
                }
            },
            Type.immed_reg => {
                assert(self.reg != null);
                try std.fmt.format(writer, " {s}", .{decodeRegister(self.w, self.reg.?)});
            },
            Type.reg_mem => {
                assert(self.reg != null);
                assert(self.displ != null);
                assert(self.disph != null);
                if (self.d) {
                    try std.fmt.format(writer, " {s}", .{decodeRegister(self.w, self.reg.?)});
                } else {
                    const mem_loc: u16 = @as(u16, self.displ.?) + (@as(u16, self.disph.?) << 8);
                    try std.fmt.format(writer, " [{d}]", .{mem_loc});
                }
            },
            Type.jump => {
                assert(self.displ != null);
                const ip_inc8: i8 = @bitCast(self.displ.?);
                try std.fmt.format(writer, " {d}", .{ip_inc8});
            },
            Type.none => {
                print("none", .{});
            },
        }
    }

    pub fn getOperandDest(self: *Instruction) Operand {
        switch (self.type) {
            Type.reg_rm => {
                assert(self.mod != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        const register = if (self.d) self.reg.? else self.rm.?;
                        const reg = getRegisterIndex(self.w, register);
                        return Operand{ .reg = reg };
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        if (self.d) {
                            const reg = getRegisterIndex(self.w, self.reg.?);
                            return Operand{ .reg = reg };
                        } else {
                            return getEffectiveAddress(self);
                        }
                    },
                }
            },
            Type.immed_rm_mov => {
                return getEffectiveAddress(self);
            },
            Type.immed_rm_multi_inst => {
                assert(self.mod != null);
                assert(self.rm != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        const reg = getRegisterIndex(self.w, self.rm.?);
                        return Operand{ .reg = reg };
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        return getEffectiveAddress(self);
                    },
                }
            },
            Type.immed_reg => {
                assert(self.reg != null);
                const reg = getRegisterIndex(self.w, self.reg.?);
                return Operand{ .reg = reg };
            },
            Type.jump => {
                assert(self.displ != null);
                const signExtend = (self.displ.? & 0b1000_0000) != 0;
                var offset = @as(u16, self.displ.?);
                if (signExtend) {
                    offset += 0b1111_1111_0000_0000;
                }
                return .{ .immed = offset };
            },
            else => {
                // TODO: Implement when we get to it.
                return .{ .none = @as(void, undefined) };
            },
        }
    }

    fn getRegisterIndex(w: bool, regrm: u3) Operand.RegisterOperand {
        var reg = Operand.RegisterOperand{};
        if (w) {
            reg.width = .full;
            switch (regrm) {
                0b000 => {
                    reg.regIndex = 0; // ax
                },
                0b001 => {
                    reg.regIndex = 2; // cx
                },
                0b010 => {
                    reg.regIndex = 3; // dx
                },
                0b011 => {
                    reg.regIndex = 1; // bx
                },
                0b100 => {
                    reg.regIndex = 4; // sp
                },
                0b101 => {
                    reg.regIndex = 5; // bp
                },
                0b110 => {
                    reg.regIndex = 6; // si
                },
                0b111 => {
                    reg.regIndex = 7; // di
                },
            }
        } else {
            switch (regrm) {
                0b000 => {
                    reg.regIndex = 0; // al
                    reg.width = .low;
                },
                0b001 => {
                    reg.regIndex = 2; // cl
                    reg.width = .low;
                },
                0b010 => {
                    reg.regIndex = 3; // dl
                    reg.width = .low;
                },
                0b011 => {
                    reg.regIndex = 1; // bl
                    reg.width = .low;
                },
                0b100 => {
                    reg.regIndex = 0; // ah
                    reg.width = .high;
                },
                0b101 => {
                    reg.regIndex = 2; // ch
                    reg.width = .high;
                },
                0b110 => {
                    reg.regIndex = 3; // dh
                    reg.width = .high;
                },
                0b111 => {
                    reg.regIndex = 1; // bh
                    reg.width = .high;
                },
            }
        }
        return reg;
    }

    pub fn getOperandSource(self: *Instruction) Operand {
        switch (self.type) {
            Type.reg_rm => {
                assert(self.mod != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        const register = if (self.d) self.rm.? else self.reg.?;
                        const reg = getRegisterIndex(self.w, register);
                        return Operand{ .reg = reg };
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        if (!self.d) {
                            const reg = getRegisterIndex(self.w, self.reg.?);
                            return Operand{ .reg = reg };
                        } else {
                            return getEffectiveAddress(self);
                        }
                    },
                }
            },
            Type.immed_reg, Type.immed_rm_mov => {
                const data = @as(u16, self.datal.?) + (@as(u16, self.datah orelse 0) << 8);
                return Operand{ .immed = data };
            },
            Type.immed_rm_multi_inst => {
                assert(self.datal != null);
                const signExtend = self.s and !self.w;
                const negativeExtend = (self.datal.? & 0b1000_0000) != 0;
                if (signExtend and negativeExtend) {
                    const immed: u16 = @as(u16, self.datal.?) + 0b1111_1111_0000_0000;
                    return Operand{ .immed = immed };
                } else {
                    const immed = @as(u16, self.datal.?) + (@as(u16, self.datah orelse 0) << 8);
                    return Operand{ .immed = immed };
                }
            },
            else => {
                // TODO: Implement when we get to it.
                return .{ .none = @as(void, undefined) };
            },
        }
    }

    fn printOperandSource(self: *Instruction, writer: anytype) !void {
        switch (self.type) {
            Type.reg_rm => {
                assert(self.mod != null);
                switch (self.mod.?) {
                    .reg_mode => {
                        const register = if (self.d) self.rm.? else self.reg.?;
                        try std.fmt.format(writer, ", {s}", .{decodeRegister(self.w, register)});
                    },
                    .mem_mode, .mem_mode_8_bit, .mem_mode_16_bit => {
                        if (!self.d) {
                            try std.fmt.format(writer, ", {s}", .{decodeRegister(self.w, self.reg.?)});
                        } else {
                            try writer.writeAll(",");
                            try printEffectiveAddress(self, writer);
                        }
                    },
                }
            },
            Type.immed_rm_mov => {
                if (self.datah == null) {
                    try std.fmt.format(writer, ", byte {d}", .{self.datal.?});
                } else {
                    const immed = @as(u16, self.datal.?) + (@as(u16, self.datah.?) << 8);
                    try std.fmt.format(writer, ", word {d}", .{immed});
                }
            },
            Type.immed_rm_multi_inst => {
                try printImmediate(self, writer);
            },
            Type.immed_reg => {
                const data = @as(u16, self.datal.?) + (@as(u16, self.datah orelse 0) << 8);
                try std.fmt.format(writer, ", {d}", .{data});
            },
            Type.reg_mem => {
                if (!self.d) {
                    try std.fmt.format(writer, ", {s}", .{decodeRegister(self.w, self.reg.?)});
                } else {
                    const mem_loc: u16 = @as(u16, self.displ.?) + (@as(u16, self.disph.?) << 8);
                    try std.fmt.format(writer, ", [{d}]", .{mem_loc});
                }
            },
            Type.jump => {
                // No second operand
                return;
            },
            Type.none => {
                print("none", .{});
            },
        }
    }

    fn getEffectiveAddress(self: *Instruction) Operand {
        assert(self.rm != null);
        var ea = Operand.EffectiveAddressOperand{};
        const signExtendNegative = if (self.displ != null and self.disph == null and self.displ.? & 0b1000_0000 != 0) true else false;
        const displacement: u16 = if (signExtendNegative) (@as(u16, self.displ.?) + 0b1111_1111_0000_0000) else (@as(u16, self.displ orelse 0) + (@as(u16, self.disph orelse 0) << 8));
        ea.displacement = displacement;
        if (self.mod.? == Mod.mem_mode and self.rm.? == 0b110) { // direct address
            return .{ .effectiveAddress = ea };
        }
        switch (self.rm.?) {
            0b000 => {
                ea.regIndex1 = 1;
                ea.regIndex2 = 6;
            },
            0b001 => {
                ea.regIndex1 = 1;
                ea.regIndex2 = 7;
            },
            0b010 => {
                ea.regIndex1 = 5;
                ea.regIndex2 = 6;
            },
            0b011 => {
                ea.regIndex1 = 5;
                ea.regIndex2 = 7;
            },
            0b100 => {
                ea.regIndex1 = 6;
            },
            0b101 => {
                ea.regIndex1 = 7;
            },
            0b110 => {
                ea.regIndex1 = 5;
            },
            0b111 => {
                ea.regIndex1 = 1;
            },
        }
        return .{ .effectiveAddress = ea };
    }

    fn printEffectiveAddress(self: *Instruction, writer: anytype) !void {
        const signExtendNegative = if (self.displ != null and self.disph == null and self.displ.? & 0b1000_0000 != 0) true else false;
        const displacement: i16 = if (signExtendNegative) @bitCast(@as(u16, self.displ.?) + 0b1111_1111_0000_0000) else @bitCast(@as(u16, self.displ orelse 0) + (@as(u16, self.disph orelse 0) << 8));
        if (self.mod.? == Mod.mem_mode and self.rm.? == 0b110) { // direct address
            try std.fmt.format(writer, " [{d}]", .{displacement});
        } else if (displacement == 0) {
            try std.fmt.format(writer, " [{s}]", .{decodeEffectiveAddress(self.rm.?)});
        } else if (displacement < 0) {
            const abs: u32 = @abs(displacement);
            try std.fmt.format(writer, " [{s} - {d}]", .{ decodeEffectiveAddress(self.rm.?), abs });
        } else {
            try std.fmt.format(writer, " [{s} + {d}]", .{ decodeEffectiveAddress(self.rm.?), displacement });
        }
    }

    fn printImmediate(self: *Instruction, writer: anytype) !void {
        assert(self.datal != null);
        const signExtend = self.s and !self.w;
        const negativeExtend = (self.datal.? & 0b1000_0000) != 0;
        if (signExtend and negativeExtend) {
            const immed: i16 = @bitCast(@as(u16, self.datal.?) + 0b1111_1111_0000_0000);
            try std.fmt.format(writer, ", {d}", .{immed});
        } else {
            const immed = @as(u16, self.datal.?) + (@as(u16, self.datah orelse 0) << 8);
            try std.fmt.format(writer, ", {d}", .{immed});
        }
    }
};

// Decoder Node and Tree
// ---------------------
const DecoderNode = struct {
    children: std.EnumMap(ByteDecoderTypes, *DecoderNode),
    isTerminal: bool,
};

pub const DecoderTree = struct {
    const Self = @This();
    root: ?*DecoderNode = null,
    count: usize = 0,
    allocator: Allocator,

    fn addToTree(self: *Self, decoderWord: []const ByteDecoderTypes) !void {
        if (self.root == null) {
            const rootNode = try self.allocator.create(DecoderNode);
            rootNode.* = .{ .isTerminal = false, .children = std.enums.EnumMap(ByteDecoderTypes, *DecoderNode){} };
            self.root = rootNode;
            self.count += 1;
        }
        var current_node = self.root.?;
        for (decoderWord) |decoderType| {
            if (current_node.children.contains(decoderType)) {
                current_node = current_node.children.getAssertContains(decoderType);
            } else {
                const next_node = try self.allocator.create(DecoderNode);
                next_node.* = .{
                    .children = std.enums.EnumMap(ByteDecoderTypes, *DecoderNode){},
                    .isTerminal = false,
                };

                current_node.children.put(decoderType, next_node);
                current_node = next_node;
                self.count += 1;
            }
        }
        current_node.isTerminal = true;
    }

    const DecoderError = error{
        FailedToMatch,
    };

    pub fn decode(self: Self, array_list: *std.ArrayList(u8), current_index: u16, instruction: *Instruction) DecoderError!u16 {
        assert(self.root != null);
        var current = self.root.?;
        var index = current_index;
        var current_byte: u8 = undefined;
        while (!current.isTerminal) {
            assert(index < array_list.items.len);
            current_byte = array_list.items[index];
            var matched: bool = false;
            var iterator = current.children.iterator();
            outer: while (iterator.next()) |entry| {
                const child = byteDecoderArray.get(entry.key);
                const masked_value = current_byte & child.bit_mask;
                for (child.bit_value) |bit_val| {
                    if (masked_value == bit_val) {
                        matched = true;
                        // print("matched node: {any}", .{entry.key});
                        child.read_data(current_byte, instruction);
                        current = entry.value.*;
                        break :outer;
                    }
                }
            }
            if (!matched) {
                print("Failed to match at index {d}!\n", .{index});
                print("Byte: {b:0>8}\n", .{current_byte});
                return DecoderError.FailedToMatch;
            }
            index += 1;
        }
        return index;
    }

    pub fn initTree(allocator: Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }
};

pub const ByteDecoderTypes = enum {
    // First mov, add, sub, cmp
    // TODO: Rename this type
    mov_reg_mem_to_from_reg_head,
    read_mod_reg_rm_reg_mode,
    read_mod_reg_rm_mem_mode_8b_disp,
    read_mod_reg_rm_mem_mode_16b_disp,
    read_mod_reg_rm_mem_mode_direct_addr,
    read_mod_reg_rm_mem_mode,

    // Second mov
    mov_imm_to_reg_mem_byte,
    mov_imm_to_reg_mem_word,
    read_mod_000_rm_reg_mode,
    read_mod_000_rm_mem_mode_8b_disp,
    read_mod_000_rm_mem_mode_16b_disp,
    read_mod_000_rm_mem_mode_direct_addr,
    read_mod_000_rm_mem_mode,

    // Third mov
    mov_imm_reg_8b,
    mov_imm_reg_16b,

    // Fourth mov
    mov_mem_acc,

    // Second add/sub/cmp
    imm_to_rm_head_byte,
    imm_to_rm_head_word,
    read_mod_inst_rm_reg_mode,
    read_mod_inst_rm_mem_mode_8b_disp,
    read_mod_inst_rm_mem_mode_16b_disp,
    read_mod_inst_rm_mem_mode_direct_addr,
    read_mod_inst_rm_mem_mode,

    // third add/sub/cmp
    imm_to_acc_head_byte,
    imm_to_acc_head_word,

    // jumps
    jnz,
    je,
    jl,
    jle,
    jb,
    jbe,
    jp,
    jo,
    js,
    jne,
    jnl,
    jg,
    jnb,
    ja,
    jnp,
    jno,
    jns,
    loop,
    loopz,
    loopnz,
    jcxz,

    // Shared
    read_disp_low,
    read_disp_high,
    read_data_low,
    read_data_high,
};

pub const byteDecoderArray = std.EnumArray(ByteDecoderTypes, ByteDecoder).init(.{
    .mov_reg_mem_to_from_reg_head = ByteDecoder{
        .bit_mask = 0b1111_1100,
        .bit_value = &[_]u8{ 0b1000_1000, 0b0000_0000, 0b0010_1000, 0b0011_1000 },
        .read_data = readMov,
    },
    .read_mod_reg_rm_reg_mode = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b1100_0000},
        .read_data = readModRegRm,
    },
    .read_mod_reg_rm_mem_mode_8b_disp = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b0100_0000},
        .read_data = readModRegRm,
    },
    .read_mod_reg_rm_mem_mode_16b_disp = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b1000_0000},
        .read_data = readModRegRm,
    },
    .read_mod_reg_rm_mem_mode_direct_addr = ByteDecoder{
        .bit_mask = 0b1100_0111,
        .bit_value = &[_]u8{0b0000_0110},
        .read_data = readModRegRm,
    },
    .read_mod_reg_rm_mem_mode = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readModRegRm,
    },
    .mov_imm_to_reg_mem_byte = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1100_0110},
        .read_data = readMovImmedToRegMem,
    },
    .mov_imm_to_reg_mem_word = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1100_0111},
        .read_data = readMovImmedToRegMem,
    },
    .read_disp_low = ByteDecoder{
        .bit_mask = 0b0000_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readDispLow,
    },
    .read_disp_high = ByteDecoder{
        .bit_mask = 0b0000_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readDispHigh,
    },
    .mov_imm_reg_8b = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b1011_0000},
        .read_data = readMovImmedReg,
    },
    .mov_imm_reg_16b = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b1011_1000},
        .read_data = readMovImmedReg,
    },
    .read_data_low = ByteDecoder{
        .bit_mask = 0b0000_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readDataLow,
    },
    .read_data_high = ByteDecoder{
        .bit_mask = 0b0000_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readDataHigh,
    },
    .read_mod_000_rm_reg_mode = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b1100_0000},
        .read_data = readMod000Rm,
    },
    .read_mod_000_rm_mem_mode_8b_disp = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b0100_0000},
        .read_data = readMod000Rm,
    },
    .read_mod_000_rm_mem_mode_16b_disp = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b1000_0000},
        .read_data = readMod000Rm,
    },
    .read_mod_000_rm_mem_mode_direct_addr = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0000_0110},
        .read_data = readMod000Rm,
    },
    .read_mod_000_rm_mem_mode = ByteDecoder{
        .bit_mask = 0b1111_1000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readMod000Rm,
    },
    .mov_mem_acc = ByteDecoder{
        .bit_mask = 0b1111_1100,
        .bit_value = &[_]u8{0b1010_0000},
        .read_data = readMemAcc,
    },
    .imm_to_rm_head_byte = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{ 0b1000_0000, 0b1000_0010, 0b1000_0011 },
        .read_data = readImmedToRmHead,
    },
    .imm_to_rm_head_word = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1000_0001},
        .read_data = readImmedToRmHead,
    },
    // For add, sub, cmp
    .read_mod_inst_rm_reg_mode = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b1100_0000},
        .read_data = readModInstRm,
    },
    .read_mod_inst_rm_mem_mode_8b_disp = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b0100_0000},
        .read_data = readModInstRm,
    },
    .read_mod_inst_rm_mem_mode_16b_disp = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b1000_0000},
        .read_data = readModInstRm,
    },
    .read_mod_inst_rm_mem_mode_direct_addr = ByteDecoder{
        .bit_mask = 0b1100_0111,
        .bit_value = &[_]u8{0b0000_0110},
        .read_data = readModInstRm,
    },
    .read_mod_inst_rm_mem_mode = ByteDecoder{
        .bit_mask = 0b1100_0000,
        .bit_value = &[_]u8{0b0000_0000},
        .read_data = readModInstRm,
    },
    .imm_to_acc_head_byte = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{ 0b0000_0100, 0b0010_1100, 0b0011_1100 },
        .read_data = readImmedToAcc,
    },
    .imm_to_acc_head_word = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{ 0b0000_0101, 0b0010_1101, 0b0011_1101 },
        .read_data = readImmedToAcc,
    },
    .jnz = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0101},
        .read_data = readJnz,
    },
    .je = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0100},
        .read_data = readJe,
    },
    .jl = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1100},
        .read_data = readJl,
    },
    .jle = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1110},
        .read_data = readJle,
    },
    .jb = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0010},
        .read_data = readJb,
    },
    .jbe = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0110},
        .read_data = readJbe,
    },
    .jp = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1010},
        .read_data = readJp,
    },
    .jo = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0000},
        .read_data = readJo,
    },
    .js = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1000},
        .read_data = readJs,
    },
    .jne = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0101},
        .read_data = readJne,
    },
    .jnl = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1101},
        .read_data = readJnl,
    },
    .jg = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1111},
        .read_data = readJg,
    },
    .jnb = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0011},
        .read_data = readJnb,
    },
    .ja = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0111},
        .read_data = readJa,
    },
    .jnp = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1011},
        .read_data = readJnp,
    },
    .jno = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_0001},
        .read_data = readJno,
    },
    .jns = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b0111_1001},
        .read_data = readJns,
    },
    .loop = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1110_0010},
        .read_data = readLoop,
    },
    .loopz = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1110_0001},
        .read_data = readLoopz,
    },
    .loopnz = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1110_0000},
        .read_data = readLoopnz,
    },
    .jcxz = ByteDecoder{
        .bit_mask = 0b1111_1111,
        .bit_value = &[_]u8{0b1110_0011},
        .read_data = readJcxz,
    },
});

test "initializes byteDecoderArray" {
    print("byteDecoderArray length: {d}\n", .{byteDecoderArray.values.len});
    try expect(byteDecoderArray.values.len > 0);
}

const decoder_words: [51][]const ByteDecoderTypes = .{
    // NOTE: First mov/add/sub/cmp
    // reg to reg mov
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_reg_mem_to_from_reg_head, ByteDecoderTypes.read_mod_reg_rm_reg_mode },
    // reg to mem mov effective address 8bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_reg_mem_to_from_reg_head, ByteDecoderTypes.read_mod_reg_rm_mem_mode_8b_disp, ByteDecoderTypes.read_disp_low },
    // reg to mem mov effective address 16bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_reg_mem_to_from_reg_head, ByteDecoderTypes.read_mod_reg_rm_mem_mode_16b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high },
    // reg to mem mov direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_reg_mem_to_from_reg_head, ByteDecoderTypes.read_mod_reg_rm_mem_mode_direct_addr, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high },
    // reg to mem mov effective address no disp
    // NOTE: this has to come after direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_reg_mem_to_from_reg_head, ByteDecoderTypes.read_mod_reg_rm_mem_mode },

    // NOTE: Second mov
    // immed to reg/mem mov 8bit reg mode
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_byte, ByteDecoderTypes.read_mod_000_rm_reg_mode, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem 8bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_byte, ByteDecoderTypes.read_mod_000_rm_mem_mode_8b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem 16bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_byte, ByteDecoderTypes.read_mod_000_rm_mem_mode_16b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_byte, ByteDecoderTypes.read_mod_000_rm_mem_mode_direct_addr, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem no disp
    // NOTE: this has to come after direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_byte, ByteDecoderTypes.read_mod_000_rm_mem_mode, ByteDecoderTypes.read_data_low },

    // immed to reg/mem mov 16bit reg mode
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_word, ByteDecoderTypes.read_mod_000_rm_reg_mode, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem 8bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_word, ByteDecoderTypes.read_mod_000_rm_mem_mode_8b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem 16bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_word, ByteDecoderTypes.read_mod_000_rm_mem_mode_16b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_word, ByteDecoderTypes.read_mod_000_rm_mem_mode_direct_addr, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem no disp
    // NOTE: this has to come after direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_to_reg_mem_word, ByteDecoderTypes.read_mod_000_rm_mem_mode, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },

    // NOTE: Third mov
    // immed to reg mov 8bit
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_reg_8b, ByteDecoderTypes.read_data_low },
    // immed to reg mov 16bit
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_imm_reg_16b, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },

    // NOTE: Fourth and fifth mov
    // mov mem to/from acc
    &[_]ByteDecoderTypes{ ByteDecoderTypes.mov_mem_acc, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high },

    // NOTE: Second add, sub, cmp
    // immed to reg/mem mov 8bit reg mode
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_byte, ByteDecoderTypes.read_mod_inst_rm_reg_mode, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem 8bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_byte, ByteDecoderTypes.read_mod_inst_rm_mem_mode_8b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem 16bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_byte, ByteDecoderTypes.read_mod_inst_rm_mem_mode_16b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_byte, ByteDecoderTypes.read_mod_inst_rm_mem_mode_direct_addr, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low },
    // immed to reg/mem mov 8bit mem no disp
    // NOTE: this has to come after direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_byte, ByteDecoderTypes.read_mod_inst_rm_mem_mode, ByteDecoderTypes.read_data_low },

    // immed to reg/mem mov 16bit reg mode
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_word, ByteDecoderTypes.read_mod_inst_rm_reg_mode, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem 8bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_word, ByteDecoderTypes.read_mod_inst_rm_mem_mode_8b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem 16bit disp
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_word, ByteDecoderTypes.read_mod_inst_rm_mem_mode_16b_disp, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_word, ByteDecoderTypes.read_mod_inst_rm_mem_mode_direct_addr, ByteDecoderTypes.read_disp_low, ByteDecoderTypes.read_disp_high, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },
    // immed to reg/mem mov 16bit mem no disp
    // NOTE: this has to come after direct address
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_rm_head_word, ByteDecoderTypes.read_mod_inst_rm_mem_mode, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },

    // NOTE: Third add, sub, cmp
    // immed to accum 8bit
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_acc_head_byte, ByteDecoderTypes.read_data_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.imm_to_acc_head_word, ByteDecoderTypes.read_data_low, ByteDecoderTypes.read_data_high },

    // NOTE: Jumps/loops
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jnz, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.je, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jl, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jle, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jb, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jbe, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jp, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jo, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.js, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jne, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jnl, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jg, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jnb, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.ja, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jnp, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jno, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jns, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.loop, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.loopz, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.loopnz, ByteDecoderTypes.read_disp_low },
    &[_]ByteDecoderTypes{ ByteDecoderTypes.jcxz, ByteDecoderTypes.read_disp_low },
};

pub fn getDecoderTree(allocator: Allocator) !DecoderTree {
    var decoder_tree = DecoderTree.initTree(allocator);
    for (decoder_words) |word| {
        try decoder_tree.addToTree(word);
    }
    return decoder_tree;
}

const ByteDecoder = struct {
    bit_mask: u8,
    bit_value: []const u8,
    read_data: *const fn (byte: u8, instruction: *Instruction) void,
};

test "initialize a DecoderTree" {
    const test_allocator = std.testing.allocator;
    var arena_allocator = std.heap.ArenaAllocator.init(test_allocator);
    const allocator = arena_allocator.allocator();
    defer arena_allocator.deinit();

    const decoder_tree = DecoderTree.initTree(allocator);
    try expect(decoder_tree.root == null);
}

test "get a DecoderTree" {
    const test_allocator = std.testing.allocator;
    var arena_allocator = std.heap.ArenaAllocator.init(test_allocator);
    const allocator = arena_allocator.allocator();
    defer arena_allocator.deinit();

    const decoder_tree = try getDecoderTree(allocator);
    try expect(decoder_tree.count > 0);
    print("Node count: {d}\n", .{decoder_tree.count});
}

// ByteDecoder read data functions
// -------------------------------
fn readMov(byte: u8, instruction: *Instruction) void {
    if ((byte & 0b1111_1100) == 0b1000_1000) {
        instruction.opcode = Instruction.OpCode.mov;
    } else if ((byte & 0b1111_1100) == 0b0000_0000) {
        instruction.opcode = Instruction.OpCode.add;
    } else if ((byte & 0b1111_1100) == 0b0010_1000) {
        instruction.opcode = Instruction.OpCode.sub;
    } else if ((byte & 0b1111_1100) == 0b0011_1000) {
        instruction.opcode = Instruction.OpCode.cmp;
    } else {
        unreachable;
    }
    instruction.d = byte & 0b00000010 != 0;
    instruction.w = byte & 0b00000001 != 0;
    instruction.type = Instruction.Type.reg_rm;
}

fn readModRegRm(byte: u8, instruction: *Instruction) void {
    instruction.mod = @enumFromInt(@as(u2, @truncate(byte >> 6)));
    instruction.reg = @truncate(byte >> 3);
    instruction.rm = @truncate(byte);
}

fn readMovDirectAddress(byte: u8, instruction: *Instruction) void {
    instruction.mod = Instruction.Mod.mem_mode;
    instruction.reg = @truncate((byte & 0b00111000) >> 3);
}

fn readDispLow(byte: u8, instruction: *Instruction) void {
    instruction.displ = byte;
}

fn readDispHigh(byte: u8, instruction: *Instruction) void {
    instruction.disph = byte;
}

fn readMovImmedReg(byte: u8, instruction: *Instruction) void {
    instruction.opcode = Instruction.OpCode.mov;
    instruction.type = Instruction.Type.immed_reg;
    instruction.w = (byte & 0b0000_1000) == 0b0000_1000;
    instruction.reg = @truncate(byte);
}

fn readDataLow(byte: u8, instruction: *Instruction) void {
    instruction.datal = byte;
}

fn readDataHigh(byte: u8, instruction: *Instruction) void {
    instruction.datah = byte;
}

fn readMovImmedToRegMem(byte: u8, instruction: *Instruction) void {
    instruction.opcode = Instruction.OpCode.mov;
    instruction.type = Instruction.Type.immed_rm_mov;
    instruction.w = (byte & 0b0000_0001 != 0);
    instruction.d = false;
}

fn readMod000Rm(byte: u8, instruction: *Instruction) void {
    instruction.mod = @enumFromInt(@as(u2, @truncate(byte >> 6)));
    instruction.rm = @truncate(byte);
}

fn readModInstRm(byte: u8, instruction: *Instruction) void {
    if ((byte & 0b0011_1000) == 0b0000_0000) {
        instruction.opcode = Instruction.OpCode.add;
    } else if ((byte & 0b0011_1000) == 0b0010_1000) {
        instruction.opcode = Instruction.OpCode.sub;
    } else if ((byte & 0b0011_1000) == 0b0011_1000) {
        instruction.opcode = Instruction.OpCode.cmp;
    } else {
        unreachable;
    }
    instruction.mod = @enumFromInt(@as(u2, @truncate(byte >> 6)));
    instruction.rm = @truncate(byte);
}

fn readMemAcc(byte: u8, instruction: *Instruction) void {
    instruction.opcode = Instruction.OpCode.mov;
    instruction.type = Instruction.Type.reg_mem;
    instruction.w = (byte & 0b0000_0001) != 0;
    instruction.reg = 0b000;
    if ((byte & 0b0000_0010) != 0) {
        instruction.d = false;
    } else {
        instruction.d = true;
    }
}

fn readImmedToRmHead(byte: u8, instruction: *Instruction) void {
    instruction.type = Instruction.Type.immed_rm_multi_inst;
    instruction.s = (byte & 0b0000_0010) != 0;
    instruction.w = (byte & 0b0000_0001) != 0;
}

fn readImmedToAcc(byte: u8, instruction: *Instruction) void {
    if ((byte & 0b1111_1100) == 0b0000_0100) {
        instruction.opcode = Instruction.OpCode.add;
    } else if ((byte & 0b1111_1100) == 0b0010_1100) {
        instruction.opcode = Instruction.OpCode.sub;
    } else if ((byte & 0b1111_1100) == 0b0011_1100) {
        instruction.opcode = Instruction.OpCode.cmp;
    } else {
        unreachable;
    }
    instruction.type = Instruction.Type.immed_reg;
    instruction.d = true;
    instruction.w = (byte & 0b0000_0001) != 0;
    instruction.reg = 0b000;
}

fn readJnz(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jnz;
    instruction.type = Instruction.Type.jump;
}

fn readJe(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.je;
    instruction.type = Instruction.Type.jump;
}

fn readJl(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jl;
    instruction.type = Instruction.Type.jump;
}

fn readJle(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jle;
    instruction.type = Instruction.Type.jump;
}

fn readJb(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jb;
    instruction.type = Instruction.Type.jump;
}

fn readJbe(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jbe;
    instruction.type = Instruction.Type.jump;
}

fn readJp(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jp;
    instruction.type = Instruction.Type.jump;
}

fn readJo(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jo;
    instruction.type = Instruction.Type.jump;
}

fn readJs(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.js;
    instruction.type = Instruction.Type.jump;
}

fn readJne(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jne;
    instruction.type = Instruction.Type.jump;
}

fn readJnl(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jnl;
    instruction.type = Instruction.Type.jump;
}

fn readJg(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jg;
    instruction.type = Instruction.Type.jump;
}

fn readJnb(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jnb;
    instruction.type = Instruction.Type.jump;
}

fn readJa(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.ja;
    instruction.type = Instruction.Type.jump;
}

fn readJnp(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jnp;
    instruction.type = Instruction.Type.jump;
}

fn readJno(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jno;
    instruction.type = Instruction.Type.jump;
}

fn readJns(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jns;
    instruction.type = Instruction.Type.jump;
}

fn readLoop(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.loop;
    instruction.type = Instruction.Type.jump;
}

fn readLoopz(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.loopz;
    instruction.type = Instruction.Type.jump;
}

fn readLoopnz(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.loopnz;
    instruction.type = Instruction.Type.jump;
}

fn readJcxz(byte: u8, instruction: *Instruction) void {
    _ = byte;
    instruction.opcode = Instruction.OpCode.jcxz;
    instruction.type = Instruction.Type.jump;
}
