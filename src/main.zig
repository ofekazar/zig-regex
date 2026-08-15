const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
    InvalidPostfix,
    TooManyInstructions,
    MemberedSetValueOutOfRange,
    EmptyAlternationUnsupported,
    NoClosingCurlyBrackets,
    NoOpeningCurlyBrackets,
    TooManyRepititions,
    InvalidRepititions,
    NoOpeningSquareBrackets,
    NoClosingSquareBrackets,
    InvalidPattern,
    InvalidLength,
};


// ---- General todos to check at a later time ----
// TODO Test memory allocation improvements effects on speed.
// Also try to reduce the amount of allocations for save groups.

// ---- In order todos.
// DONE fix group. Currently groups are not collected early. Not sure how to explain this so here is an example.
// Take this pattern (a+)(a+) and this text aaaa
// groups could match 3 ways
// 1. aaa a
// 2. aa aa
// 3. a aaa
// The most important thing is to keep our code consistent. We need to follow rules.
// The rules we will follow is to match like (1). match as much as we can on the leftmost group

// DONE in pike vm, aggressively insert split and jump operation to keep priority
// When a match is found, any lower priority threads should be removed, and result saved in a pointer
// the higher priority threads should try to keep matching, any new matches should replace the saved pointer.
// when all option are exausted, return the match. This is not a full match implementation. Our full match implementation
// is already solid.

// DONE implement with threads instead of backtracking
// DONE remove the extra jump in qm
// DONE remove tree stracture step, optimize compiler
// DONE add bol eol instructions
// DONE Build a test suite
// DONE Non capturing group (?:e)
// DONE support literals \\ \{ \( etc.
// DONE Add counted repeatitions
// e{n} - exactly n times
// e{n,} - n times or more
// e{n,m} - between n and m
// Find out what n and m? are. generalize e{n} to m = n
// Add the values as special operators to the postfix similar to groups
// DUP_0 = 2000
// DONE add lazy operators
// all 3 counted repititions as lazy
// * + ?

// TODO character classses support
// I can implement it one of 2 ways
// 1.
// Adding a range instruction to the vm.
// range a, c
// It will run similar to char but will return true in case of a, b or c
// Then we can split between differenct chars and range functions
// [Aa-b]
// split 1, 3
// char A
// jump 2
// range a, b
// We can then have precompiled character groups for \b \w \f etc.
// 2.
// A second options is a pointer to a separate compiled function for a character class
// the command will look like
// class 0
// And we will have an object
// classes: []Class
// we will call classes[0].run(sp)
// we can of course use the vm for the class function and merge the 2 instead of inlining but that would defet the purpose.


// ---- Performance ----
// TODO Test different Classes implementations
// TODO Add the project to rebar to compare performance against rust and re2
// TODO Add a vectorized loop lookahead algo
// TODO Cache DFA states.
// TODO Remove capturing groups when not part of the pattern.



// ---- Finishing touches ----
// TODO Add special case literal groups \\b \\w etc.
// TODO UTF-8
// TODO support empty alternation (|b)
// TODO Make a proper library API that is easy to use and takes the most efficient approch for the user automatically.

const root = @import("root.zig");

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected in gpa\n", .{});
        }
    }
    const allocator = gpa.allocator();

    const pattern = "[a-m][N-Z]";
    std.debug.print("pattern: {s}\n", .{pattern});
    // const text = "ab ab ab ab";
    const text = try root.random_binary_test_1(allocator);
    defer allocator.free(text);
    var program = try compile(allocator, pattern);
    defer program.deinit();

    // const cl = try generate_class("abcdefghijklmnop");
    // std.debug.print("result: {} {}", .{cl.run('h'), cl.run('z')});
    const t = i64;
    var times: std.ArrayList(t) = .empty;
    defer times.deinit(allocator);
    try debugPrintInstructionGroups(program.instructions);
    for (0..100) |_| {
        const start = std.Io.Clock.awake.now(init.io);
        var matches = try find_all(allocator, program, text);
        defer matches.deinit(allocator);
        try times.append(allocator, start.untilNow(init.io, .awake).toMicroseconds());
    }
    const elapsed = root.median(t, times.items);
    std.debug.print("search took: {d}\n", .{elapsed});







    
    // for (matches.items) |item| {
    //     std.debug.print("{}, ", .{item});
    // }
    // std.debug.print("\n", .{});



    // var elapsed: i96 = 0;
    // var result2: ?Match = null;
    // const start2 = std.Io.Clock.awake.now(init.io);
    // result2 = try match(allocator, program, text);
    // defer if (result2) |res| res.deinit();
    // elapsed += start2.untilNow(init.io, .awake).toNanoseconds();

    // std.debug.print("result is: {}. took: {d} \n", .{ result2.?.result, @divTrunc(elapsed, 1) });

    // const result = result2.?;
    // if (result.result) {
    //     var i: usize = 0;
    //     while (i < result.groups.?.len) : (i += 2) {
    //         if (result.groups.?[i] == std.math.maxInt(u32)) {
    //             std.debug.print("group {d}: <no_capture>\n", .{i / 2});
    //         } else {
    //             std.debug.print("group {d}: {d}-{d}\n", .{ i / 2, result.groups.?[i], result.groups.?[i + 1] });
    //         }
    //     }
    // }
}

