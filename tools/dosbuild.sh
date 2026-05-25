#!/bin/bash
#
# This script invokes development binaries (compiler, linker, assembler) in a DOS emulator.
#
# TODO: 
# - linking can be simplified by using CL instead of LINK
# - get rid of infile/outfile, just build in-tree? then make install copies to the output dir

TOOLCHAIN_DIR=dos
CONF_DIR=conf
CONF_FILE=$CONF_DIR/toolchain.conf
BAT_FILE=$TOOLCHAIN_DIR/build.bat
DEBUG=0
# always print toolchain stdout
VERBOSE=1
cmdline=$@
DOSBOX_BIN=${DOSBOX_BIN:-}
DOSBOX_EXTRA_ARGS=${DOSBOX_EXTRA_ARGS:-}
DOSBOX_TIMEOUT=${DOSBOX_TIMEOUT:-120}
KVIKDOS_BIN=${KVIKDOS_BIN:-}
MSDOS_PLAYER_BIN=${MSDOS_PLAYER_BIN:-}
MSDOS_USE_WINE=${MSDOS_USE_WINE:-1}
EMU_BACKEND=${EMU_BACKEND:-}
EMU_TIMEOUT=${EMU_TIMEOUT:-$DOSBOX_TIMEOUT}

function syntax() {
    [ "$1" ] && echo "Error: $1"
    echo "Syntax: dosbuild.sh cc|link|as toolchain -i infiles... -o outfile [-f flags...] [-l libs...]"
    exit 241
}

function debug() {
    if ((DEBUG)); then echo $1; fi
}

function fatal() {
    if ((DEBUG)); then echo $cmdline; fi
    echo "Error: $1"
    exit 242
}

function basedir() {
    echo $1 | cut -d '/' -f 1
}

function dossep() {
    echo "$1" | sed -e 's|/|\\|g'
}

function output_unresolved() {
    local logfile=$1
    local ext_re='_([_a-zA-Z0-9]+) in file\(s\):'
    grep "Unresolved externals" $logfile &> /dev/null || return
    echo "--- Formatted unresolved externals for pasting into YAML config:"
    while IFS= read -r line || [ "$line" ]; do 
        [[ ! $line =~ $ext_re ]] && continue
        name=${BASH_REMATCH[1]}
        echo -n "\"$name\", "
    done < "$logfile"
    echo
}

function print_log_artifacts() {
    local dos_log=$1
    local emu_log=$2
    local bat_log=$3
    local meta_log=$4
    echo "--- dosbuild artifacts ---"
    [ -f "$dos_log" ] && echo "dos log: $dos_log"
    [ -f "$emu_log" ] && echo "emulator log: $emu_log"
    [ -f "$bat_log" ] && echo "bat script: $bat_log"
    [ -f "$meta_log" ] && echo "meta: $meta_log"
}

function host_os() {
    case "$(uname -s)" in
        Linux*) echo "linux" ;;
        CYGWIN*|MINGW*|MSYS*) echo "windows" ;;
        *) echo "other" ;;
    esac
}

