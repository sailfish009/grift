#!/bin/bash
set -x

#riscv32-unknown-elf-gcc -static -nostdlib -nostartfiles -S qsort_main.c -o qsort_main32.s
#riscv64-unknown-elf-gcc -static -nostdlib -nostartfiles -S qsort_main.c -o qsort_main64.s

riscv64-unknown-elf-gcc -mcmodel=medany -march=rv64im -mabi=lp64 -static -nostdlib -nostartfiles init.S qsort_main.c -o qsort64
riscv64-unknown-elf-objdump -D qsort64 >qsort64.text

