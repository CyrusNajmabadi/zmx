//! Save and restore OSC 7501 Program Status for one shell session.
//! A report is an OSC 7501 message sent by a program. A saved task record holds
//! the latest report for that task.
//! www.superlogical.com/rex/docs/build/program-status
const std = @import("std");
const ghostty = @import("ghostty-vt");
const Report = ghostty.osc.Command.ProgramStatus.Report;
const Handler = @FieldType(ghostty.TerminalStream, "handler");

/// Saved OSC 7501 Program Status records for one zmx session. Keep the latest
/// report for the main program and each named task.
///
/// "A report with no id addresses the root record."
/// "Root and child records exist at the same time. A program can be idle at
/// its prompt while one of its workers is blocked."
/// www.superlogical.com/rex/docs/build/program-status#records-and-ids
pub const Records = struct {
    // The OSC 7501 spec lists 256 task records per terminal and permits lower limits.
    // "256. Terminals MUST support at least 64."
    // www.superlogical.com/rex/docs/build/program-status#limits
    pub const max_records = 256;

    // Saved OSC 7501 task records are ordered from oldest update to newest.
    items: std.ArrayList(Report) = .empty,

    // An allocation failure prevented us from saving an OSC 7501 update.
    // Do not send saved OSC 7501 task records to reconnecting clients until
    // an OSC 7501 'clear' without a task ID or a full terminal reset discards
    // all saved task records.
    has_unsaved_update: bool = false,

    pub fn deinit(self: *Records, alloc: std.mem.Allocator) void {
        self.removeTaskAndChildren(alloc, null);
        self.items.deinit(alloc);
    }

    /// Return the saved OSC 7501 report for this task, or for the main program if
    /// no task ID is supplied. Return 'null' if no report is saved for it.
    /// The returned bytes belong to this 'Records' instance. Do not keep them
    /// across updates or removals, which may free them.
    pub fn get(self: *const Records, id: ?[]const u8) ?Report {
        for (self.items.items) |report| {
            if (taskIdsMatch(report.readOption(.id), id)) {
                return report;
            }
        }
        return null;
    }

    /// Update saved OSC 7501 task records from a report Ghostty has checked and parsed.
    /// "Each report replaces its record completely. A key missing from the
    /// report is missing from the record afterwards."
    /// An OSC 7501 'clear' removes records whose task ID equals the report's ID
    /// or starts with that ID followed by '/'. Without an ID, it removes all records.
    /// www.superlogical.com/rex/docs/build/program-status#records-and-ids
    pub fn updateFromReport(self: *Records, alloc: std.mem.Allocator, report: Report) !void {
        const id = report.readOption(.id);
        if (report.state == .clear) {
            self.removeTaskAndChildren(alloc, id);
            if (id == null) {
                // Clearing all OSC 7501 task records gives us a known empty state again.
                // "A full reset (RIS) removes every record. A soft reset (DECSTR)
                // does not."
                // Ghostty sends this same OSC 7501 'clear' callback for a full reset.
                // www.superlogical.com/rex/docs/build/program-status#records-and-ids
                self.has_unsaved_update = false;
            }
            return;
        }

        // An unsaved OSC 7501 update means we cannot restore every task accurately.
        errdefer self.has_unsaved_update = true;

        // Ghostty reuses the bytes of a parsed OSC 7501 report when it reads
        // more output. Copy them so the saved task record remains valid.
        // Allocate before removing anything so failure preserves existing data.
        const data = try alloc.dupe(u8, report.data);
        errdefer alloc.free(data);
        try self.items.ensureTotalCapacity(alloc, @min(max_records, self.items.items.len + 1));

        for (self.items.items, 0..) |old, index| {
            if (taskIdsMatch(old.readOption(.id), id)) {
                self.removeAt(alloc, index);
                break;
            }
        }
        if (self.items.items.len == max_records) {
            // "When a report would create a record past the cap, the record
            // that was updated least recently is removed to make room."
            // www.superlogical.com/rex/docs/build/program-status#limits
            self.removeAt(alloc, 0);
        }
        self.items.appendAssumeCapacity(.{ .state = report.state, .data = data });
    }

    /// Remove saved OSC 7501 'working' and 'blocked' task records when a shell
    /// prompt begins or the process exits.
    ///
    /// "There is no heartbeat, and terminals MUST NOT require re-sending to keep
    /// a record alive. When the process attached to the terminal exits, or a new
    /// shell prompt begins (OSC 133 A), the terminal MUST drop working and
    /// blocked records and MAY drop idle ones. done and error survive both events."
    /// www.superlogical.com/rex/docs/build/program-status#states
    ///
    /// We keep 'idle' task records, as permitted. Removing a saved task record
    /// does not create or send an OSC 7501 'done' report.
    pub fn removeWorkingAndBlocked(self: *Records, alloc: std.mem.Allocator) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            switch (self.items.items[index].state) {
                .working, .blocked => self.removeAt(alloc, index),
                else => index += 1,
            }
        }
    }

    /// Write OSC 7501 messages that restore saved Program Status task records
    /// in a reconnecting terminal. Write nothing if an update could not be saved.
    /// Buffer this output before sending it so a write failure cannot send
    /// only part of the saved task list.
    pub fn writeReplay(self: *const Records, writer: *std.Io.Writer) !void {
        if (self.has_unsaved_update) {
            // Some OSC 7501 task records may be missing. Do not replace the
            // client's Program Status records with a list we know is incomplete.
            return;
        }
        // Send OSC 7501 'clear' to remove the client's old Program Status records
        // before restoring ours. Do this even when we have no saved task records.
        // "With no id, removes every record on the terminal."
        // www.superlogical.com/rex/docs/build/program-status#states
        try writer.writeAll("\x1b]7501;state=clear\x1b\\");
        for (self.items.items) |report| {
            try writer.print("\x1b]7501;{s}\x1b\\", .{report.data});
        }
    }

    /// Remove saved OSC 7501 records whose task ID equals 'id' or starts with
    /// 'id' followed by '/'. If 'id' is 'null', remove all saved task records.
    ///
    /// "Removes the addressed record and every record beneath it. With no id,
    /// removes every record on the terminal."
    /// www.superlogical.com/rex/docs/build/program-status#states
    ///
    /// "A parent does not have to exist. Terminals MUST use this relationship
    /// for clearing (see States) and app inheritance (see Keys), and MAY use
    /// it for grouping. It means nothing else."
    /// www.superlogical.com/rex/docs/build/program-status#records-and-ids
    ///
    /// An ID of 'build' removes 'build' and 'build/test', but leaves 'builder' alone.
    fn removeTaskAndChildren(self: *Records, alloc: std.mem.Allocator, id: ?[]const u8) void {
        var index: usize = 0;
        while (index < self.items.items.len) {
            var matches = true;
            if (id) |task_id| {
                matches = false;
                if (self.items.items[index].readOption(.id)) |report_id| {
                    const same_task = std.mem.eql(u8, task_id, report_id);
                    // "build/test is a child of build"
                    // www.superlogical.com/rex/docs/build/program-status#records-and-ids
                    const child_task = report_id.len > task_id.len and
                        std.mem.startsWith(u8, report_id, task_id) and
                        report_id[task_id.len] == '/';
                    matches = same_task or child_task;
                }
            }

            if (matches) {
                self.removeAt(alloc, index);
            } else {
                index += 1;
            }
        }
    }

    fn removeAt(self: *Records, alloc: std.mem.Allocator, index: usize) void {
        alloc.free(self.items.orderedRemove(index).data);
    }

    fn taskIdsMatch(first_id: ?[]const u8, second_id: ?[]const u8) bool {
        if (first_id == null) return second_id == null;
        return second_id != null and std.mem.eql(u8, first_id.?, second_id.?);
    }
};

