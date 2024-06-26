const std = @import("std");
const EvalResult = @import("eva.zig").Eva.EvalResult;

pub const Environment = struct {
    allocator: std.mem.Allocator,
    parent: ?*Environment,
    record: std.StringHashMap(EvalResult),

    pub fn init(allocator: std.mem.Allocator, parent: ?*Environment) Environment {
        return Environment{ .allocator = allocator, .parent = parent, .record = std.StringHashMap(EvalResult).init(allocator) };
    }

    pub const Error = error{VariableIsNotDefined};

    pub fn define(self: *Environment, name: []const u8, value: EvalResult) !void {
        try self.record.put(name, value);
    }

    pub fn assign(self: *Environment, name: []const u8, value: EvalResult) !void {
        const env = try self.resolve(name);
        try env.record.put(name, value);
    }

    pub fn lookup(self: *Environment, name: []const u8) !EvalResult {
        const env = try self.resolve(name);
        return env.record.get(name).?;
    }

    fn resolve(self: *Environment, name: []const u8) !*Environment {
        if (self.record.contains(name)) {
            return self;
        }

        if (self.parent) |parent| {
            return parent.resolve(name);
        }

        return Error.VariableIsNotDefined;
    }
};
