const std = @import("std");
const Io = std.Io;
const mem = std.mem;
const ascii = std.ascii;

const DefaultExts = [_][]const u8{
    ".dll",
    ".uir",
    ".exe",
    ".ini",
};

const CompressOptions = struct {
    path: []const u8,
    exts: [][]const u8,
    include_dir: ?[]const u8,
    out: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    const cmd = args[1];
    if (isHelp(cmd)) {
        try printHelp(stdout);
        try stdout.flush();
        return;
    }

    if (mem.eql(u8, cmd, "bump") or mem.eql(u8, cmd, "update")) {
        if (args.len < 3) {
            fatal(stderr, "버전이 필요합니다. 예: cvitool bump 1.2.3.4", .{});
        }
        const version = args[2];
        if (!isValidVersion(version)) {
            fatal(stderr, "버전 형식이 올바르지 않습니다. 예: 1.2.3.4", .{});
        }

        const prj_path = findSinglePrj(io, arena) catch |err| switch (err) {
            error.PrjNotFound => fatal(stderr, "현재 폴더 아래에서 .prj 파일을 찾지 못했습니다.", .{}),
            error.MultiplePrj => fatal(stderr, "여러 개의 .prj 파일이 발견되었습니다. 하나만 남겨 주세요.", .{}),
            else => return err,
        };

        const replaced = try updatePrjVersion(io, arena, prj_path, version);
        if (replaced == 0) {
            fatal(stderr, "버전 항목을 찾지 못했습니다: {s}", .{prj_path});
        }

        try stdout.print("업데이트 완료: {s} ({d}개 항목 변경)\n", .{ prj_path, replaced });
        try stdout.flush();
        return;
    }

    if (mem.eql(u8, cmd, "build")) {
        const prj_path = findSinglePrj(io, arena) catch |err| switch (err) {
            error.PrjNotFound => fatal(stderr, "현재 폴더 아래에서 .prj 파일을 찾지 못했습니다.", .{}),
            error.MultiplePrj => fatal(stderr, "여러 개의 .prj 파일이 발견되었습니다. 하나만 남겨 주세요.", .{}),
            else => return err,
        };
        try runCompile(io, stderr, prj_path);
        return;
    }

    if (mem.eql(u8, cmd, "compress")) {
        const options = parseCompressArgs(arena, args[2..]) catch |err| switch (err) {
            error.InvalidArgs => fatal(stderr, "compress 옵션이 올바르지 않습니다. cvitool help를 확인하세요.", .{}),
            else => return err,
        };
        const zip_path = try runCompress(io, arena, stderr, options);
        try stdout.print("압축 완료: {s}\n", .{zip_path});
        try stdout.flush();
        return;
    }

    if (mem.eql(u8, cmd, "upload")) {
        if (args.len < 4) {
            fatal(stderr, "사용법: cvitool upload target.zip targeturl", .{});
        }
        const zip_path = args[2];
        const target_url = args[3];
        try runUpload(io, arena, init.environ_map, stderr, zip_path, target_url);
        try stdout.print("업로드 완료: {s}\n", .{zip_path});
        try stdout.flush();
        return;
    }

    fatal(stderr, "알 수 없는 명령입니다: {s}", .{cmd});
}

fn printHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\cvitool - LabWindows/CVI 프로젝트용 CLI
        \\
        \\사용법:
        \\  cvitool bump 1.2.3.4
        \\  cvitool update 1.2.3.4
        \\  cvitool build
        \\  cvitool compress [path] [--ext <list>] [--folder <dir>] [--out <file.zip>]
        \\  cvitool upload target.zip targeturl
        \\  cvitool help
        \\
        \\compress 기본값:
        \\  path: src
        \\  ext:  *.dll *.uir *.exe *.ini
        \\  folder: 없음 (루트 폴더를 포함하지 않음)
        \\  out: <시간>_<폴더이름>.zip
        \\
        \\예시:
        \\  cvitool compress
        \\  cvitool compress dist --ext dll,exe --out release.zip
        \\  cvitool compress src --folder bin
        \\
        \\.env 참고:
        \\  CURL_ARGS 또는 CVITOOL_CURL_ARGS 값을 curl 추가 옵션으로 사용
        \\
    );
}

