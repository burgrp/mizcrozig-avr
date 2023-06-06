const std = @import("std");
const microzig = @import("microzig");
const root = @import("root");

pub fn enable_interrupts() void {
    asm volatile ("sei");
}

pub fn disable_interrupts() void {
    asm volatile ("cli");
}

pub inline fn sbi(comptime reg: u5, comptime bit: u3) void {
    asm volatile ("sbi %[reg], %[bit]"
        :
        : [reg] "I" (reg),
          [bit] "I" (bit),
    );
}

pub inline fn cbi(comptime reg: u5, comptime bit: u3) void {
    asm volatile ("cbi %[reg], %[bit]"
        :
        : [reg] "I" (reg),
          [bit] "I" (bit),
    );
}

// AVR 16bit registers need to be wrtten low byte first, high byte second
// which is opposite of how Zig writes 16bit values to memory.
pub fn write_reg16(reg: *volatile u16, value: u16) void {
    const addr = @ptrToInt(reg);
    const bytePtr = @intToPtr(*volatile [2]u8, addr);
    bytePtr.*[0] = @truncate(u8, value);
    bytePtr.*[1] = @truncate(u8, value >> 8);
}

// AVR 16bit registers need to be read low byte first, high byte second
// which is what Zig does when reading 16bit values from memory.
// We have this function just for consistency.
pub fn read_reg16(reg: *volatile u16) u16 {
    return reg.*;
}

pub const vector_table = blk: {
    std.debug.assert(std.mem.eql(u8, "RESET", std.meta.fields(microzig.chip.VectorTable)[0].name));

    // Tiny devices have 2 bytes per IVT entry, while Mega devices have 4 bytes per IVT entry,
    // so we need to use the correct jump instruction.
    // TODO: This is a bit of a hack, we should probably have a better way to recognize the family.
    const jmp_instr = if (std.mem.eql(u8, microzig.chip.properties.family, "AVR TINY")) "rjmp" else "jmp";

    var asm_str: []const u8 = jmp_instr ++ " microzig_start\n";

    const has_interrupts = @hasDecl(root, "microzig_options") and @hasDecl(root.microzig_options, "interrupts");
    if (has_interrupts) {
        const interrupts = root.microzig_options.interrupts;
        if (@hasDecl(interrupts, "RESET"))
            @compileError("Not allowed to overload the reset vector");

        inline for (std.meta.declarations(interrupts)) |decl| {
            if (!@hasField(microzig.chip.VectorTable, decl.name)) {
                var msg: []const u8 = "There is no such interrupt as '" ++ decl.name ++ "'. ISRs the 'interrupts' namespace must be one of:\n";
                inline for (std.meta.fields(microzig.chip.VectorTable)) |field| {
                    if (!std.mem.eql(u8, "RESET", field.name)) {
                        msg = msg ++ "    " ++ field.name ++ "\n";
                    }
                }

                @compileError(msg);
            }
        }
    }

    inline for (std.meta.fields(microzig.chip.VectorTable)[1..]) |entry| {
        const new_insn = if (has_interrupts) overload: {
            const interrupts = root.microzig_options.interrupts;
            if (@hasDecl(interrupts, entry.name)) {
                const handler = @field(interrupts, entry.name);

                const isr = make_isr_handler(entry.name, handler);

                break :overload jmp_instr ++ " " ++ isr.exported_name;
            } else {
                break :overload jmp_instr ++ " microzig_unhandled_vector";
            }
        } else jmp_instr ++ " microzig_unhandled_vector";

        // reserved entries are modeled as arrays, so we need to repeat the unhandled instruction
        const entryTypeInfo = @typeInfo(entry.type);
        const repeat = if (entryTypeInfo == .Array) entryTypeInfo.Array.len else 1;
        for (repeat) |_| {
            asm_str = asm_str ++ new_insn ++ "\n";
        }
    }

    const T = struct {
        fn _start() callconv(.Naked) void {
            asm volatile (asm_str);
        }
    };

    break :blk T._start;
};

fn make_isr_handler(comptime name: []const u8, comptime func: anytype) type {
    const calling_convention = switch (@typeInfo(@TypeOf(func))) {
        .Fn => |info| info.calling_convention,
        else => @compileError("Declarations in 'interrupts' namespace must all be functions. '" ++ name ++ "' is not a function"),
    };

    switch (calling_convention) {
        .Unspecified, .Signal, .Interrupt => {},
        else => @compileError("Calling conventions for interrupts must be 'Interrupt', 'Signal', or unspecified. The signal calling convention leaves global interrupts disabled during the ISR, where the interrupt calling conventions enables global interrupts for nested ISRs."),
    }

    return struct {
        pub const exported_name = "microzig_isr_" ++ name;

        pub fn isr_vector() callconv(.Signal) void {
            @call(.always_inline, func, .{});
        }

        comptime {
            const options = .{ .name = exported_name, .linkage = .Strong };
            @export(isr_vector, options);
        }
    };
}

pub const startup_logic = struct {
    export fn microzig_unhandled_vector() callconv(.Naked) noreturn {
        @panic("Unhandled interrupt");
    }

    extern fn microzig_main() noreturn;

    export fn microzig_start() callconv(.Naked) noreturn {
        // At startup the stack pointer is at the end of RAM
        // so, no need to set it manually!

        copy_data_to_ram();
        clear_bss();

        microzig_main();
    }

    fn copy_data_to_ram() void {
        asm volatile (
            \\  ; load Z register with the address of the data in flash
            \\  ldi r30, lo8(microzig_data_load_start)
            \\  ldi r31, hi8(microzig_data_load_start)
            \\  ; load X register with address of the data in ram
            \\  ldi r26, lo8(microzig_data_start)
            \\  ldi r27, hi8(microzig_data_start)
            \\  ; load address of end of the data in ram
            \\  ldi r24, lo8(microzig_data_end)
            \\  ldi r25, hi8(microzig_data_end)
            \\  rjmp .L2
            \\
            \\.L1:
            \\  lpm r18, Z+ ; copy from Z into r18 and increment Z
            \\  st X+, r18  ; store r18 at location X and increment X
            \\
            \\.L2:
            \\  cp r26, r24
            \\  cpc r27, r25 ; check and branch if we are at the end of data
            \\  brne .L1
        );
        // Probably a good idea to add clobbers here, but compiler doesn't seem to care
    }

    fn clear_bss() void {
        asm volatile (
            \\  ; load X register with the beginning of bss section
            \\  ldi r26, lo8(microzig_bss_start)
            \\  ldi r27, hi8(microzig_bss_start)
            \\  ; load end of the bss in registers
            \\  ldi r24, lo8(microzig_bss_end)
            \\  ldi r25, hi8(microzig_bss_end)
            \\  ldi r18, 0x00
            \\  rjmp .L4
            \\
            \\.L3:
            \\  st X+, r18
            \\
            \\.L4:
            \\  cp r26, r24
            \\  cpc r27, r25 ; check and branch if we are at the end of bss
            \\  brne .L3
        );
        // Probably a good idea to add clobbers here, but compiler doesn't seem to care
    }
};
