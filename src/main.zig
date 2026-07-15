const std = @import("std");

const RegexError = error{
    UnmatchedClosingParenthesis,
    UnmatchedOpeningParenthesis,
    InvalidOperator,
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("Memory leak detected\n", .{});
        }
    }

    const allocator = gpa.allocator();

    // const pattern = "xa+b";
    // std.debug.print("before: {s}\n", .{pattern});
    try raw2postfix(allocator, "a(bc|d*)e");
    try raw2postfix(allocator, "(ab|cd)+ef");
    try raw2postfix(allocator, "a?(b|cd)e*");
    try raw2postfix(allocator, "(ab(c|d))|ef");
    try raw2postfix(allocator, "a(b|c(d|e))f");

}

const Operation = enum(u16) { // Bigger is higher precedence
    concat = 256, // implicit
    pipe, // |
    plus, // +
    star, // *
    qm, // ?
    any, // - will end up as .
};

const State = struct {
    c: u16,
    out: *State,
    out1: *State,
};

// fn push_operator(
//     allocator: std.mem.Allocator,
//     outputqueue: *std.ArrayList(u16),
//     operatorqueue: *std.ArrayList(u8),
//     new_operator: Operation,
// ) !void {
    
// }

pub fn raw2postfix(
    allocator: std.mem.Allocator,
    pattern: []const u8
) !void {
    var outputqueue: std.ArrayList(u16) = .empty;
    defer outputqueue.deinit(allocator);
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
                    switch(op) {
                        '(' => {
                            found_open = true;
                            break;
                        },
                        '|' => {
                            try outputqueue.append(allocator, @intFromEnum(Operation.pipe));
                        },
                        '.' => {
                            try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                        },
                        else => {
                            return error.InvalidOperator;
                        }
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
                        try outputqueue.append(allocator, @intFromEnum(Operation.pipe));
                    }
                }
                try operatorqueue.append(allocator, '|');
                last_end = false;
            },
            '.' => { // e s
                if (last_end) {
                    if (operatorqueue.items.len > 0 and operatorqueue.items[operatorqueue.items.len - 1] == '.') {
                        try outputqueue.append(allocator, @intFromEnum(Operation.concat));
                    } else {
                        try operatorqueue.append(allocator, '.');
                    }
                }

                try outputqueue.append(allocator, '-');
                last_end = true;
            },
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
            }
        }
    }

    while (operatorqueue.pop()) |op| {
        switch(op) {
            '(' => {
                return error.UnmatchedOpeningParenthesis;
            },
            '|' => {
                try outputqueue.append(allocator, @intFromEnum(Operation.pipe));
            },
            '.' => {
                try outputqueue.append(allocator, @intFromEnum(Operation.concat));
            },
            else => unreachable,
        }
    }

    try debugprintpostfix(allocator, outputqueue.items);
}

pub fn debugprintpostfix(
    allocator: std.mem.Allocator,
    outputqueue: []const u16
) !void {
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