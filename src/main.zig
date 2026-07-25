const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
    InvalidPostfix,
    TooManyInstructions,
    MemberedSetValueOutOfRange,
};

// TODO in pike vm, aggressively insert split and jump operation to keep priority
// When a match is found, any lower priority threads should be removed, and result saved in a pointer
// the higher priority threads should try to keep matching, any new matches should replace the saved pointer.
// when all option are exausted, return the match. This is not a full match implementation. Our full match implementation
// is already solid.

// TODO add capture groups
// TODO add lazy operators
// TODO Build a test suite
// TODO Add bol/f and eol/f. With custom instraction?
// TODO Add counted repeatitions
// TODO implement with threads instead of backtracking
// TODO remove the extra jump in qm
// TODO remove tree stracture step, optimize compiler


pub fn main(init: std.process.Init) !void {
    _ = init;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected in gpa\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const pattern = "a(b)|(c)";
    // const text = "aabb";
    // const pattern = "a+b";
    // const text = "aab";
    std.debug.print("before: {s}\n", .{pattern});
    var postfix = try raw2postfix(allocator, pattern);
    defer postfix.deinit(allocator);
    try debugprintpostfix(allocator, postfix.items);

    // var instructions = try postfix2vm(allocator, postfix.items);
    // // try debugPrintInstructionGroups(instructions);
    // defer instructions.deinit(allocator);

    // const start2 = std.Io.Clock.awake.now(init.io);
    // saved = try allocator.alloc(u32, groups_counte*2);
    // errdefer allocator.free(saved);
    // const result2 = try match(allocator, instructions, text);
    // const elapsed2 = start2.untilNow(init.io, .awake);
    // std.debug.print("thompson result is: {}. thompson took: {d} \n", .{result2, elapsed2.toNanoseconds()});

    // match
    // try raw2postfix(allocator, "(ab|cd)+ef");
    // try raw2postfix(allocator, "a?(b|cd)e*");
    // try raw2postfix(allocator, "(ab(c|d))|ef");
    // try raw2postfix(allocator, "a(b|c(d|e))f");

}


const Thread = struct{
    const Self = @This();
    ip: u32,
    saved: []u32,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, ip: u32, input_saved: []const u32) !Self {
        const saved = try allocator.alloc(u32, input_saved.len);
        errdefer allocator.free(saved);
        @memcpy(saved, input_saved);

        return .{
            .ip = ip,
            .saved = saved,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.saved);
    }
};

// const Thread = u32;

const MemberedThreadSet = struct{
    const Self = @This();

    present: []bool,
    items: []Thread,
    len: usize,
    capacity: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        const present = try allocator.alloc(bool, capacity);
        errdefer allocator.free(present);
        const items = try allocator.alloc(Thread, capacity);
        errdefer allocator.free(items);

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
        for (self.items) |item| {
            item.deinit();
        }
        self.allocator.free(self.items);
    }

    pub fn clear(self: *Self) void {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            self.present[self.items[i]] = false;
        }
        self.len = 0;
    }

    pub fn add(self: *Self, value: Thread) !void {
        if (value.ip >= self.capacity) {
            return error.MemberedSetValueOutOfRange;
        } else if (self.present[value.ip]) {
            return;
        } else if (self.len >= self.capacity) {
            unreachable;
        }

        self.items[self.len] = value.ip;
        self.len += 1;
        self.present[value.ip] = true;
    }
};

const Threads = struct{
    const Self = @This();

    l1: MemberedThreadSet, // TODO Test a Set.. Probably slower for most cases but should have better scaling
    l2: MemberedThreadSet,

    current_l1: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
        var l1 = try MemberedThreadSet.init(allocator, capacity);
        errdefer l1.deinit();
        var l2 = try MemberedThreadSet.init(allocator, capacity);
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

    pub fn current(self: *Self) *MemberedThreadSet {
        return if (self.current_l1) &self.l1 else &self.l2;
    }

    pub fn other(self: *Self) *MemberedThreadSet {
        return if (self.current_l1) &self.l2 else &self.l1;
    }

    pub fn swap(self: *Self) void {
        self.current_l1 = !self.current_l1;
    }
};

const Program = struct{
    instructions: std.ArrayList(Instruction),
    groups_count: u32,
    // allocator: std.mem.Allocator,

    // pub fn deinit() 
};

