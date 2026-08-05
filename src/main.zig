const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
    InvalidPostfix,
    TooManyInstructions,
    MemberedSetValueOutOfRange,
    EmptyAlternationUnsupported,
};


// ---- General todos to check at a later time ----
// TODO Test memory allocation improvements effects on speed.
// Also try to reduce the amount of allocations for save groups.

// ---- In order todos.
// TODO fix group. Currently groups are not collected early. Not sure how to explain this so here is an example.
// Take this pattern (a+)(a+) and this text aaaa
// groups could match 3 ways
// 1. aaa a
// 2. aa aa
// 3. a aaa
// The most important thing is to keep our code consistent. We need to follow rules.
// The rules we will follow is to match like (1). match as much as we can on the leftmost group

// TODO in pike vm, aggressively insert split and jump operation to keep priority
// When a match is found, any lower priority threads should be removed, and result saved in a pointer
// the higher priority threads should try to keep matching, any new matches should replace the saved pointer.
// when all option are exausted, return the match. This is not a full match implementation. Our full match implementation
// is already solid.
// TODO add bol eol instructions
// TODO add lazy operators
// TODO Build a test suite
// TODO Add counted repeatitions
// TODO implement with threads instead of backtracking
// TODO remove the extra jump in qm
// TODO remove tree stracture step, optimize compiler
// TODO Cache DFA states
// TODO Build character groups, utf-8 support
// TODO lookahead vectorized search
// TODO support empty alternation (|b)

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected in gpa\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const pattern = "(a*)(a*)";
    const text = "aaa";
    // const pattern = "a+b";
    // const text = "aab";
    var program = try compile(allocator, pattern);
    defer program.instructions.deinit(allocator);

    try debugPrintInstructionGroups(program.instructions);

    var elapsed: i96 = 0;
    var result2: ?Match = null;
    const start2 = std.Io.Clock.awake.now(init.io);
    result2 = try match(allocator, program, text);
    defer if (result2) |res| res.deinit();
    elapsed += start2.untilNow(init.io, .awake).toNanoseconds();

    std.debug.print("result is: {}. took: {d} \n", .{ result2.?.result, @divTrunc(elapsed, 1) });

    const result = result2.?;
    if (result.result) {
        var i: usize = 0;
        while (i < result.groups.?.len) : (i += 2) {
            if (result.groups.?[i] == std.math.maxInt(u32)) {
                std.debug.print("group {d}: <no_capture>\n", .{i / 2});
            } else {
                std.debug.print("group {d}: {d}-{d}\n", .{ i / 2, result.groups.?[i], result.groups.?[i + 1] });
            }
        }
    }

    // match
    // try compile(allocator, "(ab|cd)+ef");
    // try compile(allocator, "a?(b|cd)e*");
    // try compile(allocator, "(ab(c|d))|ef");
    // try compile(allocator, "a(b|c(d|e))f");

}

const Thread = struct {
    const Self = @This();
    ip: u32,
    saved: []u32, // TODO needs to be u64
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ip: u32, saved: []u32) !Self {
        return .{
            .ip = ip,
            .saved = saved, //saved is not owned by the thread
            .allocator = allocator,
        };
    }
};

const SparseThreadSet = struct {
    const Self = @This();

    sparse: []u32,
    items: []Thread,
    len: usize,
    capacity: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        const sparse = try allocator.alloc(u32, capacity);
        errdefer allocator.free(sparse);
        const items = try allocator.alloc(Thread, capacity);
        errdefer allocator.free(items);

        @memset(sparse, std.math.maxInt(u32));

        return .{
            .sparse = sparse,
            .items = items,
            .len = 0,
            .capacity = capacity,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.sparse);
        self.allocator.free(self.items);
    }

    pub fn clear(self: *Self) void {
        self.len = 0;
    }

    pub fn replace(self: *Self, value: Thread) !void {
        if (value.ip >= self.capacity) {
            return error.MemberedSetValueOutOfRange;
        } else if (self.sparse[value.ip] < self.len and self.items[self.sparse[value.ip]].ip == value.ip) {
            self.items[self.sparse[value.ip]] = value;
            return;
        } else if (self.len >= self.capacity) {
            unreachable;
        }

        self.items[self.len] = value;
        self.sparse[value.ip] = @as(u32, @intCast(self.len));
        self.len += 1;
    }

    pub fn add(self: *Self, value: Thread) !void {
        if (value.ip >= self.capacity) {
            return error.MemberedSetValueOutOfRange;
        } else if (self.sparse[value.ip] < self.len and self.items[self.sparse[value.ip]].ip == value.ip) {
            return;
        } else if (self.len >= self.capacity) {
            unreachable;
        }

        self.items[self.len] = value;
        self.sparse[value.ip] = @as(u32, @intCast(self.len));
        self.len += 1;
    }
};