const Thread = struct {
    // TODO Test what happens when we break up ip and saved to 2 different stractures in terms of allocations and
    // cache locallity
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
        // TODO. if we end up not using this. We can change this sparse set to a membered set and it could save us a few
        // ops.
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
    const Self = @This();
    instructions: std.ArrayList(Instruction),
    groups_count: u32,
    classes: std.ArrayList(Class),
    allocator: std.mem.Allocator,

    fn deinit(self: *Self) void {
        self.instructions.deinit(self.allocator);
        self.classes.deinit(self.allocator);
    }
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

    // const thread0: Thread = try Thread.init(allocator, 0, groups);
    // try threads.current().add(thread0);

    try get_next_instruction(
        groups_allocator,
        threads.current(),
        program.instructions.items,
        0,
        0,
        data,
        groups,
    );

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
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_char => {
                    if (sp < data.len and data[sp] != @as(u8, @intCast(instruction.a.?))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .range => {
                    if (sp < data.len and data[sp] >= @as(u8, @intCast(instruction.a.?)) and data[sp] <= @as(u8, @intCast(instruction.b.?))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_range => {
                    if (sp < data.len and !(data[sp] >= @as(u8, @intCast(instruction.a.?)) and data[sp] <= @as(u8, @intCast(instruction.b.?)))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .class => {
                    if (sp < data.len and program.classes.items[instruction.a.?].run(data[sp])) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_class => {
                    if (sp < data.len and !program.classes.items[instruction.a.?].run(data[sp])) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .any => {
                    if (sp < data.len) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .match => {
                    if (sp == data.len) {
                        const result_groups = try allocator.alloc(u32, program.groups_count * 2);
                        @memcpy(result_groups, thread.saved);
                        return .{ .allocator = allocator, .groups = result_groups, .result = true };
                    }
                },
                .jump, .split, .save, .bol, .eol => {
                    try get_next_instruction(
                        groups_allocator,
                        other,
                        program.instructions.items,
                        thread.ip,
                        sp,
                        data,
                        thread.saved,
                    );
                },
            }
        }
        current.clear();
        threads.swap();
    }
    return .{ .result = false };
}

const V = @Vector(16, u8);
const Class = struct {
    const Self = @This();
    class_vector: V,

    pub fn run(self: *const Self, c: u8) bool {
        return @reduce(.Or, self.class_vector == @as(V, @splat(c)));
    }
};
fn generate_class(characters: []const u8) !Class {
    if (characters.len != 16) {
        return error.InvalidLength;
    }
    const class_vector: V = characters[0..16].*;
    return .{
        .class_vector = class_vector,
    };
}

pub fn find_all(
    allocator: std.mem.Allocator,
    program: Program,
    data: []const u8,
) !std.ArrayList(u64) {
    var threads = try Threads.init(allocator, program.instructions.items.len);
    defer threads.deinit();

    var arena_groups = std.heap.ArenaAllocator.init(allocator);
    defer arena_groups.deinit();
    var groups_allocator = arena_groups.allocator();

    var matches: std.ArrayList(u64) = .empty;

    const groups: []u32 = try groups_allocator.alloc(u32, program.groups_count * 2);
    @memset(groups, std.math.maxInt(u32)); // This define the default value in all the groups

    var sp: usize = 0;
    while (sp <= data.len) : (sp += 1) {
        try get_next_instruction(
            groups_allocator,
            threads.current(),
            program.instructions.items,
            0,
            sp,
            data,
            groups,
        );

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
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_char => {
                    if (sp < data.len and data[sp] != @as(u8, @intCast(instruction.a.?))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .range => {
                    if (sp < data.len and data[sp] >= @as(u8, @intCast(instruction.a.?)) and data[sp] <= @as(u8, @intCast(instruction.b.?))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_range => {
                    if (sp < data.len and !(data[sp] >= @as(u8, @intCast(instruction.a.?)) and data[sp] <= @as(u8, @intCast(instruction.b.?)))) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .class => {
                    if (sp < data.len and program.classes.items[@as(usize, @intCast(instruction.a.?))].run(data[sp])) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .neg_class => {
                    if (sp < data.len and !program.classes.items[@as(usize, @intCast(instruction.a.?))].run(data[sp])) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .any => {
                    if (sp < data.len) {
                        try get_next_instruction(
                            groups_allocator,
                            other,
                            program.instructions.items,
                            thread.ip + 1,
                            sp + 1,
                            data,
                            thread.saved,
                        );
                    }
                },
                .match => {
                    try matches.append(allocator, thread.saved[0]);
                    try matches.append(allocator, thread.saved[1]);
                },
                .jump, .split, .save, .bol, .eol => {
                    try get_next_instruction(
                        groups_allocator,
                        other,
                        program.instructions.items,
                        thread.ip,
                        sp,
                        data,
                        thread.saved,
                    );
                },
            }
        }
        current.clear();
        threads.swap();
    }
    return matches;
}




fn get_next_instruction(
    allocator: std.mem.Allocator,
    out: *SparseThreadSet,
    instructions: []const Instruction,
    ip: u32,
    sp: usize,
    data: []const u8,
    saved: []u32,
) !void {
    const inst = instructions[ip];
    switch (inst.type) {
        .jump => {
            const new_ip = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.a.?));
            try get_next_instruction(allocator, out, instructions, new_ip, sp, data, saved);
        },
        .split => {
            const new_ip_a = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.a.?));
            const new_ip_b = @as(u32, @intCast(@as(i32, @intCast(ip)) + inst.b.?));
            try get_next_instruction(allocator, out, instructions, new_ip_a, sp, data, saved);
            try get_next_instruction(allocator, out, instructions, new_ip_b, sp, data, saved);
        },
        .save => {
            const new_saved = try allocator.alloc(u32, saved.len);
            @memcpy(new_saved, saved);
            new_saved[@as(u32, @intCast(inst.a.?))] = @as(u32, @intCast(sp));

            try get_next_instruction(allocator, out, instructions, ip + 1, sp, data, new_saved);
        },
        .bol => {
            const c = if (sp < data.len) data[sp] else 0;
            if (sp == 0 or c == '\n') {
                try get_next_instruction(allocator, out, instructions, ip + 1, sp, data, saved);
            }
        },
        .eol => {
            const c = if (sp < data.len) data[sp] else 0;
            const last = if (sp < data.len) false else true;
            if (last or c == '\n') {
                try get_next_instruction(allocator, out, instructions, ip + 1, sp, data, saved);
            }
        },
        .char, .any, .match, .neg_char, .range, .neg_range, .class, .neg_class => {
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
    bol, // ^
    eol, // $
    range, // range concat. ab<range> a-b
    negative, // comes before a char or a range and change them to negative <neg>a ab<neg><range>
};

const NCGO: u16 = 500;     // Non capturing group open (?:
const CLASS_TAG: u16 = 501;
const NCLASS_TAG: u16 = 502;
const DUP_0: u16 = 1000;   // 1000 - 2000. Supportes repititons up to 999
const DUP_INF: u16 = 2000; // represents an empty m
const GROUP_0: u16 = 3000;

pub fn compile(allocator: std.mem.Allocator, pattern: []const u8) !Program {
    var postfix = try raw2postfix(allocator, pattern);
    defer postfix.deinit(allocator);
    try debugprintpostfix(allocator, postfix.items);
    return try postfix2vm(allocator, postfix.items);

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
    // 3. GROUP_0+ Group capture. The starting point is GROUP_0
    // The first group is open GROUP_0 + 0, close GROUP_0 + 1
    // The second group is open GROUP_0 + 2, close GROUP_0 + 3
    // ...

    var outputqueue: std.ArrayList(u16) = .empty;
    errdefer outputqueue.deinit(allocator);
    try outputqueue.ensureTotalCapacity(allocator, extended_pattern.len * 2);

    var operatorqueue: std.ArrayList(u16) = .empty;
    defer operatorqueue.deinit(allocator);
    var last_end: std.ArrayList(bool) = .empty;
    defer last_end.deinit(allocator);
    try last_end.append(allocator, false);

    var group_counter: u16 = 0;
    var i: usize = 0;
    while (i < extended_pattern.len) : (i += 1) {
        errdefer std.debug.print("Pattern failed at position {d} ('{c}')\n", .{i, extended_pattern[i]}); // TOOD remove this.

        switch (extended_pattern[i]) {
            '^' => {
                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, @intFromEnum(Operation.bol));
                last_end.items[last_end.items.len-1] = true;
            },
            '$' => {
                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, @intFromEnum(Operation.eol));
                last_end.items[last_end.items.len-1] = true;
            },
            '*' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.star));
                last_end.items[last_end.items.len-1] = true;
            },
            '?' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.qm));
                last_end.items[last_end.items.len-1] = true;
            },
            '+' => { // e
                try outputqueue.append(allocator, @intFromEnum(Operation.plus));
                last_end.items[last_end.items.len-1] = true;
            },
            '(' => { // s
                if (i+2 < extended_pattern.len and extended_pattern[i+1] == '?' and extended_pattern[i+2] == ':') {
                    // Non capturing group
                    try operatorqueue.append(allocator, NCGO);
                    i += 2;
                } else {
                    // Capturing group
                    try outputqueue.append(allocator, GROUP_0 + group_counter * 2);
                    if (last_end.items[last_end.items.len-1]) {
                        try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                    }
                    last_end.items[last_end.items.len-1] = true;
                    try operatorqueue.append(allocator, GROUP_0 + group_counter * 2);
                    group_counter += 1;
                }
                try last_end.append(allocator, false);
            },
            ')' => { // e
                var found_group_open: u16 = 0;
                while (operatorqueue.pop()) |op| {
                    if (op >= GROUP_0 or op == NCGO) {
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

                _ = last_end.pop();

                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }

                // TODO last_end considered true here.
                // currently we treat every group as an actual item so an empty group will raise an error ()
                // To add support for 0 capture we need to figure out if our grouped contained anythin to add to.
                // This could be done by changing the last_end stack to a struct with 2 booleans, 1 for last_end
                // 1 for literal seen.
                // Currently there is only one position when last_seen can be false at | so we could use the last
                // seen flag for both tasks, but this is bound to break with an unfamilar maintainer.

                if (found_group_open != NCGO) {
                    try outputqueue.append(allocator, found_group_open + 1);
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }

                last_end.items[last_end.items.len-1] = true;
            },
            '{' => {
                const closing_brackets_end = std.mem.indexOfScalar(u8, extended_pattern[i..], '}');
                if (closing_brackets_end == null) {
                    return error.NoClosingCurlyBrackets;
                }

                const e = closing_brackets_end.?;
                if (std.mem.indexOfScalar(u8, extended_pattern[i..i+e], ',')) |comma_position| {
                    const n = try std.fmt.parseInt(u16, extended_pattern[i+1..i+comma_position], 10);
                    const m  = if (comma_position + 1 == e)
                                        DUP_INF - DUP_0
                                    else
                                        try std.fmt.parseInt(u16, extended_pattern[i+comma_position+1..i+e], 10);

                    if (DUP_0 + n >= DUP_INF or DUP_0 + m > DUP_INF) {
                        return error.TooManyRepititions;
                    }
                    if (n > m) {
                        return error.InvalidRepititions;
                    }

                    if (n == 0 and m == DUP_INF - DUP_0) {
                        try outputqueue.append(allocator, @intFromEnum(Operation.star));
                    } else if (n == 1 and m == DUP_INF - DUP_0) {
                        try outputqueue.append(allocator, @intFromEnum(Operation.plus));
                    } else if (n == 0 and m == 1) {
                        try outputqueue.append(allocator, @intFromEnum(Operation.qm));
                    } else if (n == 1 and m == 1) {
                        // Do nothing
                    } else {
                        try outputqueue.append(allocator, DUP_0 + n);
                        try outputqueue.append(allocator, DUP_0 + m);
                    }
                } else {
                    const n = try std.fmt.parseInt(u16, extended_pattern[i+1..i+e], 10);
                    if (DUP_0 + n >= DUP_INF) {
                        return error.TooManyRepititions;
                    }

                    if (n == 1) {
                        // Do nothing
                    } else {
                        try outputqueue.append(allocator, DUP_0 + n);
                        try outputqueue.append(allocator, DUP_0 + n);
                    }
                }
                i += e;
            },
            '}' => {
                return error.NoOpeningCurlyBrackets;
            },
            '[' => {
                // if (last_end.items[last_end.items.len-1]) {
                //     try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                // }

                // const negative = (i+1 < extended_pattern.len and extended_pattern[i+1] == '^');
                // if (negative) {
                //     try outputqueue.append(allocator, NCLASS_TAG);
                //     i += 1;
                // } else {
                //     try outputqueue.append(allocator, CLASS_TAG);
                // }

                // var range = false;
                // var j = i+1;
                // while (j < extended_pattern.len) : (j += 1) {
                //     switch (extended_pattern[j]) {
                //         '-' => {
                //             if (range) {
                //                 return error.InvalidPattern;
                //             }
                //             range = true;
                //         },
                //         ']' => {
                //             break;
                //         },
                //         else => {
                //             if (range) {
                //                 for (outputqueue.items[outputqueue.items.len-1]+1..extended_pattern[j]+1) |ic| {
                //                     try outputqueue.append(allocator, @intCast(ic));
                //                 }
                //                 range = false;
                //             } else {
                //                 try outputqueue.append(allocator, extended_pattern[j]);
                //             }
                //         }
                //     }
                // }
                // i = j;
                // last_end.items[last_end.items.len-1] = true;

                // NOTE IMPL B

                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }

                var range = false;
                var count: usize = 0;

                // Check for negative.
                const negative = (i+1 < extended_pattern.len and extended_pattern[i+1] == '^');
                if (negative) i += 1;

                // Iterate of inputs, when \ look ahead
                var j = i+1;
                while (j < extended_pattern.len) : (j += 1) {
                    switch (extended_pattern[j]) {
                        '\\' => {
                            j += 1;
                            if (j >= extended_pattern.len) return error.InvalidPattern;

                            // TODO special cases for \\

                            if (negative and !range) {
                                try outputqueue.append(allocator, @intFromEnum(Operation.negative));
                            }
                            try outputqueue.append(allocator, extended_pattern[j]);
                            count += 1;

                            if (range) {
                                range = false;
                                if (negative) {
                                    try outputqueue.append(allocator, @intFromEnum(Operation.negative));
                                }
                                try outputqueue.append(allocator, @intFromEnum(Operation.range));
                                count -= 1;
                            }
                        },
                        '-' => {
                            if (range) {
                                return error.InvalidPattern;
                            }
                            range = true;
                        },
                        ']' => {
                            break;
                        },
                        else => {
                            if (negative and !range) {
                                try outputqueue.append(allocator, @intFromEnum(Operation.negative));
                            }
                            try outputqueue.append(allocator, extended_pattern[j]);
                            count += 1;

                            if (range) {
                                range = false;
                                if (negative) {
                                    try outputqueue.append(allocator, @intFromEnum(Operation.negative));
                                }
                                try outputqueue.append(allocator, @intFromEnum(Operation.range));
                                count -= 1;
                            }
                        }
                    }
                }
                for (0..count-1) |_| {
                    try outputqueue.append(allocator, @intFromEnum(Operation.split));
                }
                i = j;
                last_end.items[last_end.items.len-1] = true;
            },
            ']' => {
                return error.NoOpeningSquareBrackets;
            },
            '|' => { // s
                if (!last_end.items[last_end.items.len-1]) {
                    return error.EmptyAlternationUnsupported;
                }
                try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.split);
                last_end.items[last_end.items.len-1] = false;
            },
            '.' => {
                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, @intFromEnum(Operation.any));
                last_end.items[last_end.items.len-1] = true;
            },
            '\\' => {
                if (i+1 < extended_pattern.len) {
                    i += 1;

                    // TODO add special group support here. \d \w etc.

                    // copy of the switch else statement
                    if (last_end.items[last_end.items.len-1]) {
                        try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                    }
                    try outputqueue.append(allocator, extended_pattern[i]);
                    last_end.items[last_end.items.len-1] = true;
                }
            },
            else => { // e s
                if (last_end.items[last_end.items.len-1]) {
                    try push_left_associative(allocator, &outputqueue, &operatorqueue, Operation.concat);
                }
                try outputqueue.append(allocator, extended_pattern[i]);
                last_end.items[last_end.items.len-1] = true;
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
    neg_char,
    jump,
    split,
    match,
    save,
    any,
    bol,
    eol,
    range,
    neg_range,
    class,
    neg_class,
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
            262 => '^',
            263 => '$',
            264 => 'R',
            265 => '^',
            else => blk: {
                if (value < 256) {
                    break :blk @intCast(value);
                } else if (value >= GROUP_0) {
                    break :blk @intCast(value - GROUP_0 + '0');
                } else {
                    break :blk 'x';
                }
            },
        };

        if (character) |c| {
            try printable.append(allocator, c);
        }
    }

    std.debug.print("{s}\n", .{printable.items});
}

