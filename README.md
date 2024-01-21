# FuncTs：TorchScript Functionalization

- ***paper correction***
  - [Figure 2](./docs/imgs/ControlDependencyMemoryDependency.png): `%b.5`->`%b.1.`
- ***paper notation***
  - [Figure 3](./docs/imgs/TensorSSAExample.png): In (c), the number before `immut::Access`, `immut::Assign` and `tensorssa::Update` is the line number in (d). We illustrate more details of [Figure 3](./docs/imgs/TensorSSAExample.png) in this README file.

## Bulid from source

- dependency: PyTorch is all you need to compile `functs`:
  - supported PyTorch verison: V2.1.0

```shell
pip install torch==2.1.0
pip install torchvision==0.16.0 (optional)
```

- build functs from source

```python
git clone https://github.com/functs-project/functs.git --recursive
python setup.py develop --user
```

## Observation

We have discovered that numerous standard workloads are written using imperative tensor programs, which do not lend themselves well to direct
kernel fusion. While the compute library developed by hardware vendors adequately supports pure function, computation-intensive operators, imperative tensor programs often contain excessive control flow and side effects due to tensor-level mutation (such as view and in-place operators), resulting in limited fusion scope. The following timeline illustrates the proportion of time dedicated to these aspects in eight different workloads:

![proportation](./docs/imgs/post_ratio.jpg)

## Use FuncTs to perform functionalization

A [simple example](./examples/get_started.py) of functionalization beyond control flow is depicted as follows:

![T](docs/imgs/TensorSSAExample.png)

We split the algorithm into two steps:

- **Rewrite Mutation** (c). The **Rewrite Mutation** step includes two key steps:
  - **Pass Up**. In the **pass-up** step, suppose `v` is a view of `t`, the algorithm traverses the view path from `v` to `t`. When each variable is visited, an `x′ = immut::Assign(x, v′, [·])` operator is inserted into the program.
  - **Pass Down**. In the **pass-down** step, we traverse from the root node `v` to another branch that hasn't traversed by the pass-up step, while each variable is firstly visited, a `v′ = immgt::Access(x′, [·])` operator is inserted. To annotate the tensor version for subsequent block propagation, a `tensorssa::Update(v′, v)` statement is generated at the same time.
- **Block Propagation** (d). The **Block Propagation** step visits all generated `tensorssa::Update(x′,x)`, propagating the tensor mutation beyond the control flow.

By these steps, we generate a new graph. Accordingly, **we can explore a larger kernel fusion optimization space than the previous methods**.

### Tensor `Access` and Tensor `Assign`

As mentioned above, we generate `Access` and `Assign` operators during transformation. The `Access` operator is the immutable version of the `view` operator. The `Assign` operator is for generating immutable equivalent substitution of `view` and `mutation` combining with the `Access` operator. The figure below depicts the execution process of `aten::view`, `immut::Access` and `immut::Assign` operators.

![view_access_assign](./docs/imgs/VIEW_ACCESS_ASSIGN.png)

The `Access` and `Assign` operators  are two abstractions of a series of [operator instances](./functs/csrc/jit/ir/symbol_ext.h), which are shown in the table below.

| operator            | Access operator      | Assign Operator          |
| ------------------- | -------------------- | ------------------------ |
| `aten::copy_`     | `immut::Assign`    | `immut::Assign`        |
| `aten::select`    | `immut::select`    | `immut::select_rev`    |
| `aten::slice`     | `immut::slice`     | `immut::slice_rev`     |
| `aten::squeeze`   | `immut::squeeze`   | `immut::unsqueeze`     |
| `aten::unsqueeze` | `immut::unsqueeze` | `immut::squeeze`       |
| `aten::view`      | `immut::view`      | `immut::view`          |
| `aten::reshape`   | `immut::reshape`   | `immut::reshape`       |
| `aten::expand`    | `immut::expand`    | `immut::expand_rev`    |
| `aten::expand_as` | `immut::expand_as` | `immut::expand_as_rev` |
| `aten::repeat`    | `immut::repeat`    | `immut::repeat_rev`    |
| `aten::index`     | `immut::index`     | `immut::index_rev`     |

### More Details

For learning or using `FuncTs`, you can functionalize the program step by step with our pass. The original python code is:

```python
def func(a: torch.Tensor, b: torch.Tensor, n: int):
  a = a.clone()
  b = b.clone()
  for i in range(n):
    b[i] = b[i] + 1
  return b
```