function resolve_default_emulator() {
    local os=$1
    local root_dir
    root_dir="$(cd "$(dirname "$0")/.." && pwd)"
    if [ -z "$KVIKDOS_BIN" ] && [ -x "$root_dir/tools/emulators/kvikdos" ]; then
        KVIKDOS_BIN="$root_dir/tools/emulators/kvikdos"
    fi
    if [ -z "$MSDOS_PLAYER_BIN" ] && [ -f "$root_dir/tools/emulators/msdos.exe" ]; then
        MSDOS_PLAYER_BIN="$root_dir/tools/emulators/msdos.exe"
    fi
    if [ -z "$KVIKDOS_BIN" ] && [ -x /home/xor/kvikdos/kvikdos ]; then
        KVIKDOS_BIN=/home/xor/kvikdos/kvikdos
    fi
    if [ -z "$MSDOS_PLAYER_BIN" ] && [ -f /home/xor/kvikdos/msdos.exe ]; then
        MSDOS_PLAYER_BIN=/home/xor/kvikdos/msdos.exe
    fi
    if [ -z "$DOSBOX_BIN" ]; then
        if command -v dosbox >/dev/null 2>&1; then
            DOSBOX_BIN=$(command -v dosbox)
        elif [ -x /opt/dosbox-staging/dosbox ]; then
            DOSBOX_BIN=/opt/dosbox-staging/dosbox
        fi
    fi

    if [ -z "$EMU_BACKEND" ]; then
        if [ "$os" = "linux" ] && [ -x "$KVIKDOS_BIN" ]; then
            EMU_BACKEND="kvikdos"
        elif [ "$os" = "windows" ] && [ -f "$MSDOS_PLAYER_BIN" ]; then
            EMU_BACKEND="msdos"
        elif [ -n "$DOSBOX_BIN" ]; then
            EMU_BACKEND="dosbox"
        elif [ -x "$KVIKDOS_BIN" ]; then
            EMU_BACKEND="kvikdos"
        elif [ -f "$MSDOS_PLAYER_BIN" ]; then
            EMU_BACKEND="msdos"
        else
            EMU_BACKEND="dosbox"
        fi
    fi
}

function run_emulator() {
    local emu_log=$1
    local backend=$2
    shift 2
    case "$backend" in
        dosbox)
            timeout --foreground "${EMU_TIMEOUT}s" env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy "$@" &> "$emu_log"
            ;;
        kvikdos)
            timeout --foreground "${EMU_TIMEOUT}s" "$@" &> "$emu_log"
            ;;
        msdos)
            timeout --foreground "${EMU_TIMEOUT}s" "$@" &> "$emu_log"
            ;;
        *)
            echo "unknown emulator backend: $backend" > "$emu_log"
            return 127
            ;;
    esac
    return $?
}

function classify_emulator_failure() {
    local exit_code=$1
    local emu_log=$2
    if (( exit_code == 124 )); then
        echo "timeout"
        return
    fi
    if (( exit_code == 134 )); then
        if grep -q "Could not initialize video" "$emu_log"; then
            echo "video-init"
            return
        fi
        echo "abort"
        return
    fi
    if (( exit_code == 139 )); then
        echo "segfault"
        return
    fi
    if grep -q "Could not initialize video" "$emu_log"; then
        echo "video-init"
        return
    fi
    if grep -q "pa_write() failed" "$emu_log"; then
        echo "audio-init"
        return
    fi
    if grep -qi "error" "$emu_log"; then
        echo "emulator-error"
        return
    fi
    echo "unknown"
}
HOST_OS="$(host_os)"
resolve_default_emulator "$HOST_OS"
case "$EMU_BACKEND" in
    dosbox)
        [ -n "$DOSBOX_BIN" ] || fatal "Dosbox not installed"
        [ -x "$DOSBOX_BIN" ] || fatal "Configured DOSBox binary is not executable: $DOSBOX_BIN"
        [ -f "$CONF_FILE" ] || fatal "Dosbox configuration file does not exist: $CONF_FILE"
        ;;
    kvikdos)
        [ -n "$KVIKDOS_BIN" ] || fatal "kvikdos binary not configured"
        [ -x "$KVIKDOS_BIN" ] || fatal "Configured kvikdos binary is not executable: $KVIKDOS_BIN"
        ;;
    msdos)
        [ -n "$MSDOS_PLAYER_BIN" ] || fatal "MS-DOS Player binary not configured"
        [ -f "$MSDOS_PLAYER_BIN" ] || fatal "Configured MS-DOS Player binary does not exist: $MSDOS_PLAYER_BIN"
        ;;
    *)
        fatal "Unsupported EMU_BACKEND '$EMU_BACKEND' (use: kvikdos|msdos|dosbox)"
        ;;
esac

