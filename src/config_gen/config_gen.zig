const std = @import("std");

const ConfigOption = struct {
    /// Name of config option
    name: []const u8,
    /// (used in doc comments & schema.json)
    description: []const u8,
    /// zig type in string form. e.g "u32", "[]const u8", "?usize"
    type: []const u8,
    /// used in Config.zig as the default initializer
    default: []const u8,
    /// If set, this option can be configured through `zls --config`
    /// currently unused but could laer be used to automatically generate queries for setup.zig
    setup_question: ?[]const u8,
};

const Config = struct {
    options: []ConfigOption,
};

const Schema = struct {
    @"$schema": []const u8 = "http://json-schema.org/schema",
    title: []const u8 = "ZLS Config",
    description: []const u8 = "Configuration file for the zig language server (ZLS)",
    type: []const u8 = "object",
    properties: std.StringArrayHashMap(SchemaEntry),
};

const SchemaEntry = struct {
    description: []const u8,
    type: []const u8,
    default: []const u8,
};

fn zigTypeToTypescript(ty: []const u8) ![]const u8 {
    return if (std.mem.eql(u8, ty, "?[]const u8"))
        "string"
    else if (std.mem.eql(u8, ty, "bool"))
        "boolean"
    else if (std.mem.eql(u8, ty, "usize"))
        "integer"
    else
        error.UnsupportedType;
}

fn generateConfigFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    _ = allocator;

    const config_file = try std.fs.openFileAbsolute(path, .{
        .mode = .write_only,
    });
    defer config_file.close();

    var buff_out = std.io.bufferedWriter(config_file.writer());

    _ = try buff_out.write(
        \\//! DO NOT EDIT
        \\//! Configuration options for zls.
        \\//! If you want to add a config option edit
        \\//! src/config_gen/config.zig and run `zig build gen`
        \\//! GENERATED BY src/config_gen/config_gen.zig
        \\
    );

    for (config.options) |option| {
        try buff_out.writer().print(
            \\
            \\/// {s}
            \\{s}: {s} = {s},
            \\
        , .{
            std.mem.trim(u8, option.description, " \t\n\r"),
            std.mem.trim(u8, option.name, " \t\n\r"),
            std.mem.trim(u8, option.type, " \t\n\r"),
            std.mem.trim(u8, option.default, " \t\n\r"),
        });
    }

    _ = try buff_out.write(
        \\
        \\// DO NOT EDIT
        \\
    );

    try buff_out.flush();
}

fn generateSchemaFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    const schema_file = try std.fs.openFileAbsolute(path, .{
        .mode = .write_only,
    });
    defer schema_file.close();

    var buff_out = std.io.bufferedWriter(schema_file.writer());

    var properties = std.StringArrayHashMapUnmanaged(SchemaEntry){};
    defer properties.deinit(allocator);
    try properties.ensureTotalCapacity(allocator, config.options.len);

    for (config.options) |option| {
        properties.putAssumeCapacityNoClobber(option.name, .{
            .description = option.description,
            .type = try zigTypeToTypescript(option.type),
            .default = option.default,
        });
    }

    _ = try buff_out.write(
        \\{
        \\    "$schema": "http://json-schema.org/schema",
        \\    "title": "ZLS Config",
        \\    "description": "Configuration file for the zig language server (ZLS)",
        \\    "type": "object",
        \\    "properties": 
    );

    try serializeObjectMap(properties, .{
        .whitespace = .{
            .indent_level = 1,
        },
    }, buff_out.writer());

    _ = try buff_out.write("\n}\n");
    try buff_out.flush();
}

fn updateREADMEFile(allocator: std.mem.Allocator, config: Config, path: []const u8) !void {
    var readme_file = try std.fs.openFileAbsolute(path, .{ .mode = .read_write });
    defer readme_file.close();

    var readme = std.ArrayListUnmanaged(u8){
        .items = try readme_file.readToEndAlloc(allocator, std.math.maxInt(usize)),
    };
    defer readme.deinit(allocator);

    const start_indicator = "<!-- DO NOT EDIT | THIS SECTION IS AUTO-GENERATED | DO NOT EDIT -->";
    const end_indicator = "<!-- DO NOT EDIT -->";

    const start = start_indicator.len + (std.mem.indexOf(u8, readme.items, start_indicator) orelse return error.SectionNotFound);
    const end = std.mem.indexOfPos(u8, readme.items, start, end_indicator) orelse return error.SectionNotFound;

    var new_readme = std.ArrayListUnmanaged(u8){};
    defer new_readme.deinit(allocator);
    var writer = new_readme.writer(allocator);

    try writer.writeAll(
        \\
        \\| Option | Type | Default value | What it Does |
        \\| --- | --- | --- | --- |
        \\
    );

    for (config.options) |option| {
        try writer.print(
            \\| `{s}` | `{s}` | `{s}` | {s} |
            \\
        , .{
            std.mem.trim(u8, option.name, " \t\n\r"),
            std.mem.trim(u8, option.type, " \t\n\r"),
            std.mem.trim(u8, option.default, " \t\n\r"),
            std.mem.trim(u8, option.description, " \t\n\r"),
        });
    }

    try readme.replaceRange(allocator, start, end - start, new_readme.items);

    try readme_file.seekTo(0);
    try readme_file.writeAll(readme.items);
}

pub fn main() !void {
    var arg_it = std.process.args();

    _ = arg_it.next() orelse @panic("");
    const config_path = arg_it.next() orelse @panic("first argument must be path to Config.zig");
    const schema_path = arg_it.next() orelse @panic("second argument must be path to schema.json");
    const readme_path = arg_it.next() orelse @panic("third argument must be path to README.md");

    var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa = general_purpose_allocator.allocator();

    const parse_options = std.json.ParseOptions{
        .allocator = gpa,
    };
    var token_stream = std.json.TokenStream.init(@embedFile("config.json"));
    const config = try std.json.parse(Config, &token_stream, parse_options);
    defer std.json.parseFree(Config, config, parse_options);

    try generateConfigFile(gpa, config, config_path);
    try generateSchemaFile(gpa, config, schema_path);
    try updateREADMEFile(gpa, config, readme_path);

    std.log.warn(
        \\ If you have added a new configuration option and it should be configuration through the config wizard, then edit src/setup.zig
    , .{});

    std.log.info(
        \\ Changing configuration options may also require editing the `package.json` from zls-vscode at https://github.com/zigtools/zls-vscode/blob/master/package.json
    , .{});
}

fn serializeObjectMap(
    value: anytype,
    options: std.json.StringifyOptions,
    out_stream: anytype,
) @TypeOf(out_stream).Error!void {
    try out_stream.writeByte('{');
    var field_output = false;
    var child_options = options;
    if (child_options.whitespace) |*child_whitespace| {
        child_whitespace.indent_level += 1;
    }
    var it = value.iterator();
    while (it.next()) |entry| {
        if (!field_output) {
            field_output = true;
        } else {
            try out_stream.writeByte(',');
        }
        if (child_options.whitespace) |child_whitespace| {
            try child_whitespace.outputIndent(out_stream);
        }

        try std.json.stringify(entry.key_ptr.*, options, out_stream);
        try out_stream.writeByte(':');
        if (child_options.whitespace) |child_whitespace| {
            if (child_whitespace.separator) {
                try out_stream.writeByte(' ');
            }
        }
        try std.json.stringify(entry.value_ptr.*, child_options, out_stream);
    }
    if (field_output) {
        if (options.whitespace) |whitespace| {
            try whitespace.outputIndent(out_stream);
        }
    }
    try out_stream.writeByte('}');
}