We can dump the `torch.Graph` IR generated by `torch.jit.script` here.

```ruby
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %28 : bool = prim::Constant[value=0]()
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
   = prim::Loop(%n.1, %12) # examples/get_started.py:13:2
    block0(%i.1 : int):
      %19 : Tensor = aten::select(%b.5, %18, %i.1) # examples/get_started.py:14:11
      %22 : Tensor = aten::add(%19, %20, %20) # examples/get_started.py:14:11
      %27 : Tensor = aten::select(%b.5, %18, %i.1) # examples/get_started.py:14:4
      %29 : Tensor = aten::copy_(%27, %22, %28) # examples/get_started.py:14:4
      -> (%12)
  return (%b.5)
```

The first step is *Rewrite Mutation*, which converts `View` and `Mutation` to equivalent `Access` and `Assign` operators.

```python
# step 1: rewrite mutation
mutate_info = functs._C.TensorSSAMutateInfo()
functs._C._jit_pass_rewrite_mutation(jit_func.graph, mutate_info)
print("graph after rewrite mutation")
print(jit_func.graph)
print("mutated values: ")
print(mutate_info.mutValues)
print("mutated nodes: ")
print(mutate_info.mutNodes)
```

We define an object of `TensorSSAMutateInfo` to collect the mutated values and mutated nodes after `functs._C._jit_pass_rewrite_mutation`. The output isgraph after rewrite mutation

```ruby
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %28 : bool = prim::Constant[value=0]()
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
   = prim::Loop(%n.1, %12) # examples/get_started.py:13:2
    block0(%i.1 : int):
      %40 : Tensor = immut::select(%b.5, %18, %i.1)
      %22 : Tensor = aten::add(%40, %20, %20) # examples/get_started.py:14:11
      %41 : Tensor = immut::select(%b.5, %18, %i.1)
      %42 : Tensor = immut::assign(%41, %22, %28)
      %43 : Tensor = immut::assign(%41, %22, %28)
      %44 : Tensor = immut::select_rev(%b.5, %43, %18, %i.1)
      %46 : Tensor = immut::select(%44, %18, %i.1)
      %45 : Tensor = immut::select(%44, %18, %i.1)
      %47 : Tensor = immut::assign(%45, %45, %28)
       = tssa::update(%44, %b.5)
       = tssa::update(%46, %40)
       = tssa::update(%45, %41)
       = tssa::update(%47, %42)
      -> (%12)
  return (%b.5)
```

```python
mutated values:
[b.5 defined in (%b.5 : Tensor = aten::clone(%b.1, %7)),
 41 defined in (%41 : Tensor = immut::select(%b.5, %18, %i.1)),
 40 defined in (%40 : Tensor = immut::select(%b.5, %18, %i.1)),
 42 defined in (%42 : Tensor = immut::assign(%41, %22, %28))]

mutated nodes:
{40 defined in (%40 : Tensor = immut::select(%b.5, %18, %i.1)): [ = tssa::update(%46, %40)],
 42 defined in (%42 : Tensor = immut::assign(%41, %22, %28)): [ = tssa::update(%47, %42)],
 41 defined in (%41 : Tensor = immut::select(%b.5, %18, %i.1)): [ = tssa::update(%45, %41)],
 b.5 defined in (%b.5 : Tensor = aten::clone(%b.1, %7)): [ = tssa::update(%44, %b.5)]}
```

The next pass is `functs._C.jit_pass_block_propagation`:

```python
# step 2: block propagation
functs._C._jit_pass_block_propagation(jit_func.graph, mutate_info)
print("graph after block propagation")
print(jit_func.graph)
```

We insert more `tensorssa::Update` nodes for functionalization beyond the control flow. (`= tssa::update(%49, %b.5)` and `= tssa::update(%48, %b.5)`)