# extract tool name (compiler/linker/assembler) and toolchain from cmdline
tool=$1
if [ "$tool" != "test" ]; then
    chain=$2
    { [ "$tool" ] && [ "$chain" ]; } || syntax
    shift 2
    # make sure the toolchain directory exists
    TOOLCHAIN_DIR+="/$chain"
    [ -d "$TOOLCHAIN_DIR" ] || fatal "Toolchain directory does not exist: $TOOLCHAIN_DIR"
    # determine tool executable name based on toolchain type (ms c, turbo c, ...)
    toolok=1
    if [[ $chain =~ ^msc ]]; then
        case $tool in
        cc) tool=cl;;
        link) ;;
        lib) ;;
        *) toolok=0;;
        esac
    elif [[ $chain =~ ^qc ]]; then
        case $tool in
        cc) tool=qcl;;
        link) 
            tool=link
            [ $chain = qc251 ] && tool=qlink
            ;;
        *) toolok=0;;
        esac
    elif [[ $chain =~ ^tc || $chain =~ ^tcpp ]]; then
        case $tool in
        cc) tool=tcc;;
        link) tool=tlink;;
        *) toolok=0;;
        esac
    elif [[ $chain =~ ^bcpp ]]; then
        case $tool in
        cc) tool=bcc;;
        link) tool=tlink;;
        *) toolok=0;;
        esac    
    elif [[ $chain =~ ^masm ]]; then
        case $tool in
        as) tool=masm;;
        *) toolok=0;;
        esac
    elif [[ $chain =~ ^wc ]]; then
        case $tool in
        cc) tool=wcc386;;
        *) toolok=0;;
        esac
    elif [[ $chain =~ ^tasm ]]; then
        case $tool in
        as) tool=tasm;;
        *) toolok=0;;
        esac
    else
        fatal "Toochain not recognized: $chain"
    fi
    ((toolok)) || fatal "Tool '$tool' not supported by toolchain '$chain'"
    tool_exe=$(find -L "$TOOLCHAIN_DIR" -iname "$tool.exe" 2>/dev/null | head -1)
    debug "tool = $tool, chain = $chain, tool_exe = $tool_exe"
    [ -f "$tool_exe" ] || fatal "Unable to find '$tool.exe' in $TOOLCHAIN_DIR"
else
    debug "Running test application"
    shift 1
fi

# extract input, output and flags from cmdline
infiles=''
outfile=''
flags=''
libs=''
argtype=''
until [ -z "$1" ]; do
    arg=$1
    case $arg in
    -i) argtype=i
        ;;
    -o) argtype=o
        ;;
    -f) argtype=f
        ;;
    -l) argtype=l
        ;;
    *)
        case $argtype in
            i) [ "$infiles" ] && infiles+=" "
               infiles+="$arg"
               ;;
            o) 
               [ "$outfile" ] && syntax "More than one output file on cmdline"
               outfile=$arg;
               ;;
            f) 
               [ "$flags" ] && flags+=" "
               flags+="$arg";
               ;;
            l) 
               [ "$libs" ] && libs+=" "
               libs+="$arg";
               ;;
            *) syntax "unrecognized argument: $arg";
        esac
        ;;
    esac
    shift
done
debug "in: '$infiles', out: '$outfile', flags: '$flags', libs: '$libs'"
[ "$infiles" ] || syntax "empty infiles"
if [ "$tool" != "test" ]; then
    [ "$outfile" ] || syntax "empty outfiles"
fi

# examine input and output base directories, must make them available in dosbox
infile_dir=''
infiles_dos=''
libs_dos=''
for f in $infiles; do
    curdir=$(basedir $f)
    if [ -z "$infile_dir" ]; then
        infile_dir=$curdir
    fi
    [ "$infiles_dos" ] && infiles_dos+=" "
    infiles_dos+="$(dossep ${f#${infile_dir}/})"
done
outfile_dir=$(basedir $outfile)
outfile_name=$(basename $outfile)
outfile_noext="${outfile_name%.*}"
rspname=${outfile_noext}.rsp
infile_rsp=$infile_dir/$rspname
outfile_drive='e'
if [ "$infile_dir" = "$outfile_dir" ]; then
    outfile_drive='d'
fi
outfile_dos="${outfile_drive}:\\$(dossep ${outfile#${outfile_dir}/})"
for l in $libs; do
    [ "$libs_dos" ] && libs_dos+=" "
    if [[ "$l" == "${outfile_dir}"* ]]; then
        libs_dos+="${outfile_drive}:\\$(dossep ${l#${outfile_dir}/})"
    else
        libs_dos+="$l"
    fi
