const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- wayland-scanner code generation ---
    const wl_protocols = generateWaylandProtocols(b);

    // --- toml dependency ---
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    // --- main executable ---
    const exe = b.addExecutable(.{
        .name = "hyprglaze",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_dep.module("toml") },
            },
        }),
    });

    // Generated protocol headers
    exe.root_module.addIncludePath(wl_protocols.include_path);
    // Generated protocol C sources
    exe.root_module.addCSourceFile(.{
        .file = wl_protocols.xdg_shell_c,
    });
    exe.root_module.addCSourceFile(.{
        .file = wl_protocols.layer_shell_c,
    });

    // stb_image implementation
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    // System libraries
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.linkSystemLibrary("wayland-egl", .{});
    exe.root_module.linkSystemLibrary("EGL", .{});
    exe.root_module.linkSystemLibrary("GLESv2", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // --- run step ---
    const run_step = b.step("run", "Run hyprglaze");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // --- ipc test utility ---
    const ipc_test = b.addExecutable(.{
        .name = "hypr-ipc-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    ipc_test.root_module.link_libc = true;
    b.installArtifact(ipc_test);

    const ipc_run_step = b.step("ipc-test", "Run Hyprland IPC test utility");
    const ipc_run_cmd = b.addRunArtifact(ipc_test);
    ipc_run_step.dependOn(&ipc_run_cmd.step);
    ipc_run_cmd.step.dependOn(b.getInstallStep());
}

const WaylandProtocols = struct {
    include_path: std.Build.LazyPath,
    xdg_shell_c: std.Build.LazyPath,
    layer_shell_c: std.Build.LazyPath,
};

fn generateWaylandProtocols(b: *std.Build) WaylandProtocols {
    const xdg_shell_xml = b.path("protocols/xdg-shell.xml");
    const layer_shell_xml = b.path("protocols/wlr-layer-shell-unstable-v1.xml");

    // Generate client headers
    const xdg_shell_header = runScanner(b, "client-header", xdg_shell_xml, "xdg-shell-client-protocol.h");
    const layer_shell_header = runScanner(b, "client-header", layer_shell_xml, "wlr-layer-shell-unstable-v1-client-protocol.h");

    // Generate C source (private-code for static linking)
    const xdg_shell_c = runScanner(b, "private-code", xdg_shell_xml, "xdg-shell-protocol.c");
    const layer_shell_c = runScanner(b, "private-code", layer_shell_xml, "wlr-layer-shell-unstable-v1-protocol.c");

    // Create a write-files step to collect headers into a single include dir
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(xdg_shell_header, "xdg-shell-client-protocol.h");
    _ = wf.addCopyFile(layer_shell_header, "wlr-layer-shell-unstable-v1-client-protocol.h");

    return .{
        .include_path = wf.getDirectory(),
        .xdg_shell_c = xdg_shell_c,
        .layer_shell_c = layer_shell_c,
    };
}

fn runScanner(
    b: *std.Build,
    mode: []const u8,
    xml_input: std.Build.LazyPath,
    output_basename: []const u8,
) std.Build.LazyPath {
    const scanner = b.addSystemCommand(&.{"wayland-scanner"});
    scanner.addArg(mode);
    scanner.addFileArg(xml_input);
    return scanner.addOutputFileArg(output_basename);
}