/// Reads one shell's output to update its screen and save OSC 7501 Program
/// Status task records, even while no client is attached. Keeps unfinished
/// terminal messages so a reconnecting client can continue reading them.
pub const Stream = struct {
    vt: ghostty.TerminalStream,
    alloc: std.mem.Allocator,
    records: *Records,

    /// The caller owns the terminal and the 'Records' instance and must keep
    /// both alive at their original addresses until this stream is deinitialized.
    /// Keep the stream itself at a fixed address while processing output because Ghostty
    /// callbacks find it through fields inside it.
    pub fn init(alloc: std.mem.Allocator, term: *ghostty.Terminal, records: *Records) Stream {
        var result: Stream = .{
            .vt = .init(.{
                .allocator = alloc,
                // This handler leaves 'write_pty' unset, so Ghostty cannot send
                // OSC 7501 capability replies. The attached terminal replies
                // instead, avoiding duplicate answers to the same query.
                .handler = term.vtHandler(),
                // A reconnect can happen halfway through an OSC 7501 message.
                // Save enough bytes for the spec's whole-sequence limit.
                // "4096 bytes. The largest legal report is under 3300."
                // www.superlogical.com/rex/docs/build/program-status#limits
                .continuation_max_bytes = ghostty.osc.program_status.max_sequence_bytes,
            }),
            .alloc = alloc,
            .records = records,
        };
        result.vt.handler.effects.program_status = &onReport;
        result.vt.handler.effects.semantic_prompt = &onPrompt;
        return result;
    }

    pub fn deinit(self: *Stream) void {
        self.vt.deinit();
    }

    pub fn nextSlice(self: *Stream, data: []const u8) void {
        self.vt.nextSlice(data);
    }

    /// Write OSC 7501 messages restoring saved task records, then any unfinished
    /// terminal message. Call after restoring the screen and before sending new
    /// output so the next bytes finish the message the program had already started.
    /// Buffer this output before sending it and discard it if writing fails.
    pub fn writeReplay(self: *const Stream, writer: *std.Io.Writer) !void {
        try self.records.writeReplay(writer);
        // Even if we could not save all OSC 7501 reports, continue any unfinished live
        // message. Ghostty leaves out actions it already performed, so reading
        // the saved bytes does not repeat them.
        self.vt.writeContinuation(writer) catch |err| switch (err) {
            // Other terminal messages can exceed the OSC 7501 sequence limit.
            // If Ghostty could not save one, keep the screen and OSC 7501 restoration.
            error.ContinuationUnavailable => std.log.warn("unfinished terminal sequence unavailable on reattach", .{}),
            else => return err,
        };
    }

    fn fromHandler(handler: *Handler) *Stream {
        // Ghostty gives us the handler inside 'vt'. Walk back through these two
        // containing fields to reach our stream and its saved OSC 7501 task records.
        const vt: *ghostty.TerminalStream = @fieldParentPtr("handler", handler);
        return @fieldParentPtr("vt", vt);
    }

    fn onReport(handler: *Handler, report: Report) void {
        const self = fromHandler(handler);
        self.records.updateFromReport(self.alloc, report) catch |err| {
            std.log.warn("failed to retain program status: {s}", .{@errorName(err)});
        };
    }

    fn onPrompt(handler: *Handler, event: ghostty.SemanticPrompt) void {
        const self = fromHandler(handler);
        if (event.kind == .prompt_start) {
            self.records.removeWorkingAndBlocked(self.alloc);
        }
    }
};

