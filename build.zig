const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zp64c",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zp64c");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);

    const optimization_report_tests = b.addSystemCommand(&.{ "python3", "-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_optimization_report.py" });
    const optimization_report_test_step = b.step("optimization-report-test", "Test optimization measurement and comparison reports");
    optimization_report_test_step.dependOn(&optimization_report_tests.step);

    const e2e_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_small_demos.sh", "--skip-build" });
    e2e_cmd.step.dependOn(b.getInstallStep());
    const e2e_step = b.step("e2e", "Run end-to-end host tests");
    e2e_step.dependOn(&test_run.step);
    e2e_step.dependOn(&e2e_cmd.step);

    const asm_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_small_demos.sh", "--skip-build" });
    asm_cmd.step.dependOn(b.getInstallStep());
    const asm_step = b.step("asm-test", "Run assembler-backed tests");
    asm_step.dependOn(&test_run.step);
    asm_step.dependOn(&asm_cmd.step);

    const emu_runner = b.addExecutable(.{
        .name = "zeropage_emu_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emu_test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    emu_runner.root_module.addIncludePath(b.path("third_party/peddle"));
    emu_runner.root_module.addIncludePath(b.path("third_party/peddle/Peddle"));
    emu_runner.root_module.addCSourceFiles(.{
        .files = &.{
            "third_party/peddle/zeropage_peddle.cpp",
            "third_party/peddle/Peddle/Peddle.cpp",
            "third_party/peddle/Peddle/PeddleDebugger.cpp",
            "third_party/peddle/Peddle/PeddleDisassembler.cpp",
            "third_party/peddle/Peddle/StrWriter.cpp",
        },
        .flags = &.{
            "-std=c++20",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
        },
    });
    emu_runner.root_module.link_libcpp = true;

    const emu_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/emu_test_runner.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    emu_runner_tests.root_module.addIncludePath(b.path("third_party/peddle"));
    emu_runner_tests.root_module.addIncludePath(b.path("third_party/peddle/Peddle"));
    emu_runner_tests.root_module.addCSourceFiles(.{
        .files = &.{
            "third_party/peddle/zeropage_peddle.cpp",
            "third_party/peddle/Peddle/Peddle.cpp",
            "third_party/peddle/Peddle/PeddleDebugger.cpp",
            "third_party/peddle/Peddle/PeddleDisassembler.cpp",
            "third_party/peddle/Peddle/StrWriter.cpp",
        },
        .flags = &.{
            "-std=c++20",
            "-Wno-unused-parameter",
            "-Wno-unused-variable",
        },
    });
    emu_runner_tests.root_module.link_libcpp = true;
    const emu_runner_test_run = b.addRunArtifact(emu_runner_tests);
    test_step.dependOn(&emu_runner_test_run.step);

    const emu_run = b.addRunArtifact(emu_runner);
    emu_run.step.dependOn(b.getInstallStep());
    const emu_step = b.step("emu-test", "Run host 6502/6510 emulator tests");
    emu_step.dependOn(&test_run.step);
    emu_step.dependOn(&emu_run.step);

    const section_marker_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_section_markers.sh" });
    section_marker_cmd.step.dependOn(b.getInstallStep());
    const section_marker_step = b.step("section-marker-test", "Verify section ownership markers are emitted and byte-neutral");
    section_marker_step.dependOn(&test_run.step);
    section_marker_step.dependOn(&section_marker_cmd.step);

    const vice_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_vice_automation.sh" });
    vice_cmd.step.dependOn(b.getInstallStep());
    const vice_step = b.step("vice-test", "Run optional VICE integration tests");
    vice_step.dependOn(&test_run.step);
    vice_step.dependOn(&vice_cmd.step);

    const sampleapps_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_sampleapps.sh", "--skip-build" });
    sampleapps_cmd.step.dependOn(b.getInstallStep());

    const sheet_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_spreadsheet.sh" });
    sheet_cmd.step.dependOn(b.getInstallStep());
    const sheet_step = b.step("spreadsheet", "Build the standalone and available ReadyOS spreadsheet images");
    sheet_step.dependOn(&sheet_cmd.step);

    const sheet_vice_cmd = b.addSystemCommand(&.{ "bash", "scripts/verify_spreadsheet.sh", "--vice" });
    sheet_vice_cmd.step.dependOn(b.getInstallStep());
    const sheet_vice_step = b.step("spreadsheet-vice", "Run optional spreadsheet VICE integration plans");
    sheet_vice_step.dependOn(&sheet_vice_cmd.step);

    const size_cmd = b.addSystemCommand(&.{ "bash", "scripts/size_report.sh" });
    size_cmd.step.dependOn(&e2e_cmd.step);
    size_cmd.step.dependOn(&emu_run.step);
    size_cmd.step.dependOn(&sampleapps_cmd.step);
    const size_step = b.step("size-report", "Generate size report");
    size_step.dependOn(&test_run.step);
    size_step.dependOn(&size_cmd.step);
}