```ruby
graph after block propagation
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %28 : bool = prim::Constant[value=0]()
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
  %48 : Tensor = prim::Loop(%n.1, %12, %b.5) # examples/get_started.py:13:2
    block0(%i.1 : int, %49 : Tensor):
       = tssa::update(%49, %b.5)
      %40 : Tensor = immut::select(%b.5, %18, %i.1)
      %22 : Tensor = aten::add(%40, %20, %20) # examples/get_started.py:14:11
      %41 : Tensor = immut::select(%b.5, %18, %i.1)
      %42 : Tensor = immut::assign(%41, %22, %28)
      %43 : Tensor = immut::assign(%41, %22, %28)
      %44 : Tensor = immut::select_rev(%b.5, %43, %18, %i.1)
      %46 : Tensor = immut::select(%44, %18, %i.1)
      %45 : Tensor = immut::select(%44, %18, %i.1)
      %47 : Tensor = immut::assign(%45, %45, %28)
       = tssa::update(%44, %b.5)
       = tssa::update(%46, %40)
       = tssa::update(%45, %41)
       = tssa::update(%47, %42)
      -> (%12, %b.5)
   = tssa::update(%48, %b.5)
  return (%b.5)
```

The `tensorssa::Update` indicates the version of values which need to be updated. `functs._C._jit_pass_rename` substitutes the origin version of the value (`UpdateNode.input(1)`) to the new version (`UpdateNode.input(0)`) after this update node (`UpdateNode`).

```python
# step 3: rename
functs._C._jit_pass_rename(jit_func.graph)
print("graph after rename according tensorssa::Update")
print(jit_func.graph)
```

```ruby
graph after rename according tensorssa::Update
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %28 : bool = prim::Constant[value=0]()
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
  %48 : Tensor = prim::Loop(%n.1, %12, %b.5) # examples/get_started.py:13:2
    block0(%i.1 : int, %49 : Tensor):
       = tssa::update(%49, %b.5)
      %40 : Tensor = immut::select(%49, %18, %i.1)
      %22 : Tensor = aten::add(%40, %20, %20) # examples/get_started.py:14:11
      %41 : Tensor = immut::select(%49, %18, %i.1)
      %42 : Tensor = immut::assign(%41, %22, %28)
      %43 : Tensor = immut::assign(%41, %22, %28)
      %44 : Tensor = immut::select_rev(%49, %43, %18, %i.1)
      %46 : Tensor = immut::select(%44, %18, %i.1)
      %45 : Tensor = immut::select(%44, %18, %i.1)
      %47 : Tensor = immut::assign(%45, %45, %28)
       = tssa::update(%44, %49)
       = tssa::update(%46, %40)
       = tssa::update(%45, %41)
       = tssa::update(%47, %42)
      -> (%12, %44)
   = tssa::update(%48, %44)
  return (%48)
```

After `functs._C._jit_pass_rename`, `tensorssa::Update` can be removed safely by `functs._C._jit_pass_remove_update`.

```python
# step 4: remove update
functs._C._jit_pass_tensorssa_remove_update(jit_func.graph)
print("graph after remove update")
print(jit_func.graph)
```

```ruby
graph after remove update
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %28 : bool = prim::Constant[value=0]()
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
  %48 : Tensor = prim::Loop(%n.1, %12, %b.5) # examples/get_started.py:13:2
    block0(%i.1 : int, %49 : Tensor):
      %40 : Tensor = immut::select(%49, %18, %i.1)
      %22 : Tensor = aten::add(%40, %20, %20) # examples/get_started.py:14:11
      %41 : Tensor = immut::select(%49, %18, %i.1)
      %44 : Tensor = immut::select_rev(%49, %22, %18, %i.1)
      %46 : Tensor = immut::select(%44, %18, %i.1)
      %45 : Tensor = immut::select(%44, %18, %i.1)
      -> (%12, %44)
  return (%48)
```

`FuncTs` `ConvertToTensorSSA` is completely compatible with other `torchscript` passes such as `DCE`, `CES`, `Constant propagation`, `fusion`, `create autodiff subgraphs`.

```python
# step 5: cse, dce, constant_propagation
torch._C._jit_pass_cse(jit_func.graph)
torch._C._jit_pass_dce(jit_func.graph)
torch._C._jit_pass_constant_propagation(jit_func.graph)
print("after csd, dce and constant propagation")
jit_func.graph.alias_db().dump()
```

