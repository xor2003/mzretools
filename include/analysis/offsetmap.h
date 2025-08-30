#ifndef ANALYSIS_OFFSETMAP_H
#define ANALYSIS_OFFSETMAP_H

#include <map>
#include <vector>
#include <string>
#include "dos/address.h"
#include "dos/types.h"

struct MappingInfo {
    Address targetAddress;
    Address sourceInstructionAddress;
    std::string sourceInstructionStr;
};

class OffsetMap {
    using MapSet = std::vector<SOffset>;
    Size maxData;
    std::map<Address, MappingInfo> codeMap;
    std::map<SOffset, std::vector<SOffset>> dataMap;
    std::map<SOffset, SOffset> stackMap;
    std::vector<Segment> segments;

public:
    explicit OffsetMap(const Size maxData);
    OffsetMap();
    
    Address getCode(const Address &from);
    bool codeMatch(const Address from, const MappingInfo& newMapping);
    bool dataMatch(const SOffset from, const SOffset to);
    bool stackMatch(const SOffset from, const SOffset to);
    
    void resetStack();
    void addSegment(const Segment &seg);

private:
    std::string dataStr(const MapSet &ms) const;
};

#endif // ANALYSIS_OFFSETMAP_H