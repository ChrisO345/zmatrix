const std = @import("std");
const rng = std.Random;
const stdout = std.io.getStdOut();

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("termios.h");
});

const Screen = struct {
    term_width: usize,
    term_height: usize,
    charset: []const u8,
    random: *const std.Random,
    points: []Point,
    prev_points: []Point,
    chance: usize,
    colors: []usize,

    const MaxLifetime: usize = 9;

    const Point = struct {
        x: usize,
        y: usize,
        speed: usize,
        lifetime: usize,
        char: u8,
        head: bool,
    };

    pub fn init(
        charset: []const u8,
        chance: usize,
        random: *const std.Random,
        allocator: *std.mem.Allocator,
    ) !Screen {
        const term = try Screen.get_screen_size();

        const total_points = term.width * term.height;

        const points = try allocator.alloc(Point, total_points);
        for (points) |*p| {
            p.* = .{ .x = 0, .y = 0, .speed = 0, .lifetime = 0, .char = ' ', .head = false };
        }

        const prev_points = try allocator.alloc(Point, total_points);
        for (prev_points) |*p| {
            p.* = .{ .x = 0, .y = 0, .speed = 0, .lifetime = 0, .char = ' ', .head = false };
        }

        // Create the colors array with distributed numbers between 0 and 255
        const colors = try allocator.alloc(usize, MaxLifetime);
        for (0..MaxLifetime) |i| {
            colors[i] = i * (255 / (MaxLifetime - 1));
        }

        // Hide the cursor
        try stdout.writeAll("\x1b[?25l");

        // Clear the screen
        try stdout.writeAll("\x1b[2J\x1b[H");

        return Screen{
            .term_width = term.width,
            .term_height = term.height,
            .charset = charset,
            .random = random,
            .points = points,
            .prev_points = prev_points,
            .chance = chance,
            .colors = colors,
        };
    }

    pub fn deinit(self: *Screen, allocator: *std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.prev_points);
        allocator.free(self.colors);

        // Show the cursor again
        const res = stdout.writeAll("\x1b[?25h");
        errdefer {
            if (res) |err| {
                std.debug.print("Failed to show cursor: {any}\n", .{err});
            }
        }
    }

    fn get_screen_size() !struct { width: usize, height: usize } {
        var ws: c.struct_winsize = undefined;
        const res = c.ioctl(1, c.TIOCGWINSZ, &ws); // 1 = STDOUT_FILENO
        if (res == -1) {
            return error.UnexpectedIoctlError;
        }

        return .{ .width = ws.ws_col, .height = ws.ws_row };
    }

    pub fn display(self: *Screen) !void {
        const estimated_size = self.term_width * self.term_height * 10;
        var buffer = try std.ArrayList(u8).initCapacity(std.heap.page_allocator, estimated_size);
        defer buffer.deinit();

        try buffer.appendSlice("\x1b[?1049h");
        // try buffer.appendSlice("\x1b[?25l");
        try buffer.appendSlice("\x1b[H");

        for (self.points, 0..) |*point, i| {
            const col = i % self.term_width;
            const row = i / self.term_width;
            const prev = self.prev_points[i];
            const changed = point.char != prev.char or point.lifetime != prev.lifetime or point.head != prev.head;

            if (changed) {
                try buffer.writer().print("\x1b[{d};{d}H", .{ row + 1, col + 1 });

                if (point.lifetime > 0) {
                    const color = self.colors[point.lifetime - 1];
                    if (point.head) {
                        try buffer.writer().print("\x1b[1;37m{c}\x1b[0m", .{point.char});
                    } else {
                        try buffer.writer().print("\x1b[38;2;0;{d};0m{c}\x1b[0m", .{ color, point.char });
                    }
                } else {
                    try buffer.append(' ');
                }

                self.prev_points[i] = point.*;
            }
        }

        var written: usize = 0;
        while (written < buffer.items.len) {
            const bytes = buffer.items[written..];
            const n = stdout.write(bytes) catch |err| switch (err) {
                error.WouldBlock => continue, // try again
                else => return err,
            };
            written += n;
        }
    }

    pub fn shift_down(self: *Screen) void {
        var row = self.term_height - 1;
        while (row > 0) : (row -= 1) {
            const dst_start = row * self.term_width;
            const src_start = (row - 1) * self.term_width;

            for (0..self.term_width) |col| {
                const dst_idx = dst_start + col;
                const src_idx = src_start + col;

                const src_val = self.points[src_idx].lifetime;

                if (src_val > 0) {
                    const ch = self.points[dst_idx].char;
                    self.points[dst_idx] = self.points[src_idx];
                    self.points[dst_idx].y += 1;
                    self.points[dst_idx].char = ch;
                } else if (self.points[dst_idx].lifetime > 0) {
                    self.points[dst_idx].lifetime -= 1;
                    self.points[dst_idx].head = false;
                }

                if (src_val > 0 and self.points[src_idx].head) {
                    self.points[dst_idx].char = self.charset[self.random.intRangeAtMost(usize, 0, self.charset.len - 1)];
                }
            }
        }

        for (0..self.term_width) |col| {
            const idx = col;
            if (self.points[idx].lifetime > 0) {
                self.points[idx].lifetime -= 1;
                self.points[idx].head = false;
            }
        }
    }

    pub fn apply_new_origins(self: *Screen, chance: usize) void {
        for (0..self.term_width) |col| {
            const val = self.random.intRangeAtMost(usize, 0, chance);
            if (val == 0) {
                const idx = col;
                self.points[idx] = .{
                    .x = col,
                    .y = 0,
                    .speed = self.random.intRangeAtMost(usize, 1, 10),
                    .lifetime = self.random.intRangeAtMost(usize, 5, MaxLifetime),
                    .char = self.charset[self.random.intRangeAtMost(usize, 0, self.charset.len - 1)],
                    .head = true,
                };
            }
        }
    }

    pub fn iter(self: *Screen) void {
        self.shift_down();
        self.apply_new_origins(self.chance);
    }
};

