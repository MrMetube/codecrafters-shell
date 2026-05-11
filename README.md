[![progress-banner](https://backend.codecrafters.io/progress/shell/7ec902db-51b5-401e-95d4-a34cd715dcdf)](https://app.codecrafters.io/users/codecrafters-bot?r=2qF)

This is based on the ["Build Your Own Shell" Challenge](https://app.codecrafters.io/courses/shell/overview).

This implementation provides an interactive POSIX-style shell that interprets commands, runs external programs and builtins, and exposes a REPL.

It implements a prompt and parsing, with builtins such as exit, echo, and type, and runs executables found in PATH.

Navigation: with pwd and cd(absolute, relative, and home-directory paths) commands.

Quoting: handle single quotes, double quotes, and backslash escaping.

Redirection: redirect stdout and stderr, with options to create or append files.

Background jobs: start jobs with &, list running jobs, and reap finished jobs.

Pipelines: pipe a command’s stdout to the next command’s stdin and chain multiple commands in a single pipeline.