```ruby
===1. GRAPH===
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %n.1 : int):
  %18 : int = prim::Constant[value=0]() # examples/get_started.py:14:11
  %12 : bool = prim::Constant[value=1]() # examples/get_started.py:13:2
  %7 : NoneType = prim::Constant()
  %20 : int = prim::Constant[value=1]() # examples/get_started.py:14:18
  %b.5 : Tensor = aten::clone(%b.1, %7) # examples/get_started.py:12:6
  %48 : Tensor = prim::Loop(%n.1, %12, %b.5) # examples/get_started.py:13:2
    block0(%i.1 : int, %49 : Tensor):
      %40 : Tensor = immut::select(%49, %18, %i.1)
      %22 : Tensor = aten::add(%40, %20, %20) # examples/get_started.py:14:11
      %44 : Tensor = immut::select_rev(%49, %22, %18, %i.1)
      -> (%12, %44)
  return (%48)

===2. ALIAS DB===
%49 points to: %b.5
%a.1 points to: WILDCARD for type Tensor
%48 points to: %44
%b.1 points to: WILDCARD for type Tensor

===3. Writes===
```

Functionalization of a more complicated case is shown as follows:

![ControlDependency](./docs/imgs/ControlDependencyMemoryDependency.png "Control dependency &amp; Memory dependency")

- Before functionalization

```ruby
graph(%a.1 : Tensor,
      %b.1 : Tensor,
      %idx.1 : int):
  %30 : bool = prim::Constant[value=0]()
  %4 : NoneType = prim::Constant()
  %10 : int = prim::Constant[value=0]()
  %14 : int = prim::Constant[value=1]()
  %a.5 : Tensor = aten::clone(%a.1, %4)
  %b.5 : Tensor = aten::clone(%b.1, %4)
  %11 : bool = aten::ge(%idx.1, %10)
  %a : Tensor = prim::If(%11)
    block0():
      %a.9 : Tensor = aten::add(%a.5, %14, %14)
      %23 : Tensor = aten::select(%b.5, %10, %idx.1)
      %29 : Tensor = aten::select(%a.9, %10, %idx.1)
      %31 : Tensor = aten::copy_(%23, %29, %30)
      -> (%a.9)
    block1():
      %a.17 : Tensor = aten::sub(%a.5, %14, %14)
      %42 : int = aten::neg(%idx.1)
      %44 : Tensor = aten::select(%b.5, %10, %42)
      %51 : int = aten::neg(%idx.1)
      %53 : Tensor = aten::select(%a.17, %10, %51)
      %55 : Tensor = aten::copy_(%44, %53, %30)
      -> (%a.17)
  %64 : Tensor = aten::add(%a, %b.5, %14)
  return (%64)
```

- After functionalization

```ruby
graph(%a.35 : Tensor,
      %b.11 : Tensor,
      %idx.1 : int):
  %79 : NoneType = prim::Constant()
  %b.1 : Tensor = aten::clone(%b.11, %79)
  %a.1 : Tensor = aten::clone(%a.35, %79)
  %10 : int = prim::Constant[value=0]()
  %14 : int = prim::Constant[value=1]()
  %a.5 : Tensor = aten::clone(%a.1, %79)
  %b.5 : Tensor = aten::clone(%b.1, %79)
  %11 : bool = aten::ge(%idx.1, %10)
  %a : Tensor, %93 : Tensor = prim::If(%11)
    block0():
      %a.9 : Tensor = aten::add(%a.5, %14, %14)
      %29 : Tensor = aten::select(%a.9, %10, %idx.1)
      %86 : Tensor = immut::select_rev(%b.5, %29, %10, %idx.1)
      -> (%a.9, %86)
    block1():
      %a.17 : Tensor = aten::sub(%a.5, %14, %14)
      %42 : int = aten::neg(%idx.1)
      %53 : Tensor = aten::select(%a.17, %10, %42)
      %90 : Tensor = immut::select_rev(%b.5, %53, %10, %42)
      -> (%a.17, %90)
  %64 : Tensor = aten::add(%a, %93, %14)
  return (%64)
```

```
> **_NOTE:_**  For illustration, we canonicalize the code in *Figure* by adjusting the variable name by hand.
```

We construct several [test cases](./test/test_basic.py), which show that our method can perform functionalization beyond the control flow.

## Optimization

### Vertical Optimization

We utilize PyTorch NNC to implement several view tensor expressions, which are part of a domain-specific language (DSL) that can be scheduled
 and automatically converted to device code, including CUDA. The code generation for these operators has been tested in [test tensorexpr](./test/test_immut_tensorexpr.py).
Take a python code snippet as an [example](./examples/kernel_fusion.py), the `torch.nn.Module` is

