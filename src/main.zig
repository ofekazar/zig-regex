const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
    InvalidPostfix,
    TooManyInstructions,
    MemberedSetValueOutOfRange,
};

// TODO add capture groups
// TODO add lazy operators
// TODO Build a test suite
// TODO Add bol/f and eol/f
// TODO Add counted repeatitions
// TODO implement with threads instead of backtracking
// TODO remove the extra jump in qm

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected in gpa\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const pattern = "a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?a?aaaaaaaaaaaaaaaaaaaaaaaaa";
    const text = "aaaaaaaaaaaaaaaaaaaaaaaaa";
    // const pattern = "a+b";
    // const text = "aab";
    std.debug.print("before: {s}\n", .{pattern});
    var postfix = try raw2postfix(allocator, pattern);
    defer postfix.deinit(allocator);
    try debugprintpostfix(allocator, postfix.items);
    var instructions = try nfatree2instructions(allocator, postfix.items);
    // try debugPrintInstructionGroups(instructions);
    defer instructions.deinit(allocator);

    const start = std.Io.Clock.awake.now(init.io);
    const result = try match_backtracking(allocator, instructions, text);
    const elapsed_backtracking = start.untilNow(init.io, .awake);
    std.debug.print("backtracking result is: {}. backtracking took: {d} ns\n", .{result, elapsed_backtracking.toNanoseconds()});

    const start2 = std.Io.Clock.awake.now(init.io);
    const result2 = try match_thompson(allocator, instructions, text);
    const elapsed2 = start2.untilNow(init.io, .awake);
    std.debug.print("thompson result is: {}. thompson took: {d} \n", .{result2, elapsed2.toNanoseconds()});
    // match
    // try raw2postfix(allocator, "(ab|cd)+ef");
    // try raw2postfix(allocator, "a?(b|cd)e*");
    // try raw2postfix(allocator, "(ab(c|d))|ef");
    // try raw2postfix(allocator, "a(b|c(d|e))f");

}

const Registers = struct{
    ip: u32 = 0,  // Instruction Pointer
    sp: u32 = 0,  // Source Pointer
};

pub fn match_backtracking(
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    data: []const u8
) !bool {
    var found = false;
    var registers = Registers{};
    var backtrack: std.ArrayList(Registers) = .empty;
    defer backtrack.deinit(allocator);

    while (registers.ip < instructions.items.len) {
        const instruction = instructions.items[registers.ip];
        switch(instruction.type) {
            .char => {
                if (registers.sp < data.len and data[registers.sp] == @as(u8, @intCast(instruction.a.?))) {
                    registers.ip += 1;
                    registers.sp += 1;
                } else {
                    registers = backtrack.pop() orelse break;
                }
            },
            .jump => registers.ip = instruction.a.?,
            .split => {
                try backtrack.append(allocator, Registers{
                    .ip = instruction.b.?,
                    .sp = registers.sp,
                });
                registers.ip = instruction.a.?;
            },
            .match => {
                if (registers.sp == data.len) {
                    found = true;
                    break;
                } else {
                    registers = backtrack.pop() orelse break;
                }
            },
        }
    }
    return found;
}


// const Thread = struct{
//     ip: u32 = 0,
// };

const Thread = u32;

const MemberedSet = struct{
    const Self = @This();

    present: []bool,
    items: []usize,
    len: usize,
    capacity: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        const present = try allocator.alloc(bool, capacity);
        errdefer allocator.free(present);
        const items = try allocator.alloc(usize, capacity);
        errdefer allocator.free(present);

        @memset(present, false);

        return .{
            .present = present,
            .items = items,
            .len = 0,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.present);
        self.allocator.free(self.items);
    }

    pub fn clear(self: *Self) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            self.present[self.items[i]] = false;
        }
        self.len = 0;
    }

    pub fn add(self: *Self, value: usize) !void {
        if (value >= self.capacity) {
            return error.MemberedSetValueOutOfRange;
        } else if (self.present[value]) {
            return;
        } else if (self.len+1 >= self.capacity) {
            unreachable;
        }

        self.items[self.len] = value;
        self.len += 1;
        self.present[value] = true;
    }
};

const Threads = struct{
    const Self = @This();

    l1: MemberedSet, // TODO Test a Set.. Probably slower for most cases but should have better scaling
    l2: MemberedSet,

    current_l1: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        var l1 = try MemberedSet.init(allocator, capacity);
        errdefer l1.deinit();
        var l2 = try MemberedSet.init(allocator, capacity);
        errdefer l2.deinit();
        return .{
            .l1 = l1,
            .l2 = l2,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.l1.deinit();
        self.l2.deinit();
        self.* = undefined;
    }

    pub fn current(self: *Self) *MemberedSet {
        return if (self.current_l1) &self.l1 else &self.l2;
    }

    pub fn other(self: *Self) *MemberedSet {
        return if (self.current_l1) &self.l2 else &self.l1;
    }

    pub fn swap(self: *Self) void {
        self.current_l1 = !self.current_l1;
    }
};