done
debug "infile_dir='$infile_dir', infiles_dos='$infiles_dos', outfile_dir='$outfile_dir', outfile_dos='$outfile_dos', libs_dos='$libs_dos', infile_rsp='$infile_rsp'"
if [ "$tool" != "test" ]; then
    [ -d "$infile_dir" ] || fatal "Input directory does not exist: $infile_dir"
    [ -d "$outfile_dir" ] || fatal "Output directory does not exist: $outfile_dir"
    find "$outfile_dir" -maxdepth 1 -iname "$(basename "$outfile")" -exec rm -f {} +
fi
outfile_base="${outfile_dos%.*}"
outfile_map="$outfile_base.map"

# compose tool cmdline in dos based on tool type
cmdline=$tool
case $tool in
    cl|qcl)
        [ "$flags" ] && cmdline+=" $flags"
        cmdline+=" /c /Fo$outfile_dos $infiles_dos"
        ;;
    tcc|bcc)
        [ "$flags" ] && cmdline+=" $flags"
        # compile
        [[ $outfile_dos =~ \.(obj|OBJ) ]] && cmdline+=" -c -o$outfile_dos"
        # link
        [[ $outfile_dos =~ \.(exe|EXE) ]] && cmdline+=" -e$outfile_dos -LC:\\$chain\lib"
        cmdline+=" $infiles_dos"
        ;;        
    link|qlink)
        [ "$flags" ] && cmdline+=" $flags"
        # build response file, get around cmdline length limit
        > $infile_rsp
        count=0
        for o in $infiles_dos; do
            echo -n "$o" >> $infile_rsp
            if ((++count == 8)); then
                echo "+" >> $infile_rsp
                count=0
            else
                echo -n " " >> $infile_rsp
            fi
        done
        if ((count != 8)); then
            echo "" >> $infile_rsp
        fi
        echo "$outfile_dos" >> $infile_rsp
        echo "$outfile_map" >> $infile_rsp
        # libraries can be specified together with the object files, in which case they are called "load libraries" and linked in their entirety,
        # or in this specific section of the command line or response file, when they are "regular libraries" and only the object files required 
        # for external reference resolution will be linked in
        if [ "$libs_dos" ]; then
            echo $libs_dos >> $infile_rsp
        else
            echo ";" >> $infile_rsp
        fi
        if ((DEBUG)); then
        echo "--- $infile_rsp:"
        cat $infile_rsp
        echo "---"
        fi
        cmdline+=" @${rspname}"
        ;;
    lib)
        echo -n "$outfile_dos" > $infile_rsp
        if [ "$flags" ]; then
            echo -n " $flags" >> $infile_rsp
        fi
        count=$(echo $infiles_dos | wc -w)
        idx=1
        for o in $infiles_dos; do
            if ((idx != count)); then
                echo "+$o&" >> $infile_rsp
            else
                echo "+$o" >> $infile_rsp
            fi
            ((++idx))
        done
        echo ";" >> $infile_rsp
        if ((DEBUG)); then
        echo "--- $infile_rsp:"
        cat $infile_rsp
        echo "---"
        fi
        cmdline+=" @${rspname}"
        ;;
    tlink)
        compiler_dir=$TC_DIR
        [ "$flags" ] && cmdline+=" $flags"
        fatal "tlink not implemented"
        # cmdline+=" $infiles_dos,$outfile_dos,,,"
        ;;        
    masm)
        compiler_dir=$MASM_DIR
        [ "$flags" ] && cmdline+=" $flags"
        cmdline+=" $infiles_dos,$outfile_dos,,;"
        ;;
    tasm)
        compiler_dir=$TC_DIR
        [ "$flags" ] && cmdline+=" $flags"
        cmdline+=" $infiles_dos,$outfile_dos,,;"
        ;;        
    wcc386)
        [ "$flags" ] && cmdline+=" $flags"
        cmdline+=" /fo=$outfile_dos $infiles_dos"    
        ;;
    test)
        cmdline=$infiles_dos
        ;;
    *)
        echo "Unrecognized tool: $tool";
        exit 243
        ;;