fn isHelp(arg: []const u8) bool {
    return mem.eql(u8, arg, "help") or mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help");
}

fn isValidVersion(version: []const u8) bool {
    var it = mem.splitScalar(u8, version, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |c| {
            if (!ascii.isDigit(c)) return false;
        }
        count += 1;
    }
    return count == 4;
}

fn findSinglePrj(io: Io, allocator: std.mem.Allocator) ![]const u8 {
    var dir = try Io.Dir.cwd().openDir(io, ".", .{ .iterate = true });
    defer dir.close(io);

    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    var found: ?[]const u8 = null;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!mem.endsWith(u8, entry.path, ".prj")) continue;

        const path_copy = try allocator.dupe(u8, entry.path);
        if (found != null) return error.MultiplePrj;
        found = path_copy;
    }
    return found orelse error.PrjNotFound;
}

fn updatePrjVersion(io: Io, allocator: std.mem.Allocator, prj_path: []const u8, version: []const u8) !usize {
    const file = try Io.Dir.cwd().openFile(io, prj_path, .{});
    defer file.close(io);

    var read_buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(allocator, .unlimited);

    const newline: []const u8 = if (mem.indexOf(u8, content, "\r\n") != null) "\r\n" else "\n";

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var lines = mem.splitScalar(u8, content, '\n');
    var first = true;
    var replaced: usize = 0;

    while (lines.next()) |raw_line| {
        if (!first) try out.appendSlice(allocator, newline);
        first = false;

        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        const trimmed = mem.trimStart(u8, line, " \t");
        const prefix_len = line.len - trimmed.len;

        if (mem.startsWith(u8, trimmed, "Numeric File Version = \"")) {
            replaced += 1;
            try out.appendSlice(allocator, line[0..prefix_len]);
            try out.appendSlice(allocator, "Numeric File Version = \"");
            try out.appendSlice(allocator, version);
            try out.appendSlice(allocator, "\"");
            continue;
        }

        if (mem.startsWith(u8, trimmed, "Numeric Prod Version = \"")) {
            replaced += 1;
            try out.appendSlice(allocator, line[0..prefix_len]);
            try out.appendSlice(allocator, "Numeric Prod Version = \"");
            try out.appendSlice(allocator, version);
            try out.appendSlice(allocator, "\"");
            continue;
        }

        try out.appendSlice(allocator, line);
    }

    if (replaced == 0) return 0;

    const out_file = try Io.Dir.cwd().createFile(io, prj_path, .{ .truncate = true });
    defer out_file.close(io);

    var write_buffer: [4096]u8 = undefined;
    var writer = out_file.writer(io, &write_buffer);
    try writer.interface.writeAll(out.items);
    try writer.flush();

    return replaced;
}

fn runCompile(io: Io, stderr: *Io.Writer, prj_path: []const u8) !void {
    var args = [_][]const u8{ "compile", prj_path };
    var child = std.process.spawn(io, .{
        .argv = &args,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            fatal(stderr, "compile 명령을 찾을 수 없습니다. PATH에 등록되어 있는지 확인하세요.", .{});
        },
        else => return err,
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            fatal(stderr, "compile 실행 실패 (exit code {d})", .{code});
        },
        else => fatal(stderr, "compile 실행 실패", .{}),
    }
}

