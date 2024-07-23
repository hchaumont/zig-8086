const std = @import("std");
const Instruction = @import("decoder_tree.zig").Instruction;

pub const Emulator = struct {
    var memory = [_]u8{0} ** (1024 * 1024);
    var registers = [_]u16{0} ** 8;
    const regNames = [_]*const [2:0]u8{ "ax", "bx", "cx", "dx", "sp", "bp", "si", "di" };
    var signFlag: bool = false;
    var zeroFlag: bool = false;

    pub fn emulateInstruction(self: *Emulator, writer: anytype, instruction: *Instruction, prev_index: u16, current_index: *u16) !void {
        const operandSource = instruction.getOperandSource();
        const operandDest = instruction.getOperandDest();
        switch (instruction.opcode) {
            Instruction.OpCode.mov => {
                try self.emulateMov(writer, operandSource, operandDest);
            },
            Instruction.OpCode.add => {
                try self.emulateAdd(writer, operandSource, operandDest);
            },
            Instruction.OpCode.sub => {
                try self.emulateSub(writer, operandSource, operandDest);
            },
            Instruction.OpCode.cmp => {
                try self.emulateCmp(writer, operandSource, operandDest);
            },
            Instruction.OpCode.jnz => {
                try self.emulateJnz(operandDest, current_index);
            },
            else => {
                // nothing
            },
        }
        try std.fmt.format(writer, "ip {x} -> {x}", .{ prev_index, current_index.* });
    }

    pub fn printRegisters(self: *Emulator, writer: anytype) !void {
        _ = self;
        try writer.writeAll("Final Registers:\n");
        for (registers, 0..) |reg, i| {
            try std.fmt.format(writer, "      {s}: 0x{x:0>4}\n", .{ regNames[i], reg });
        }
    }

    pub fn printFlags(self: *Emulator, writer: anytype) !void {
        _ = self;
        try writer.writeAll("Final Flags: ");
        if (signFlag) try writer.writeAll("S");
        if (zeroFlag) try writer.writeAll("Z");
        try writer.writeAll("\n");
    }

    fn setFlags(newVal: u16) void {
        if (newVal == 0) {
            zeroFlag = true;
            signFlag = false;
        } else if ((newVal & 0x8000) != 0) {
            signFlag = true;
            zeroFlag = false;
        } else {
            signFlag = false;
            zeroFlag = false;
        }
    }

    fn emulateMov(self: *Emulator, writer: anytype, operandSource: Instruction.Operand, operandDest: Instruction.Operand) !void {
        _ = self;
        // _ = writer;
        var newVal: u16 = 0;
        switch (operandSource) {
            .immed => |immed| {
                newVal = immed;
            },
            .reg => |reg| {
                newVal = registers[reg.regIndex];
                // TODO: Deal with half-width registers
            },
            .effectiveAddress => |ea| {
                var memory_addr: usize = 0;
                if (ea.regIndex1 != null) {
                    memory_addr += registers[ea.regIndex1.?];
                }
                if (ea.regIndex2 != null) {
                    memory_addr += registers[ea.regIndex2.?];
                }
                memory_addr += ea.displacement;
                newVal = @as(u16, memory[memory_addr]) + (@as(u16, memory[memory_addr + 1]) << 8);
            },
            .none => {},
        }
        var oldVal: u16 = 0;
        switch (operandDest) {
            .immed => {},
            .reg => |reg| {
                oldVal = registers[reg.regIndex];
                registers[reg.regIndex] = newVal;
            },
            .effectiveAddress => |ea| {
                var memory_addr: usize = 0;
                if (ea.regIndex1 != null) {
                    memory_addr += registers[ea.regIndex1.?];
                }
                if (ea.regIndex2 != null) {
                    memory_addr += registers[ea.regIndex2.?];
                }
                memory_addr += ea.displacement;
                oldVal = @as(u16, memory[memory_addr]) + (@as(u16, memory[memory_addr + 1]) << 8);
                memory[memory_addr] = @truncate(newVal);
                memory[memory_addr + 1] = @truncate(newVal >> 8);
            },
            else => {},
        }
        try std.fmt.format(writer, "Old Value: {x} New Value: {x} ; ", .{ oldVal, newVal });
    }

    fn emulateAdd(self: *Emulator, writer: anytype, operandSource: Instruction.Operand, operandDest: Instruction.Operand) !void {
        _ = self;
        var summand: u16 = 0;
        var newVal: u16 = 0;
        switch (operandSource) {
            .immed => |immed| {
                summand = immed;
            },
            .reg => |reg| {
                summand = registers[reg.regIndex];
            },
            else => {},
        }
        var oldVal: u16 = 0;
        switch (operandDest) {
            .reg => |reg| {
                oldVal = registers[reg.regIndex];
                const addResult = @addWithOverflow(registers[reg.regIndex], summand);
                // TODO: Check overflow bit if we care about flag
                registers[reg.regIndex] = addResult[0];
                newVal = registers[reg.regIndex];
            },
            else => {},
        }
        setFlags(newVal);
        try std.fmt.format(writer, "Old Value: {x} New Value: {x} ; ", .{ oldVal, newVal });
    }

    fn emulateSub(self: *Emulator, writer: anytype, operandSource: Instruction.Operand, operandDest: Instruction.Operand) !void {
        _ = self;
        var oldVal: u16 = 0;
        var subtrahend: u16 = 0;
        var newVal: u16 = 0;
        switch (operandSource) {
            .immed => |immed| {
                subtrahend = immed;
            },
            .reg => |reg| {
                subtrahend = registers[reg.regIndex];
            },
            else => {},
        }
        switch (operandDest) {
            .reg => |reg| {
                oldVal = registers[reg.regIndex];
                const subResult = @subWithOverflow(registers[reg.regIndex], subtrahend);
                // TODO: check overflow bit if we care about setting that flag
                registers[reg.regIndex] = subResult[0];
                newVal = registers[reg.regIndex];
            },
            else => {},
        }
        setFlags(newVal);
        try std.fmt.format(writer, "Old Value: {x} New Value: {x} ; ", .{ oldVal, newVal });
    }

    fn emulateCmp(self: *Emulator, writer: anytype, operandSource: Instruction.Operand, operandDest: Instruction.Operand) !void {
        _ = self;
        var oldVal: u16 = 0;
        var subtrahend: u16 = 0;
        var newVal: u16 = 0;
        switch (operandSource) {
            .immed => |immed| {
                subtrahend = immed;
            },
            .reg => |reg| {
                subtrahend = registers[reg.regIndex];
            },
            else => {},
        }
        switch (operandDest) {
            .reg => |reg| {
                oldVal = registers[reg.regIndex];
                const subResult = @subWithOverflow(registers[reg.regIndex], subtrahend);
                // TODO: check overflow bit if we care about setting that flag
                newVal = subResult[0];
                // we don't set the value
            },
            else => {},
        }
        setFlags(newVal);
        try std.fmt.format(writer, "Cmp value: {x} ; ", .{newVal});
    }

    fn emulateJnz(self: *Emulator, operandDest: Instruction.Operand, current_index: *u16) !void {
        _ = self;
        if (!zeroFlag) {
            const offset = operandDest.immed;
            const new_index = @addWithOverflow(current_index.*, offset);
            current_index.* = new_index[0];
        }
    }
};
