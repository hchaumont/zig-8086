# zig-8086
Intel 8086 instruction decoder and emulator written as an exercise to learn Zig.
Given a binary input file representing Intel 8086 instructions, will output the
decoded assembly instructions. Can optionally also emulate running instructions
and inspect register and flag state.

Encodings based on the information in [Intel 8086 Family User's Manual](https://archive.org/details/manualzilla-id-6912386).

## Usage
To build:
```
zig build
```
To run:
```
./decoder FILENAME [execute]
```
The optional parameter `execute` will emulate running the input file.
