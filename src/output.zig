const std = @import("std");
const c = @import("c.zig").c;

const RenderData = struct {
    output: *c.wlr_output,
    renderer: *c.wlr_renderer,
    view: *View,
    when: *c.struct_timespec,
};

const Output = struct {
    server: *Server,
    wlr_output: *c.wlr_output,
    listen_frame: c.wl_listener,

    pub fn init(server: *Server, wlr_output: *c.wlr_output) !@This() {
        // Some backends don't have modes. DRM+KMS does, and we need to set a mode
        // before we can use the output. The mode is a tuple of (width, height,
        // refresh rate), and each monitor supports only a specific set of modes. We
        // just pick the monitor's preferred mode, a more sophisticated compositor
        // would let the user configure it.

        // if not empty
        if (c.wl_list_empty(&wlr_output.*.modes) == 0) {
            const mode = c.wlr_output_preferred_mode(wlr_output);
            c.wlr_output_set_mode(wlr_output, mode);
            c.wlr_output_enable(wlr_output, true);
            if (!c.wlr_output_commit(wlr_output)) {
                return error.CantCommitWlrOutputMode;
            }
        }

        var output = @This(){
            .server = server,
            .wlr_output = wlr_output,
            .listen_frame = c.wl_listener{
                .link = undefined,
                .notify = handle_frame,
            },
        };

        // Sets up a listener for the frame notify event.
        c.wl_signal_add(&wlr_output.*.events.frame, &output.*.listen_frame);

        // Add the new output to the layout. The add_auto function arranges outputs
        // from left-to-right in the order they appear. A more sophisticated
        // compositor would let the user configure the arrangement of outputs in the
        // layout.
        c.wlr_output_layout_add_auto(server.output_layout, wlr_output);

        // Creating the global adds a wl_output global to the display, which Wayland
        // clients can see to find out information about the output (such as
        // DPI, scale factor, manufacturer, etc).
        c.wlr_output_create_global(wlr_output);

        return output;
    }

    fn handle_frame(listener: [*c]c.wl_listener, data: ?*c_void) callconv(.C) void {
        // This function is called every time an output is ready to display a frame,
        // generally at the output's refresh rate (e.g. 60Hz).
        var output = @fieldParentPtr(Output, "frame", listener);
        var renderer = output.*.server.*.renderer;

        var now: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &now);

        // wlr_output_attach_render makes the OpenGL context current.
        if (!c.wlr_output_attach_render(output.*.wlr_output, null)) {
            return;
        }
        // The "effective" resolution can change if you rotate your outputs.
        var width: c_int = undefined;
        var height: c_int = undefined;
        c.wlr_output_effective_resolution(output.*.wlr_output, &width, &height);
        // Begin the renderer (calls glViewport and some other GL sanity checks)
        c.wlr_renderer_begin(renderer, width, height);

        const color = [_]f32{ 0.3, 0.3, 0.3, 1.0 };
        c.wlr_renderer_clear(renderer, &color);

        // Each subsequent view is rendered on top of the last.
        for (output.*.server.views.span()) |*view| {
            if (!view.*.mapped) {
                // An unmapped view should not be rendered.
                continue;
            }
            var rdata = RenderData{
                .output = output.*.wlr_output,
                .view = view,
                .renderer = renderer,
                .when = &now,
            };
            // This calls our render_surface function for each surface among the
            // xdg_surface's toplevel and popups.
            c.wlr_xdg_surface_for_each_surface(view.*.xdg_surface, render_surface, &rdata);
        }

        // Hardware cursors are rendered by the GPU on a separate plane, and can be
        // moved around without re-rendering what's beneath them - which is more
        // efficient. However, not all hardware supports hardware cursors. For this
        // reason, wlroots provides a software fallback, which we ask it to render
        // here. wlr_cursor handles configuring hardware vs software cursors for you,
        // and this function is a no-op when hardware cursors are in use.
        c.wlr_output_render_software_cursors(output.*.wlr_output, null);

        // Conclude rendering and swap the buffers, showing the final frame
        // on-screen.
        c.wlr_renderer_end(renderer);
        // TODO: handle failure
        _ = c.wlr_output_commit(output.*.wlr_output);
    }

    fn render_surface(surface: [*c]c.wlr_surface, sx: c_int, sy: c_int, data: ?*c_void) callconv(.C) void {
        // This function is called for every surface that needs to be rendered.
        var rdata = @ptrCast(*RenderData, @alignCast(@alignOf(RenderData), data));
        var view = rdata.*.view;
        var output = rdata.*.output;

        // We first obtain a wlr_texture, which is a GPU resource. wlroots
        // automatically handles negotiating these with the client. The underlying
        // resource could be an opaque handle passed from the client, or the client
        // could have sent a pixel buffer which we copied to the GPU, or a few other
        // means. You don't have to worry about this, wlroots takes care of it.
        var texture = c.wlr_surface_get_texture(surface);
        if (texture == null) {
            return;
        }

        // The view has a position in layout coordinates. If you have two displays,
        // one next to the other, both 1080p, a view on the rightmost display might
        // have layout coordinates of 2000,100. We need to translate that to
        // output-local coordinates, or (2000 - 1920).
        var ox: f64 = 0.0;
        var oy: f64 = 0.0;
        c.wlr_output_layout_output_coords(view.*.server.*.output_layout, output, &ox, &oy);
        ox += @intToFloat(f64, view.*.x + sx);
        oy += @intToFloat(f64, view.*.y + sy);

        // We also have to apply the scale factor for HiDPI outputs. This is only
        // part of the puzzle, TinyWL does not fully support HiDPI.
        var box = c.wlr_box{
            .x = @floatToInt(c_int, ox * output.*.scale),
            .y = @floatToInt(c_int, oy * output.*.scale),
            .width = @floatToInt(c_int, @intToFloat(f32, surface.*.current.width) * output.*.scale),
            .height = @floatToInt(c_int, @intToFloat(f32, surface.*.current.height) * output.*.scale),
        };

        // Those familiar with OpenGL are also familiar with the role of matricies
        // in graphics programming. We need to prepare a matrix to render the view
        // with. wlr_matrix_project_box is a helper which takes a box with a desired
        // x, y coordinates, width and height, and an output geometry, then
        // prepares an orthographic projection and multiplies the necessary
        // transforms to produce a model-view-projection matrix.
        //
        // Naturally you can do this any way you like, for example to make a 3D
        // compositor.
        var matrix: [9]f32 = undefined;
        var transform = c.wlr_output_transform_invert(surface.*.current.transform);
        c.wlr_matrix_project_box(&matrix, &box, transform, 0.0, &output.*.transform_matrix);

        // This takes our matrix, the texture, and an alpha, and performs the actual
        // rendering on the GPU.
        _ = c.wlr_render_texture_with_matrix(rdata.*.renderer, texture, &matrix, 1.0);

        // This lets the client know that we've displayed that frame and it can
        // prepare another one now if it likes.
        c.wlr_surface_send_frame_done(surface, rdata.*.when);
    }
};
