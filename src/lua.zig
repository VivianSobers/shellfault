const std = @import("std");

pub const c = @import("c");

pub const State = struct {
    gpa: std.mem.Allocator,
    l: *c.lua_State,

    pub fn init(gpa: std.mem.Allocator) !State {
        const l = c.luaL_newstate() orelse return error.LuaInitFailed;
        c.luaL_openlibs(l);
        return State{
            .gpa = gpa,
            .l = l,
        };
    }

    pub fn deinit(self: *State) void {
        c.lua_close(self.l);
    }

    pub fn evalNumber(self: *State, src: [:0]const u8) !f64 {
        if (c.luaL_loadstring(self.l, src.ptr) != c.LUA_OK) {
            c.lua_settop(self.l, -2);
            return error.LuaCompileError;
        }

        if (c.lua_pcallk(self.l, 0, 1, 0, 0, null) != c.LUA_OK) {
            c.lua_settop(self.l, -2);
            return error.LuaRuntimeError;
        }

        if (c.lua_isnumber(self.l, -1) == 0) {
            c.lua_settop(self.l, -2);
            return error.NotANumber;
        }

        const val = c.lua_tonumberx(self.l, -1, null);
        c.lua_settop(self.l, -2);
        return @as(f64, @floatCast(val));
    }
};

test "embedded lua evaluates arithmetic" {
    var state = try State.init(std.testing.allocator);
    defer state.deinit();

    const result = try state.evalNumber("return 1 + 2");
    try std.testing.expectEqual(@as(f64, 3), result);
}
