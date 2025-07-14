const std = @import("std");

const ecs = @import("../ecs.zig");

pub const Record = @import("entity/Record.zig");
pub const Entity = ecs.Entity;

/// The `Index` is a data structure that keeps track of alive `Entity`s.
/// It also helps with creating new `Entity`s, removing `Entity`s, and re-using previously removed ones.
/// Finally, it stores a `Record` for every tracked `Entity`.
///
/// The `Index` is implemented as a sparse set, with a configurable page size.
/// The ideal value for `page_bits` heavily depends on the target machine,
/// whether memory usage or performance is more important, etc.
/// Generally, any value between `6` and `12` provides a "good enough" balance,
/// with 6 being slower with slightly less memory per allocation,
/// and 12 being faster with more memory per allocation.
pub fn Index(page_bits: u5) type {
    return struct {
        pub const Self = @This();

        /// The errors that can occur on certain operations on the `Index`.
        pub const Error = std.mem.Allocator.Error;

        /// A `Page` of `Record`s.
        /// Exists purely to prevent all `Records` from living in one massive allocation.
        pub const Page = struct {
            /// The size of a `Page`, in `Record`s.
            pub const size = 1 << page_bits;
            /// A mask to get the offset into a `Page`.
            pub const mask = size - 1;

            /// The `Record`s in this `Page`.
            records: [size]Record = .{@as(Record, .{})} ** size,

            /// Get the index into the `pages` arraylist of the `Index`, for a given `id`.
            fn index(id: u32) u32 {
                return id >> page_bits;
            }

            /// Get the offset into a `Page`, for a given `id`.
            fn offset(id: u32) u32 {
                return id & mask;
            }
        };

        /// A dense list of currently alive `Entity`s,
        /// directly followed by `Entity`s waiting to be re-used.
        dense: std.ArrayListUnmanaged(Entity) = .{},
        /// A list of all `Page`s, not meant for external access.
        pages: std.ArrayListUnmanaged(?*Page) = .{},
        /// The amount of currently alive `Entity`s.
        /// Also the index where the re-usable `Entity`s start in the `dense` array.
        alive: u32 = 1,
        /// The largest currently allocated `Id`.
        max_id: Entity.Id = .invalid,

        /// Initialize a new `Index` using the given `allocator`.
        /// The same allocator must be used for all other operations that need one,
        /// including the final call to `deinit`.
        pub fn init(allocator: std.mem.Allocator) Error!Self {
            var to_return: Self = .{};

            try to_return.dense.append(allocator, .{}); // slot 0 is the invalid `Entity`

            return to_return;
        }

        /// De-initialize the `Index`.
        /// Ensure the given allocators are the same ones used so far.
        pub fn deinit(
            self: *Self,
            allocator: std.mem.Allocator,
            page_allocator: std.mem.Allocator,
        ) void {
            for (self.pages.items) |maybe_page| {
                const page = maybe_page orelse continue;
                page_allocator.destroy(page);
            }

            self.pages.deinit(allocator);
            self.dense.deinit(allocator);
        }

        /// Get the `Record` for an `Entity`, returning `null` if it doesn't exist or is invalid.
        /// This does **not** check if the `generation` field of the `Entity` matches, or if the `Entity` is alive, for that, use
        /// `getOrNull`.
        pub fn getAnyOrNull(self: *const Self, entity: Entity) ?*Record {
            const id = entity.id.get() orelse return null;
            const page_index = Page.index(id);
            const maybe_page = if (page_index < self.pages.items.len)
                self.pages.items[page_index]
            else
                null;
            const page = maybe_page orelse return null;
            const record = &page.records[Page.offset(id)];

            if (record.dense == .invalid) {
                return null;
            }

            return record;
        }

        /// Get the `Record` for an `Entity`, without doing any checks. Only use this if you are
        /// certain the `Entity` exists.
        pub fn getAny(self: *const Self, entity: Entity) *Record {
            const id = entity.id.get().?;
            const page_index = Page.index(id);
            const page = self.pages.items[page_index].?;

            return &page.records[Page.offset(id)];
        }

        /// Get the `Record` for an `Entity`, returning `null` if it doesn't exist or is invalid.
        /// If checking whether the generation matches or whether the `Entity` is even alive is not needed,
        /// prefer to use `getAnyOrNull`.
        pub fn getOrNull(self: *const Self, entity: Entity) ?*Record {
            const record = self.getAnyOrNull(entity) orelse return null;
            const dense = record.dense.get() orelse 0;

            if (dense >= self.alive) {
                return null;
            }
            if (self.dense.items[dense] != entity) {
                return null;
            }

            return record;
        }

        /// Create a new `Entity`, or re-use an old one.
        /// The `allocator` and `page_allocator` must be consistent across calls.
        /// The `allocator` and `page_allocator` can be the same allocator in simple cases, but
        /// for performance tuning, using seperate allocators can help.
        /// The `allocator` will be used for arraylists that are dynamically resized,
        /// while the `page_allocator` creates a single `Page` at a time, and only destroys them when
        /// `deinit` is called.
        pub fn newEntity(
            self: *Self,
            allocator: std.mem.Allocator,
            page_allocator: std.mem.Allocator,
        ) Error!Entity {
            if (self.alive != self.dense.items.len) {
                // re-use an `Entity`
                const dense = self.alive;

                self.alive += 1;

                return self.dense.items[dense];
            }

            self.max_id = .init((self.max_id.get() orelse 0) +% 1);

            const id = self.max_id;

            const e: Entity = .{ .id = id };
            try self.dense.append(allocator, e);

            const raw_id = id.get() orelse 0;
            const page = try self.ensurePage(
                allocator,
                page_allocator,
                raw_id,
            );

            const record = &page.records[Page.offset(raw_id)];
            record.dense = .init(self.alive);
            self.alive += 1;

            return e;
        }

        /// Create `count` new `Entities`, re-using old ones where possible.
        /// The `allocator` and `page_allocator` must be consistent across calls.
        /// The `allocator` and `page_allocator` can be the same allocator in simple cases, but
        /// for performance tuning, using seperate allocators can help.
        /// The `allocator` will be used for arraylists that are dynamically resized,
        /// while the `page_allocator` creates a single `Page` at a time, and only destroys them when
        /// `deinit` is called.
        pub fn newEntities(
            self: *Self,
            allocator: std.mem.Allocator,
            page_allocator: std.mem.Allocator,
            count: u32,
        ) Error![]const Entity {
            const alive = self.alive;
            const dense_count = self.dense.items.len;
            const new_count = alive + count;

            if (new_count < dense_count) {
                self.alive = new_count;

                return self.dense.items[alive..new_count];
            }

            try self.dense.ensureUnusedCapacity(allocator, count);

            for (dense_count..@intCast(new_count)) |dense| {
                const id = (self.max_id.get() orelse 0) +% 1;
                self.max_id = .init(id);

                const e: Entity = .{ .id = self.max_id };
                try self.dense.append(allocator, e);

                const page = try self.ensurePage(
                    allocator,
                    page_allocator,
                    id,
                );

                const record = &page.records[Page.offset(id)];
                record.dense = .init(@intCast(dense));
            }

            self.alive = new_count;
            return self.dense.items[alive..new_count];
        }

        /// Remove an `Entity` from the `Index` (if it exists),
        /// and marks it as reusable.
        pub fn remove(
            self: *Self,
            entity: Entity,
        ) void {
            const record = self.getOrNull(entity) orelse return;

            const dense = record.dense;

            self.alive -= 1;
            const swapped_entity_ptr = &self.dense.items[self.alive];
            const swapped_entity = swapped_entity_ptr.*;
            const swapped_record = self.getAny(swapped_entity);

            swapped_record.dense = dense;
            record.* = .{ .dense = .init(self.alive) };

            self.dense.items[dense.get().?] = swapped_entity;
            swapped_entity_ptr.* = entity.next();
        }

        /// Check whether an `Entity` is alive.
        pub fn isAlive(self: *const Self, entity: Entity) bool {
            return self.getOrNull(entity) != null;
        }

        fn ensurePage(
            self: *Self,
            allocator: std.mem.Allocator,
            page_allocator: std.mem.Allocator,
            id: u32,
        ) Error!*Page {
            const page_index = Page.index(id);

            if (page_index >= self.pages.items.len) {
                try self.pages.appendNTimes(
                    allocator,
                    null,
                    page_index - self.pages.items.len + 1,
                );
            }

            const page_ptr = &self.pages.items[page_index];
            return page_ptr.* orelse {
                const p = try page_allocator.create(Page);
                p.* = .{};
                page_ptr.* = p;
                return p;
            };
        }
    };
}

const testing = std.testing;

test "Entity Index newEntity" {
    var index: Index(4) = try .init(testing.allocator);
    defer index.deinit(testing.allocator, testing.allocator);

    const e = try index.newEntity(
        testing.allocator,
        testing.allocator,
    );
    try testing.expect(index.isAlive(e));
}

test "Entity Index newEntities" {
    var index: Index(4) = try .init(testing.allocator);
    defer index.deinit(testing.allocator, testing.allocator);

    const entities = try index.newEntities(
        testing.allocator,
        testing.allocator,
        16,
    );

    for (entities) |e| {
        try testing.expect(index.isAlive(e));
    }
}

test "Entity Index remove" {
    var index: Index(4) = try .init(testing.allocator);
    defer index.deinit(testing.allocator, testing.allocator);

    const e = try index.newEntity(
        testing.allocator,
        testing.allocator,
    );
    try testing.expect(index.isAlive(e));

    index.remove(e);

    try testing.expect(!index.isAlive(e));
}
