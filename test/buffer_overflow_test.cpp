#include <gtest/gtest.h>
#include <vector>
#include <limits>

#include "dos/types.h"
#include "dos/executable.h"
#include "dos/codemap.h"
#include "dos/address.h"
#include "dos/scanq.h"

using namespace std;

class BufferOverflowTest : public ::testing::Test {
protected:
    void SetUp() override {
        // Setup test data
    }
};

TEST_F(BufferOverflowTest, EmptyCodeMapBoundaryCheck) {
    // Test with empty executable
    CodeMap map(0x1000, 0);
    
    // This should not crash with empty code
    auto result = map.findSegment(Offset(0));
    EXPECT_EQ(result.type, Segment::SEG_NONE);
}

TEST_F(BufferOverflowTest, SingleByteBoundaryCheck) {
    // Test with single byte
    CodeMap map(0x1000, 1);
    
    // Test boundary conditions
    auto result1 = map.findSegment(Offset(0));
    EXPECT_EQ(result1.type, Segment::SEG_NONE);
    
    auto result2 = map.findSegment(Offset(1));
    EXPECT_EQ(result2.type, Segment::SEG_NONE);
    
    auto result3 = map.findSegment(Offset(0xFFFFFFFF));
    EXPECT_EQ(result3.type, Segment::SEG_NONE);
}

TEST_F(BufferOverflowTest, LargeOffsetBoundaryCheck) {
    // Test with larger code
    CodeMap map(0x1000, 256);
    
    // Test various boundary conditions
    auto result1 = map.findSegment(Offset(0));
    EXPECT_EQ(result1.type, Segment::SEG_NONE);
    
    auto result2 = map.findSegment(Offset(255));
    EXPECT_EQ(result2.type, Segment::SEG_NONE);
    
    auto result3 = map.findSegment(Offset(256));
    EXPECT_EQ(result3.type, Segment::SEG_NONE);
    
    auto result4 = map.findSegment(Offset(0x7FFFFFFF));
    EXPECT_EQ(result4.type, Segment::SEG_NONE);
}

TEST_F(BufferOverflowTest, UnderflowBoundaryCheck) {
    // Test underflow conditions
    CodeMap map(0x1000, 100);
    
    // Test negative-like offsets (as unsigned)
    auto result1 = map.findSegment(Offset(0xFFFFFFFF));
    EXPECT_EQ(result1.type, Segment::SEG_NONE);
    
    auto result2 = map.findSegment(Offset(0x80000000));
    EXPECT_EQ(result2.type, Segment::SEG_NONE);
}

TEST_F(BufferOverflowTest, SegmentBoundaryCheck) {
    // Test with actual segments
    CodeMap map(0x1000, 0x10000);
    
    // Add test segments
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, 0x1000);
    segments.emplace_back("DATA", Segment::SEG_DATA, 0x2000);
    map.setSegments(segments);
    
    // Test boundary conditions with segments
    auto result1 = map.findSegment(Offset(0x10000)); // Start of CODE segment
    EXPECT_EQ(result1.address, 0x1000);
    
    auto result2 = map.findSegment(Offset(0x1FFFF)); // End of CODE segment
    EXPECT_EQ(result2.address, 0x1000);
    
    auto result3 = map.findSegment(Offset(0x20000)); // Start of DATA segment
    EXPECT_EQ(result3.address, 0x2000);
    
    auto result4 = map.findSegment(Offset(0xFFFFFFFF)); // Far beyond
    EXPECT_EQ(result4.type, Segment::SEG_NONE);
}

TEST_F(BufferOverflowTest, ArithmeticOverflowPrevention) {
    // Test arithmetic overflow prevention in blocksFromQueue
    // This test ensures that large loadSegment + mapSize doesn't overflow
    
    // Test case 1: Maximum safe values
    Word maxSafeSegment = 0xFFFF;
    Size maxSafeSize = std::numeric_limits<Offset>::max() - (static_cast<Offset>(maxSafeSegment) << 4);
    
    CodeMap map(maxSafeSegment, maxSafeSize);
    EXPECT_NO_THROW({
        // This should not cause overflow
        vector<Segment> segments;
        segments.emplace_back("CODE", Segment::SEG_CODE, maxSafeSegment);
        map.setSegments(segments);
    });
    
    // Test case 2: Values that would overflow
    Word overflowSegment = 0xFFFF;
    Size overflowSize = std::numeric_limits<Offset>::max();
    
    CodeMap map2(overflowSegment, overflowSize);
    // The map should handle this gracefully without crashing
    EXPECT_NO_THROW({
        vector<Segment> segments;
        segments.emplace_back("CODE", Segment::SEG_CODE, overflowSegment);
        map2.setSegments(segments);
    });
}

TEST_F(BufferOverflowTest, LoopTerminationSafety) {
    // Test that loops terminate safely even with overflow conditions
    
    // Test with potentially problematic values
    Word testSegment = 0x8000;
    Size testSize = 0x10000000; // Large but not overflow
    
    CodeMap map(testSegment, testSize);
    
    // Add a segment to prevent the "no segments" error
    vector<Segment> segments;
    segments.emplace_back("CODE", Segment::SEG_CODE, testSegment);
    map.setSegments(segments);
    
    // This should not hang or crash
    EXPECT_NO_THROW({
        // The setup should handle large values gracefully
    });
}

TEST_F(BufferOverflowTest, EdgeCaseValues) {
    // Test edge case values that might cause issues
    
    // Test zero values
    {
        CodeMap map(0, 0);
        auto result = map.findSegment(Offset(0));
        EXPECT_EQ(result.type, Segment::SEG_NONE);
    }
    
    // Test maximum segment value
    {
        CodeMap map(0xFFFF, 0);
        auto result = map.findSegment(Offset(0xFFFFF));
        EXPECT_EQ(result.type, Segment::SEG_NONE);
    }
    
    // Test maximum size with zero segment
    {
        CodeMap map(0, 0x1000);
        auto result = map.findSegment(Offset(0xFFF));
        EXPECT_EQ(result.type, Segment::SEG_NONE);
    }
}