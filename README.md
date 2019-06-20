# Line Counter
A command-line line counter for your code. Recursively scans files over multiple threads and counts the code, blanks and comments.

| Option               | Description                            | Example      | Default |
| -------------------- | -------------------------------------- | ------------ | ------  |
| -h --help            | Shows the help screen                  | -h           | false   |
| -r --recursive       | Recursively search directories         | -r           | false   |
| -e -extensions       | Set file extensions to match           | -e=.js.php   | .cpp.h  |
| -sc --single-comment | Sets the single comment delimiter      | -sc=//,#     | //      |
| -mc --multi-comment  | Sets the multiline comment delimiters  | -mc=/\*,\*/  | /\*,\*/ |
| -t  --threads        | Sets the number of threads             | -t=5         | 4       |
| -b  --buffer         | Sets the size of the getline buffer    | -t=64        | 32      |
| -fp --full-paths     | Shows the absolute path to the file    | -fp          | false   |

## Notes
### Threads
Setting `t` to 1 will make it single-threaded, instead of launching with a thread pool of 1.

### Buffer
The getline buffer is how many bytes will be read and checked for a newline. A larger buffer will be faster as it will have to do less reads but it will cost more RAM (each thread calls getline).

## Output
![Output](https://i.imgur.com/lg3kTbp.png)
