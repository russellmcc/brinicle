#pragma once

#define MACRO_JOIN_HELPER(a, b) a##b
#define MACRO_JOIN(a, b) MACRO_JOIN_HELPER(a, b)

#define MACRO_STRING_HELPER(a) #a
#define MACRO_STRING(a) MACRO_STRING_HELPER(a)