fn parseCompressArgs(allocator: std.mem.Allocator, args: []const []const u8) !CompressOptions {
    var path_value: []const u8 = "src";
    var include_dir: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    var exts_list: std.ArrayList([]const u8) = .empty;
    try exts_list.ensureUnusedCapacity(allocator, DefaultExts.len);
    for (DefaultExts) |ext| {
        try exts_list.append(allocator, ext);
    }

    var path_set = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--path") or mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            path_value = args[i];
            path_set = true;
            continue;
        }
        if (mem.eql(u8, arg, "--ext") or mem.eql(u8, arg, "-e")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            exts_list.clearRetainingCapacity();
            try parseExtList(allocator, args[i], &exts_list);
            if (exts_list.items.len == 0) return error.InvalidArgs;
            continue;
        }
        if (mem.eql(u8, arg, "--folder") or mem.eql(u8, arg, "--include-dir") or mem.eql(u8, arg, "-d")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            include_dir = args[i];
            continue;
        }
        if (mem.eql(u8, arg, "--out") or mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.InvalidArgs;
            out_path = args[i];
            continue;
        }
        if (mem.startsWith(u8, arg, "-")) return error.InvalidArgs;

        if (!path_set) {
            path_value = arg;
            path_set = true;
            continue;
        }
        return error.InvalidArgs;
    }

    return .{
        .path = path_value,
        .exts = exts_list.items,
        .include_dir = include_dir,
        .out = out_path,
    };
}

fn parseExtList(allocator: std.mem.Allocator, raw: []const u8, list: *std.ArrayList([]const u8)) !void {
    var it = mem.tokenizeAny(u8, raw, ",; \t");
    while (it.next()) |token| {
        var ext = token;
        if (mem.startsWith(u8, ext, "*.")) ext = ext[1..];
        if (ext.len == 0) continue;
        if (ext[0] != '.') {
            const owned = try std.fmt.allocPrint(allocator, ".{s}", .{ext});
            try list.append(allocator, owned);
        } else {
            try list.append(allocator, ext);
        }
    }
}

fn runCompress(io: Io, allocator: std.mem.Allocator, stderr: *Io.Writer, options: CompressOptions) ![]const u8 {
    const search_root = try resolveSearchRoot(allocator, options.path, options.include_dir);
    const include_prefix = if (options.include_dir != null) Io.Dir.path.basename(search_root) else null;
    const base_dir = if (include_prefix != null) (Io.Dir.path.dirname(search_root) orelse ".") else search_root;

    const files = collectFiles(io, allocator, search_root, include_prefix, options.exts) catch |err| switch (err) {
        error.FileNotFound => fatal(stderr, "경로를 찾지 못했습니다: {s}", .{search_root}),
        error.NotDir => fatal(stderr, "폴더가 아닙니다: {s}", .{search_root}),
        else => return err,
    };
    if (files.len == 0) {
        fatal(stderr, "압축할 파일을 찾지 못했습니다.", .{});
    }

    const out_path = options.out orelse try defaultZipName(allocator, io, search_root);
    const out_path_abs = try toAbsolutePath(allocator, out_path);

    const tar_ok = runTarZip(io, allocator, out_path_abs, base_dir, files) catch |err| switch (err) {
        error.CommandFailed => fatal(stderr, "tar 압축 실행에 실패했습니다.", .{}),
        else => return err,
    };
    if (tar_ok) {
        return out_path;
    }

    runPowerShellZip(io, allocator, out_path_abs, base_dir, files) catch |err| switch (err) {
        error.CommandFailed => fatal(stderr, "Compress-Archive 실행에 실패했습니다.", .{}),
        else => return err,
    };
    return out_path;
}

fn resolveSearchRoot(allocator: std.mem.Allocator, base_path: []const u8, include_dir: ?[]const u8) ![]const u8 {
    if (include_dir) |dir| {
        if (Io.Dir.path.isAbsolute(dir)) return dir;
        return try Io.Dir.path.join(allocator, &.{ base_path, dir });
    }
    return base_path;
}