/// A test shell session with its own Ghostty screen, saved OSC 7501 task records,
/// and output reader, without starting a shell.
const TestSession = struct {
    term: ghostty.Terminal = undefined,
    records: Records = .{},
    stream: Stream = undefined,

    /// Initialize in place so the stream's pointers keep referring to these fields.
    fn init(self: *TestSession) !void {
        self.term = try ghostty.Terminal.init(std.testing.io, std.testing.allocator, .{ .cols = 80, .rows = 24 });
        self.stream = Stream.init(std.testing.allocator, &self.term, &self.records);
    }

    fn deinit(self: *TestSession) void {
        self.stream.deinit();
        self.records.deinit(std.testing.allocator);
        self.term.deinit(std.testing.allocator);
    }

    fn report(self: *TestSession, data: []const u8) void {
        self.stream.nextSlice("\x1b]7501;");
        self.stream.nextSlice(data);
        self.stream.nextSlice("\x1b\\");
    }
};

test "program status owns reports and replaces complete records" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();

    // Deliberately split escape sequences across reads, including the terminator.
    f.stream.nextSlice("\x1b]");
    f.stream.nextSlice("7501;state=blocked:app=claude-code:kind=permission:msg=QXBwcm92ZT8=\x1b");
    f.stream.nextSlice("\\");
    f.report("state=working:id=worker:progress=37");
    try std.testing.expectEqual(.blocked, f.records.get(null).?.state);
    try std.testing.expectEqualStrings("claude-code", f.records.get(null).?.readOption(.app).?);
    try std.testing.expectEqual(.permission, f.records.get(null).?.readOption(.kind).?);
    try std.testing.expectEqual(@as(u8, 37), f.records.get("worker").?.readOption(.progress).?);

    f.report("state=idle");
    const root = f.records.get(null).?;
    try std.testing.expectEqual(.idle, root.state);
    try std.testing.expect(root.readOption(.app) == null);
    try std.testing.expect(root.readOption(.kind) == null);
    try std.testing.expect(root.readOption(.msg) == null);
    try std.testing.expectEqual(@as(usize, 2), f.records.items.items.len);
}