const Threads = struct {
    const Self = @This();

    l1: SparseThreadSet, // TODO Test a Set.. Probably slower for most cases but should have better scaling
    l2: SparseThreadSet,

    current_l1: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        var l1 = try SparseThreadSet.init(allocator, capacity);
        errdefer l1.deinit();
        var l2 = try SparseThreadSet.init(allocator, capacity);
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

    pub fn current(self: *Self) *SparseThreadSet {
        return if (self.current_l1) &self.l1 else &self.l2;
    }

    pub fn other(self: *Self) *SparseThreadSet {
        return if (self.current_l1) &self.l2 else &self.l1;
    }

    pub fn swap(self: *Self) void {
        self.current_l1 = !self.current_l1;
    }
};

const Program = struct {
    instructions: std.ArrayList(Instruction),
    groups_count: u32,
    // TODO include allocator    allocator: std.mem.Allocator,

    // pub fn deinit()
};

const Match = struct {
    const Self = @This();

    result: bool,
    groups: ?[]u32 = null,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: Self) void {
        if (self.groups) |groups| {
            self.allocator.?.free(groups);
        }
    }
};

pub fn match(
    allocator: std.mem.Allocator,
    program: Program,
    data: []const u8,
) !Match {
    var threads = try Threads.init(allocator, program.instructions.items.len);
    defer threads.deinit();

    var arena_groups = std.heap.ArenaAllocator.init(allocator);
    defer arena_groups.deinit();
    var groups_allocator = arena_groups.allocator();


    const groups: []u32 = try groups_allocator.alloc(u32, program.groups_count * 2);
    @memset(groups, std.math.maxInt(u32)); // This define the default value in all the groups

    const thread0: Thread = try Thread.init(allocator, 0, groups);
    try threads.current().add(thread0);

    var sp: usize = 0;
    while (sp <= data.len) : (sp += 1) {
        var i: usize = 0;
        const current = threads.current();
        const other = threads.other();
        // std.debug.print("{{", .{});
        // for (0..current.len) |ii| {
        //     std.debug.print(" {d} ", .{current.items[ii].ip});
        // }
        // std.debug.print("}}\n", .{});
        while (i < current.len) : (i += 1) {
            const thread = current.items[i];
            const instruction = program.instructions.items[thread.ip];
            switch (instruction.type) {
                .char => {
                    if (sp < data.len and data[sp] == @as(u8, @intCast(instruction.a.?))) {
                        try get_next_instruction(groups_allocator, other, program.instructions.items, thread.ip + 1, sp + 1, thread.saved);
                    }
                },
                .any => {
                    if (sp < data.len) {
                        try get_next_instruction(groups_allocator, other, program.instructions.items, thread.ip + 1, sp + 1, thread.saved);
                    }
                },
                .match => {
                    if (sp == data.len) {
                        const result_groups = try allocator.alloc(u32, program.groups_count * 2);
                        @memcpy(result_groups, thread.saved);
                        return .{ .allocator = allocator, .groups = result_groups, .result = true };
                    }
                },
                else => {
                    try get_next_instruction(groups_allocator, other, program.instructions.items, thread.ip, sp, thread.saved);
                }
            }
        }
        current.clear();
        threads.swap();
    }
    return .{ .result = false };
}


fn get_next_instruction(
    allocator: std.mem.Allocator,
    out: *SparseThreadSet,
    instructions: []const Instruction,
    ip: u32,
    sp: usize,
    saved: []u32,
) !void {
    const inst = instructions[ip];
    switch (inst.type) {
        .jump => {
            const new_ip = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.a.?));
            try get_next_instruction(allocator, out, instructions, new_ip, sp, saved);
        },
        .split => {
            const new_ip_a = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.a.?));
            const new_ip_b = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.b.?));
            try get_next_instruction(allocator, out, instructions, new_ip_a, sp, saved);
            try get_next_instruction(allocator, out, instructions, new_ip_b, sp, saved);
        },
        .save => {
            const new_saved = try allocator.alloc(u32, saved.len);
            @memcpy(new_saved, saved);
            new_saved[@as(u32, @intCast(inst.a.?))] = @as(u32, @intCast(sp));

            const new_ip = ip + 1;
            try get_next_instruction(allocator, out, instructions, new_ip, sp, new_saved);
        },
        else => {
            const new_thread = try Thread.init(allocator, ip, saved);
            try out.add(new_thread);
        },
    }
}

