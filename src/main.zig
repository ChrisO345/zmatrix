const std = @import("std");
const stdout = std.io.getStdOut();
const rng = std.Random;

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var prng = rng.DefaultPrng.init(42);
    var rand = prng.random();
    const spawn_chance = 4;

    // TODO: Use a dynamic terminal sizing
    const term_width = 10;
    const term_height = 20;
    // const charset = "ABCDEF";

    const origins = try allocator.alloc(usize, term_width * term_height);
    defer allocator.free(origins);

    // Initialize origins with 0
    for (origins) |*pos| {
        pos.* = 0;
    }

    std.debug.print("Initial columns: {d}\n", .{origins});

    // Randomize origins
    apply_new_origins(origins, term_width, spawn_chance, &rand);

    std.debug.print("Randomized columns: {d}\n", .{origins});
    shift_down(origins, term_width, term_height);
    std.debug.print("Shifted columns: {d}\n", .{origins});

    while (true) {
        try stdout.writeAll("\x1b[2J\x1b[H");
        for (origins, 0..) |*pos, i| {
            const col = i % term_width;

            if (pos.* > 0) {
                try stdout.writer().print("{d} ", .{pos.*});
            } else {
                try stdout.writeAll("  ");
            }

            if (col == term_width - 1) {
                try stdout.writeAll("\n");
            }
        }
        shift_down(origins, term_width, term_height);
        apply_new_origins(origins, term_width, spawn_chance, &rand);
        std.time.sleep(std.time.ns_per_s / 10);
    }
}

fn apply_new_origins(arr: []usize, term_width: usize, chance: usize, rand: *std.Random) void {
    // var prng = rng.DefaultPrng.init(42);
    // const rand = prng.random();
    for (arr, 0..) |*pos, idx| {
        if (idx >= term_width) {
            break;
        }
        pos.* = rand.intRangeAtMost(usize, 0, chance);
        if (pos.* == chance) {
            pos.* = rand.intRangeAtMost(usize, 1, 10);
        } else {
            pos.* = 0; // No origin for this column
        }
    }
}

fn shift_down(arr: []usize, term_width: usize, term_height: usize) void {
    // From bottom to top (excluding row 0)
    var row = term_height - 1;
    while (row > 0) : (row -= 1) {
        const dst_start = row * term_width;
        const src_start = (row - 1) * term_width;

        for (0..term_width) |col| {
            const src_val = arr[src_start + col];

            if (src_val > 0) {
                // Copy non-zero value from row above
                arr[dst_start + col] = src_val;
            } else {
                // Decay existing value at destination
                if (arr[dst_start + col] > 0) {
                    arr[dst_start + col] -= 1;
                }
            }
        }
    }

    // Handle the top row: just decay all non-zero values
    for (0..term_width) |col| {
        const idx = col;
        if (arr[idx] > 0) {
            arr[idx] -= 1;
        }
    }
}
