#ifndef DOS_SECURITY_H
#define DOS_SECURITY_H

#include <cstdint>
#include <stdexcept>
#include <cstring>

namespace Security {

/**
 * Safe memory access utilities to prevent buffer overflows
 */
class SafeAccess {
public:
    /**
     * Safely read a value from memory with bounds checking
     * @param data Pointer to the data buffer
     * @param offset Offset to read from
     * @param size Total size of the buffer
     * @return The value at the specified offset
     * @throws std::out_of_range if offset is out of bounds
     */
    template<typename T>
    static T safeRead(const uint8_t* data, size_t offset, size_t size) {
        if (offset + sizeof(T) > size) {
            throw std::out_of_range("Memory access out of bounds");
        }
        T value;
        std::memcpy(&value, data + offset, sizeof(T));
        return value;
    }

    /**
     * Safely read a 16-bit little-endian value from memory
     * @param data Pointer to the data buffer
     * @param offset Offset to read from
     * @param size Total size of the buffer
     * @return The 16-bit value at the specified offset
     * @throws std::out_of_range if offset is out of bounds
     */
    template<typename T>
    static T safeRead16(const uint8_t* data, size_t offset, size_t size) {
        if (offset + 2 > size) {
            throw std::out_of_range("Memory access out of bounds");
        }
        return static_cast<T>(data[offset] | (data[offset + 1] << 8));
    }

    /**
     * Check if a memory range is valid
     * @param data Pointer to the data buffer
     * @param offset Starting offset
     * @param length Length of the range
     * @param size Total size of the buffer
     * @return true if the range is valid, false otherwise
     */
    static bool isValidRange(const uint8_t* data, size_t offset, size_t length, size_t size) {
        if (!data) return false;
        if (offset > size) return false;
        if (length > size - offset) return false;
        return true;
    }

    /**
     * Clamp an offset to valid range
     * @param offset Input offset
     * @param size Total buffer size
     * @return Clamped offset (guaranteed to be < size)
     */
    static size_t clampOffset(size_t offset, size_t size) {
        return (offset >= size) ? (size - 1) : offset;
    }
};

// Convenience aliases for the SafeAccess methods
template<typename T>
T safeRead(const uint8_t* data, size_t offset, size_t size) {
    return SafeAccess::safeRead<T>(data, offset, size);
}

template<typename T>
T safeRead16(const uint8_t* data, size_t offset, size_t size) {
    return SafeAccess::safeRead16<T>(data, offset, size);
}

} // namespace Security

#endif // DOS_SECURITY_H