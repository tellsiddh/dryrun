# dryrun

A safe and intelligent dry-run tool for Bash operations.  
It simulates potentially destructive shell commands, supports native dry-run flags where available, and provides helpful diagnostics for shell scripts.

---

## Features

- Real dry-run support for tools like `rsync`, `apt`, `yum`, `git`, `terraform`, and `kubectl`
- Simulation of filesystem commands: `rm`, `cp`, `mv`, `mkdir`, `touch`, etc.
- Script parsing to simulate execution line-by-line
- Syntax checking via `bash -n`
- Static analysis for:
  - Unquoted variable usage
  - Dangerous patterns like `rm -rf $VAR`
  - Linting with `shellcheck`

---

## Usage

```bash
dryrun <command> [arguments...]
```

### Examples

```bash
dryrun rm -rf /etc
dryrun apt-get install nginx
dryrun cp file.txt /tmp/
dryrun rsync -av . /backup
```

### Extended modes

```bash
dryrun syntax script.sh        # Syntax check with bash -n
dryrun trace script.sh         # Print commands without executing them
dryrun script script.sh        # Simulate file operations in a script
dryrun check-vars script.sh    # Warn about unquoted/dangerous variables
dryrun lint script.sh          # Lint the script using shellcheck
```

---

## Installation

Make the script executable and move it into your PATH:

```bash
chmod +x dryrun.sh
sudo mv dryrun.sh /usr/local/bin/dryrun
```

Then you can run it from anywhere:

```bash
dryrun <command>
```

---

## Requirements

- `bash`
- `shellcheck` (optional, for `dryrun lint`)

---


## Author

Developed by Siddharth Jain.  
Feel free to contribute or suggest improvements.
