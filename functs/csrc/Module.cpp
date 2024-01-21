#include <vector>
#include <torch/extension.h>

#include <functs/csrc/jit/python/init.h>
#include <functs/csrc/jit/python/script_init.h>
#include <functs/csrc/jit/tensorexpr/lowerings.h>

#include <fuser/nnc_func.h>
#include <passes/refine_types.h>
#include <passes/fuse_ops.h>
#include <passes/canonicalize.h>

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  torch::jit::faitInitCanonicalizeOps();
  torch::jit::faitInitShapeInferOperator();
  torch::jit::faitInitFusableOps();
  torch::jit::tensorexpr::faitInitNNCLoweringFunc();
  torch::jit::tensorexpr::faitInitNNCShapeFunc();
  torch::jit::tensorexpr::init_nnc_ext();
  torch::jit::initJITFuncTsBindings(m);
  torch::jit::initJITFuncTsModuleBindings(m);
}


