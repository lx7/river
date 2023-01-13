// This file is part of river, a dynamic tiling wayland compositor.
//
// Copyright 2020 The River Developers
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, version 3.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

const Self = @This();

const std = @import("std");
const mem = std.mem;
const xkb = @import("xkbcommon");

const util = @import("util.zig");

const Server = @import("Server.zig");
const Mode = @import("Mode.zig");
const AttachMode = @import("view_stack.zig").AttachMode;
const View = @import("View.zig");

pub const FocusFollowsCursorMode = enum {
    disabled,
    /// Only change focus on entering a surface
    normal,
    /// Change focus on any cursor movement
    always,
};

pub const WarpCursorMode = enum {
    disabled,
    @"on-output-change",
    @"on-focus-change",
};

pub const HideCursorWhenTypingMode = enum {
    disabled,
    enabled,
};

pub const SingleViewMode = enum {
    normal,
    @"on-single-output",
    @"on-multi-output",
};

/// Color of background in RGBA with premultiplied alpha (alpha should only affect nested sessions)
background_color: [4]f32 = [_]f32{ 0.0, 0.16862745, 0.21176471, 1.0 }, // Solarized base03

/// Width of borders in pixels
border_width: u31 = 2,

/// Color of border of focused window in RGBA with premultiplied alpha
border_color_focused: [4]f32 = [_]f32{ 0.57647059, 0.63137255, 0.63137255, 1.0 }, // Solarized base1

/// Color of border of unfocused window in RGBA with premultiplied alpha
border_color_unfocused: [4]f32 = [_]f32{ 0.34509804, 0.43137255, 0.45882353, 1.0 }, // Solarized base01

/// Color of border of urgent window in RGBA with premultiplied alpha
border_color_urgent: [4]f32 = [_]f32{ 0.86274510, 0.19607843, 0.18431373, 1.0 }, // Solarized red

/// Color of border of single window in RGBA
border_color_single: [4]f32 = [_]f32{ 0, 0, 0, 1.0 }, // black

/// single_view_mode defines how to draw borders when only one single 
/// (non-fullscreen) window is visible
single_view_mode: SingleViewMode = .normal,

/// Map of keymap mode name to mode id
/// Does not own the string keys. They are owned by the corresponding Mode struct.
mode_to_id: std.StringHashMap(u32),

/// All user-defined keymap modes, indexed by mode id
modes: std.ArrayListUnmanaged(Mode),

/// Sets of app_ids and titles which will be started floating
float_filter_app_ids: std.StringHashMapUnmanaged(void) = .{},
float_filter_titles: std.StringHashMapUnmanaged(void) = .{},

/// Sets of app_ids and titles which are allowed to use client side decorations
csd_filter_app_ids: std.StringHashMapUnmanaged(void) = .{},
csd_filter_titles: std.StringHashMapUnmanaged(void) = .{},

/// The selected focus_follows_cursor mode
focus_follows_cursor: FocusFollowsCursorMode = .disabled,

/// If true, the cursor warps to the center of the focused output
warp_cursor: WarpCursorMode = .disabled,

/// The default layout namespace for outputs which have never had a per-output
/// value set. Call Output.handleLayoutNamespaceChange() on setting this if
/// Output.layout_namespace is null.
default_layout_namespace: []const u8 = &[0]u8{},

/// Bitmask restricting the tags of newly created views.
spawn_tagmask: u32 = std.math.maxInt(u32),

/// Determines where new views will be attached to the view stack.
attach_mode: AttachMode = .top,

/// Keyboard repeat rate in characters per second
repeat_rate: u31 = 25,

/// Keyboard repeat delay in milliseconds
repeat_delay: u31 = 600,

/// Cursor hide timeout in milliseconds
cursor_hide_timeout: u31 = 0,

/// Hide the cursor while typing
cursor_hide_when_typing: HideCursorWhenTypingMode = .disabled,

xkb_context: *xkb.Context,
/// The xkb keymap used for all keyboards
keymap: *xkb.Keymap,

pub fn init() !Self {
    const xkb_context = xkb.Context.new(.no_flags) orelse return error.XkbContextFailed;
    defer xkb_context.unref();

    // Passing null here indicates that defaults from libxkbcommon and
    // its XKB_DEFAULT_LAYOUT, XKB_DEFAULT_OPTIONS, etc. should be used.
    const keymap = xkb.Keymap.newFromNames(xkb_context, null, .no_flags) orelse return error.XkbKeymapFailed;
    defer keymap.unref();

    var self = Self{
        .mode_to_id = std.StringHashMap(u32).init(util.gpa),
        .modes = try std.ArrayListUnmanaged(Mode).initCapacity(util.gpa, 2),
        .xkb_context = xkb_context.ref(),
        .keymap = keymap.ref(),
    };
    errdefer self.deinit();

    // Start with two empty modes, "normal" and "locked"
    {
        // Normal mode, id 0
        const owned_slice = try util.gpa.dupeZ(u8, "normal");
        try self.mode_to_id.putNoClobber(owned_slice, 0);
        self.modes.appendAssumeCapacity(.{ .name = owned_slice });
    }
    {
        // Locked mode, id 1
        const owned_slice = try util.gpa.dupeZ(u8, "locked");
        try self.mode_to_id.putNoClobber(owned_slice, 1);
        self.modes.appendAssumeCapacity(.{ .name = owned_slice });
    }

    return self;
}

pub fn deinit(self: *Self) void {
    self.mode_to_id.deinit();
    for (self.modes.items) |*mode| mode.deinit();
    self.modes.deinit(util.gpa);

    {
        var it = self.float_filter_app_ids.keyIterator();
        while (it.next()) |key| util.gpa.free(key.*);
        self.float_filter_app_ids.deinit(util.gpa);
    }

    {
        var it = self.float_filter_titles.keyIterator();
        while (it.next()) |key| util.gpa.free(key.*);
        self.float_filter_titles.deinit(util.gpa);
    }

    {
        var it = self.csd_filter_app_ids.keyIterator();
        while (it.next()) |key| util.gpa.free(key.*);
        self.csd_filter_app_ids.deinit(util.gpa);
    }

    {
        var it = self.csd_filter_titles.keyIterator();
        while (it.next()) |key| util.gpa.free(key.*);
        self.csd_filter_titles.deinit(util.gpa);
    }

    util.gpa.free(self.default_layout_namespace);

    self.keymap.unref();
    self.xkb_context.unref();
}

pub fn shouldFloat(self: Self, view: *View) bool {
    if (view.getAppId()) |app_id| {
        if (self.float_filter_app_ids.contains(std.mem.span(app_id))) {
            return true;
        }
    }

    if (view.getTitle()) |title| {
        if (self.float_filter_titles.contains(std.mem.span(title))) {
            return true;
        }
    }

    return false;
}

pub fn csdAllowed(self: Self, view: *View) bool {
    if (view.getAppId()) |app_id| {
        if (self.csd_filter_app_ids.contains(std.mem.span(app_id))) {
            return true;
        }
    }

    if (view.getTitle()) |title| {
        if (self.csd_filter_titles.contains(std.mem.span(title))) {
            return true;
        }
    }

    return false;
}
