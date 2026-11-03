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

    // Force LLVM backend + LLD even in Debug. The self-hosted x86_64
    // linker can't handle the 64-bit PC-relative relocations in the
    // `.sframe` section of `crt1.o` from gcc 15+ (R_X86_64_PC64). Still true
    // of the official Zig 0.16.0 build (CI, Oct 2026), even though Arch's
    // packaged 0.16.0 happens to link it. Routing every optimize mode
    // through LLVM matches the working ReleaseSafe path.
    const llvm_backend = true;

    // --- C headers ---
    // Zig 0.17 removed @cImport: the build translates src/c.h once and every
    // file imports the result as "c".
    const c_tc = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c_tc.addIncludePath(wl_protocols.include_path);
    const c_mod = c_tc.createModule();

    // --- main executable ---
    const exe = b.addExecutable(.{
        .name = "hyprglaze",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_dep.module("toml") },
                .{ .name = "c", .module = c_mod },
            },
        }),
        .use_llvm = llvm_backend,
        .use_lld = llvm_backend,
    });

    // Generated protocol headers
    exe.root_module.addIncludePath(wl_protocols.include_path);
    // Generated protocol C sources
    for (wl_protocols.sources) |src| {
        exe.root_module.addCSourceFile(.{ .file = src });
    }

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
    exe.root_module.linkSystemLibrary("pulse-simple", .{});
    exe.root_module.linkSystemLibrary("pulse", .{});
    exe.root_module.link_libc = true;

    b.installArtifact(exe);

    // Runtime data, laid out as the daemon looks for it: shaders and sprites
    // under share/hyprglaze (its fallback after the CWD), and the systemd
    // user units. `zig build --prefix /usr` is then the whole install.
    b.installDirectory(.{
        .source_dir = b.path("shaders"),
        .install_dir = .prefix,
        .install_subdir = "share/hyprglaze/shaders",
        .include_extensions = &.{".frag"},
    });
    b.installFile("sprites/buddy.png", "share/hyprglaze/sprites/buddy.png");
    b.installFile("contrib/hyprglaze.service", "lib/systemd/user/hyprglaze.service");
    b.installFile("contrib/hyprglaze@.service", "lib/systemd/user/hyprglaze@.service");

    // --- run step ---
    const run_step = b.step("run", "Run hyprglaze");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // 0.17: the build graph no longer exposes b.args; the run step
    // forwards whatever follows `zig build run --` itself.
    run_cmd.addPassthruArgs();

    // --- ipc test utility ---
    const ipc_test = b.addExecutable(.{
        .name = "hypr-ipc-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ipc_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .use_llvm = llvm_backend,
        .use_lld = llvm_backend,
    });
    ipc_test.root_module.link_libc = true;
    // A debugging aid: run by its step, never installed (or packaged).

    const ipc_run_step = b.step("ipc-test", "Run Hyprland IPC test utility");
    const ipc_run_cmd = b.addRunArtifact(ipc_test);
    ipc_run_step.dependOn(&ipc_run_cmd.step);

    // --- unit tests ---
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "toml", .module = toml_dep.module("toml") },
                .{ .name = "c", .module = c_mod },
            },
        }),
        .use_llvm = llvm_backend,
        .use_lld = llvm_backend,
    });
    // watcher.zig calls libc (inotify, getenv) via std.c.
    tests.root_module.link_libc = true;
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

const WaylandProtocols = struct {
    include_path: std.Build.LazyPath,
    /// Generated protocol implementations, added to the module as C sources.
    sources: []const std.Build.LazyPath,
};

fn generateWaylandProtocols(b: *std.Build) WaylandProtocols {
    // basename -> the header/source names wayland-scanner conventionally
    // produces for it. Adding a protocol is one entry.
    const protocols = [_]struct { xml: []const u8, header: []const u8, source: []const u8 }{
        .{
            .xml = "protocols/xdg-shell.xml",
            .header = "xdg-shell-client-protocol.h",
            .source = "xdg-shell-protocol.c",
        },
        .{
            .xml = "protocols/wlr-layer-shell-unstable-v1.xml",
            .header = "wlr-layer-shell-unstable-v1-client-protocol.h",
            .source = "wlr-layer-shell-unstable-v1-protocol.c",
        },
        // Needed together: fractional-scale reports the compositor's preferred
        // scale, viewporter is how the resulting buffer is mapped back onto
        // the surface's logical size.
        .{
            .xml = "protocols/viewporter.xml",
            .header = "viewporter-client-protocol.h",
            .source = "viewporter-protocol.c",
        },
        .{
            .xml = "protocols/fractional-scale-v1.xml",
            .header = "fractional-scale-v1-client-protocol.h",
            .source = "fractional-scale-v1-protocol.c",
        },
    };

    const wf = b.addWriteFiles();
    var sources = b.allocator.alloc(std.Build.LazyPath, protocols.len) catch @panic("OOM");

    for (protocols, 0..) |p, i| {
        const xml = b.path(p.xml);
        _ = wf.addCopyFile(runScanner(b, "client-header", xml, p.header), p.header);
        sources[i] = runScanner(b, "private-code", xml, p.source);
    }

    return .{
        .include_path = wf.getDirectory(),
        .sources = sources,
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
