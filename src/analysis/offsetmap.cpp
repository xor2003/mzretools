#include "analysis/offsetmap.h"
#include <sstream>

OffsetMap::OffsetMap(const Size maxData) : maxData(maxData) {}

OffsetMap::OffsetMap() : maxData(0) {}

Address OffsetMap::getCode(const Address &from) {
    if (codeMap.count(from)) {
        return codeMap.at(from).targetAddress;
    }
    return Address();
}

bool OffsetMap::codeMatch(const Address from, const MappingInfo& newMapping) {
    // Check if source is already mapped to a different target
    if (codeMap.count(from)) {
        const MappingInfo& existingMapping = codeMap.at(from);
        if (existingMapping.targetAddress != newMapping.targetAddress) {
            return false;
        }
        return true; // Already mapped to same target
    }

    // Check if target is already mapped to a different source
    for (const auto& entry : codeMap) {
        if (entry.second.targetAddress == newMapping.targetAddress && entry.first != from) {
            return false;
        }
    }

    // Create new mapping
    codeMap[from] = newMapping;
    return true;
}

bool OffsetMap::dataMatch(const SOffset from, const SOffset to) {
    // Check if source is already mapped to a different target
    // Check if source is already mapped to a different target
    if (dataMap.count(from)) {
        const auto& existing = dataMap[from];
        for (const auto& offset : existing) {
            if (offset == to) {
                return true; // Already mapped to same target
            }
        }
        
        // Check if we've reached the maximum number of mappings for this source
        if (existing.size() >= maxData) {
            return false;
        }
    }

    // Count how many times this target has been mapped from any source
    Size targetCount = 0;
    for (const auto& [src, targets] : dataMap) {
        for (const auto& target : targets) {
            if (target == to) {
                targetCount++;
            }
        }
    }

    // Check if target has reached maxData mappings
    if (targetCount >= maxData) {
        return false;
    }

    // Create new mapping
    dataMap[from].push_back(to);
    return true;
}

bool OffsetMap::stackMatch(const SOffset from, const SOffset to) {
    // Check if source is already mapped to a different target
    if (stackMap.count(from)) {
        const auto& existing = stackMap[from];
        if (existing != to) {
            return false;
        }
        return true; // Already mapped to same target
    }

    // Check if target is already mapped to a different source
    for (const auto& entry : stackMap) {
        if (entry.second == to && entry.first != from) {
            return false;
        }
    }

    // Create new mapping
    stackMap[from] = to;
    return true;
}

void OffsetMap::resetStack() {
    stackMap.clear();
}

void OffsetMap::addSegment(const Segment &seg) {
    segments.push_back(seg);
}

std::string OffsetMap::dataStr(const MapSet &ms) const {
    std::ostringstream oss;
    for (auto offset : ms) oss << std::hex << offset << " ";
    return oss.str();
}