esac
debug "cmdline: $cmdline"

#echo "--- build running $tool from $chain"
# create dos bat file for launching inside the emulator

if [ "$EMU_BACKEND" = "dosbox" ]; then
cat > $BAT_FILE <<EOF
set PATH=Z:\;C:\\$chain\\bin;C:\\$chain\binb;C:\\$chain\bound;C:\\$chain
set INCLUDE=C:\\$chain\\include
set LIB=C:\\$chain\\lib
mount d $infile_dir
mount e $outfile_dir
mount c "$(dirname "$tool_exe")/../"
d:
$cmdline > LOG.TXT
EOF
else
cat > $BAT_FILE <<EOF
set PATH=C:\\$chain\\bin;C:\\$chain\binb;C:\\$chain\bound;C:\\$chain
set INCLUDE=C:\\$chain\\include
set LIB=C:\\$chain\\lib
$cmdline > LOG.TXT
EOF
fi

if ((DEBUG)); then 
    echo "--- $BAT_FILE"
    cat $BAT_FILE; 
    echo "---"
fi

# remove logfile from previous run if exists to avoid reporting bogus errors in case of build failure
logfile=$infile_dir/LOG.TXT
emu_logfile=build.log
artifact_base=''
artifact_dos_log=''
artifact_emu_log=''
artifact_bat=''
artifact_meta=''
runtime_conf=''
if [ "$tool" != "test" ]; then
    artifact_base="$outfile_dir/${outfile_noext}"
else
    test_name=$(basename $(echo "$infiles" | awk '{print $1}'))
    test_name="${test_name%.*}"
    artifact_base="$infile_dir/${test_name}"
fi
artifact_dos_log="${artifact_base}.dos.log"
artifact_emu_log="${artifact_base}.emu.log"
artifact_bat="${artifact_base}.dosbuild.bat"
artifact_meta="${artifact_base}.dosbuild.meta"
runtime_conf="${artifact_base}.dosbox.runtime.conf"
rm -f $logfile
rm -f $emu_logfile
rm -f "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta" "$runtime_conf"
cp "$BAT_FILE" "$artifact_bat"
{
    echo "tool=$tool"
    [ "$chain" ] && echo "toolchain=$chain"
echo "cwd=$(pwd)"
    echo "infile_dir=$infile_dir"
    [ "$outfile" ] && echo "outfile=$outfile"
    echo "cmdline=$cmdline"
    echo "emulator_backend=$EMU_BACKEND"
    echo "host_os=$HOST_OS"
    echo "dosbox_bin=$DOSBOX_BIN"
    echo "kvikdos_bin=$KVIKDOS_BIN"
    echo "msdos_player_bin=$MSDOS_PLAYER_BIN"
    echo "start_epoch=$(date +%s)"
} > "$artifact_meta"

if [ "$EMU_BACKEND" = "dosbox" ] && [[ "$DOSBOX_BIN" == *dosbox-staging* ]]; then
    cat > "$runtime_conf" <<EOF
[sdl]
output=surface
waitonerror=false

[dosbox]
machine=svga_s3
memsize=16

[cpu]
core=normal
cputype=386
cycles=20000

[mixer]
nosound=true

[dos]
xms=true
ems=true
umb=true
EOF
fi
# start bat file in emulator in headless mode
[ "$tool" != "test" ] && echo "$cmdline"
if [ "$EMU_BACKEND" = "dosbox" ]; then
    if [[ "$DOSBOX_BIN" == *dosbox-staging* ]]; then
        emu_args=(--noprimaryconf --nolocalconf -conf "$runtime_conf" --set output=surface --set waitonerror=false)
    else
        emu_args=(-conf "$CONF_FILE")
    fi
    if [ -n "$DOSBOX_EXTRA_ARGS" ]; then
        # shellcheck disable=SC2206
        extra_args=($DOSBOX_EXTRA_ARGS)
        emu_args+=("${extra_args[@]}")
    fi
    emu_args+=("$BAT_FILE" -exit 24)
    run_emulator "$emu_logfile" "$EMU_BACKEND" "$DOSBOX_BIN" "${emu_args[@]}"