```python
class Normalize(torch.nn.Module):
    def forward(self,
                src: torch.Tensor,
                mean: float, scale: float):
        # only inner-procedure is supported bynow.
        src = src.clone()
        # RGB to BGR
        dup = src.clone()
        dup[..., 0] = src[..., 2]
        dup[..., 2] = src[..., 0]
        return (dup - mean) * scale
```

and the `torch.jit.script` is

```ruby
graph(%self : __torch__.Normalize,
      %src.1 : Tensor,
      %mean.1 : float,
      %scale.1 : float):
  %30 : int = prim::Constant[value=1]()
  %18 : bool = prim::Constant[value=0]()
  %12 : int = prim::Constant[value=-1]() # examples/kernel_fusion.py:13:22
  %5 : NoneType = prim::Constant()
  %11 : int = prim::Constant[value=2]() # examples/kernel_fusion.py:13:31
  %15 : int = prim::Constant[value=0]() # examples/kernel_fusion.py:13:17
  %src.5 : Tensor = aten::clone(%src.1, %5) # examples/kernel_fusion.py:10:14
  %dup.1 : Tensor = aten::clone(%src.5, %5) # examples/kernel_fusion.py:12:14
  %13 : Tensor = aten::select(%src.5, %12, %11) # examples/kernel_fusion.py:13:22
  %17 : Tensor = aten::select(%dup.1, %12, %15) # examples/kernel_fusion.py:13:8
  %19 : Tensor = aten::copy_(%17, %13, %18) # examples/kernel_fusion.py:13:8
  %22 : Tensor = aten::select(%src.5, %12, %15) # examples/kernel_fusion.py:14:22
  %25 : Tensor = aten::select(%dup.1, %12, %11) # examples/kernel_fusion.py:14:8
  %27 : Tensor = aten::copy_(%25, %22, %18) # examples/kernel_fusion.py:14:8
  %31 : Tensor = aten::sub(%dup.1, %mean.1, %30) # examples/kernel_fusion.py:15:16
  %33 : Tensor = aten::mul(%31, %scale.1) # examples/kernel_fusion.py:15:16
  return (%33)
```

The following code performs kernel fusion directly without `TensorSSA`.

```python
# a copy of `torch._C._jit_pass_fuse_tensorexprs`
# but decoupled with TorchScript profiler guided optimization
# by a shape inference module
functs._C._jit_pass_fuse_tensorexpr(jit_g)
print(f"torch.jit.script fused graph:\n{jit_g}")
```

It generates `TensorExprGroup`s with limited scope.

```ruby
torch.jit.script fused graph:
graph(%self : __torch__.Normalize,
      %src.1 : Float(800, 1333, 3, device=cuda:0),
      %mean.1 : float,
      %scale.1 : float):
  %18 : bool = prim::Constant[value=0]()
  %12 : int = prim::Constant[value=-1]() # examples/kernel_fusion.py:14:22
  %11 : int = prim::Constant[value=2]() # examples/kernel_fusion.py:14:31
  %15 : int = prim::Constant[value=0]() # examples/kernel_fusion.py:14:17
  %dup.7 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0), %src.11 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = prim::TensorExprGroup_0(%src.1)
  %13 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = aten::select(%src.11, %12, %11) # examples/kernel_fusion.py:14:22
  %17 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = aten::select(%dup.7, %12, %15) # examples/kernel_fusion.py:14:8
  %19 : FloatTensor(device=cuda:0) = aten::copy_(%17, %13, %18) # examples/kernel_fusion.py:14:8
  %22 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = aten::select(%src.11, %12, %15) # examples/kernel_fusion.py:15:22
  %25 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = aten::select(%dup.7, %12, %11) # examples/kernel_fusion.py:15:8
  %27 : FloatTensor(device=cuda:0) = aten::copy_(%25, %22, %18) # examples/kernel_fusion.py:15:8
  %44 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = prim::TensorExprGroup_1(%scale.1, %dup.7, %mean.1)
  return (%44)
with prim::TensorExprGroup_0 = graph(%src.1 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0)):
  %4 : NoneType = prim::Constant()
  %src.11 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::clone(%src.1, %4) # examples/kernel_fusion.py:11:14
  %dup.7 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::clone(%src.11, %4) # examples/kernel_fusion.py:13:14
  return (%dup.7, %src.11)
with prim::TensorExprGroup_1 = graph(%scale.1 : float,
      %dup.1 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0),
      %mean.1 : float):
  %5 : int = prim::Constant[value=1]()
  %6 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::sub(%dup.1, %mean.1, %5) # examples/kernel_fusion.py:16:16
  %2 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::mul(%6, %scale.1) # examples/kernel_fusion.py:16:16
  return (%2)
```

