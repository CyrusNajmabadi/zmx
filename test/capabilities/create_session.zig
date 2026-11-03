//! Start or reuse a session through libzmx for capability integration tests.
const std = @import("std");
const zmx = @import("zmx");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const mode = args.next() orelse "selected";
    const options: zmx.CreateOptions = if (std.mem.eql(u8, mode, "default"))
        .{}
    else if (std.mem.eql(u8, mode, "empty"))
        .{ .optional_capabilities = &.{} }
    else if (std.mem.eql(u8, mode, "selected"))
        .{ .optional_capabilities = &.{zmx.capability_definitions.program_status} }
    else
        return error.UnknownTestMode;
    _ = try zmx.create(init.gpa, init.io, "libzmx-capabilities", options);
}
