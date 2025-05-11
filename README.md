# uzage

A lightweight process resource usage monitoring tool written in Zig.

## Overview

`uzage` (pronounced "usage") is a command-line utility for monitoring CPU and memory usage of processes on Linux systems. It can either monitor an existing process by PID or launch and monitor a new process.

## Features

- Monitor CPU and memory usage of any process
- Launch and monitor a new process
- Configurable sampling interval
- Output to console or JSON file
- Graceful termination with Ctrl+C

## Installation

### Prerequisites

- Zig compiler (0.11.0 or newer)

### Building from source

```bash
git clone https://github.com/yourusername/uzage.git
cd uzage
zig build -Doptimize=ReleaseSafe
```

The executable will be available at `zig-out/bin/uzage`.

## Usage

```
uzage - Process resource usage monitoring tool

Usage:
  uzage [options] <pid>
  uzage [options] -- <command> [args...]

Options:
  -h, --help            Show help information
  -V, --version         Show version information
  -o, --output <file>   Write results to file
  -t, --interval <ms>   Set sampling interval (milliseconds), default 100ms

Examples:
  uzage 1234            Monitor process with PID 1234
  uzage -- python script.py  Launch and monitor Python script
```

### Examples

Monitor an existing process:

```bash
uzage 1234
```

Launch and monitor a new process:

```bash
uzage -- ls -la
```

Change sampling interval to 500ms:

```bash
uzage -t 500 1234
```

Output to JSON file:

```bash
uzage -o usage.json 1234
```

## How it works

`uzage` reads process information from the `/proc` filesystem on Linux:

- CPU usage is calculated from `/proc/<pid>/stat`
- Memory usage is obtained from `/proc/<pid>/statm`

The tool samples these values at regular intervals and calculates the CPU percentage and memory usage.

## Limitations

- Currently only supports Linux systems
- CPU usage calculation assumes a standard USER_HZ value of 100

## License

[MIT License](LICENSE)