pub fn match(
    allocator: std.mem.Allocator,
    program: Program,
    data: []const u8,
) !bool {
    var threads = try Threads.init(allocator, program.instructions.items.len);
    defer threads.deinit();


    var groups: []u32 = try allocator.alloc(u32, program.groups_count);
    errdefer allocator.free(groups);
    var thread0 = Thread.init(allocator, 0, groups);
    groups = .{};

    errdefer thread0.deinit();
    try threads.current().add(thread0);

    var sp: usize = 0;
    while (sp <= data.len) : (sp += 1) {
        var i: usize = 0;
        const current = threads.current();
        const other = threads.other();
        while (i < current.len) : (i += 1) {
            const thread = current.items[i];
            const instruction = program.instructions.items[thread.ip];
            switch(instruction.type) {
                .char => {
                    if (sp < data.len and data[sp] == @as(u8, @intCast(instruction.a.?))) {
                        const new_thread = try Thread.init(allocator, thread.ip+1, thread.saved);
                        errdefer new_thread.deinit();
                        try other.add(new_thread);
                    }
                },
                .jump => {
                    const new_thread = try Thread.init(allocator, instruction.a.?, thread.saved);
                    errdefer new_thread.deinit();
                    try current.add(new_thread);
                },
                .split => {
                    var new_thread0: ?Thread = try Thread.init(allocator, instruction.a.?, thread.saved);
                    errdefer if (new_thread0) |*nt0| nt0.deinit();
                    try current.add(new_thread0.?);
                    new_thread0 = null;
                    // TODO I don't like it too much.

                    const new_thread1 = try Thread.init(allocator, instruction.b.?, thread.saved);
                    errdefer new_thread1.deinit();
                    try current.add(new_thread1);
                },
                .match => {
                    if (sp == data.len) {
                        // TODO also save at 1
                        // todo memcpy back grouops
                        return true;
                    }
                },
                .save => {
                    thread.saved[instruction.a.?] = sp;
                    const new_thread = try Thread.init(allocator, thread.ip+1, thread.saved);
                    errdefer new_thread.deinit();
                    try current.add(new_thread);
                },
            }
        }
        current.clear();
        threads.swap();
    }
    return false;
}

/// Search is looking for a single submatch in a list. In case of several submatches the rules for the one returned
/// are as followed, ordered by priority:
/// 1. The match that starts at the leftmost character of the data.
/// 2. The longest match avaiable.
///
/// Example:
/// data = "text <html> </html> text"
/// pattern = "<.+>"
/// result -> "<html></html>"
///
/// not "<html>". There is another match at the same leftmost position that is longer.
/// and not "</html>" not the left most match
pub fn search(
    allocator: std.mem.Allocator,
    instructions: std.ArrayList(Instruction),
    data: []const u8
) !bool {
    // TODO need to capture full match
    // Need to print result.
    var threads = try Threads.init(allocator, instructions.items.len);
    defer threads.deinit();

    var sp: usize = 0;
    while (sp <= data.len) : (sp += 1) {
        try threads.current().add(0);
        var i: usize = 0;
        while (i < threads.current().len) : (i += 1) {
            const ip = threads.current().items[i];
            const instruction = instructions.items[ip];
            switch(instruction.type) {
                .char => {
                    if (sp < data.len and data[sp] == @as(u8, @intCast(instruction.a.?))) {
                        try threads.other().add(ip+1);
                    }
                },
                .match => {
                    return true;
                },
                else => {
                    try get_next_instruction(threads.current(), instructions.items, ip);
                }
            }
        }
        threads.current().clear();
        threads.swap();
    }
    return false;
}

fn get_next_instruction(
    out: *MemberedThreadSet,
    instructions: []const Instruction,
    ip: usize,
) !void {
    const inst = instructions[ip];
    switch(inst.type) {
        .split => {
            try get_next_instruction(out, instructions, inst.a.?);
            try get_next_instruction(out, instructions, inst.b.?);
        },
        .jump => {
            try get_next_instruction(out, instructions, inst.a.?);
        },
        else => {
            try out.add(ip);
        },
    }
}

const Operation = enum(u16) { // Bigger is higher precedence
    concat = 256, // implicit
    split, // |
    plus, // +
    star, // *
    qm, // ?
    // any, // - will end up as .
};