test "program status clears descendants at path boundaries without requiring a parent" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=idle");
    f.report("state=blocked:id=build/test:kind=question");
    f.report("state=working:id=builder/test");
    f.report("state=clear:id=build");
    try std.testing.expect(f.records.get("build/test") == null);
    try std.testing.expect(f.records.get("builder/test") != null);
    try std.testing.expect(f.records.get(null) != null);
    f.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status lifetimes distinguish prompts screens soft resets and full resets" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=working");
    f.report("state=blocked:id=blocked");
    f.report("state=done:id=done");
    f.report("state=error:id=error");
    f.report("state=idle:id=idle");
    f.stream.nextSlice("\x1b[?1049h\x1b[?1049l\x1b[!p");
    try std.testing.expectEqual(@as(usize, 5), f.records.items.items.len);
    f.stream.nextSlice("\x1b]133;A\x07");
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("blocked") == null);
    try std.testing.expectEqual(@as(usize, 3), f.records.items.items.len);

    f.report("state=working");
    f.records.removeWorkingAndBlocked(std.testing.allocator);
    try std.testing.expect(f.records.get(null) == null);
    try std.testing.expect(f.records.get("done") != null);
    f.stream.nextSlice("\x1bc");
    try std.testing.expectEqual(@as(usize, 0), f.records.items.items.len);
}

test "program status rejects malformed and oversized reports atomically" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=done:app=test");
    const invalid = [_][]const u8{
        "state=unknown",
        "state=blocked:id=bad//id",
        "state=blocked:msg=A",
        "state=blocked:msg=Cg==", // newline
        "state=blocked:title=wog=", // C1 control U+0088
        "state=blocked:abcdefghijklmnopq=x",
        "state=blocked:app=" ++ "a" ** 33,
        "state=blocked:msg=" ++ "YQ==" ** 684,
        "state=blocked:title=" ++ "YQ==" ** 65,
        "state=blocked:unknown=" ++ "x" ** 4096,
    };
    for (invalid) |data| {
        f.report(data);
        try std.testing.expectEqualStrings("test", f.records.get(null).?.readOption(.app).?);
        try std.testing.expectEqual(.done, f.records.get(null).?.state);
        try std.testing.expectEqual(@as(usize, 1), f.records.items.items.len);
    }
}

