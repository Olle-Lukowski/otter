//! A piece of metadata for every alive `Entity`.
//! It helps the `Entity.Index` keep track of the full `Entity` for just an `Id`.
//! It will also hold more metadata in the future,
//! for example to find out what `Entity`s are added to each `Entity`.

/// An index into the `dense` array of the `Entity.Index`.
/// One value is reserved as invalid.
pub const Dense = enum(u32) {
    /// The only invalid value for a `Dense`.
    invalid,
    /// A catch-all variant for all valid values of a `Dense`.
    _,

    /// Create a `Dense` from a raw `u32`.
    pub fn init(dense: u32) Dense {
        return @enumFromInt(dense);
    }

    /// Get the raw `u32` from this `Dense`, if valid.
    pub fn get(self: Dense) ?u32 {
        return switch (self) {
            .invalid => null,
            _ => @intFromEnum(self),
        };
    }
};

/// The index where the full `Entity` for this record can be found.
dense: Dense = .invalid,