As a result of implicit tensor mutation, the `aten::copy_` and `aten::select` operators cannot be fused to `TensorExprGroup`, which increases the task latency. If we perform `TensorSSA` and then kernel fusion, the `aten::copy_` and `aten::select` can be converted to fusible and immutable operators.

```python
functs_fn = functs.jit.script(Normalize().eval().cuda())
functs._C._jit_pass_fuse_tensorexpr(functs_g)
print(f"functs.jit.script fused graph:\n{functs_g}")
```

```ruby
graph(%self : __torch__.___torch_mangle_0.Normalize,
      %src.1 : Float(800, 1333, 3, device=cuda:0),
      %mean.1 : float,
      %scale.1 : float):
  %37 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = prim::TensorExprGroup_0(%scale.1, %mean.1, %src.1)
  return (%37)
with prim::TensorExprGroup_0 = graph(%scale.1 : float,
      %mean.1 : float,
      %src.1 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0)):
  %5 : int = prim::Constant[value=1]()
  %27 : int = prim::Constant[value=0]()
  %34 : int = prim::Constant[value=2]()
  %35 : int = prim::Constant[value=-1]()
  %46 : NoneType = prim::Constant()
  %src.6 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::clone(%src.1, %46) # examples/kernel_fusion.py:11:14
  %dup.2 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::clone(%src.6, %46) # examples/kernel_fusion.py:13:14
  %31 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = immut::select(%src.6, %35, %34)
  %24 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = immut::select_rev(%dup.2, %31, %35, %27)
  %17 : Float(800, 1333, strides=[1333, 1], device=cuda:0) = immut::select(%src.6, %35, %27)
  %11 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = immut::select_rev(%24, %17, %35, %34)
  %6 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::sub(%11, %mean.1, %5) # examples/kernel_fusion.py:16:16
  %2 : Float(800, 1333, 3, strides=[3999, 3, 1], device=cuda:0) = aten::mul(%6, %scale.1) # examples/kernel_fusion.py:16:16
  return (%2)
```

The functional part of the program can be represented as a direct acyclic graph (DAG). As a result, it can be converted to NNC directly. The figure below depicts the procedure of code generation:

![normalized](./docs/imgs/functionalization_codegen.png)

The code can be generated by TorchScript NNC:

```python
fusion_subgraph = list(functs_g.nodes())[0].g("Subgraph")
print(te.TensorExprKernel(fusion_subgraph).get_code_text())
```

```c
#define NAN __int_as_float(0x7fffffff)
#define POS_INFINITY __int_as_float(0x7f800000)
#define NEG_INFINITY __int_as_float(0xff800000)


template<typename T>
__device__ T maximum(T a, T b) {
  return isnan(a) ? a : (a > b ? a : b);
}

template<typename T>
__device__ T minimum(T a, T b) {
  return isnan(a) ? a : (a < b ? a : b);
}

extern "C" __global__
void fused_clone_clone_sub_mul(double vscale_1, double vmean_1, float* tsrc_1, float* aten_mul) {
{
if ((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)<3199200ll ? 1 : 0) {
    float v = __ldg(tsrc_1 + (((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) / 3999ll) * 3999ll + 3ll * ((((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) / 3ll) % 1333ll));
    float v_1 = __ldg(tsrc_1 + ((((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) / 3999ll) * 3999ll + 3ll * ((((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) / 3ll) % 1333ll)) + 2ll);
    float v_2 = __ldg(tsrc_1 + (long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x));
    aten_mul[(long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)] = ((((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) % 3ll==2ll ? v : (((long long)(threadIdx.x) + 512ll * (long long)(blockIdx.x)) % 3ll==0ll ? v_1 : v_2)) - (float)(vmean_1)) * (float)(vscale_1);
  }}
}
```

Vertical fusion achieves significant speed up in this task:

```python
functs.utils.evaluate_func(Normalize(),
                           [torch.rand(800, 1333, 3).cuda(), 0.0, 1.0],
                           name="eager",
                           run_duration=2.)
# eager: 9802 iters, min = 56.8us, max = 2.509ms, avg = 204.1us

functs.utils.evaluate_func(torch.jit.script(Normalize()),
                           [torch.rand(800, 1333, 3).cuda(), 0.0, 1.0],
                           name="jit",
                           run_duration=2.)
# jit: 13400 iters, min = 35.81us, max = 569.4us, avg = 149.3us

functs.utils.evaluate_func(functs.jit.script(Normalize()),
                           [torch.rand(800, 1333, 3).cuda(), 0.0, 1.0],
                           name="functs",
                           run_duration=2.)
# functs: 56602 iters, min = 11.94us, max = 5.817ms, avg = 35.33us
```

### Horizontal Parallelization

We extend NNC to support [horizontal parallelization](./fait/tensorexpr/functor_parallization.h), pure function inner the loop without loop-carried dependency can be fused to one kernel and run simultaneously.
Taking a snippet in the actual scenario as an example, this code appears in the post-processing stage of computer vision detection networks.
It involves numerous `tensor view` and `tensor copy` operations.

```python
class MultiScaleBboxProcess(torch.nn.Module):
    def decode_bboxes(self, bboxes, pred_bboxes, stride: float):
        # assert pred_bboxes.size(-1) == bboxes.size(-1) == 4
        xy_centers = (bboxes[..., :2] + bboxes[..., 2:]) * 0.5 + (
            pred_bboxes[..., :2] - 0.5
        ) * stride
        whs = (bboxes[..., 2:] - bboxes[..., :2]) * 0.5 * pred_bboxes[..., 2:].exp()
        decoded_bboxes = torch.stack(
            (
                xy_centers[..., 0] - whs[..., 0],
                xy_centers[..., 1] - whs[..., 1],
                xy_centers[..., 0] + whs[..., 0],
                xy_centers[..., 1] + whs[..., 1],
            ),
            dim=-1,
        )
        return decoded_bboxes.clone()

    def forward(
        self,
        bboxes_list: List[torch.Tensor],
        pred_bboxes_list: List[torch.Tensor],
        stride_list: List[float],
    ):
        outs = []
        for bboxes, pred_bboxes, stride in zip(
            bboxes_list, pred_bboxes_list, stride_list
        ):
            out = self.decode_bboxes(bboxes, pred_bboxes, stride)
            outs.append(out)
        return outs
```

Since the loops are independent of each other, after eliminating the side effects caused by tensor mutation, it can be further parallelized at the graph-IR level in a horizontal direction.