const Operation = enum(u16) { // Bigger is higher precedence
    concat = 256, // implicit
    split, // |
    plus, // +
    star, // *
    qm, // ?
    any, // .
};

const GROUP_0: u16 = 1000;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Program {
    var postfix = try raw2postfix(allocator, pattern);
    defer postfix.deinit(allocator);
    try debugprintpostfix(allocator, postfix.items);
    return try postfix2vm2(allocator, postfix.items);

    // std.debug.print("before: {s}\n", .{pattern});
}

fn push_left_associative(
    allocator: std.mem.Allocator,
    outputqueue: *std.ArrayList(u16),
    operatorqueue: *std.ArrayList(u16),
    operator: Operation,
) !void {
    const operator_value: u16 = @intFromEnum(operator);
    for (0..operatorqueue.items.len) |_| {
        const last = operatorqueue.items[operatorqueue.items.len - 1];
        if (last <= operator_value) {
            try outputqueue.append(allocator, operatorqueue.pop().?);
        } else {
            break;
        }
    }
    try operatorqueue.append(allocator, operator_value);
}

pub fn raw2postfix(allocator: std.mem.Allocator, pattern: []const u8) !std.ArrayList(u16) {
    const extended_pattern = try std.fmt.allocPrint(allocator, "({s})", .{pattern});
    defer allocator.free(extended_pattern);

    // outputqueue and operatorqueue u16 type is broken in to 3 parts:
    // 1. 0-256 are literals
    // 2. 256+ The operators in the enum Operation
    // 3. 1000+ Group capture. The starting point is GROUP_0
    // The first group is open GROUP_0 + 0, close GROUP_0 + 1
    // The second group is open GROUP_0 + 2, close GROUP_0 + 3
    // ...

    var outputqueue: std.ArrayList(u16) = .empty;
    errdefer outputqueue.deinit(allocator);
    try outputqueue.ensureTotalCapacity(allocator, extended_pattern.len * 2);

    var operatorqueue: std.ArrayList(u16) = .empty;
    defer operatorqueue.deinit(allocator);
    var last_end: bool = false;

    var group_counter: u16 = 0;
    for (extended_pattern) |c| {
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
                try outputqueue.append(allocator, GROUP_0 + group_counter * 2);
                if (last_end) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try operatorqueue.append(allocator, GROUP_0 + group_counter * 2);
                last_end = false;
                group_counter += 1;
            },
            ')' => { // e
                var found_group_open: u16 = 0;
                while (operatorqueue.pop()) |op| {
                    if (op >= GROUP_0) {
                        found_group_open = op;
                        break;
                    }

                    const op_as_enum = @as(Operation, @enumFromInt(op));
                    if (op_as_enum == Operation.split or op_as_enum == Operation.concat) {
                        try outputqueue.append(allocator, op);
                    } else {
                        return error.InvalidOperator;
                    }
                }

                if (found_group_open == 0) {
                    return error.UnmatchedClosingParenthesis;
                }

                try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);

                try outputqueue.append(allocator, found_group_open + 1);
                try outputqueue.append(allocator, @intFromEnum(Operation.concat));

                last_end = true;
            },
            '|' => { // s
                if (!last_end) {
                    return error.EmptyAlternationUnsupported;
                }
                try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.split);
                last_end = false;
            },
            '.' => {
                if (last_end) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, @intFromEnum(Operation.any));
                last_end = true;
            },
            else => { // e s
                if (last_end) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, c);
                last_end = true;
            },
        }
    }

    while (operatorqueue.pop()) |op| {
        if (op >= GROUP_0 and op % 2 == 0) {
            return error.UnmatchedOpeningParenthesis;
        }

        const op_as_enum = @as(Operation, @enumFromInt(op));
        if (op_as_enum == Operation.split or op_as_enum == Operation.concat) {
            try outputqueue.append(allocator, op);
        } else {
            return error.InvalidOperator;
        }
    }

    return outputqueue;
}

const InstuctionType = enum(u8) {
    char,
    jump,
    split,
    match,
    save,
    any,
    // bol,
    // eol,
};

const Instruction = struct {
    type: InstuctionType,
    a: ?i32,
    b: ?i32,
};

const StateType = enum(u16) {
    split = 256,
    match,
    any,
};


