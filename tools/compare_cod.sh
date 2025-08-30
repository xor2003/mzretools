#!/bin/bash
# Enhanced COD comparison tool with compiler-specific normalization

# Arguments: <COD file> <ASM file> <function name>

if [ $# -ne 3 ]; then
    echo "Usage: $0 <COD file> <ASM file> <function name>"
    exit 1
fi

COD_FILE="$1"
ASM_FILE="$2"
FUNC_NAME="$3"

# Extract function assembly with context - COD uses PROC/ENDP, original uses proc/endp
awk "/${FUNC_NAME}[[:space:]]*PROC/,/${FUNC_NAME}[[:space:]]*ENDP/" "$COD_FILE" > /tmp/cod_func.asm
awk "/${FUNC_NAME} proc/,/${FUNC_NAME} endp/" "$ASM_FILE" > /tmp/orig_func.asm

# Normalize differences
sed -i -e 's/_gfx_jump_32/gfx_jump_32/g' \
       -e 's/seg[0-9a-f]\+/seg_0/g' \
       -e 's/offset \(dseg\|_data\)/offset DGROUP/g' \
       /tmp/cod_func.asm /tmp/orig_func.asm

# Compare the normalized files
diff -u --color=always /tmp/orig_func.asm /tmp/cod_func.asm > compare_results.txt

# Keep files for analysis (commented out cleanup)
# rm /tmp/cod_func.asm /tmp/orig_func.asm