#pragma once

#include <c10/core/ScalarType.h>
#include <torch/extension.h>
#include <torch/csrc/Export.h>
#include <torch/csrc/python_headers.h>

TORCH_API extern PyTypeObject THPDtypeType;

namespace torch {
namespace jit {
void initJITFuncTsModuleBindings(py::module m);
}
} // namespace torch