test "program status evicts the least recently updated record" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();
    var buf: [64]u8 = undefined;
    for (0..Records.max_records) |i| {
        f.report(try std.fmt.bufPrint(&buf, "state=working:id=task-{d}", .{i}));
    }
    // Refreshing 'task-0' protects it. Adding 'task-256' removes 'task-1' instead.
    f.report("state=blocked:id=task-0");
    f.report("state=working:id=task-256");
    try std.testing.expectEqual(@as(usize, Records.max_records), f.records.items.items.len);
    try std.testing.expect(f.records.get("task-0") != null);
    try std.testing.expect(f.records.get("task-1") == null);
    try std.testing.expect(f.records.get("task-256") != null);
}

test "program status records with the same id are isolated between sessions" {
    var first: TestSession = .{};
    try first.init();
    defer first.deinit();
    var second: TestSession = .{};
    try second.init();
    defer second.deinit();
    first.report("state=blocked:id=worker");
    second.report("state=done:id=worker");
    first.report("state=clear");
    try std.testing.expectEqual(@as(usize, 0), first.records.items.items.len);
    try std.testing.expectEqual(.done, second.records.get("worker").?.state);
}

test "program status preserves existing records on allocation failure" {
    var records: Records = .{};
    defer records.deinit(std.testing.allocator);
    try records.updateFromReport(std.testing.allocator, .{ .state = .done, .data = "state=done:app=test" });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, records.updateFromReport(failing.allocator(), .{
        .state = .blocked,
        .data = "state=blocked",
    }));
    try std.testing.expectEqual(.done, records.get(null).?.state);
    try std.testing.expectEqualStrings("test", records.get(null).?.readOption(.app).?);
}

test "program status replay preserves every report split across attachment" {
    const alloc = std.testing.allocator;
    const sequences = [_][]const u8{
        "\x1b]7501;state=idle:app=agent:msg=UmVhZHk=\x07",
        "\x1b]7501;state=blocked:id=worker/test:kind=permission:progress=37\x1b\\",
        "\x1b]7501;state=clear:id=worker\x1b\\",
        "\x1b]7501;state=clear\x07",
    };
    for (sequences) |sequence| {
        for (0..sequence.len + 1) |cut| {
            var source: TestSession = .{};
            try source.init();
            defer source.deinit();
            source.report("state=working:app=agent");
            source.report("state=working:id=worker/test");
            source.stream.nextSlice(sequence[0..cut]);

            var replay: std.Io.Writer.Allocating = .init(alloc);
            defer replay.deinit();
            try source.stream.writeReplay(&replay.writer);
            var target: TestSession = .{};
            try target.init();
            defer target.deinit();
            target.report("state=error:id=stale");
            target.stream.nextSlice(replay.writer.buffered());
            source.stream.nextSlice(sequence[cut..]);
            target.stream.nextSlice(sequence[cut..]);
            try std.testing.expectEqual(source.records.items.items.len, target.records.items.items.len);
            for (source.records.items.items) |record| {
                const restored = target.records.get(record.readOption(.id)) orelse return error.TestUnexpectedNull;
                try std.testing.expectEqual(record.state, restored.state);
                try std.testing.expectEqualStrings(record.data, restored.data);
            }
        }
    }
}

