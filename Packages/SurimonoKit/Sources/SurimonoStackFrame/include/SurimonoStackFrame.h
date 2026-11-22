#ifndef SURIMONO_STACK_FRAME_H
#define SURIMONO_STACK_FRAME_H

#include <stdint.h>

/// The address of the caller's frame on the thread's own stack. Swift cannot take it: the address of a local can be
/// moved to a heap-allocated fake stack by AddressSanitizer, and then says nothing about the stack left.
uintptr_t surimono_frame_address(void);

#endif
