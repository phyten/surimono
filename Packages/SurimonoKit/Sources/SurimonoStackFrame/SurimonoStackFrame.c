#include "SurimonoStackFrame.h"

// Not inlined, so that the frame is this function's own, one call below the caller.
__attribute__((noinline)) uintptr_t surimono_frame_address(void) {
    return (uintptr_t)__builtin_frame_address(0);
}
