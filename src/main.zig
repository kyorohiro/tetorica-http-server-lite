const std = @import("std");
const builtin = @import("builtin");

fn streamRead(stream: std.net.Stream, buf: []u8) !usize {
    if (builtin.os.tag == .windows) {
        const n = std.os.windows.ws2_32.recv(
            stream.handle,
            buf.ptr,
            @intCast(buf.len),
            0,
        );

        if (n == -1) {
            return error.SocketReadFailed;
        }

        return @intCast(n);
    } else {
        return try stream.read(buf);
    }
}

const Request = struct {
    method: []const u8,
    path: []const u8,
};

const ByteRange = struct {
    start: u64,
    end: u64,

    fn len(self: ByteRange) u64 {
        return self.end - self.start + 1;
    }
};

const BoundServer = struct {
    server: std.net.Server,
    port: u16,
};

pub fn main() !void {
    const bound = try listenOnAvailablePort("127.0.0.1", 8080, 32);
    var server = bound.server;
    defer server.deinit();

    std.debug.print("serving {s} at http://127.0.0.1:{d}/\n", .{ ".", bound.port });

    while (true) {
        const conn = try server.accept();
        handleConnection(conn) catch |err| {
            if (!isIgnorableConnectionError(err)) {
                std.debug.print("connection error: {}\n", .{err});
            }
        };
    }
}

fn listenOnAvailablePort(host: []const u8, start_port: u16, attempts: u16) !BoundServer {
    var port = start_port;
    var remaining = attempts;

    while (remaining > 0) : ({
        remaining -= 1;
        port +%= 1;
    }) {
        const address = try std.net.Address.parseIp4(host, port);
        const server = address.listen(.{
            .reuse_address = false,
        }) catch |err| switch (err) {
            error.AddressInUse => continue,
            else => return err,
        };

        return .{
            .server = server,
            .port = port,
        };
    }

    return error.AddressInUse;
}

fn isIgnorableConnectionError(err: anyerror) bool {
    return switch (err) {
        error.BrokenPipe,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.EndOfStream,
        error.NotOpenForReading,
        error.OperationAborted,
        => true,
        error.Unexpected => builtin.os.tag == .windows,
        else => false,
    };
}

fn handleConnection(conn: std.net.Server.Connection) !void {
    defer conn.stream.close();

    var req_buf: [4096]u8 = undefined;
    const n = try streamRead(conn.stream, &req_buf);
    // const n = try conn.stream.read(&req_buf);
    if (n == 0) return;

    const request = parseRequest(req_buf[0..n]) catch {
        try sendTextResponse(conn, "400 Bad Request", "bad request\n", false);
        return;
    };
    const range_header = findHeaderValue(req_buf[0..n], "Range");

    const is_head = std.mem.eql(u8, request.method, "HEAD");
    if (!is_head and !std.mem.eql(u8, request.method, "GET")) {
        try sendTextResponse(conn, "405 Method Not Allowed", "method not allowed\n", false);
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const normalized_path = normalizeRequestPath(allocator, request.path) catch {
        try sendTextResponse(conn, "400 Bad Request", "invalid path\n", is_head);
        return;
    };

    var cwd = std.fs.cwd();
    var file = cwd.openFile(normalized_path, .{}) catch |err| switch (err) {
        error.IsDir => {
            try serveDirectory(conn, cwd, allocator, normalized_path, request.path, is_head);
            return;
        },
        error.FileNotFound => {
            try sendTextResponse(conn, "404 Not Found", "not found\n", is_head);
            return;
        },
        else => return err,
    };
    defer file.close();

    const stat = try file.stat();
    if (stat.kind == .directory) {
        try serveDirectory(conn, cwd, allocator, normalized_path, request.path, is_head);
        return;
    }

    const range = if (range_header) |value|
        parseRangeHeader(value, stat.size) catch |err| switch (err) {
            error.InvalidRange => {
                try sendRangeNotSatisfiable(conn, stat.size, is_head);
                return;
            },
            else => return err,
        }
    else
        null;

    try serveFile(conn, file, normalized_path, stat.size, is_head, range);
}

fn parseRequest(raw: []const u8) !Request {
    const line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return error.BadRequest;
    var parts = std.mem.tokenizeScalar(u8, raw[0..line_end], ' ');

    const method = parts.next() orelse return error.BadRequest;
    const path = parts.next() orelse return error.BadRequest;
    _ = parts.next() orelse return error.BadRequest;

    return .{
        .method = method,
        .path = path,
    };
}

fn normalizeRequestPath(allocator: std.mem.Allocator, request_path: []const u8) ![]const u8 {
    var query_split = std.mem.splitScalar(u8, request_path, '?');
    const path_without_query = query_split.first();
    if (path_without_query.len == 0 or path_without_query[0] != '/') {
        return error.InvalidPath;
    }

    var parts = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, path_without_query[1..], '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) return error.InvalidPath;
        if (std.mem.indexOfScalar(u8, part, '\\') != null) return error.InvalidPath;
        try parts.append(allocator, part);
    }

    if (parts.items.len == 0) {
        return try allocator.dupe(u8, ".");
    }

    return try std.fs.path.join(allocator, parts.items);
}

