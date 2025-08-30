#!/usr/bin/bash
set -exu
make clean
#make build/3DOBJECT.pat

#/home/xor/games/f15se2-re/mzretools/tools/compare_pat.py build/3DOBJECT.pat /home/xor/games/f15se2-re/target_3DOBJECT.pat

#make build/3DPLANES.pat

#/home/xor/games/f15se2-re/mzretools/tools/compare_pat.py build/3DPLANES.pat /home/xor/games/f15se2-re/target_3DPLANES.pat

#make build/AWACS.pat

#/home/xor/games/f15se2-re/mzretools/tools/compare_pat.py build/AWACS.pat /home/xor/games/f15se2-re/target_AWACS.pat

#make build/NJOYCAL.pat

#/home/xor/games/f15se2-re/mzretools/tools/compare_pat.py build/NJOYCAL.pat /home/xor/games/f15se2-re/target_NJOYCAL.pat

make build/FLTMATH.pat

/home/xor/games/f15se2-re/mzretools/tools/compare_pat.py build/FLTMATH.pat /home/xor/games/f15se2-re/target_FLTMATH.pat