fn setTerminalRawMode(fd: c_int, orig_termios: *c.struct_termios) void {
    _ = c.tcgetattr(fd, orig_termios);
    var raw = orig_termios.*;
    raw.c_lflag &= ~@as(c_uint, c.ICANON | c.ECHO); // disable canonical mode and echo
    _ = c.tcsetattr(fd, c.TCSANOW, &raw);
}

fn restoreTerminal(fd: c_int, orig_termios: *const c.struct_termios) void {
    _ = c.tcsetattr(fd, c.TCSANOW, orig_termios);
}

fn keyPressed() ?u8 {
    var bytes: [1]u8 = undefined;
    const result = c.read(0, &bytes, 1);
    if (result == 1) {
        return bytes[0];
    }
    return null;
}

pub fn main() !void {
    const chance = 10;

    var allocator = std.heap.page_allocator;
    var prng = rng.DefaultPrng.init(42);
    const random = prng.random();

    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    var screen = try Screen.init(charset, chance, &random, &allocator);
    defer {
        screen.deinit(&allocator);
    }

    // Terminal setup to allow key input without blocking
    var orig_termios: c.struct_termios = undefined;
    setTerminalRawMode(0, &orig_termios);
    defer restoreTerminal(0, &orig_termios);
    _ = c.fcntl(
        @as(c_int, 0),
        @as(c_int, c.F_SETFL),
        c.fcntl(@as(c_int, 0), @as(c_int, c.F_GETFL), @as(c_int, 0)) | @as(c_int, c.O_NONBLOCK),
    );

    const fps: comptime_float = 12;
    const frames: comptime_int = @intFromFloat(1e9 / fps);

    while (true) {
        if (keyPressed()) |key| {
            if (key == 'q') break;
        }

        screen.iter();
        try screen.display();
        std.time.sleep(frames);
    }
}
