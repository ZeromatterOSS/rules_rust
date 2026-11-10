#include <iostream>
#include <unwind.h>

extern "C" const void *binary_unwinder() {
    return reinterpret_cast<const void *>(&_Unwind_RaiseException);
}

extern "C" const void *binary_cout() { return &std::cout; }
