package lc

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "core:thread"
import "core:strconv"

import "fs"

categories := [?]string {
    "Comments",
    "Blank",
    "Code",
    "Total"
};

COLUMNS :: len(categories);

PATH_PADDING :: 1;
HEADER_WIDTH :: 16;

Scan_Entry :: struct {
    info:          fs.File_Info,
    scanned:       bool,
    blank_count:   u64,
    comment_count: u64,
    code_count:    u64,
}

Options :: struct {
    recursive: bool,
    
    override_ext: bool,
    extensions: string,
    
    override_sc: bool,
    single_comments: [dynamic]string,
    
    // @TODO: multiple multiline comment?
    override_mc: bool,
    mc_begin: string,
    mc_end: string,
    
    thread_count: int,
    buffer_size: int,
    
    full_paths: bool,
    only_results: bool,
};

Thread_Data :: struct {
    entry:   ^Scan_Entry,
    options: ^Options,
};

main :: proc() {
    if len(os.args) <= 1 {
        show_help();
        return;
    }
    
    start_time := time.now();
    
    options: Options;
    defer if options.single_comments != nil do delete(options.single_comments);
    
    paths: [dynamic]string;
    defer {
        for i in 0..<len(paths) {
            delete(paths[i]);
        }
        delete(paths);
    }
    
    // Parse arguments
    for arg in os.args[1:] {
        if arg[0] != '-' {    
            path := fs.normalize_path(arg);
            
            // Check if the directory is valid
            info, error := fs.get_dir_info(path);
            defer if error == fs.Dir_Error.None do fs.delete_dir_info(&info);
            
            if error == fs.Dir_Error.None {
                append(&paths, strings.clone(path));
            } else {
                fmt.printf("[!] Cannot open directory '%v' with error '%v'\n", path, error);
            }
        } else {
            // It's an option, parse
            opt := arg;
            set := "";
            
            index := strings.last_index_any(arg, "=");
            
            if index != -1 {
                opt = arg[:index];
                set = arg[index + 1:];
            }
            
            switch opt {
                case "-h", "--help":
                    show_help();
                    return;
                    
                case "-r", "--recursive":
                    if set == "" {
                        options.recursive = true;
                    } else {
                        fmt.printf("[!] Unexpected arguments for option '%v'\n", opt);
                    }
                
                case "-e", "--extentions":
                    if set != "" {
                        options.override_ext = true;
                        options.extensions = set;
                    } else {
                        fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                    }
                    
                case "-sc", "--single-comment":
                    if set != "" {
                        options.override_sc = true;
                        options.single_comments = parse_comma_options(set);
                    } else {
                        fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                    }
                    
                case "-mc", "--multi-comment":
                    if set != "" {
                        mc := parse_comma_options(set);
                        
                        defer delete(mc);
                        
                        if len(mc) != 2 {
                            fmt.printf("[!] Expected 2 arguments for option '%v' but got %v", opt, len(mc));
                        } else {
                            options.override_mc = true;
                            
                            // We know that the length == 2
                            #no_bounds_check {
                                options.mc_begin = mc[0];
                                options.mc_end   = mc[1];
                            }
                        }
                    } else {
                        fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                    }
                    
                case "-t", "--threads":
                    if set != "" {
                        options.thread_count = strconv.parse_int(set);
                    } else {
                        fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                    }
                    
                case "-b", "--buffer":
                    if set != "" {
                        options.buffer_size = strconv.parse_int(set);
                    } else {
                        fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                    }
                    
                case "-fp", "--full-paths":
                    if set == "" {
                        options.full_paths = true;
                    } else {
                        fmt.printf("[!] Unexpected arguments for option '%v'\n", opt);
                    }
                    
                case "-or", "--only-results":
                    if set == "" {
                        options.only_results = true;
                    } else {
                        fmt.println("[!] Unexpected arguments for option '%v'\n", opt);
                    }
                    
                case:
                    fmt.printf("[!] Unknown option '%v'\n", opt);
            }
        }
    }
    
    // Check if we have no paths
    if len(paths) == 0 {
        fmt.printf("[!] No paths specified");
        return;
    }
    
    // Default values
    if !options.override_sc {
        sc: [dynamic]string;
        
        append(& sc, "//");
        options.single_comments = sc;
    }
    
    if !options.override_mc {
        options.mc_begin = "/*";
        options.mc_end   = "*/";        
    }
    
    if !options.override_ext {
        options.extensions = ".cpp.h";
    }
    
    if options.thread_count <= 0 {
        options.thread_count = 4;
    }
        
    if options.buffer_size <= 0 {
        options.buffer_size = 32;
    }
    
    files: [dynamic]fs.File_Info;
    
    // We don't need to delete the File_Info's because they get copied to the Scan_Entry's
    defer delete(files);
    
    // Split extentions
    exts: [dynamic]string;
    
    for {
        index := strings.index_any(options.extensions, ".");
    
        if index == -1 do break;
    
        new_str := options.extensions[:index];
        
        append(&exts, new_str);
        options.extensions = options.extensions[index+1:];
    }
    new_str := options.extensions;
    append(&exts, new_str);
    
    // Get the files
    for path in paths {
        tmp, error := fs.get_all_files(path, true, options.recursive, ..exts[:]);
        if error == fs.Dir_Error.None {
            for file in tmp {
                append(&files, file);
            }
            
            delete(tmp);
        } else {
            fmt.printf("[!] Cannot open directory '%v' with error '%v'\n", path, error);
        }
    }
    
    if len(exts) > 0 do delete(exts);
    
    if len(files) == 0 {
        fmt.printf("[!] No files scanned");
        return;
    }
    
    // Create scan entries and copy File_Info's
    entries := make([dynamic]Scan_Entry, len(files));
    defer {
        for i in 0..<len(entries) {
            fs.delete_file_info(&entries[i].info);
        }
        delete(entries);
    }
    
    for file, i in files {
        entries[i].info = file;
    }
    
    // Find the longest path
    longest_path: int = 0;
    for file in files {
        if options.full_paths {
            if len(file.path) > longest_path {
                longest_path = len(file.path);
            }
        } else {
            if len(fs.get_filename(file.path)) > longest_path {
                longest_path = len(fs.get_filename(file.path));
            }
        }
    }
    
    comment_count_total : u64 = 0;
    blank_count_total   : u64 = 0;
    code_count_total    : u64 = 0;
    
    total_bytes: f64 = 0.0;
    next_file_index := 0;
        
    if options.thread_count > 1 {
        threads := make([dynamic]^thread.Thread, 0, options.thread_count);
        defer delete(threads);
        
        start_new_thread :: proc(entries: ^[dynamic]Scan_Entry, index: int, options: ^Options) -> ^thread.Thread {
            t := thread.create(scan_file);
            
            assert(t != nil);
            
            t.user_index = index;
            data := new(Thread_Data);
            data.entry = &((entries^)[index]);
            data.options = options;
            
            t.data = data;
            thread.start(t);
            return t;
        }
        
        for in 0..<options.thread_count {
            if next_file_index < len(entries) {
                append(&threads, start_new_thread(&entries, next_file_index, &options));
                next_file_index += 1;
            }
        }
        
        all_threads_done := false;
        for next_file_index < len(entries) || !all_threads_done {
            for i := 0; i < len(threads); {
                if t := threads[i]; thread.is_done(t) {
                    thread.destroy(t);    
                    ordered_remove(&threads, i);
                    
                    if next_file_index < len(entries) {
                        append(&threads, start_new_thread(&entries, next_file_index, &options));
                        next_file_index += 1;
                    }
                    
                    all_threads_done = len(threads) == 0;
                } else {
                    i += 1;
                }
            }
        }
    } else {
        // If our thread_count == 1 we're not gonna start any threads
        for next_file_index < len(entries) {
            scan_file(&entries[next_file_index], &options);
            next_file_index += 1;
        }
    }
    
    // Print the header
    if !options.only_results {
        print_header(longest_path);
        print_seperator(longest_path);
    }
    
    for e in entries {
        // Add these counts to the total
        comment_count_total += e.comment_count;
        blank_count_total   += e.blank_count;
        code_count_total    += e.code_count;
        
        total_bytes += f64(e.info.file_size);
        
        if !options.only_results {
            path := (options.full_paths) ? e.info.path : fs.get_filename(e.info.path);
            pad := strings.right_justify(" ", longest_path - len(path) + PATH_PADDING, " ");
            
            defer delete(pad);
            
            fmt.printf("%v%v|", path, pad);
            counts := [COLUMNS]u64 {
                e.comment_count,
                e.blank_count,
                e.code_count,
                e.comment_count + e.blank_count + e.code_count
            };
            
            print_counts(counts);
        }
    }
    
    total := [?]u64 {
        comment_count_total,
        blank_count_total,
        code_count_total,
        comment_count_total + blank_count_total + code_count_total,
    };
    
    // Promote bytes
    mag := "b";
    if total_bytes > 1024.0 {
        total_bytes /= 1024.0;
        mag = "KiB";
    }
        
    if total_bytes > 1024.0 {
        total_bytes /= 1024.0;
        mag = "MiB";
    }
    
    if total_bytes > 1024.0 {
        total_bytes /= 1024.0;
        mag = "GiB";
    }
    
    if total_bytes > 1024.0 {
        total_bytes /= 1024.0;
        mag = "TiB";
    }
    
    print_seperator(longest_path);
    
	pad := strings.right_justify(" ", longest_path + PATH_PADDING, " ");
	defer delete(pad);
	
	fmt.printf("%v|", pad);
	print_counts(total);
	
	print_seperator(longest_path);
	print_header(longest_path);

    diff := time.diff(start_time, time.now());
    fmt.printf("Scanned %v files of %v %v total in %v seconds", len(entries), total_bytes, mag, time.duration_seconds(diff));
}