fn postfix2vm(
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

    var classes: std.ArrayList(Class) = .empty;
    var group_max: u32 = 0;
    var i: usize = 0;
    while (i < postfix.len) : (i += 1) {
        const c = postfix[i];
        if (c < 256) {
            var fragment: std.ArrayList(Instruction) = .empty;
            try fragment.append(allocator, .{
                .type = .char,
                .a = c,
                .b = null,
            });
            try fragments.append(allocator, fragment);
        } else if (c == CLASS_TAG or c == NCLASS_TAG) {
            var chars: [16]u8 = undefined;

            for (postfix[i + 1 .. i + 17], 0..) |cc, j| {
                chars[j] = @intCast(cc);
            }

            try classes.append(allocator, try generate_class(&chars));
            var fragment: std.ArrayList(Instruction) = .empty;
            try fragment.append(allocator, .{
                .type = if (c == CLASS_TAG) .class else .neg_class,
                .a = @as(i32, @intCast(classes.items.len - 1)),
                .b = null,
            });
            try fragments.append(allocator, fragment);
            i += 16;
        } else if (c >= DUP_0 and c <= DUP_INF) {
            // Special cases that doesn't show up here:
            // n == 1, m == 1    Nothing
            // n == 0, m == 1    ?
            // n == 0, m == inf  *
            // n == 1, m == inf  +

            if (i+1 >= postfix.len) {
                return error.InvalidPostfix;
            }
            var fragment: std.ArrayList(Instruction) = .empty;
            const n = c - DUP_0;
            const m = postfix[i+1] - DUP_0;
            const eager: bool = !(
                i+2 < postfix.len and
                std.enums.fromInt(Operation, postfix[i+2]) != null and
                @as(Operation, @enumFromInt(postfix[i+2])) == .qm
            );
            var b = fragments.pop() orelse return error.InvalidPostfix;
            defer b.deinit(allocator);
            for (0..n) |_| {
                for (0..b.items.len) |fragment_index| {
                    try fragment.append(allocator, b.items[fragment_index]);
                }
            }
            if (m == DUP_INF - DUP_0) {
                try fragment.append(allocator, .{
                    .type = .split,
                    .a = if (eager) -1 * @as(i32, @intCast(b.items.len)) else 1,
                    .b = if (eager) 1 else -1 * @as(i32, @intCast(b.items.len)),
                });
            } else {
                for (0..m-n) |_| {
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = if (eager) 1 else @as(i32, @intCast(b.items.len + 1)),
                        .b = if (eager) @as(i32, @intCast(b.items.len + 1)) else 1,
                    });
                    for (0..b.items.len) |fragment_index| {
                        try fragment.append(allocator, b.items[fragment_index]);
                    }
                }
            }

            if (fragment.items.len > 0) {
                try fragments.append(allocator, fragment);
            }

            i += if (!eager) 2 else 1;  // When lazy there is an extra ? character therefore 2.
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

                    const eager: bool = !(
                        i+1 < postfix.len and
                        std.enums.fromInt(Operation, postfix[i+1]) != null and
                        @as(Operation, @enumFromInt(postfix[i+1])) == .qm
                    );
                    if (!eager) i += 1;
                    try b.append(allocator, .{
                        .type = .split,
                        .a = if (eager) -1 * @as(i32, @intCast(b.items.len)) else 1,
                        .b = if (eager) 1 else -1 * @as(i32, @intCast(b.items.len)),
                    });

                    try fragments.append(allocator, b);
                    b = .empty;
                },
                .star => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);

                    var fragment: std.ArrayList(Instruction) = .empty;
                    const eager: bool = !(
                        i+1 < postfix.len and
                        std.enums.fromInt(Operation, postfix[i+1]) != null and
                        @as(Operation, @enumFromInt(postfix[i+1])) == .qm
                    );
                    if (!eager) i += 1;
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = if (eager) 1 else @as(i32, @intCast(b.items.len + 2)),
                        .b = if (eager) @as(i32, @intCast(b.items.len + 2)) else 1,
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

                    const eager: bool = !(
                        i+1 < postfix.len and
                        std.enums.fromInt(Operation, postfix[i+1]) != null and
                        @as(Operation, @enumFromInt(postfix[i+1])) == .qm
                    );
                    if (!eager) i += 1;
                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .split,
                        .a = if (eager) 1 else @as(i32, @intCast(b.items.len + 1)),
                        .b = if (eager) @as(i32, @intCast(b.items.len + 1)) else 1,
                    });
                    for (b.items) |item| {
                        try fragment.append(allocator, item);
                    }

                    try fragments.append(allocator, fragment);
                },
                .bol => {
                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .bol,
                        .a = null,
                        .b = null,
                    });
                    try fragments.append(allocator, fragment);
                },
                .eol => {
                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .eol,
                        .a = null,
                        .b = null,
                    });
                    try fragments.append(allocator, fragment);
                },
                .range => {
                    var b = fragments.pop() orelse return error.InvalidPostfix;
                    defer b.deinit(allocator);
                    if (b.items.len != 1 or b.items[0].type != .char) return error.InvalidPostfix;

                    var a = fragments.pop() orelse return error.InvalidPostfix;
                    defer a.deinit(allocator);
                    if (a.items.len != 1 or a.items[0].type != .char) return error.InvalidPostfix;

                    var fragment: std.ArrayList(Instruction) = .empty;
                    try fragment.append(allocator, .{
                        .type = .range,
                        .a = a.items[0].a,
                        .b = b.items[0].a,
                    });
                    try fragments.append(allocator, fragment);
                },
                .negative => {
                    i += 1;
                    if (i >= postfix.len) return error.InvalidPostfix;

                    if (postfix[i] < 256) {
                        // TODO DUP
                        var fragment: std.ArrayList(Instruction) = .empty;
                        try fragment.append(allocator, .{
                            .type = .neg_char,
                            .a = c,
                            .b = null,
                        });
                        try fragments.append(allocator, fragment);
                    } else if (@as(Operation, @enumFromInt(postfix[i])) == .range) {
                        var b = fragments.pop() orelse return error.InvalidPostfix;
                        defer b.deinit(allocator);
                        if (b.items.len != 1 or b.items[0].type != .char) return error.InvalidPostfix;

                        var a = fragments.pop() orelse return error.InvalidPostfix;
                        defer a.deinit(allocator);
                        if (a.items.len != 1 or a.items[0].type != .char) return error.InvalidPostfix;

                        var fragment: std.ArrayList(Instruction) = .empty;
                        try fragment.append(allocator, .{
                            .type = .neg_range,
                            .a = a.items[0].a,
                            .b = b.items[0].a,
                        });
                        try fragments.append(allocator, fragment);
                    } else {
                        return error.InvalidPostfix;
                    }
                }
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
        .groups_count = (group_max + 1) / 2,
        .classes = classes,
        .allocator = allocator,
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
            .neg_char => {
                const value = inst.a orelse {
                    std.debug.print("neg_char <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "neg_char '{c}' ({d})\n",
                    .{ @as(u8, @intCast(value)), value },
                );
            },
            .class => {
                const value = inst.a orelse {
                    std.debug.print("class <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "class {d}\n",
                    .{ value },
                );
            },
            .neg_class => {
                const value = inst.a orelse {
                    std.debug.print("neg_class <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "neg_class {d}\n",
                    .{ value },
                );
            },
            .range => {
                const value_a = inst.a orelse {
                    std.debug.print("range <missing operand>, b\n", .{});
                    continue;
                };
                const value_b = inst.b orelse {
                    std.debug.print("range a, <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "range '{c}' - '{c}'\n",
                    .{ @as(u8, @intCast(value_a)), @as(u8, @intCast(value_b)) },
                );
            },
            .neg_range => {
                const value_a = inst.a orelse {
                    std.debug.print("neg_range <missing operand>, b\n", .{});
                    continue;
                };
                const value_b = inst.a orelse {
                    std.debug.print("neg_range a, <missing operand>\n", .{});
                    continue;
                };

                std.debug.print(
                    "neg_range '{c}' - '{c}')\n",
                    .{ @as(u8, @intCast(value_a)), @as(u8, @intCast(value_b)) },
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

            .match => std.debug.print("match\n", .{}),
            .any => std.debug.print("any\n", .{}),
            .bol => std.debug.print("bol\n", .{}),
            .eol => std.debug.print("eol\n", .{}),
        }
    }

    std.debug.print("\n", .{});
}


const Case = struct {
    pattern: []const u8,
    text: []const u8,
    expected: []const u32,
    success: bool = true,
};

fn test_cases(cases: []const Case) !void {
    const allocator = std.testing.allocator;

    for (cases) |case| {
        std.debug.print("pattern: {s}\n", .{case.pattern});
        var program = try compile(allocator, case.pattern);
        defer program.instructions.deinit(allocator);

        const result = try match(allocator, program, case.text);
        defer result.deinit();
        if (result.result) {
            const groups = result.groups.?;

            try std.testing.expectEqual(case.expected.len, groups.len);

            for (case.expected, groups) |expected, actual| {
                try std.testing.expectEqual(expected, actual);
            }
        } else {
            try std.testing.expect(!case.success);
        }
    }
}

test "capture groups" {
    const cases = [_]Case{
        .{ .pattern = "^(a+)(a+)$", .text = "aaaa", .expected = &.{ 0, 4, 0, 3, 3, 4 }, },
        .{ .pattern = "^(a*)(a*)$", .text = "aaa", .expected = &.{ 0, 3, 0, 3, 3, 3 }, },
        .{ .pattern = "^(a+)$", .text = "aaaa", .expected = &.{ 0, 4, 0, 4 }, },
        .{ .pattern = "^(a|aa)$", .text = "aa", .expected = &.{ 0, 2, 0, 2 }, },
        .{ .pattern = "^(a+?)(a+?)$", .text = "aaaa", .expected = &.{ 0, 4, 0, 1, 1, 4 }, },
        .{ .pattern = "^(a*?)(a*?)$", .text = "aaa", .expected = &.{ 0, 3, 0, 0, 0, 3 }, },
        .{ .pattern = "^(a+?)$", .text = "aaaa", .expected = &.{ 0, 4, 0, 4 }, },
    };
    try test_cases(&cases);
}


test "literal backslash" {
    const cases = [_]Case{
        .{ .pattern = "\\(ab\\)\\+", .text = "(ab)+", .expected = &.{0, 5}, },
        .{ .pattern = "(\\()", .text = "(", .expected = &.{0, 1, 0, 1}, },
    };
    try test_cases(&cases);
}

test "Counted reptitions" {
    const allocator = std.testing.allocator;
    const pattern = "(?:ab){2,4}a{1}a{3,}";
    const text = "abababaaaaaaa";
    var program = try compile(allocator, pattern);
    defer program.instructions.deinit(allocator);
    const result = try match(allocator, program, text);
    defer result.deinit();
    try std.testing.expect(result.result);
}

test "lazy counted reptitions" {
    const cases = [_]Case{
        .{ .pattern = "^(a{3}?)$", .text = "aaa", .expected = &.{0, 3, 0, 3}, },
        .{ .pattern = "^(a{3,}?)a*$", .text = "aaaa", .expected = &.{0, 4, 0, 3}, },
        .{ .pattern = "^(a{3,})a*$", .text = "aaaa", .expected = &.{0, 4, 0, 4}, },
        .{ .pattern = "^(a{3,5}?)a*$", .text = "aaaa", .expected = &.{ 0, 4, 0, 3}, },
        .{ .pattern = "^(a{3,5})a*$", .text = "aaaa", .expected = &.{ 0, 4, 0, 4}, },
    };
    try test_cases(&cases);
}

test "character classes" {
    const cases = [_]Case{
        .{ .pattern = "^[abc]$", .text = "b", .expected = &.{0, 1}, },
        .{ .pattern = "^[a-c]$", .text = "b", .expected = &.{0, 1}, },
        .{ .pattern = "^[a-c]$", .text = "d", .expected = &.{}, .success = false ,},
        .{ .pattern = "^[A-Za-z0-9]$", .text = "G", .expected = &.{0, 1}, },
        .{ .pattern = "^[A-Za-z0-9]$", .text = "7", .expected = &.{0, 1}, },
        .{ .pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$", .text = "hello_123", .expected = &.{0, 9}, },
        .{ .pattern = "^[a-zA-Z_][a-zA-Z0-9_]*$", .text = "hello_123*", .expected = &.{}, .success = false ,},
    };
    try test_cases(&cases);
}