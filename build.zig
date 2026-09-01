const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 16) {
        @compileError(std.fmt.comptimePrint(
            "unsupported Zig version: expected 0.16.x, found {}",
            .{builtin.zig_version},
        ));
    }
}

pub fn build(b: *std.Build) void {
    b.reference_trace = 10;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filter = b.option([]const u8, "test-filter", "Run matching tests only");
    const test_filters: []const []const u8 = if (test_filter) |filter| &.{filter} else &.{};

    const core_module = b.addModule("book_read", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const executable = addExecutable(b, .{
        .core_module = core_module,
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(executable);

    const run_command = b.addRunArtifact(executable);
    run_command.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| run_command.addArgs(arguments);
    const run_step = b.step("run", "Run the PDF reader");
    run_step.dependOn(&run_command.step);

    const check_step = b.step("check", "Compile without installing");
    check_step.dependOn(&executable.step);

    const unit_tests = b.addTest(.{
        .root_module = core_module,
        .filters = test_filters,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_unit_step = b.step("test:unit", "Run platform-independent unit tests");
    test_unit_step.dependOn(&run_unit_tests.step);

    // The application tests run on the in-memory backend and therefore link
    // no native library; they only need the core module.
    const application_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/application_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "book_read", .module = core_module }},
        }),
        .filters = test_filters,
    });
    const run_application_tests = b.addRunArtifact(application_tests);
    const test_application_step = b.step(
        "test:application",
        "Run application, interface, and storage tests on the in-memory backend",
    );
    test_application_step.dependOn(&run_application_tests.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(test_unit_step);
    test_step.dependOn(test_application_step);

    const tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_style.zig"),
            .target = b.graph.host,
        }),
        .filters = test_filters,
    });
    const run_tool_tests = b.addRunArtifact(tool_tests);
    const test_tools_step = b.step("test:tools", "Run repository tooling tests");
    test_tools_step.dependOn(&run_tool_tests.step);
    test_step.dependOn(test_tools_step);

    const desktop_module = b.createModule(.{
        .root_source_file = b.path("src/desktop.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "book_read", .module = core_module }},
    });
    addNativeLibraries(b, desktop_module);
    const native_test_module = b.createModule(.{
        .root_source_file = b.path("tests/native_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "book_read", .module = core_module },
            .{ .name = "app", .module = desktop_module },
        },
    });
    native_test_module.addIncludePath(b.path("src"));
    native_test_module.linkSystemLibrary("sdl3", .{});
    const native_tests = b.addTest(.{
        .root_module = native_test_module,
        .filters = test_filters,
    });
    const run_native_tests = b.addRunArtifact(native_tests);
    run_native_tests.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    const test_native_step = b.step("test:native", "Run native bridge and platform tests");
    test_native_step.dependOn(&run_native_tests.step);
    test_step.dependOn(test_native_step);

    const format_command = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "build.zig",
        "src",
        "tests",
        "tools",
    });
    const format_step = b.step("fmt", "Format Zig source files");
    format_step.dependOn(&format_command.step);

    const format_check_command = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "fmt",
        "--check",
        "--ast-check",
        "build.zig",
        "src",
        "tests",
        "tools",
    });
    const format_check_step = b.step("fmt:check", "Check formatting and Zig syntax");
    format_check_step.dependOn(&format_check_command.step);

    const lint_step = b.step("lint", "Run formatting, syntax, and compiler checks");
    lint_step.dependOn(format_check_step);
    lint_step.dependOn(check_step);

    const style_checker = b.addExecutable(.{
        .name = "check-style",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_style.zig"),
            .target = b.graph.host,
        }),
    });
    const run_style_checker = b.addRunArtifact(style_checker);
    run_style_checker.addArg("build.zig");
    for (collectStyleFiles(b)) |style_file| run_style_checker.addArg(style_file);
    lint_step.dependOn(&run_style_checker.step);

    const reject_invalid_style = b.addRunArtifact(style_checker);
    reject_invalid_style.addArg("tests/fixtures/style-invalid.txt");
    reject_invalid_style.expectExitCode(1);
    test_tools_step.dependOn(&reject_invalid_style.step);

    const smoke_test = b.addRunArtifact(executable);
    smoke_test.addArgs(&.{ "--smoke-test", "tests/fixtures/smoke.pdf" });
    smoke_test.setEnvironmentVariable("SDL_VIDEODRIVER", "dummy");
    const integration_step = b.step("test:integration", "Render a PDF through the native stack");
    integration_step.dependOn(&smoke_test.step);

    const release_core_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const release_executable = addExecutable(b, .{
        .core_module = release_core_module,
        .target = target,
        .optimize = .ReleaseSafe,
    });
    const release_check_step = b.step("check:release", "Compile a ReleaseSafe executable");
    release_check_step.dependOn(&release_executable.step);

    const ci_step = b.step("ci", "Run every required continuous-integration check");
    ci_step.dependOn(lint_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(integration_step);
    ci_step.dependOn(release_check_step);
}

const ExecutableOptions = struct {
    core_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn addExecutable(b: *std.Build, options: ExecutableOptions) *std.Build.Step.Compile {
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .imports = &.{.{ .name = "book_read", .module = options.core_module }},
    });
    addNativeLibraries(b, root_module);

    return b.addExecutable(.{
        .name = "book-read",
        .root_module = root_module,
    });
}

fn addNativeLibraries(b: *std.Build, module: *std.Build.Module) void {
    module.addIncludePath(b.path("src"));
    module.addCSourceFile(.{
        .file = b.path("src/bridge.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
    });
    module.linkSystemLibrary("sdl3", .{});
    module.linkSystemLibrary("poppler-glib", .{});
    module.linkSystemLibrary("cairo", .{});
    module.linkSystemLibrary("gobject-2.0", .{});
    module.linkSystemLibrary("glib-2.0", .{});
    module.linkSystemLibrary("c", .{});
}

/// Every source file under the checked directories, so a new file can never
/// bypass the style checker by being forgotten in a list.
fn collectStyleFiles(b: *std.Build) []const []const u8 {
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "src", "tests", "tools" }) |root| {
        var dir = b.build_root.handle.openDir(b.graph.io, root, .{ .iterate = true }) catch |err| {
            std.debug.panic("could not open {s} for style checks: {s}", .{ root, @errorName(err) });
        };
        defer dir.close(b.graph.io);
        var walker = dir.walk(b.allocator) catch @panic("out of memory");
        defer walker.deinit();
        while (walker.next(b.graph.io) catch |err| {
            std.debug.panic("could not walk {s}: {s}", .{ root, @errorName(err) });
        }) |entry| {
            if (entry.kind != .file) continue;
            const extension = std.fs.path.extension(entry.basename);
            if (!std.mem.eql(u8, extension, ".zig") and !std.mem.eql(u8, extension, ".c") and
                !std.mem.eql(u8, extension, ".h")) continue;
            const path = b.fmt("{s}/{s}", .{ root, entry.path });
            files.append(b.allocator, path) catch @panic("out of memory");
        }
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    return files.items;
}
