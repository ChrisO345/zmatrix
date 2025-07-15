const std = @import("std");
const rng = std.Random;

const stdout = std.io.getStdOut();
const Screen = struct {
    term_width: usize,
    term_height: usize,
    charset: []const u8,
    random: *const std.Random,
    points: []Point,
    chance: usize,

    const Point = struct {
        x: usize,
        y: usize,
        speed: usize,
        lifetime: usize,
        char: u8,
        head: bool,
    };

    pub fn init(
        term_width: usize,
        term_height: usize,
        charset: []const u8,
        chance: usize,
        random: *const std.Random,
        allocator: *std.mem.Allocator,
    ) !Screen {
        const total_points = term_width * term_height;

        const points = try allocator.alloc(Point, total_points);
        for (points) |*p| {
            p.* = .{ .x = 0, .y = 0, .speed = 0, .lifetime = 0, .char = ' ', .head = false };
        }

        return Screen{
            .term_width = term_width,
            .term_height = term_height,
            .charset = charset,
            .random = random,
            .points = points,
            .chance = chance,
        };
    }

    pub fn deinit(self: *Screen, allocator: *std.mem.Allocator) void {
        allocator.free(self.points);
    }

    pub fn display(self: *Screen) !void {
        try stdout.writeAll("\x1b[2J\x1b[H");
        for (self.points, 0..) |*point, i| {
            const col = i % self.term_width;

            if (point.lifetime > 0) {
                try stdout.writer().print("{c}", .{point.char});
            } else {
                try stdout.writeAll(" ");
            }

            if (col == self.term_width - 1) {
                try stdout.writeAll("\n");
            }
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
                    self.points[dst_idx] = self.points[src_idx];
                    self.points[dst_idx].y += 1;
                } else if (self.points[dst_idx].lifetime > 0) {
                    self.points[dst_idx].lifetime -= 1;
                }
            }
        }

        // Decay the top row
        for (0..self.term_width) |col| {
            const idx = col;
            if (self.points[idx].lifetime > 0) {
                self.points[idx].lifetime -= 1;
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
                    .lifetime = self.random.intRangeAtMost(usize, 5, 9),
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

pub fn main() !void {
    const fps: comptime_float = 10;
    const chance = 10;

    var allocator = std.heap.page_allocator;
    var prng = rng.DefaultPrng.init(42);
    const random = prng.random();

    const term_width = 40;
    const term_height = 20;
    const charset = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";

    var screen = try Screen.init(term_width, term_height, charset, chance, &random, &allocator);
    defer screen.deinit(&allocator);

    while (true) {
        screen.iter();
        try screen.display();
        std.time.sleep(1e9 / fps);
    }
}