@private
scan_file :: proc { scan_file_threaded, scan_file_direct };

@private
scan_file_threaded:: proc(t: ^thread.Thread) -> int {
    data := cast(^Thread_Data) t.data;
    return scan_file_direct(data.entry, data.options);
}

@private
scan_file_direct :: proc(entry: ^Scan_Entry, options: ^Options) -> int {
    file, error := os.open(entry.info.path);
    defer if error == 0 do os.close(file);
    
    if error != os.ERROR_NONE {
        fmt.printf("[!] cannot open file '%v', skipping... (error code: %v)\n", entry.info.path, error);
        return 0;
    }
            
    in_comment := false;
    
    cont := true;
    scan_loop: for cont {
        full_line: string;
        cont, full_line = fs.getline(file, options.buffer_size);
        defer if len(full_line) > 0 do delete(full_line);
        
        line := strings.trim_space(full_line);
        
        // Blank lines
        if len(line) == 0 {
            if !in_comment do entry.blank_count   += 1;
            else           do entry.comment_count += 1;
            continue;
        }
        
        // Single-comment check
        if !in_comment {
            for sc in options.single_comments {
                if len(sc) > len(line) do continue;
                
                if strings.contains(line, sc) {
                    entry.comment_count += 1;
                    continue scan_loop;
                }
            }
        }
        
        if len(line) >= len(options.mc_begin) &&
           len(line) >= len(options.mc_end) {
            if strings.contains(line, options.mc_begin) {
                entry.comment_count += 1;
                in_comment = true;
                continue;
            }
            
            end := line[len(line) - len(options.mc_end):];
            if end == options.mc_end && in_comment {
                entry.comment_count += 1;
                in_comment = false;
                continue;
            }
        }
        
        if !in_comment do entry.code_count    += 1;
        else           do entry.comment_count += 1;
    }
        
    entry.scanned = true;
    return 0;
}