test "program status replay continues pending queries without repeating dispatched queries" {
    const S = struct {
        fn reply(handler: *Handler, data: []const u8) void {
            const stream = Stream.fromHandler(handler);
            const session: *TestSession = @fieldParentPtr("stream", stream);
            const target: *@This() = @fieldParentPtr("session", session);
            target.replies.appendSlice(std.testing.allocator, data) catch @panic("test allocation failed");
        }

        session: TestSession = .{},
        replies: std.ArrayList(u8) = .empty,
    };
    const queries = [_][]const u8{ "\x1b]7501;?\x07", "\x1b]7501;?\x1b\\" };
    for (queries) |query| {
        for (0..query.len) |cut| {
            var source: TestSession = .{};
            try source.init();
            defer source.deinit();
            source.stream.nextSlice(query[0..cut]);
            var replay: std.Io.Writer.Allocating = .init(std.testing.allocator);
            defer replay.deinit();
            try source.stream.writeReplay(&replay.writer);
            var target: S = .{};
            try target.session.init();
            defer target.session.deinit();
            defer target.replies.deinit(std.testing.allocator);
            target.session.stream.vt.handler.effects.write_pty = &S.reply;
            target.session.stream.nextSlice(replay.writer.buffered());
            try std.testing.expectEqual(@as(usize, 0), target.replies.items.len);
            target.session.stream.nextSlice(query[cut..]);
            // Ghostty considers the query complete when it reads the escape
            // byte of the two-byte terminator. Replaying the final backslash
            // must not process the same query again.
            const dispatched = query[query.len - 1] == '\\' and cut == query.len - 1;
            if (dispatched) {
                try std.testing.expectEqual(@as(usize, 0), target.replies.items.len);
            } else {
                const terminator: []const u8 = if (query[query.len - 1] == 7) "\x07" else "\x1b\\";
                var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
                defer expected.deinit();
                try expected.writer.print("\x1b]7501;{s}{s}", .{ ghostty.osc.program_status.query_reply, terminator });
                try std.testing.expectEqualStrings(expected.writer.buffered(), target.replies.items);
            }
        }
    }
}

test "program status replay stays unavailable after a missed update until root clear or reset" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "\x1b]7501;state=clear\x07", "\x1bc" }) |reset| {
        var f: TestSession = .{};
        try f.init();
        defer f.deinit();
        f.report("state=working:app=agent");
        var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, f.records.updateFromReport(failing.allocator(), .{ .state = .idle, .data = "state=idle" }));
        f.report("state=done:id=worker");
        f.report("state=clear:id=worker");
        f.stream.nextSlice("\x1b]133;A\x07");
        var unavailable: std.Io.Writer.Allocating = .init(alloc);
        defer unavailable.deinit();
        try f.stream.writeReplay(&unavailable.writer);
        try std.testing.expectEqual(@as(usize, 0), unavailable.writer.buffered().len);

        f.stream.nextSlice(reset);
        var recovered: std.Io.Writer.Allocating = .init(alloc);
        defer recovered.deinit();
        try f.stream.writeReplay(&recovered.writer);
        try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\", recovered.writer.buffered());
    }
}

test "program status replay recovers after an oversized unrelated continuation" {
    var f: TestSession = .{};
    try f.init();
    defer f.deinit();
    f.report("state=blocked:id=worker");
    f.stream.nextSlice("\x1b]52;c;" ++ "YQ==" ** 1100);
    var replay: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer replay.deinit();
    try f.stream.writeReplay(&replay.writer);
    try std.testing.expectEqualStrings("\x1b]7501;state=clear\x1b\\\x1b]7501;state=blocked:id=worker\x1b\\", replay.writer.buffered());
    f.stream.nextSlice("\x07\x1b]7501;state=idle");
    replay.clearRetainingCapacity();
    try f.stream.writeReplay(&replay.writer);
    try std.testing.expect(std.mem.endsWith(u8, replay.writer.buffered(), "\x1b]7501;state=idle"));
}

test "program status failed record capacity growth disables replay without leaking copied bytes" {
    var records: Records = .{};
    defer records.deinit(std.testing.allocator);
    // Copying the OSC 7501 report succeeds, then growing the saved task list fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, records.updateFromReport(failing.allocator(), .{ .state = .working, .data = "state=working" }));
    try std.testing.expectEqual(@as(usize, 0), records.items.items.len);
    try std.testing.expect(records.has_unsaved_update);
}
