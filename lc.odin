package main

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

print_counts :: proc(counts: [COLUMNS]u64) {
    for i in 0..<len(counts) {
        count_len := strings.rune_count(fmt.tprintf("%v", counts[i]));
    
        text := fmt.tprintf("%v |", counts[i]);
        pad  := strings.right_justify(" ", HEADER_WIDTH - count_len - 1, " ");
        
        fmt.printf("%v%v", pad, text);
    }
    fmt.println();
}

// @TODO: buffering the input into a string and then printing it is probably aster
print_seperator:: proc(longest_path: int) {
    pad  := strings.right_justify("-", longest_path + PATH_PADDING, "-");
    fmt.printf("%v|", pad);
    
    for in 0..<COLUMNS {
        for in 0..<HEADER_WIDTH {
            fmt.printf("-");
        }
        fmt.printf("|");
    }
    fmt.println();
}

print_header :: proc(longest_path: int) {
    pad := strings.right_justify(" ", longest_path + PATH_PADDING, " ");
    fmt.printf("%v|", pad);
    
    for i in 0..<COLUMNS {
        pad = strings.right_justify(" ", HEADER_WIDTH - len(categories[i]) - 2, " ");
        fmt.printf(" %v%v |", categories[i], pad);
    }
    fmt.println();
}

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
}

parse_comma_options :: proc(s: string) -> ^[dynamic]string {
    opts: [dynamic]string;
    
    for true {
        index := strings.index_any(s, ",");
    
        if index == -1 do break;
    
        new_str := s[:index];
        append(&opts, new_str);
        s = s[index+1:];
    }
    
    append(&opts, s);
    
    return &opts;
}

Scan_Entry :: struct {
    info:          fs.File_Info,
    scanned:       bool,
    blank_count:   u64,
    comment_count: u64,
    code_count:    u64,
}

