#pragma once
#include "Brinicle/Kernel/KernelFactory.h"
#include <memory>

namespace Brinicle {
std::unique_ptr<KernelFactory> make_kernel_factory();
}