@private
print_counts :: proc(counts: [COLUMNS]u64) {
    for i in 0..<len(counts) {
        count_len := strings.rune_count(fmt.tprintf("%v", counts[i]));
    
        text := fmt.aprintf("%v |", counts[i]);
        pad  := strings.right_justify(" ", HEADER_WIDTH - count_len - 1, " ");
        
        fmt.printf("%v%v", pad, text);
        
        delete(text);
        delete(pad);
    }
    fmt.println();
}

@private
print_seperator:: proc(longest_path: int) {
    pad := strings.right_justify("-", longest_path + PATH_PADDING, "-");
    defer delete(pad);
    
    fmt.printf("%v|", pad);
    
    for in 0..<COLUMNS {
        for in 0..<HEADER_WIDTH {
            fmt.printf("-");
        }
        fmt.printf("|");
    }
    fmt.println();
}

@private
print_header :: proc(longest_path: int) {
    {
        pad := strings.right_justify(" ", longest_path + PATH_PADDING, " ");    
        fmt.printf("%v|", pad);
        delete(pad);
    }
    
    for i in 0..<COLUMNS {
        pad := strings.right_justify(" ", HEADER_WIDTH - len(categories[i]) - 2, " ");
        fmt.printf(" %v%v |", categories[i], pad);
        delete(pad);
    }
    fmt.println();
}

@private
show_help :: proc() {
    fmt.printf("Usage: %s [options] <directories...>\n\n", os.args[0]);
    fmt.printf("  Options:\n");
    fmt.printf("      -h  --help           | Show this help screen\n");
    fmt.printf("                           |\n");
    fmt.printf("      -r  --recursive      | recursively search directories\n");
    fmt.printf("                           | default: false\n");
    fmt.printf("                           |\n");
    fmt.printf("      -e  --extensions     | set file extensions to match\n");
    fmt.printf("                           | example: -e=.php.js\n");
    fmt.printf("                           | default: .cpp.h\n");
    fmt.printf("                           |\n");
    fmt.printf("      -sc --single-comment | sets the single line comment delimiter\n");
    fmt.printf("                           | example: -sc=//,#\n");
    fmt.printf("                           | default: //\n");
    fmt.printf("                           |\n");
    fmt.printf("      -mc --multi-comment  | sets the multiline comment delimiters\n");
    fmt.printf("                           | example: -mc=/*,*/\n");
    fmt.printf("                           | default: /*,*/\n");
    fmt.printf("                           |\n");
    fmt.printf("      -t  --threads        | set the amount of threads it will use\n");
    fmt.printf("                           | example: -t=1\n");
    fmt.printf("                           | default: 4\n");
    fmt.printf("                           |\n");
    fmt.printf("      -b  --buffer         | sets the size of the getline buffer in bytes (more ram usage, faster, less reads)\n");
    fmt.printf("                           | example: -b=64\n");
    fmt.printf("                           | default: 32\n");
    fmt.printf("                           |\n");
    fmt.printf("      -fp  --full-paths    | shows the full filepath instead of just the filename\n");
    fmt.printf("                           | default: false\n");
    fmt.printf("                           |\n");
    fmt.printf("      -or  --only-results  | don't show the per-file results, just the total sum\n");
    fmt.printf("                           | default: false\n");
}

@private
parse_comma_options :: proc(s: string) -> [dynamic]string {
    opts: [dynamic]string;
    
    ns := s;
    for {
        index := strings.index_any(ns, ",");
    
        if index == -1 do break;
        
        append(&opts, ns[:index]);
        ns = ns[index+1:];
    }
    
    append(&opts, ns);
    return opts;
}
