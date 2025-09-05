#include <gtest/gtest.h>
#include "dos/codemap.h"
#include "dos/address.h"

using namespace std;

class CodeMapTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Setup common test data
    }
};

TEST_F(CodeMapTest, FindSegmentByOffset_Basic) {
    // Create a CodeMap with known segments
    CodeMap map(0x1000, 0x10000);
    
    // Add test segments
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    segments.emplace_back("DATA", Segment::SEG_DATA, 0x2000);
    segments.emplace_back("STACK", Segment::SEG_STACK, 0x3000);
    map.setSegments(segments);
    
    // Test finding segments by offset
    // Segment 0x1000 starts at offset 0x10000 (0x1000 << 4)
    Offset codeStart = SEG_TO_OFFSET(0x1000);
    Offset dataStart = SEG_TO_OFFSET(0x2000);
    Offset stackStart = SEG_TO_OFFSET(0x3000);
    
    // Test exact segment start
    EXPECT_EQ(map.findSegment(codeStart).address, 0x1000);
    EXPECT_EQ(map.findSegment(dataStart).address, 0x2000);
    EXPECT_EQ(map.findSegment(stackStart).address, 0x3000);
    
    // Test offset within segment (should find the segment)
    EXPECT_EQ(map.findSegment(codeStart + 0x1234).address, 0x1000);
    EXPECT_EQ(map.findSegment(dataStart + 0x5678).address, 0x2000);
    
    // Test offset at segment boundary (should find the segment)
    EXPECT_EQ(map.findSegment(codeStart + 0xFFFF).address, 0x1000);
    
    // Test offset just past segment (should find next segment)
    Segment beyond = map.findSegment(codeStart + 0x10000);
    EXPECT_TRUE(beyond.address == 0x2000 || beyond.type == Segment::SEG_NONE);
    
    // Test offset before any segment (should return empty segment)
    EXPECT_EQ(map.findSegment(codeStart - 1).type, Segment::SEG_NONE);
}

TEST_F(CodeMapTest, FindSegmentByOffset_EdgeCases) {
    CodeMap map(0x1000, 0x10000);
    
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    map.setSegments(segments);
    
    Offset codeStart = SEG_TO_OFFSET(0x1000);
    
    // Test maximum valid offset within segment
    EXPECT_EQ(map.findSegment(codeStart + 0xFFFF).address, 0x1000);
    
    // Test edge case: offset exactly at segment end
    EXPECT_EQ(map.findSegment(codeStart + 0x10000 - 1).address, 0x1000);
    
    // Test edge case: offset just beyond segment
    Segment beyond = map.findSegment(codeStart + 0x10000);
    EXPECT_TRUE(beyond.address != 0x1000 || beyond.type == Segment::SEG_NONE);
}

TEST_F(CodeMapTest, FindSegmentByOffset_UnderflowBug) {
    // This test specifically targets the underflow bug that was fixed
    CodeMap map(0x1000, 0x10000);
    
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    segments.emplace_back("DATA", Segment::SEG_DATA, 0x2000);
    map.setSegments(segments);
    
    Offset codeStart = SEG_TO_OFFSET(0x1000);
    
    // Test the underflow scenario: offset less than segment start
    // Before fix: this would cause integer underflow in (off - segOff)
    // After fix: should correctly return empty segment
    Segment result = map.findSegment(codeStart - 1);
    EXPECT_EQ(result.type, Segment::SEG_NONE);
    
    // Test offset between segments
    result = map.findSegment(codeStart + 0x10000);
    EXPECT_TRUE(result.address == 0x2000 || result.type == Segment::SEG_NONE);
}

TEST_F(CodeMapTest, FindSegmentByOffset_PastMode) {
    CodeMap map(0x1000, 0x10000);
    
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    segments.emplace_back("DATA", Segment::SEG_DATA, 0x2000);
    map.setSegments(segments);
    
    Offset codeStart = SEG_TO_OFFSET(0x1000);
    Offset dataStart = SEG_TO_OFFSET(0x2000);
    
    // Test past mode - should find next segment
    EXPECT_EQ(map.findSegment(codeStart - 1, true).address, 0x1000);
    EXPECT_EQ(map.findSegment(codeStart + 0x1234, true).address, 0x2000);
    EXPECT_EQ(map.findSegment(dataStart - 1, true).address, 0x2000);
}

TEST_F(CodeMapTest, FindSegmentByOffset_SingleSegment) {
    CodeMap map(0x1000, 0x10000);
    
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    map.setSegments(segments);
    
    Offset codeStart = SEG_TO_OFFSET(0x1000);
    
    // Test all positions within the single segment
    EXPECT_EQ(map.findSegment(codeStart).address, 0x1000);
    EXPECT_EQ(map.findSegment(codeStart + 1).address, 0x1000);
    EXPECT_EQ(map.findSegment(codeStart + 0x8000).address, 0x1000);
    EXPECT_EQ(map.findSegment(codeStart + 0xFFFF).address, 0x1000);
    
    // Test positions outside the segment
    EXPECT_EQ(map.findSegment(codeStart - 1).type, Segment::SEG_NONE);
    EXPECT_EQ(map.findSegment(codeStart + 0x10000).type, Segment::SEG_NONE);
}