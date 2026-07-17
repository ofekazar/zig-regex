const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
    InvalidPostfix,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected in gpa\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var state_arena = std.heap.ArenaAllocator.init(allocator);
    defer state_arena.deinit();
    const state_allocator = state_arena.allocator();

    // const pattern = "xa+b";
    // std.debug.print("before: {s}\n", .{pattern});
    var postfix = try raw2postfix(allocator, "a(bc|d*)e");
    defer postfix.deinit(allocator);
    _ = try postfix2nfavm(allocator, state_allocator, postfix.items);
    // try raw2postfix(allocator, "(ab|cd)+ef");
    // try raw2postfix(allocator, "a?(b|cd)e*");
    // try raw2postfix(allocator, "(ab(c|d))|ef");
    // try raw2postfix(allocator, "a(b|c(d|e))f");

}

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

const Instuctions = enum(u8) {
    char,
    jump,
    split,
    match,
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
                .plus => {},
                .star => {},
                .qm => {},
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

// pub fn postfix2nfa(
//     allocator: std.mem.Allocator,
//     postfix: []const u16
// ) void {

// }