fn collectFiles(
    io: Io,
    allocator: std.mem.Allocator,
    search_root: []const u8,
    include_prefix: ?[]const u8,
    exts: [][]const u8,
) ![][]const u8 {
    var dir = if (Io.Dir.path.isAbsolute(search_root))
        try Io.Dir.openDirAbsolute(io, search_root, .{ .iterate = true })
    else
        try Io.Dir.cwd().openDir(io, search_root, .{ .iterate = true });
    defer dir.close(io);

    var walker = try Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    var list: std.ArrayList([]const u8) = .empty;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!extMatches(entry.path, exts)) continue;

        if (include_prefix) |prefix| {
            const rel = try Io.Dir.path.join(allocator, &.{ prefix, entry.path });
            try list.append(allocator, rel);
        } else {
            try list.append(allocator, try allocator.dupe(u8, entry.path));
        }
    }

    return list.items;
}

fn extMatches(path_value: []const u8, exts: [][]const u8) bool {
    const ext = Io.Dir.path.extension(path_value);
    if (ext.len == 0) return false;
    for (exts) |want| {
        if (ascii.eqlIgnoreCase(ext, want)) return true;
    }
    return false;
}

fn defaultZipName(allocator: std.mem.Allocator, io: Io, search_root: []const u8) ![]const u8 {
    const folder = Io.Dir.path.basename(search_root);
    const safe_folder = if (folder.len == 0 or mem.eql(u8, folder, ".")) "archive" else folder;
    const stamp = try formatUtcTimestamp(allocator, io);
    return try std.fmt.allocPrint(allocator, "{s}_{s}.zip", .{ stamp, safe_folder });
}

fn toAbsolutePath(allocator: std.mem.Allocator, path_value: []const u8) ![]const u8 {
    if (Io.Dir.path.isAbsolute(path_value)) return path_value;
    const cwd = try std.process.getCwdAlloc(allocator);
    return try Io.Dir.path.join(allocator, &.{ cwd, path_value });
}

fn formatUtcTimestamp(allocator: std.mem.Allocator, io: Io) ![]const u8 {
    const now = try Io.Clock.Timestamp.now(io, .real);
    const secs = @as(u64, @intCast(now.raw.toSeconds()));
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = epoch.getDaySeconds();
    return try std.fmt.allocPrint(allocator, "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        day.year,
        @intFromEnum(md.month),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

fn runTarZip(
    io: Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    base_dir: []const u8,
    files: [][]const u8,
) !bool {
    var args: std.ArrayList([]const u8) = .empty;
    try args.append(allocator, "tar");
    try args.append(allocator, "-a");
    try args.append(allocator, "-c");
    try args.append(allocator, "-f");
    try args.append(allocator, out_path);
    try args.append(allocator, "-C");
    try args.append(allocator, base_dir);
    for (files) |file| {
        try args.append(allocator, file);
    }

    var child = std.process.spawn(io, .{
        .argv = args.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
    return true;
}

fn runPowerShellZip(
    io: Io,
    allocator: std.mem.Allocator,
    out_path: []const u8,
    base_dir: []const u8,
    files: [][]const u8,
) !void {
    const escaped_out = try escapePsSingleQuoted(allocator, out_path);

    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(allocator, "$ErrorActionPreference='Stop'; Compress-Archive -Path @(");
    for (files, 0..) |file, idx| {
        if (idx != 0) try cmd.appendSlice(allocator, ",");
        const escaped = try escapePsSingleQuoted(allocator, file);
        try cmd.appendSlice(allocator, "'");
        try cmd.appendSlice(allocator, escaped);
        try cmd.appendSlice(allocator, "'");
    }
    try cmd.appendSlice(allocator, ") -DestinationPath '");
    try cmd.appendSlice(allocator, escaped_out);
    try cmd.appendSlice(allocator, "' -Force");

    const args = [_][]const u8{ "powershell", "-NoProfile", "-Command", cmd.items };
    var child = std.process.spawn(io, .{
        .argv = &args,
        .cwd = base_dir,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            const args_pwsh = [_][]const u8{ "pwsh", "-NoProfile", "-Command", cmd.items };
            var child_pwsh = try std.process.spawn(io, .{
                .argv = &args_pwsh,
                .cwd = base_dir,
                .stdin = .ignore,
                .stdout = .inherit,
                .stderr = .inherit,
                .create_no_window = true,
            });
            const term_pwsh = try child_pwsh.wait(io);
            switch (term_pwsh) {
                .exited => |code| if (code != 0) return error.CommandFailed,
                else => return error.CommandFailed,
            }
            return;
        },
        else => return err,
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) return error.CommandFailed,
        else => return error.CommandFailed,
    }
}

fn escapePsSingleQuoted(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (input) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "''");
        } else {
            try out.append(allocator, c);
        }
    }
    return out.items;
}