main :: proc() {
    if len(os.args) <= 1 {
        show_help();
        return;
    }
    
    Options :: struct {
        recursive: bool,
        
        override_ext: bool,
        extensions: string,
        
        override_sc: bool,
        single_comments: ^[dynamic]string,
        
        // @TODO: multiple multiline comment
        override_mc: bool,
        mc_begin: string,
        mc_end: string,
        
        thread_count: int,
        buffer_size: int,
        full_paths: bool,
    };
    
    options: Options;
    
    paths: [dynamic]string;
    defer delete(paths);
    
    // Parse arguments
    skip_first := false;
    for arg in os.args {
        if !skip_first {
            skip_first = true;
            continue;
        }
        
        if arg[0] != '-' {
            path := fs.normalize_path(arg);
        
            // Check if the directory is valid
            _, error := fs.get_dir_info(path);
            
            if error == fs.Dir_Error.None {
                append(&paths, path);
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
            
            if opt == "-h" || opt == "--help" {
                show_help();
                return;
            } else if opt == "-r" || opt == "--recursive" {
                if set == "" {
                    options.recursive = true;
                } else {
                    fmt.printf("[!] Unexpected arguments for option '%v'\n", opt);
                }
            } else if opt == "-e" || opt == "--extensions" {
                if set != "" {
                    options.override_ext = true;
                    options.extensions = set;
                } else {
                    fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                }
            } else if opt == "-sc" || opt == "--single-comment" {
                if set != "" {
                    options.override_sc = true;
                    options.single_comments = parse_comma_options(set);
                } else {
                    fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                }
            } else if opt == "-mc" || opt == "--multi-comment" {
                if set != "" {
                    mc := parse_comma_options(set);
                    
                    defer delete(mc^);
                                        
                    if len(mc) != 2 {
                        fmt.printf("[!] Expected 2 arguments for option '%v' but got %v", opt, len(mc));
                    } else {
                        options.override_mc = true;
                        
                        // We know that the length == 2
                        #no_bounds_check {
                            options.mc_begin = (mc^)[0];
                            options.mc_end   = (mc^)[1];
                        }
                    }
                } else {
                    fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                }
            } else if opt == "-t" || opt == "--threads" {
                if set != "" {
                    options.thread_count = strconv.parse_int(set);
                } else {
                    fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                }
            } else if opt == "-b" || opt == "--buffer" {
                if set != "" {
                    options.buffer_size = strconv.parse_int(set);
                } else {
                    fmt.printf("[!] Expected arguments for option '%v'\n", opt);
                }
            } else if opt == "-fp" || opt == "--full-paths" {
                if set == "" {
                    options.full_paths = true;
                } else {
                    fmt.printf("[!] Unexpected arguments for option '%v'\n", opt);
                }
            } else {
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
        
        append(&sc, "//");
        options.single_comments = &sc;
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
    
    // Get the files
    for path in paths {
        tmp, error := fs.get_all_files(path, true, options.recursive, options.extensions);
        
        if error == fs.Dir_Error.None {
            for file in tmp {
                append(&files, file);
            }
            delete(tmp);
        } else {
            fmt.printf("[!] Cannot open directory '%v' with error '%v'\n", path, error);
        }
    }
    
    if len(files) == 0 {
        fmt.printf("[!] No files scanned");
        return;
    }
    
    // Create scan entries and copy File_Info's
    entries := make([dynamic]Scan_Entry, len(files));
    defer delete(entries);
    
    for i in 0..<len(files) {
        entries[i].info = files[i];
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
    
    delete(files);
    files = nil;
    
    comment_count_total : u64 = 0;
    blank_count_total   : u64 = 0;
    code_count_total    : u64 = 0;
    
    Thread_Data :: struct {
        entry:   ^Scan_Entry,
        options: ^Options,
    };
    
    scan_file :: proc(t: ^thread.Thread) -> int {
        data    := cast(^Thread_Data) t.data;
        entry   := data.entry;
        options := data.options;
        
        file, error := os.open(entry.info.path);
        
        if error != os.ERROR_NONE {
            fmt.printf("[!] cannot open file '%v', skipping... (error code: %v)\n", entry.info.path, error);
            return 0;
        }
                
        in_comment := false;
        
        line := "";
        cont := true;
        for true {
            if !cont do break;
        
            cont = fs.getline(file, &line, options.buffer_size);
            line = strings.trim_space(line);
            
            // Blank lines
            if len(line) == 0 {
                entry.blank_count += 1;
                continue;
            }
            
            // Single-comment check
            if !in_comment {
                skip_line := false;
                
                for i in 0..<len(options.single_comments) {
                    if len(options.single_comments[i]) > len(line) do continue;
                    
                    if strings.contains(line, options.single_comments[i]) {
                        entry.comment_count += 1;
                        skip_line = true;
                        break;
                    }
                }
                
                if skip_line do continue;
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
                    in_comment = false;
                    continue;
                }
            }
            
            entry.code_count += 1;
        }
        
        entry.scanned = true;
        os.close(file);
        return 0;
    }

    
    start_time := time.now();
    total_bytes: f64 = 0.0;
    
    threads := make([dynamic]^thread.Thread, 0, options.thread_count);
    defer delete(threads);
    
    next_file_index := 0;
    
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
                e := entries[t.user_index];
            
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
    
    end_time := time.now();
    
    // Print the header
    print_header(longest_path);
    print_seperator(longest_path);
    
    for e in entries {
        path := (options.full_paths) ? e.info.path : fs.get_filename(e.info.path);
        
        pad := strings.right_justify(" ", longest_path - len(path) + PATH_PADDING, " ");
        total_bytes += f64(e.info.file_size);
        
        fmt.printf("%v%v|", path, pad);
        
        // Add these counts to the total
        comment_count_total += e.comment_count;
        blank_count_total   += e.blank_count;
        code_count_total    += e.code_count;
        
        counts := [COLUMNS]u64 {
            e.comment_count,
            e.blank_count,
            e.code_count,
            e.comment_count + e.blank_count + e.code_count
        };
        
        print_counts(counts);
        
    }
    
    total := [?]u64 {
        comment_count_total,
        blank_count_total,
        code_count_total,
        comment_count_total + blank_count_total + code_count_total,
    };
    
    // Convert to KiB    
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
    fmt.printf("%v|", pad);
    print_counts(total);
    
    print_seperator(longest_path);
    print_header(longest_path);
        
    diff := time.diff(start_time, end_time);
    fmt.printf("Scanned %v files of %v %v total in %v seconds", len(entries), total_bytes, mag, time.duration_seconds(diff));
}