const GROUP_0: u16 = 1000;

pub fn raw2postfix(allocator: std.mem.Allocator, pattern: []const u8) !std.ArrayList(u16) {
    // TODO change to union instead of magic u16.. Maybe magic u16 is fine when documented because it is most likely
    // very fast but how fast? Its kinda ugly and prune to bugs. What am I looking for here? 100% performance or 80% and
    // maintainable?
    var outputqueue: std.ArrayList(u16) = .empty;
    errdefer outputqueue.deinit(allocator);
    try outputqueue.ensureTotalCapacity(allocator, pattern.len * 2);

    var operatorqueue: std.ArrayList(u16) = .empty;
    defer operatorqueue.deinit(allocator);

    // 1000+ groups
    try outputqueue.append(allocator, GROUP_0);

    // last_end start with false even when the previous item is a group because
    // this is the full capture group and will be appended to the query result
    // at the end of the postifix with the arguement .1.
    // This means that the fragments at the end of the postfix would look like
    // this before merging:
    // 0, <result>, <concat>, 1, <concat>
    // concat 0 to the full result and the concat to this, 1 at the end.
    var last_end: bool = false;

    var group_counter: u16 = 1;
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
            '(' => { // s e
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == @intFromEnum(Operation.concat)) {
                        try outputqueue.append(allocator, operatorqueue.items[operatorqueue.items.len - 1]);
                    } else {
                        try operatorqueue.append(allocator, @intFromEnum(Operation.concat));
                    }
                }
                try operatorqueue.append(allocator, GROUP_0 + group_counter*2);
                try outputqueue.append(allocator, GROUP_0 + group_counter*2);
                last_end = true;
                group_counter += 1;
            },
            ')' => { // e
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == @intFromEnum(Operation.concat)) {
                        try outputqueue.append(allocator, operatorqueue.items[operatorqueue.items.len - 1]);
                    } else {
                        try operatorqueue.append(allocator, @intFromEnum(Operation.concat));
                    }
                }
                var found_group_open: u16 = 0;
                for (0..operatorqueue.items.len) |i| {
                    const op = operatorqueue.items[operatorqueue.items.len - 1 - i];
                    if (op >= GROUP_0 and op%2 == 0) {
                        found_group_open = op;
                        break;
                    }
                }
                if (found_group_open == 0) {
                    return error.UnmatchedClosingParenthesis;
                }
                try outputqueue.append(allocator, found_group_open+1);

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

                last_end = true;
            },
            '|' => { // s
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == @intFromEnum(Operation.concat)) {
                        try outputqueue.append(allocator, operatorqueue.pop().?);
                    }
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == @intFromEnum(Operation.split)) {
                        try outputqueue.append(allocator, @intFromEnum(Operation.split));
                    }
                }
                try operatorqueue.append(allocator, @intFromEnum(Operation.split));
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
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == @intFromEnum(Operation.concat)) {
                        try outputqueue.append(allocator, operatorqueue.items[operatorqueue.items.len - 1]);
                    } else {
                        try operatorqueue.append(allocator, @intFromEnum(Operation.concat));
                    }
                }
                try outputqueue.append(allocator, c);
                last_end = true;
            },
        }
    }

    while (operatorqueue.pop()) |op| {
        if (op >= GROUP_0 and op%2 == 0) {
            return error.UnmatchedOpeningParenthesis;
        }

        const op_as_enum = @as(Operation, @enumFromInt(op));
        if (op_as_enum == Operation.split or op_as_enum == Operation.concat) {
            try outputqueue.append(allocator, op);
        } else {
            return error.InvalidOperator;
        }
    }

    try outputqueue.append(allocator, @intFromEnum(Operation.concat));
    try outputqueue.append(allocator, GROUP_0 + 1);
    try outputqueue.append(allocator, @intFromEnum(Operation.concat));


    // try debugprintpostfix(allocator, outputqueue.items);

    return outputqueue;
}

const InstuctionType = enum(u8) {
    char,
    jump,
    split,
    match,
    save,
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
        } else if (c > GROUP_0) {
            // TODO

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


/// This function takes the nfa treelike structure and builds the instruction list
/// from it.
fn postfix2vm(
    allocator: std.mem.Allocator,
    postfix: []const u16,
) !Program {
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