pub fn match_thompson(
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    data: []const u8
) !bool {
    var threads = try Threads.init(allocator, instructions.items.len);
    defer threads.deinit();
    try threads.current().add(0);
    var sp: usize = 0;
    while (sp <= data.len) : (sp += 1) {
        var i: usize = 0;
        const current = threads.current();
        _ = current;
        while (i < threads.current().len) : (i += 1) {
            const ip = threads.current().items[i];
            const instruction = instructions.items[ip];
            switch(instruction.type) {
                .char => {
                    if (sp < data.len and data[sp] == @as(u8, @intCast(instruction.a.?))) {
                        try threads.other().add(ip+1);
                    }
                },
                .jump => try threads.current().add(instruction.a.?),
                .split => {
                    try threads.current().add(instruction.a.?);
                    try threads.current().add(instruction.b.?);
                },
                .match => {
                    if (sp == data.len) {
                        return true;
                    }
                },
            }
        }
        threads.current().clear();
        threads.swap();
    }
    return false;
}

// pub fn match_thompson_with_custom_threadset(
//     allocator: std.mem.Allocator,
//     instructions: std.ArrayList(Instruction),
//     data: []const u8
// ) !bool {

const Operation = enum(u16) { // Bigger is higher precedence
    concat = 256, // implicit
    split, // |
    plus, // +
    star, // *
    qm, // ?
    // any, // - will end up as .
};

// fn push_operator(
//     allocator: std.mem.Allocator,
//     outputqueue: *std.ArrayList(u16),
//     operatorqueue: *std.ArrayList(u8),
//     new_operator: Operation,
// ) !void {

// }

pub fn raw2postfix(allocator: std.mem.Allocator, pattern: []const u8) !std.ArrayList(u16) {
    var outputqueue: std.ArrayList(u16) = .empty;
    errdefer outputqueue.deinit(allocator);
    try outputqueue.ensureTotalCapacity(allocator, pattern.len * 2);

    var operatorqueue: std.ArrayList(u8) = .empty;
    defer operatorqueue.deinit(allocator);

    var last_end: bool = false;
    for (pattern) |c| {
        switch (c) {
            '*' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.star));
                last_end = true;
            },
            '?' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.qm));
                last_end = true;
            },
            '+' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.plus));
                last_end = true;
            },
            '(' => { // s
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '.') {
                        try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                    } else {
                        try operatorqueue.append(allocator, '.');
                    }
                }
                try operatorqueue.append(allocator, '(');
                last_end = false;
            },
            ')' => { // e
                var found_open = false;
                while (operatorqueue.pop()) |op| {
                    switch (op) {
                        '(' => {
                            found_open = true;
                            break;
                        },
                        '|' => {
                            try outputqueue.append(allocator, @intFromEnum(Operation.split));
                        },
                        '.' => {
                            try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                        },
                        else => {
                            return error.InvalidOperator;
                        },
                    }
                }
                if (!found_open) {
                    return error.UnmatchedClosingParenthesis;
                }
                last_end = true;
            },
            '|' => { // s
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '.') {
                        _ = operatorqueue.pop();
                        try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                    }
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '|') {
                        try outputqueue.append(allocator, @intFromEnum(Operation.split));
                    }
                }
                try operatorqueue.append(allocator, '|');
                last_end = false;
            },
            // '.' => { // e s
            //     if (last_end) {
            //         if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '.') {
            //             try outputqueue.append(allocator, @intFromEnum(Operation.concat));
            //         } else {
            //             try operatorqueue.append(allocator, '.');
            //         }
            //     }

            //     try outputqueue.append(allocator, '-');
            //     last_end = true;
            // },
            else => { // e s
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '.') {
                        try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                    } else {
                        try operatorqueue.append(allocator, '.');
                    }
                }
                try outputqueue.append(allocator, c);
                last_end = true;
            },
        }
    }

    while (operatorqueue.pop()) |op| {
        switch (op) {
            '(' => {
                return error.UnmatchedOpeningParenthesis;
            },
            '|' => {
                try outputqueue.append(allocator, @intFromEnum(Operation.split));
            },
            '.' => {
                try outputqueue.append(allocator, @intFromEnum(Operation.concat));
            },
            else => unreachable,
        }
    }

    // try debugprintpostfix(allocator, outputqueue.items);
    return outputqueue;
}

const InstuctionType = enum(u8) {
    char,
    jump,
    split,
    match,
};

const Instruction = struct {
    type: InstuctionType,
    a: ?u32,
    b: ?u32,
};