pub fn debugprintpostfix(allocator: std.mem.Allocator, outputqueue: []const u16) !void {
    var printable: std.ArrayList(u8) = .empty;
    defer printable.deinit(allocator);

    for (outputqueue) |value| {
        const character: ?u8 = switch (value) {
            256 => '-',
            257 => '|',
            258 => '+',
            259 => '*',
            260 => '?',
            261 => '.',
            else => blk: {
                if (value < 256) {
                    break :blk @intCast(value);
                } else if (value >= GROUP_0) {
                    break :blk @intCast(value - GROUP_0 + '0');
                } else {
                    break :blk null;
                }
            },
        };

        if (character) |c| {
            try printable.append(allocator, c);
        }
    }

    std.debug.print("{s}\n", .{printable.items});
}

fn postfix2vm2(
    allocator: std.mem.Allocator,
    postfix: []const u16,
) !Program {
    var fragments: std.ArrayList(std.ArrayList(Instruction)) = .empty;
    defer {
        for (0..fragments.items.len) |i| {
            fragments.items[i].deinit(allocator);
        }
        fragments.deinit(allocator);
    }

    var group_max: u32 = 0;
    for (postfix) |c| {
        if (c < 256) {
            var fragment: std.ArrayList(Instruction) = .empty;
            try fragment.append(allocator, .{
                .type = .char,
                .a = c,
                .b = null,
            });
            try fragments.append(allocator, fragment);
        } else if (c >= GROUP_0) {
            var fragment: std.ArrayList(Instruction) = .empty;
            try fragment.append(allocator, .{
                .type = .save,
                .a = c - GROUP_0,
                .b = null,
            });
            try fragments.append(allocator, fragment);
            group_max = if (c - GROUP_0 > group_max) c - GROUP_0 else group_max;
        } else {
            switch (@as(Operation, @enumFromInt(c))) {
                .any => {
                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .any,
                        .a = null,
                        .b = null,
                    });
                    try fragments.append(allocator, fragment);
                },
                .concat => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);
                    var a = fragments.pop() orelse return error.InvalidPostfix;
                    defer a.deinit(allocator);

                    for (b.items) |item| {
                        try a.append(allocator, item);
                    }

                    try fragments.append(allocator, a);
                    a = .empty;
                },
                .split => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);
                    var a = fragments.pop() orelse return error.InvalidPostfix;
                    defer a.deinit(allocator);

                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = 1,
                        .b = @as(i32, @intCast(a.items.len + 2)),
                    });
                    for (a.items) |item| {
                        try fragment.append(allocator, item);
                    }
                    try fragment.append(allocator, .{
                        .type = .jump,
                        .a = @as(i32, @intCast(b.items.len + 1)),
                        .b = null,
                    });

                    for (b.items) |item| {
                        try fragment.append(allocator, item);
                    }
                    try fragments.append(allocator, fragment);
                },
                .plus => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);

                    try b.append(allocator, .{
                        .type = .split,
                        .a = -1 * @as(i32, @intCast(b.items.len)),
                        .b = 1,
                    });

                    try fragments.append(allocator, b);
                    b = .empty;
                },
                .star => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);

                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = 1,
                        .b = @as(i32, @intCast(b.items.len + 2)),
                    });
                    for (b.items) |item| {
                        try fragment.append(allocator, item);
                    }
                    try fragment.append(allocator, .{
                        .type = .jump,
                        .a = -1 * @as(i32, @intCast(b.items.len)) - 1,
                        .b = null,
                    });

                    try fragments.append(allocator, fragment);
                },
                .qm => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);

                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = 1,
                        .b = @as(i32, @intCast(b.items.len + 1)),
                    });
                    for (b.items) |item| {
                        try fragment.append(allocator, item);
                    }

                    try fragments.append(allocator, fragment);
                },
            }
        }
    }
    if (fragments.items.len != 1) {
        std.debug.print("Fragments length is not 1 at the end of postfix: {}\n", .{fragments.items.len});
        return error.InvalidPostfix;
    }

    var base = fragments.pop().?;
    try base.append(allocator, .{
        .type = .match,
        .a = null,
        .b = null,
    });

    return .{
        .instructions = base,
        .groups_count = (group_max + 1) / 2
    };
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

            .save => {
                const value = inst.a orelse {
                    std.debug.print("save <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "save {d}\n",
                    .{value},
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

            .any => {
                std.debug.print("any\n", .{});
            },
        }
    }

    std.debug.print("\n", .{});
}