fn findHeaderValue(raw: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const request_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return null;
    var lines = std.mem.splitSequence(u8, raw[request_line_end + 2 .. header_end], "\r\n");
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..colon], " \t");
        if (!std.ascii.eqlIgnoreCase(key, name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn parseRangeHeader(value: []const u8, size: u64) !?ByteRange {
    if (!std.mem.startsWith(u8, value, "bytes=")) return error.InvalidRange;

    const spec = std.mem.trim(u8, value["bytes=".len..], " \t");
    if (spec.len == 0 or std.mem.indexOfScalar(u8, spec, ',') != null) {
        return error.InvalidRange;
    }

    const dash_index = std.mem.indexOfScalar(u8, spec, '-') orelse return error.InvalidRange;
    const start_text = spec[0..dash_index];
    const end_text = spec[dash_index + 1 ..];

    if (size == 0) return error.InvalidRange;

    if (start_text.len == 0) {
        const suffix_len = std.fmt.parseUnsigned(u64, end_text, 10) catch return error.InvalidRange;
        if (suffix_len == 0) return error.InvalidRange;
        const clamped = @min(suffix_len, size);
        return .{
            .start = size - clamped,
            .end = size - 1,
        };
    }

    const start = std.fmt.parseUnsigned(u64, start_text, 10) catch return error.InvalidRange;
    if (start >= size) return error.InvalidRange;

    if (end_text.len == 0) {
        return .{
            .start = start,
            .end = size - 1,
        };
    }

    const raw_end = std.fmt.parseUnsigned(u64, end_text, 10) catch return error.InvalidRange;
    const end = @min(raw_end, size - 1);
    if (start > end) return error.InvalidRange;

    return .{
        .start = start,
        .end = end,
    };
}

fn serveDirectory(
    conn: std.net.Server.Connection,
    cwd: std.fs.Dir,
    allocator: std.mem.Allocator,
    normalized_path: []const u8,
    request_path: []const u8,
    is_head: bool,
) !void {
    const with_index = try std.fs.path.join(allocator, &.{ normalized_path, "index.html" });
    if (cwd.openFile(with_index, .{})) |index_file| {
        defer index_file.close();
        const stat = try index_file.stat();
        try serveFile(conn, index_file, with_index, stat.size, is_head, null);
        return;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }

    var dir = try cwd.openDir(normalized_path, .{ .iterate = true });
    defer dir.close();

    var list = try std.ArrayList(u8).initCapacity(allocator, 0);
    defer list.deinit(allocator);
    const writer = list.writer(allocator);

    try writer.print("<!doctype html><html><body><h1>Index of {s}</h1><ul>", .{request_path});

    if (!std.mem.eql(u8, request_path, "/")) {
        try writer.writeAll("<li><a href=\"../\">../</a></li>");
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const slash = if (entry.kind == .directory) "/" else "";
        try writer.print(
            "<li><a href=\"{s}{s}\">{s}{s}</a></li>",
            .{ entry.name, slash, entry.name, slash },
        );
    }

    try writer.writeAll("</ul></body></html>\n");

    try sendResponse(
        conn,
        "200 OK",
        "text/html; charset=utf-8",
        list.items,
        is_head,
    );
}

fn serveFile(
    conn: std.net.Server.Connection,
    file: std.fs.File,
    path: []const u8,
    size: u64,
    is_head: bool,
    range: ?ByteRange,
) !void {
    const effective_range = range orelse ByteRange{
        .start = 0,
        .end = if (size == 0) 0 else size - 1,
    };
    const is_partial = range != null;
    const content_length = if (is_partial) effective_range.len() else size;

    if (is_partial) {
        try sendHeader(
            conn,
            "206 Partial Content",
            contentType(path),
            content_length,
            size,
            effective_range,
        );
    } else {
        try sendHeader(conn, "200 OK", contentType(path), content_length, null, null);
    }

    if (is_head) return;

    if (is_partial) {
        try file.seekTo(effective_range.start);
    }

    var buf: [8192]u8 = undefined;
    var remaining = content_length;

    while (remaining > 0) {
        const to_read: usize = @intCast(@min(@as(u64, buf.len), remaining));
        const n = try file.read(buf[0..to_read]);
        if (n == 0) break;
        try conn.stream.writeAll(buf[0..n]);
        remaining -= n;
    }
}

fn sendTextResponse(
    conn: std.net.Server.Connection,
    status: []const u8,
    body: []const u8,
    is_head: bool,
) !void {
    try sendResponse(conn, status, "text/plain; charset=utf-8", body, is_head);
}

fn sendResponse(
    conn: std.net.Server.Connection,
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
    is_head: bool,
) !void {
    try sendHeader(conn, status, content_type, body.len, null, null);
    if (is_head) return;
    try conn.stream.writeAll(body);
}

fn sendHeader(
    conn: std.net.Server.Connection,
    status: []const u8,
    content_type: []const u8,
    content_length: u64,
    total_size: ?u64,
    range: ?ByteRange,
) !void {
    var header_buf: [512]u8 = undefined;
    const header = if (range) |r|
        try std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {}\r\n" ++
                "Accept-Ranges: bytes\r\n" ++
                "Content-Range: bytes {}-{}/{}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{ status, content_type, content_length, r.start, r.end, total_size.? },
        )
    else
        try std.fmt.bufPrint(
            &header_buf,
            "HTTP/1.1 {s}\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {}\r\n" ++
                "Accept-Ranges: bytes\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{ status, content_type, content_length },
        );
    try conn.stream.writeAll(header);
}

fn sendRangeNotSatisfiable(
    conn: std.net.Server.Connection,
    size: u64,
    is_head: bool,
) !void {
    const body = "range not satisfiable\n";
    var header_buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "HTTP/1.1 416 Range Not Satisfiable\r\n" ++
            "Content-Type: text/plain; charset=utf-8\r\n" ++
            "Content-Length: {}\r\n" ++
            "Accept-Ranges: bytes\r\n" ++
            "Content-Range: bytes */{}\r\n" ++
            "Connection: close\r\n" ++
            "\r\n",
        .{ body.len, size },
    );
    try conn.stream.writeAll(header);
    if (is_head) return;
    try conn.stream.writeAll(body);
}

fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html; charset=utf-8";
    if (std.mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript; charset=utf-8";
    if (std.mem.eql(u8, ext, ".json")) return "application/json; charset=utf-8";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}
