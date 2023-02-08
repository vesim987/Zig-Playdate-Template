const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.build.Builder) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    try createPlaydateExecutable(.{
        .builder = b,
        .name = "example",
        .root_source_file = .{ .path = "src/main.zig" },
        .optimize = optimize,
        .target = target,
    });
}

pub const PlaydateExecutableOptions = struct {
    builder: *std.Build.Builder,
    name: []const u8,
    root_source_file: std.Build.FileSource,
    optimize: std.builtin.OptimizeMode,
    target: std.zig.CrossTarget,
    playdate_sdk_path: ?[]const u8 = null,
};

pub const PlaydateExecutable = struct {};

pub fn createPlaydateExecutable(options: PlaydateExecutableOptions) !void {
    const b = options.builder;
    const pdx_file_name = b.fmt("{s}.pdx", .{options.name});

    b.addModule(.{
        .name = "pdapi",
        .source_file = .{ .path = "./src/playdate_api_definitions.zig" },
    });
    const pdapi = b.modules.get("pdapi").?;

    const lib = b.addSharedLibrary(.{
        .name = "pdex",
        .root_source_file = options.root_source_file,
        .optimize = options.optimize,
        .target = .{},
    });

    const output_path = try std.fs.path.join(b.allocator, &.{ b.install_path, "Source" });
    lib.setOutputDir(output_path);
    lib.addModule("pdapi", pdapi);
    lib.install();

    const playdate_target = try std.zig.CrossTarget.parse(.{
        .arch_os_abi = "thumb-freestanding-eabihf",
        .cpu_features = "cortex_m7-fp64-fp_armv8d16-fpregs64-vfp2-vfp3d16-vfp4d16",
    });
    const game_elf = b.addExecutable(.{
        .name = "pdex.elf",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = playdate_target,
        .optimize = options.optimize,
    });
    game_elf.step.dependOn(&lib.step);
    game_elf.link_function_sections = true;
    game_elf.stack_size = 61800;
    game_elf.setLinkerScriptPath(.{ .path = "link_map.ld" });
    game_elf.setOutputDir(b.install_path);
    if (options.optimize == .ReleaseFast) {
        game_elf.omit_frame_pointer = true;
    }
    game_elf.addModule("pdapi", pdapi);
    game_elf.install();

    const playdate_sdk_path = blk: {
        if (options.playdate_sdk_path) |path| break :blk path;
        break :blk try std.process.getEnvVarOwned(b.allocator, "PLAYDATE_SDK_PATH");
    };

    const copy_assets = CopyStep.create(b, .{ .path = "assets/playdate_image.png" }, .{ .path = "zig-out/Source/playdate_image.png" });
    copy_assets.step.dependOn(&game_elf.step);

    const emit_device_binary = b.addSystemCommand(&.{ b.zig_exe, "objcopy", "-O", "binary", "zig-out/pdex.elf", "zig-out/Source/pdex.bin" });
    emit_device_binary.step.dependOn(&copy_assets.step);

    switch (builtin.target.os.tag) {
        .windows => {},
        .macos => {
            const rename_dylib = b.addSystemCommand(&.{ "mv", "zig-out/Source/libpdex.dylib", "zig-out/Source/pdex.dylib" });
            rename_dylib.step.dependOn(&game_elf.step);
        },
        .linux => {
            var rename_so = CopyStep.create(b, .{ .path = "zig-out/Source/libpdex.so" }, .{ .path = "zig-out/Source/pdex.so" });
            rename_so.step.dependOn(&game_elf.step);
        },
        else => {
            @panic("Unsupported OS!");
        },
    }
    const executable_suffix = if (builtin.target.os.tag == .windows) ".exe" else "";

    const pdx_full_path = b.fmt("zig-out/{s}", .{pdx_file_name});
    const pdc_path = b.fmt("{s}/bin/pdc{s}", .{ playdate_sdk_path, executable_suffix });
    const pdc = b.addSystemCommand(&.{ pdc_path, "--skip-unknown", "zig-out/Source", pdx_full_path });
    pdc.step.dependOn(&emit_device_binary.step);
    b.getInstallStep().dependOn(&pdc.step);

    const pd_simulator_path = b.fmt("{s}/bin/PlaydateSimulator{s}", .{ playdate_sdk_path, executable_suffix });
    const run_cmd = b.addSystemCommand(&.{ pd_simulator_path, pdx_full_path });
    run_cmd.step.dependOn(&pdc.step);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

const CopyStep = struct {
    const Step = std.Build.Step;

    pub const base_id = .install_file;

    step: Step,
    builder: *std.Build,
    source: std.Build.FileSource,
    destination: std.Build.FileSource,

    pub fn create(
        builder: *std.Build,
        source: std.Build.FileSource,
        destination: std.Build.FileSource,
    ) *CopyStep {
        const self = builder.allocator.create(CopyStep) catch @panic("OOM");
        self.* = CopyStep{
            .builder = builder,
            .step = Step.init(.install_file, builder.fmt("copying {s} to {s}", .{ source.getDisplayName(), destination.getDisplayName() }), builder.allocator, make),
            .source = source,
            .destination = destination,
        };
        return self;
    }

    fn make(step: *Step) !void {
        const self = @fieldParentPtr(CopyStep, "step", step);
        const full_src_path = self.source.getPath(self.builder);
        const full_dest_path = self.destination.getPath(self.builder);
        try self.builder.updateFile(full_src_path, full_dest_path);
    }
};
