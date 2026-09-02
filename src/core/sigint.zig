const std = @import("std");
const builtin = @import("builtin");

var triggered: bool = false;

pub fn isTriggered() bool {
    return @atomicLoad(bool, &triggered, .monotonic);
}

pub fn trigger() void {
    @atomicStore(bool, &triggered, true, .monotonic);
}

/// Clears a delivered interrupt so the caller can absorb it instead of letting
/// the chat loop tear the session down on its next pass. Only the orchestrate
/// abort path uses this: it stops an interactive run and returns to the prompt.
pub fn clear() void {
    @atomicStore(bool, &triggered, false, .monotonic);
}

pub fn register() !void {
    if (builtin.os.tag == .windows) {
        return registerWindows();
    }
    return registerPosix();
}

fn registerPosix() !void {
    const handler = struct {
        fn handler(sig: std.posix.SIG) callconv(.c) void {
            _ = sig;
            @atomicStore(bool, &triggered, true, .monotonic);
        }
    }.handler;
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.INT, &act, null);
}

fn registerWindows() !void {
    const HandlerRoutine = *const fn (dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

    const handler: HandlerRoutine = struct {
        fn ctrlHandler(dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL {
            _ = dwCtrlType;
            @atomicStore(bool, &triggered, true, .monotonic);
            return .TRUE;
        }
    }.ctrlHandler;

    const SetConsoleCtrlHandler = @extern(*const fn (
        handler: HandlerRoutine,
        add: std.os.windows.BOOL,
    ) callconv(.winapi) std.os.windows.BOOL, .{ .name = "SetConsoleCtrlHandler" });

    if (SetConsoleCtrlHandler(handler, .TRUE) == .FALSE) {
        return error.SetConsoleCtrlHandlerFailed;
    }
}

test "trigger sets the triggered flag" {
    triggered = false;
    try std.testing.expect(!isTriggered());
    trigger();
    try std.testing.expect(isTriggered());
    triggered = false;
}

test "register installs a SIGINT handler that sets the flag" {
    if (comptime builtin.os.tag == .linux) {
        triggered = false;
        defer triggered = false;

        var previous: std.posix.Sigaction = undefined;
        std.posix.sigaction(.INT, null, &previous);
        defer std.posix.sigaction(.INT, &previous, null);

        try register();
        try std.testing.expect(!isTriggered());
        try std.posix.raise(.INT);
        try std.testing.expect(isTriggered());
    } else {
        return error.SkipZigTest;
    }
}

test "clear resets a delivered interrupt" {
    triggered = false;
    defer triggered = false;
    trigger();
    try std.testing.expect(isTriggered());
    clear();
    try std.testing.expect(!isTriggered());
}