const State = struct {
    c: u16,
    out: ?*State,
    out1: ?*State,
};

const Fragment = struct {
    start: *State,
    outs: std.ArrayList(*?*State),
};

const StateType = enum(u16) {
    split = 256,
    match,
};

pub fn postfix2nfavm(
    temp_allocator: std.mem.Allocator,
    state_allocator: std.mem.Allocator,
    postfix: []const u16,
) !*State {
    var fragments: std.ArrayList(Fragment) = .empty;
    defer {
        for (0..fragments.items.len) |i| {
            fragments.items[i].outs.deinit(temp_allocator);
        }
        fragments.deinit(temp_allocator);
    }
    // var nfaindices: std.ArrayList(u32) = .empty;
    // defer nfaindices.deinit(temp_allocator);
    for (postfix) |c| {
        if (c < 256) {
            const state = try state_allocator.create(State);
            state.* = .{
                .c = c,
                .out = null,
                .out1 = null,
            };
            var outs: std.ArrayList(*?*State) = .empty;
            errdefer outs.deinit(temp_allocator);
            try outs.append(temp_allocator, &state.out);
            try fragments.append(temp_allocator, Fragment{
                .start = state,
                .outs = outs,
            });
            outs = .empty;
        } else {
            switch (@as(Operation, @enumFromInt(c))) {
                .concat => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    errdefer b.outs.deinit(temp_allocator);
                    var a = fragments.pop() orelse return error.InvalidPostfix;
                    defer a.outs.deinit(temp_allocator);

                    for (a.outs.items) |out| {
                        out.* = b.start;
                    }

                    try fragments.append(temp_allocator, Fragment{
                        .start = a.start,
                        .outs = b.outs,
                    });
                    b.outs = .empty;
                },
                .split => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.outs.deinit(temp_allocator);
                    var a = fragments.pop() orelse return error.InvalidPostfix;
                    errdefer a.outs.deinit(temp_allocator);
                    const state = try state_allocator.create(State);
                    state.* = .{
                        .c = @intFromEnum(StateType.split),
                        .out = a.start,
                        .out1 = b.start,
                    };

                    try a.outs.appendSlice(temp_allocator, b.outs.items);
                    try fragments.append(temp_allocator, Fragment{
                        .start = state,
                        .outs = a.outs,
                    });
                    a.outs = .empty;
                },
                .plus => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.outs.deinit(temp_allocator);
                    const state = try state_allocator.create(State);
                    state.* = .{
                        .c = @intFromEnum(StateType.split),
                        .out = b.start,
                        .out1 = null,
                    };

                    for (b.outs.items) |out| {
                        out.* = state;
                    }

                    var outs: std.ArrayList(*?*State) = .empty;
                    errdefer outs.deinit(temp_allocator);

                    try outs.append(temp_allocator, &state.out1);

                    try fragments.append(temp_allocator, Fragment{
                        .start = b.start,
                        .outs = outs,
                    });

                    outs = .empty;
                },
                .star => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.outs.deinit(temp_allocator);
                    const state = try state_allocator.create(State);
                    state.* = .{
                        .c = @intFromEnum(StateType.split),
                        .out = b.start,
                        .out1 = null,
                    };

                    for (b.outs.items) |out| {
                        out.* = state;
                    }

                    var outs: std.ArrayList(*?*State) = .empty;
                    errdefer outs.deinit(temp_allocator);

                    try outs.append(temp_allocator, &state.out1);

                    try fragments.append(temp_allocator, Fragment{
                        .start = state,
                        .outs = outs,
                    });

                    outs = .empty;
                },
                .qm => {
                    // TODO A question mark causes a double jump
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.outs.deinit(temp_allocator);
                    const state = try state_allocator.create(State);
                    state.* = .{
                        .c = @intFromEnum(StateType.split),
                        .out = b.start,
                        .out1 = null,
                    };

                    var outs: std.ArrayList(*?*State) = .empty;
                    errdefer outs.deinit(temp_allocator);

                    try outs.appendSlice(temp_allocator, b.outs.items);
                    try outs.append(temp_allocator, &state.out1);

                    try fragments.append(temp_allocator, Fragment{
                        .start = state,
                        .outs = outs,
                    });

                    outs = .empty;
                },
                // .any => {

                // },
            }
        }
    }
    if (fragments.items.len != 1) {
        std.debug.print("Fragments length is not 1 at the end of postfix: {}\n", .{fragments.items.len});
        return error.InvalidPostfix;
    }

    var base = fragments.pop().?;
    defer base.outs.deinit(temp_allocator);

    const match_state = try state_allocator.create(State);
    match_state.* = .{
        .c = @intFromEnum(StateType.match),
        .out = null,
        .out1 = null,
    };

    for (base.outs.items) |out| {
        out.* = match_state;
    }

    return base.start;
}