```ruby
graph(%self : __torch__.MultiScaleBboxProcess,
      %bboxes_list.1 : Tensor[],
      %pred_bboxes_list.1 : Tensor[],
      %stride_list.1 : float[]):
  %120 : int = prim::Constant[value=3]()
  %77 : int = prim::Constant[value=1]() # pmap.py:91:32
  %78 : int = prim::Constant[value=0]() # pmap.py:90:32
  %79 : float = prim::Constant[value=0.5]() # pmap.py:84:59
  %80 : int = prim::Constant[value=2]() # pmap.py:84:35
  %81 : int = prim::Constant[value=-1]() # pmap.py:84:22
  %82 : NoneType = prim::Constant()
  %150 : Float(*, 4, device=cuda:0)[] = tssa::ParallelFunctor_0[parallel_degree=3, is_parallel_map=1, is_parallel_args=[1, 1, 1], input_refine_types=[Float(*, 4, device=cuda:0), Float(*, 4, device=cuda:0), float]](%bboxes_list.1, %pred_bboxes_list.1, %stride_list.1)
  return (%150)
with tssa::ParallelFunctor_0 = graph(%0 : int,
      %1 : Float(*, 4, device=cuda:0),
      %2 : Float(*, 4, device=cuda:0),
      %3 : float):
  %32 : float = prim::Constant[value=0.5]() # pmap.py:84:59
  %35 : int = prim::Constant[value=2]() # pmap.py:84:35
  %45 : int = prim::Constant[value=0]() # pmap.py:90:32
  %59 : int = prim::Constant[value=1]() # pmap.py:91:32
  %62 : int = prim::Constant[value=-1]() # pmap.py:84:22
  %64 : NoneType = prim::Constant()
  %4 : Float(*, 2, device=cuda:0) = aten::slice(%1, %62, %64, %35, %59) # pmap.py:84:22
  %9 : Float(*, 2, device=cuda:0) = aten::slice(%1, %62, %35, %64, %59) # pmap.py:84:40
  %14 : Float(*, 2, device=cuda:0) = aten::add(%4, %9, %59) # pmap.py:84:22
  %16 : Float(*, 2, device=cuda:0) = aten::mul(%14, %32) # pmap.py:84:22
  %18 : Float(*, 2, device=cuda:0) = aten::slice(%2, %62, %64, %35, %59) # pmap.py:85:12
  %23 : Float(*, 2, device=cuda:0) = aten::sub(%18, %32, %59) # pmap.py:85:12
  %26 : Float(*, 2, device=cuda:0) = aten::mul(%23, %3) # pmap.py:85:12
  %xy_centers.2 : Float(*, 2, device=cuda:0) = aten::add(%16, %26, %59) # pmap.py:84:22
  %29 : Float(*, 2, device=cuda:0) = aten::sub(%9, %4, %59) # pmap.py:87:15
  %31 : Float(*, 2, device=cuda:0) = aten::mul(%29, %32) # pmap.py:87:15
  %33 : Float(*, 2, device=cuda:0) = aten::slice(%2, %62, %35, %64, %59) # pmap.py:87:58
  %38 : Float(*, 2, device=cuda:0) = aten::exp(%33) # pmap.py:87:58
  %whs.2 : Float(*, 2, device=cuda:0) = aten::mul(%31, %38) # pmap.py:87:15
  %40 : Float(*, device=cuda:0) = immut::select(%xy_centers.2, %62, %45)
  %43 : Float(*, device=cuda:0) = immut::select(%whs.2, %62, %45)
  %46 : Float(*, device=cuda:0) = aten::sub(%40, %43, %59) # pmap.py:90:16
  %48 : Float(*, device=cuda:0) = immut::select(%xy_centers.2, %62, %59)
  %51 : Float(*, device=cuda:0) = immut::select(%whs.2, %62, %59)
  %54 : Float(*, device=cuda:0) = aten::sub(%48, %51, %59) # pmap.py:91:16
  %56 : Float(*, device=cuda:0) = aten::add(%40, %43, %59) # pmap.py:92:16
  %58 : Float(*, device=cuda:0) = aten::add(%48, %51, %59) # pmap.py:93:16
  %60 : Tensor[] = prim::ListConstruct(%46, %54, %56, %58)
  %decoded_bboxes.2 : Float(*, 4, device=cuda:0) = aten::stack(%60, %62) # pmap.py:88:25
  %out.5 : Float(*, 4, device=cuda:0) = aten::clone(%decoded_bboxes.2, %64) # pmap.py:97:15
  return (%out.5)
```

```python
jit: 5276 iters, min = 351.6us, max = 2.426ms, avg = 379.1us
functs unroll: 75260 iters, min = 24.88us, max = 3.258ms, avg = 26.57us
functs pmap: 106829 iters, min = 17.59us, max = 3.266ms, avg = 18.72us
```

## Evaluation

### Speed Up

The performance speed-up is shown as follows:

- [get_latency.py](./scripts/get_latency.py)
- [1660ti log](./scripts/latency_log.txt)

![latency](./docs/imgs/latency.jpg)

### Kernel launch counts

The kernel counts performance is shown as follows:

![kernel launch](./docs/imgs/kernel_launch.jpg)

After functionalization, our performance of kernel launch is better than TorchScript + NNC without Tensor in all workloads. Specifically, compared with TorchDynamo + TorchInductor, the performance boost of kernel launch in NASRNN, seq2seq and Attention is not obvious because TorchDynamo is a tracing-based jit and expands the control flow by unrolling, which has more fusion scope than TorchScipt frontend.

### Scalability

- In different batch sizes

![scalability batch size](./docs/imgs/scalability_bs.jpg)

- in different sequence length

![seq length](./docs/imgs/scalability_seq_len.jpg)

### Latency with CUDA Graph

![kernel launch](./docs/imgs/latency_cudagraph.jpg)

[CUDA Graphs](https://developer.nvidia.com/blog/cuda-10-features-revealed/), which made its debut in CUDA 10, let a series of CUDA kernels be defined and encapsulated as a single unit, i.e., a graph of operations, rather than a sequence of individually-launched operations. We profile the speedup w.r.t. PyTorch Eager in different iters per graph capture. We select NASRNN, Attention and LSTM because other workloads cannot be captured as a whole graph because of unsupported operators and structures. The figure above shows that all compilation pipelines can equally speed up by CUDA Graph.