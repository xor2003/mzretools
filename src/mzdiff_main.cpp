#include "dos/analysis.h"
#include "dos/output.h"
#include "dos/util.h"
#include "dos/error.h"
#include "dos/executable.h"

#include <iostream>
#include <string>

using namespace std;

int main(int argc, char *argv[]) {
    const Word loadSeg = 0x0;
    setOutputLevel(LOG_WARN);
    setModuleVisibility(LOG_CPU, false);
    if (argc < 3) {
        usage();
    }
    // parse cmdline args
    Analyzer::Options opt;
    string baseSpec, pathMap, compareSpec, dataSegment, pathTmap;
    int posarg = 0;
    for (int aidx = 1; aidx < argc; ++aidx) {
        string arg(argv[aidx]);
        if (arg == "--debug") setOutputLevel(LOG_DEBUG);
        else if (arg == "--verbose") setOutputLevel(LOG_VERBOSE);
        else if (arg == "--dbgcpu") setModuleVisibility(LOG_CPU, true);
        else if (arg == "--idiff") opt.ignoreDiff = true;
        else if (arg == "--nocall") opt.noCall = true;
        else if (arg == "--asm") opt.checkAsm = true;
        else if (arg == "--nostat") opt.noStats = true;
        else if (arg == "--rskip") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --rskip");
            opt.refSkip = stoi(argv[++aidx], nullptr, 10);
        }
        else if (arg == "--tskip") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --tskip");
            opt.tgtSkip = stoi(argv[++aidx], nullptr, 10);
        }
        else if (arg == "--ctx") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --ctx");
            opt.ctxCount = stoi(argv[++aidx], nullptr, 10);
        }
        else if (arg == "--dctx") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --dctx");
            opt.dataCtxCount = stoi(argv[++aidx], nullptr, 10);
        }        
        else if (arg == "--map") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --map");
            pathMap = argv[++aidx];
            opt.mapPath = pathMap;
        }
        else if (arg == "--tmap") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --tmap");
            pathTmap = argv[++aidx];
        }
        else if (arg == "--loose") opt.strict = false;
        else if (arg == "--variant") opt.variant = true;
        else if (arg == "--data") {
            if (aidx + 1 >= argc) fatal("Option requires an argument: --data");
            dataSegment = argv[++aidx];
        }
        else if (arg == "--extdata") opt.extData = true;
        else if (arg.starts_with("--")) fatal("Unrecognized option: " + arg);
        else { // positional arguments
            switch (++posarg) {
            case 1: baseSpec = arg; break;
            case 2: compareSpec = arg; break;
            default: fatal("Unrecognized argument: " + arg);
            }
        }
    }
    // actually do stuff
    bool compareResult = false;
    try {
        Executable exeBase = loadExe(baseSpec, loadSeg, opt, true);
        Executable exeCompare = loadExe(compareSpec, loadSeg, opt, false);
        CodeMap map;
        if (!pathMap.empty()) {
            map = { pathMap, loadSeg };
        } 
        Analyzer a{opt};
        // code comparison
        if (dataSegment.empty()) {
            compareResult = a.compareCode(exeBase, exeCompare, map);
        }
        // data comparison
        else {
            CodeMap tgtMap;
            if (pathMap.empty()) fatal("Data comparison needs a map of the reference executable, use --map");
            if (pathTmap.empty()) {
                pathTmap = replaceExtension(pathMap, "tgt");
                if (!checkFile(pathTmap).exists) fatal("No target map provided with --tmap for data comparison and guessed location " + pathTmap + " does not exist");
                verbose("Using guessed target map location: " + pathTmap);
            }
            tgtMap = { pathTmap, loadSeg };
            compareResult = a.compareData(exeBase, exeCompare, map, tgtMap, dataSegment);
        }
    }
    catch (Error &e) {
        fatal(e.why());
    }
    catch (std::exception &e) {
        fatal(string(e.what()));
    }    
    catch (...) {
        fatal("Unknown exception");
    }
    return compareResult ? 0 : 1;
}