pub fn debugprintpostfix(allocator: std.mem.Allocator, outputqueue: []const u16) !void {
    var printable: std.ArrayList(u8) = .empty;
    defer printable.deinit(allocator);

    for (outputqueue) |value| {
        const character: ?u8 = switch (value) {
            256 => '.',
            257 => '|',
            258 => '+',
            259 => '*',
            260 => '?',
            261 => '-',
            else => if (value < 256)
                @intCast(value)
            else
                null,
        };

        if (character) |c| {
            try printable.append(allocator, c);
        }
    }

    std.debug.print("{s}\n", .{printable.items});
}

fn nfatree2instructions(
    allocator: std.mem.Allocator,
    postfix: []const u16,
) !std.ArrayList(Instruction) {
    var state_arena = std.heap.ArenaAllocator.init(allocator);
    defer state_arena.deinit();
    const state_allocator = state_arena.allocator();
    const base = try postfix2nfavm(allocator, state_allocator, postfix);

    var seen = std.AutoHashMap(*State, u32).init(allocator);
    defer seen.deinit();

    const BackpropData = struct {
        state: *State,
        split_index: usize,
    };

    var current_state = base;
    var backprop: std.ArrayList(BackpropData) = .empty;
    defer backprop.deinit(allocator);

    var output_instructions: std.ArrayList(Instruction) = .empty;
    errdefer output_instructions.deinit(allocator);

    while (true) {
        if (seen.get(current_state)) |index| {
            try output_instructions.append(allocator, .{
                .type = .jump,
                .a = index,
                .b = null,
            });
            const bp = backprop.pop() orelse break;
            current_state = bp.state;
            output_instructions.items[bp.split_index].b =
                std.math.cast(u32, output_instructions.items.len) orelse return error.TooManyIntstructions;
        }
        else if (current_state.c < 256) {
            try output_instructions.append(allocator, .{
                .type = .char,
                .a = current_state.c,
                .b = null,
            });
            const index = std.math.cast(u32, output_instructions.items.len - 1) orelse return error.TooManyIntstructions;
            try seen.put(current_state, index);
            current_state = current_state.out.?;
        }
        else {
            switch(@as(StateType, @enumFromInt(current_state.c))) {
                .split => {
                    const split_state = current_state;
                    var a: u32 = 0;
                    var b: u32 = 0;
                    if (seen.get(current_state.out.?)) |out_state_index| {
                        current_state = current_state.out1.?;
                        a = out_state_index;
                        b = std.math.cast(u32, output_instructions.items.len + 1) orelse return error.TooManyIntstructions;
                    } else {
                        try backprop.append(allocator, .{
                            .split_index = output_instructions.items.len,
                            .state = current_state.out1.?
                        });
                        a = std.math.cast(u32, output_instructions.items.len + 1) orelse return error.TooManyIntstructions;
                        b = 0;
                        current_state = current_state.out.?;
                    }

                    try output_instructions.append(allocator, .{
                        .type = .split,
                        .a = a,
                        .b = b,
                    });
                    const index = std.math.cast(u32, output_instructions.items.len - 1) orelse return error.TooManyIntstructions;
                    try seen.put(split_state, index);
                },
                .match => {
                    try output_instructions.append(allocator, .{
                        .type = .match,
                        .a = null,
                        .b = null,
                    });
                    const index = std.math.cast(u32, output_instructions.items.len - 1) orelse return error.TooManyIntstructions;
                    try seen.put(current_state, index);

                    const bp = backprop.pop() orelse break;
                    current_state = bp.state;
                    output_instructions.items[bp.split_index].b =
                        std.math.cast(u32, output_instructions.items.len) orelse return error.TooManyIntstructions;
                }
            }
        }
    }

    return output_instructions;
}

pub fn debugPrintInstructionGroups(
    node: std.ArrayList(Instruction),
) !void {

    for (node.items, 0..) |inst, i| {
        std.debug.print("  {d}: ", .{i});

        switch (inst.type) {
            .char => {
                const value = inst.a orelse {
                    std.debug.print("char <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "char '{c}' ({d})\n",
                    .{ @as(u8, @intCast(value)), value },
                );
            },

            .jump => {
                if (inst.a) |offset| {
                    std.debug.print("jump {d}\n", .{offset});
                } else {
                    std.debug.print("jump <missing operand>\n", .{});
                }
            },

            .split => {
                if (inst.a != null and inst.b != null) {
                    std.debug.print(
                        "split {d}, {d}\n",
                        .{ inst.a.?, inst.b.? },
                    );
                } else {
                    std.debug.print("split <missing operand>\n", .{});
                }
            },

            .match => {
                std.debug.print("match\n", .{});
            },
        }
    }

    std.debug.print("\n", .{});
}
