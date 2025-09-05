#include "dos/analysis.h"
#include "dos/opcodes.h"
#include "dos/output.h"
#include "dos/util.h"
#include "dos/error.h"
#include "dos/executable.h"
#include "dos/editdistance.h"
#include "dos/security.h"
#include "dos/instruction.h"
// Functions moved to analyzer.cpp

#include <iostream>
#include <istream>
#include <sstream>
#include <algorithm>
#include <fstream>
#include <string>
#include <cstring>
#include <map>

using namespace std;

#ifdef DEBUG
#define DUMP_REGS(regs) debug(regs.toString())
#else
#define DUMP_REGS(regs)
#endif

OUTPUT_CONF(LOG_ANALYSIS)

void searchMessage(const Address &addr, const string &msg) {
    output(addr.toString() + ": " + msg, LOG_ANALYSIS, LOG_DEBUG);
}


// dictionary of equivalent instruction sequences for variant-enabled comparison
// TODO: support user-supplied equivalence dictionary 
// TODO: do not hardcode, place in text file
// TODO: automatic reverse match generation
// TODO: replace strings with Instruction-s/Signature-s, support more flexible matching?
static const map<string, vector<vector<string>>> INSTR_VARIANT = {
    { "add sp, 0x2", { 
            { "pop cx" }, 
            { "inc sp", "inc sp" },
        },
    },
    { "add sp, 0x4", { 
            { "pop cx", "pop cx" }, 
        },
    },
    { "sub ax, ax", { 
            { "xor ax, ax" }, 
        },
    },    
};


struct Duplicate {
    Distance distance;
    Size refSize, tgtSize, dupIdx;
    vector<Block> dupBlocks;

    Duplicate(const Distance distance, const Size refSize, const Size tgtSize, const Size dupIdx) : distance(distance), refSize(refSize), tgtSize(tgtSize), dupIdx(dupIdx) {}
    Duplicate(const Distance distance) : Duplicate(distance, 0, 0, BAD_ROUTINE) {}
    Duplicate() : Duplicate(MAX_DISTANCE) {}
    bool isValid() const { return distance != MAX_DISTANCE; }
    void clear() { distance = MAX_DISTANCE; }
    string toString() const {
        ostringstream str;
        str << "distance = " << distance << ", size ref: " << refSize << " tgt: " << tgtSize << ", idx: " << dupIdx;
        return str.str();
    }
};