fn runUpload(
    io: Io,
    allocator: std.mem.Allocator,
    base_env: *const std.process.Environ.Map,
    stderr: *Io.Writer,
    zip_path: []const u8,
    target_url: []const u8,
) !void {
    {
        const file = Io.Dir.cwd().openFile(io, zip_path, .{}) catch |err| switch (err) {
            error.FileNotFound => fatal(stderr, "파일을 찾지 못했습니다: {s}", .{zip_path}),
            else => return err,
        };
        file.close(io);
    }

    var env_map = try base_env.clone(allocator);
    defer env_map.deinit();
    try applyDotEnv(io, allocator, &env_map);

    var curl_args: std.ArrayList([]const u8) = .empty;
    try curl_args.append(allocator, "curl");

    if (env_map.get("CVITOOL_CURL_ARGS") orelse env_map.get("CURL_ARGS")) |extra| {
        try appendTokenizedArgs(allocator, extra, &curl_args);
    }

    try curl_args.appendSlice(allocator, &.{ "-f", "-S", "-s", "-T", zip_path, target_url });

    var child = std.process.spawn(io, .{
        .argv = curl_args.items,
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
        .environ_map = &env_map,
        .create_no_window = true,
    }) catch |err| switch (err) {
        error.FileNotFound => fatal(stderr, "curl 명령을 찾을 수 없습니다.", .{}),
        else => return err,
    };

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            fatal(stderr, "curl 업로드 실패 (exit code {d})", .{code});
        },
        else => fatal(stderr, "curl 업로드 실패", .{}),
    }
}

fn applyDotEnv(io: Io, allocator: std.mem.Allocator, env_map: *std.process.Environ.Map) !void {
    const file = Io.Dir.cwd().openFile(io, ".env", .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(io);

    var read_buffer: [2048]u8 = undefined;
    var reader = file.reader(io, &read_buffer);
    const content = try reader.interface.allocRemaining(allocator, .unlimited);

    var lines = mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        line = mem.trim(u8, line, " \t");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;

        const eq = mem.indexOfScalar(u8, line, '=') orelse continue;
        var key = mem.trim(u8, line[0..eq], " \t");
        var value = mem.trim(u8, line[eq + 1 ..], " \t");
        if (key.len == 0) continue;

        if (value.len >= 2) {
            const q = value[0];
            if ((q == '\'' or q == '"') and value[value.len - 1] == q) {
                value = value[1 .. value.len - 1];
            }
        }

        try env_map.put(key, value);
    }
}

fn appendTokenizedArgs(allocator: std.mem.Allocator, raw: []const u8, list: *std.ArrayList([]const u8)) !void {
    var it = mem.tokenizeAny(u8, raw, " \t");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        try list.append(allocator, token);
    }
}

fn fatal(writer: *Io.Writer, comptime fmt: []const u8, args: anytype) noreturn {
    writer.print(fmt ++ "\n", args) catch {};
    writer.flush() catch {};
    std.process.exit(1);
}
