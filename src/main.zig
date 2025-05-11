const std = @import("std");

const version = "0.1.0";

const Config = struct {
    pid: ?u32 = null,
    command: ?[]const []const u8 = null,
    output_file: ?[]const u8 = null,
    interval_ms: u32 = 100,
};

var should_exit = false;

fn sigintHandler(_: c_int) callconv(.C) void {
    should_exit = true;
    std.debug.print("\n收到中断信号，正在退出...\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var config = Config{};
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "-V") or std.mem.eql(u8, arg, "--version")) {
            try printVersion();
            return;
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: 缺少输出文件路径\n", .{});
                return error.MissingArgument;
            }
            config.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--interval")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: 缺少间隔时间值\n", .{});
                return error.MissingArgument;
            }
            config.interval_ms = try std.fmt.parseInt(u32, args[i], 10);
            if (config.interval_ms < 1) {
                std.debug.print("错误: 间隔时间不能小于1ms\n", .{});
                return error.InvalidArgument;
            }
        } else if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("错误: 缺少命令\n", .{});
                return error.MissingArgument;
            }
            config.command = args[i..];
            break;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.print("错误: 未知选项 '{s}'\n", .{arg});
            return error.UnknownOption;
        } else {
            // 尝试解析为PID
            config.pid = try std.fmt.parseInt(u32, arg, 10);
        }
    }

    // 验证参数
    if (config.pid == null and config.command == null) {
        std.debug.print("错误: 必须指定PID或命令\n", .{});
        try printHelp();
        return error.MissingArgument;
    }

    try runMonitor(allocator, config);
}

fn printHelp() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\uzage - 进程资源使用监控工具
        \\
        \\用法:
        \\  uzage [选项] <pid>
        \\  uzage [选项] -- <command> [args...]
        \\
        \\选项:
        \\  -h, --help            显示帮助信息
        \\  -V, --version         显示版本信息
        \\  -o, --output <file>   将结果输出到文件
        \\  -t, --interval <ms>   设置采样间隔(毫秒), 默认100ms
        \\
        \\示例:
        \\  uzage 1234            监控PID为1234的进程
        \\  uzage -- python script.py  启动并监控Python脚本
        \\
    , .{});
}

fn printVersion() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("uzage v{s}\n", .{version});
}

fn runMonitor(allocator: std.mem.Allocator, config: Config) !void {
    var pid: u32 = undefined;
    var child_process: ?std.process.Child = null;

    // 如果提供了命令，启动子进程
    if (config.command) |cmd| {
        std.debug.print("启动命令: {s}\n", .{cmd[0]});

        child_process = std.process.Child.init(cmd, allocator);
        child_process.?.spawn() catch {
            std.debug.print("错误: 无法启动进程 '{s}'\n", .{cmd[0]});
            return error.ProcessSpawnFailed;
        };

        pid = @intCast(child_process.?.id);
        std.debug.print("进程已启动，PID: {d}\n", .{pid});
    } else {
        pid = config.pid.?;
    }

    // 打开输出文件（如果指定）
    var output_file: ?std.fs.File = null;
    defer if (output_file) |*f| f.close();

    if (config.output_file) |path| {
        output_file = try std.fs.cwd().createFile(path, .{});
    }

    // 开始监控循环
    try monitorProcess(allocator, pid, config.interval_ms, output_file);

    // 如果我们启动了子进程，等待它结束
    if (child_process) |*child| {
        const term = try child.wait();
        switch (term) {
            .Exited => |code| std.debug.print("进程已退出，退出码: {d}\n", .{code}),
            else => std.debug.print("进程异常终止\n", .{}),
        }
    }
}

const ProcessStats = struct {
    utime: u64,
    stime: u64,
    timestamp_ms: u64,
};

const ProcessUsage = struct {
    timestamp_ms: u64,
    cpu_percent: f32,
    memory_bytes: u64,
};

fn monitorProcess(allocator: std.mem.Allocator, pid: u32, interval_ms: u32, output_file: ?std.fs.File) !void {
    _ = allocator;

    // 设置信号处理
    const posix = std.posix;
    const sigaction = posix.Sigaction{
        .handler = .{ .handler = sigintHandler },
        .mask = posix.empty_sigset,
        .flags = 0,
    };
    try posix.sigaction(posix.SIG.INT, &sigaction, null);

    std.debug.print("开始监控PID: {d}, 间隔: {d}ms\n", .{ pid, interval_ms });

    // 检查进程是否存在
    if (!try processExists(pid)) {
        std.debug.print("错误: 进程 {d} 不存在\n", .{pid});
        return error.ProcessNotFound;
    }

    // 获取初始状态
    var prev_stats = try getProcessStats(pid);

    // 监控循环
    var running = true;
    while (running and !should_exit) {
        // 等待采样间隔
        std.time.sleep(interval_ms * std.time.ns_per_ms);

        // 检查进程是否仍在运行
        running = try processExists(pid);
        if (!running) break;

        // 获取当前状态
        const current_stats = try getProcessStats(pid);

        // 计算CPU和内存使用情况
        const usage = try calculateUsage(pid, prev_stats, current_stats);

        // 更新前一个状态
        prev_stats = current_stats;

        // 输出结果
        if (output_file) |file| {
            try writeUsageToFile(file.writer(), usage);
        } else {
            try printUsage(usage);
        }
    }

    if (should_exit) {
        std.debug.print("监控已停止\n", .{});
    } else {
        std.debug.print("进程 {d} 已终止，停止监控\n", .{pid});
    }
}