elif [ "$EMU_BACKEND" = "kvikdos" ]; then
    emu_tool_root="$(pwd)/dos/$chain"
    if [ -n "$tool_exe" ]; then
        emu_tool_root="$(dirname "$tool_exe")/../"
    fi
    kvikdos_args=(
        "--mount=c:$emu_tool_root"
        "--mount=d:$infile_dir/"
        "--mount=e:$outfile_dir/"
        "--drive=d"
        "--cwd-dos=D:\\"
        "--prog=D:\\$(basename "$BAT_FILE")"
    )
    run_emulator "$emu_logfile" "$EMU_BACKEND" "$KVIKDOS_BIN" "${kvikdos_args[@]}" "$BAT_FILE"
elif [ "$EMU_BACKEND" = "msdos" ]; then
    if [ "$HOST_OS" = "linux" ] && [ "$MSDOS_USE_WINE" = "1" ]; then
        run_emulator "$emu_logfile" "$EMU_BACKEND" wine "$MSDOS_PLAYER_BIN" "$BAT_FILE"
    else
        run_emulator "$emu_logfile" "$EMU_BACKEND" "$MSDOS_PLAYER_BIN" "$BAT_FILE"
    fi
fi
emu_exit=$?
emu_failure=$(classify_emulator_failure "$emu_exit" "$emu_logfile")
[ -f "$logfile" ] && cp "$logfile" "$artifact_dos_log"
[ -f "$emu_logfile" ] && cp "$emu_logfile" "$artifact_emu_log"
if (( emu_exit != 0 )); then
    echo "emulator_failure=$emu_failure" >> "$artifact_meta"
    echo "emulator_exit=$emu_exit" >> "$artifact_meta"
    if [ "$emu_failure" = "timeout" ]; then
        echo "Error: emulator timed out after ${EMU_TIMEOUT}s"
    else
        echo "Error: emulator failed ($emu_failure)"
    fi
    echo "Emulator exited with error code: $emu_exit"
    print_log_artifacts "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta"
    exit $emu_exit
fi
echo "emulator_failure=none" >> "$artifact_meta"
echo "emulator_exit=0" >> "$artifact_meta"

# check if successful by examining if output file exists (case-insensitive check)
if [ "$tool" != "test" ]; then
    # Case-insensitive search for output file
    outfile_found=$(find "$outfile_dir" -maxdepth 1 -iname "$(basename "$outfile")" -newermt "@$(grep '^start_epoch=' "$artifact_meta" | cut -d= -f2)" -print -quit)
    if [ -z "$outfile_found" ]; then
        if [ -f "$logfile" ]; then
            cat $logfile;
        else
            cat $emu_logfile
            echo "Build failed and no output file found, check emulator configuration"
        fi
        echo "outfile_status=missing_or_stale" >> "$artifact_meta"
        print_log_artifacts "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta"
        exit 244;
    else
        # Use the found file path
        outfile="$outfile_found"
        echo "outfile_status=fresh" >> "$artifact_meta"
        echo "outfile_found=$outfile" >> "$artifact_meta"
    fi
    # the linker can create an output file even in presence of errors so check log
    if grep -i "error" $logfile &> /dev/null; then
        rm $outfile
        cat $logfile;
        # special handling for MS C linker output
        [[ $chain =~ ^msc && $tool = "link" ]] && output_unresolved "$logfile"
        print_log_artifacts "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta"
        exit 245;
    fi
    if grep -ie "warning" $logfile &> /dev/null || ((VERBOSE)); then
        cat $logfile;
    fi
    print_log_artifacts "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta"
else
    cat $logfile
    print_log_artifacts "$artifact_dos_log" "$artifact_emu_log" "$artifact_bat" "$artifact_meta"
    grep -ie "failed" $logfile &> /dev/null && exit 1
fi

debug "success"
exit 0