fn processExists(pid: u32) !bool {
    // 在Linux上，检查/proc/[pid]目录是否存在
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/proc/{d}", .{pid});

    std.fs.cwd().access(path, .{}) catch |err| {
        if (err == error.FileNotFound) return false;
        return err;
    };

    return true;
}

fn getProcessStats(pid: u32) !ProcessStats {
    var path_buf: [128]u8 = undefined;

    // 读取/proc/[pid]/stat获取CPU使用情况
    const stat_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/stat", .{pid});
    const stat_file = try std.fs.cwd().openFile(stat_path, .{});
    defer stat_file.close();

    var stat_buf: [1024]u8 = undefined;
    const stat_len = try stat_file.readAll(&stat_buf);
    const stat_content = stat_buf[0..stat_len];

    // 找到comm字段的括号位置
    const comm_end = std.mem.lastIndexOf(u8, stat_content, ")") orelse return error.InvalidFormat;

    // 从comm之后开始解析
    var iter = std.mem.tokenizeAny(u8, stat_content[comm_end + 1 ..], " ");

    // 跳过state和ppid等字段到utime (第14个字段)
    var i: usize = 0;
    while (i < 11) : (i += 1) {
        _ = iter.next() orelse return error.InvalidFormat;
    }

    // 读取utime和stime
    const utime_str = iter.next() orelse return error.InvalidFormat;
    const stime_str = iter.next() orelse return error.InvalidFormat;

    const utime = try std.fmt.parseInt(u64, utime_str, 10);
    const stime = try std.fmt.parseInt(u64, stime_str, 10);

    return ProcessStats{
        .utime = utime,
        .stime = stime,
        .timestamp_ms = @intCast(std.time.milliTimestamp()),
    };
}

fn calculateUsage(pid: u32, prev: ProcessStats, current: ProcessStats) !ProcessUsage {
    // 计算CPU时间差
    const utime_diff = current.utime - prev.utime;
    const stime_diff = current.stime - prev.stime;
    const total_time_diff = utime_diff + stime_diff;

    // 计算实际时间差（毫秒）
    const time_diff_ms = current.timestamp_ms - prev.timestamp_ms;
    if (time_diff_ms == 0) return error.InvalidTimeDiff;

    // 计算CPU使用率
    const hertz: f32 = 100.0; // 通常Linux的USER_HZ是100
    const cpu_percent = ((@as(f32, @floatFromInt(total_time_diff)) * 1000.0) /
        (@as(f32, @floatFromInt(time_diff_ms)) * hertz)) * 100.0;

    // 获取内存使用情况
    var path_buf: [128]u8 = undefined;
    const statm_path = try std.fmt.bufPrint(&path_buf, "/proc/{d}/statm", .{pid});
    const statm_file = try std.fs.cwd().openFile(statm_path, .{});
    defer statm_file.close();

    var statm_buf: [128]u8 = undefined;
    const statm_len = try statm_file.readAll(&statm_buf);
    const statm_content = statm_buf[0..statm_len];

    var statm_iter = std.mem.tokenizeAny(u8, statm_content, " ");
    _ = statm_iter.next(); // 跳过total
    const resident_pages_str = statm_iter.next() orelse return error.InvalidFormat;

    const resident_pages = try std.fmt.parseInt(u64, resident_pages_str, 10);
    const page_size = std.mem.page_size;
    const memory_bytes = resident_pages * page_size;

    return ProcessUsage{
        .timestamp_ms = current.timestamp_ms,
        .cpu_percent = cpu_percent,
        .memory_bytes = memory_bytes,
    };
}

fn printUsage(usage: ProcessUsage) !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("时间: {d}ms, CPU: {d:.1}%, 内存: {d:.2}MB\n", .{ usage.timestamp_ms, usage.cpu_percent, @as(f32, @floatFromInt(usage.memory_bytes)) / (1024 * 1024) });
}

fn writeUsageToFile(writer: std.fs.File.Writer, usage: ProcessUsage) !void {
    // 手动构建JSON字符串，因为std.json.stringify在处理浮点数时可能有问题
    try writer.print("{{\"timestamp_ms\":{d},\"cpu_percent\":{d:.2},\"memory_bytes\":{d}}}\n", .{
        usage.timestamp_ms,
        usage.cpu_percent,
        usage.memory_bytes,
    });
}
