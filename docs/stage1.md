# Stage 1 architecture (`envoc1`)

`envoc1` is written in Envo-Core and built by `envoc0` (PLAN D11). Its front end mirrors
Stage 0 pass for pass so the two can be compared output for output (D14); its middle and
back end go through EIR v1 (D15). This page records the design of the parts that have no
Stage 0 counterpart. File-by-file contents are in
[`stage1/README.md`](../stage1/README.md).

## Pipeline

```
sources ─ lex ─ parse ─ check ─ lower ─► EIR ─ verify ─ x86-64 backend ─ PE / ELF writer
                                          ▲
                      runtime (Envo-Core, compiled with every program)
```

## Code generation (M2.7)

**Lowering** turns the checked tree into EIR ([eir.model.1]–[eir.model.6]):

- Every local and parameter gets a `slot` in the entry block; reads and writes are `load`
  and `store`. No SSA construction is needed, and the result is still valid SSA.
- `str` and slices are the struct `{ ptr, u64 }`; structs and arrays live in slots and are
  copied with `copy`. Aggregate arguments are passed as a pointer to a copy the callee
  owns; aggregate results through a hidden first `%ret: ptr` parameter ([eir.model.3]).
- Run-time checks are EIR's checked instructions: `add.chk` and friends, `div`/`rem`,
  `shl`/`shr`, `bounds`, so overflow, division, shift and index checks panic exactly where
  Stage 0's do, with the same reasons.
- `match` lowers to `switch`; `&&` and `||` to branches; top-level statements become
  `@__main`, which returns the exit code.
- Statics and string literals become globals.

**The backend** keeps every SSA value in its own `rbp` slot (D15): each instruction loads
its operands into fixed registers, computes, and stores its result. Block parameters are
slots written by the branch that jumps there. There is no register allocator and no
optimizer; speed is Stage 2's job.

**Calling convention** (the "Envo convention" of [eir.ssa.5], for Stage 1 output): the
caller reserves `8 × n` bytes, stores argument *i* at `[rsp + 8i]`, keeps `rsp` 16-byte
aligned, and calls; the callee reads argument *i* at `[rbp + 16 + 8i]`; the result is in
`rax`; the caller releases the space.

## The runtime (M2.7; answers PLAN open question 8)

Stage 0 copies its own assembled runtime block into each program. `envoc1` cannot, so
**the Stage 1 runtime is written in Envo-Core** (`stage1/runtime/`) and compiled
into every program it builds, like any other source file:

- `runtime/common.envo`: the heap (a bump allocator over page-sized chunks), the
  built-ins (`print`, `write`, `read`, `open`, `close`, `alloc`, `exit`, `argc`, `arg`,
  `panic`), panic messages and exit codes, all with Stage 0's behaviour and messages.
- `runtime/linux.envo` and `runtime/windows.envo`: the OS layer, including Windows'
  UTF-16 conversion of paths and its command-line splitting.

The OS layer needs two operations Envo-Core cannot express, which the backend encodes as
**target intrinsics**, valid only in runtime code:

| Intrinsic | Target | Meaning |
|---|---|---|
| `intrinsic syscall(i64 n, i64 a, …)` → `i64` | Linux | `syscall` with up to six arguments |
| `intrinsic wincall(i64 k, i64 a, …)` → `i64` | Windows | call import *k* of the image's import address table with the Microsoft x64 convention; 10 arguments, or 12 (`__wincall12`) |
| `intrinsic wincallp(i64 fn, i64 a, …)` → `i64` | Windows | call the function at address *fn* the same way, with 12 arguments (`__wincallp`) |

The portable EIR intrinsics of [eir.md](https://github.com/envoscale/EnvoScale/blob/main/docs/spec/eir.md) §5.6 (`write`, `read`, …) lower to
calls into this runtime, so EIR itself stays target-independent and the script VM (M6) can
implement them directly.

The runtime's source is embedded in `envoc1` as string constants generated from
`runtime/*.envo` by `envoc1 embed`; `bootstrap.* test` fails if the generated file is out
of date, so the readable sources and what `envoc1` compiles cannot drift apart.

## Generics, methods and interfaces (M2.8)

`check/generic.envo` adds Envo-S1's generics to the checker, and lowering compiles each
instantiation separately (monomorphization, PLAN D13).

**Environments.** A generic item has a list of type arguments, its *environment*: the
owner's parameters first (the struct, `impl` or interface a method belongs to), then the
item's own. Each type parameter is a symbol holding its index in that list, and a type
parameter type (`TYK_PARAM`) points at it, so substitution is positional and needs no
names. An interface's methods have one extra entry at index 0, `This`, the implementing
type; the interface's own parameters follow.

**Types.** A generic instance (`Box<i64>`, `IComparable<T>`) is interned like derived
types: same struct and same arguments, same type index, so type equality stays an
integer comparison. A generic struct's fields are resolved once, with its parameters in
scope; an instance's field types and layout are the field types with its arguments
substituted. Layouts that still mention parameters only serve to find cycles (E0303).

**Checking.** A generic body is checked once, at its definition ([type.gen.2]): a value of
parameter type `T` supports only assignment, passing, returning, and the methods of its
`where` bounds. At a call, explicit type arguments fill the environment; the rest are
inferred by matching parameter types against argument types, typed arguments first and
untyped literals last (so `Max(x, 1)` with `x: i64` is `Max<i64>`, and `Max(1, 2)` is
`Max<i32>`). Then every bound is checked against the substituted arguments: a concrete
type meets a bound through an `impl` (or a struct's `: I` list); a type parameter only
through the bounds of the function being checked. The call records its callee and
environment.

**Methods** live in a table keyed by owner and name: a struct's or enum's symbol, or the
type itself for primitives (`impl IHash for i64`). A struct body's methods, `impl T`
methods and an interface implementation's methods all go there, as do default bodies an
implementation inherits. Receivers follow [item.method.1]: no receiver is `in this`;
`in this` and `ref this` pass a pointer; `this` passes a copy. `in` and `ref` parameters
are also passed by address ([own.mode.1]); in the body they are places reached through
that pointer, and an `in` place is read-only (E0315).

**Interfaces** are bounds only ([s1.type.3]): an interface method called on a value of
parameter type is resolved when the body is instantiated, to the implementation's method
for the concrete type, or to the interface's default body instantiated with `This` set to
that type. An implementation must provide every method without a default body with the
interface's signature (E0337, E0339) and nothing else (E0340).

**Instantiation.** After checking, `CollectInstances` walks the recorded calls from the
top-level statements and the non-generic functions outward, substituting each call's
environment with that of the body containing it, and makes one instance per distinct
(function, type arguments). Every method, generic or not, is compiled through an
instance, so only methods that are called are compiled. Instantiation more than 64
levels deep is E0350. Lowering then compiles every instance with its environment, so
each node's type is substituted as it is lowered.

**Names.** An instance's EIR name is the function's name (with its owner for a method)
followed by each type argument: `@Max.i64`, `@Box.Get.i64`, `@i64.Compare`. Type
arguments are written self-delimiting (`0.` pointer, `1.` slice, `2.N.` array, and a
generic instance's argument count before its arguments: `Box.1.i64`), so different
instances never share a name.

**Leave-outs.** While M2 was built, Envo-S1 constructs `envoc1` did not compile yet were
reported as a temporary E0951. M2.13 removed it: every such construct is now compiled, or
recorded in `envo-s1.md` ([s1.type.3], [s1.item.7], [s1.expr.8]) as not part of
Envo-S1 and reported as E0950.

## Closures (M2.9)

`check/closure.envo` and `lower/closure.envo` implement RFC 0003 with one representation
for every function-typed value: the function value `$fnv = { code: ptr, env: ptr }`
([fn.abi.2]). Code takes the hidden result pointer (for an aggregate result), then
`env`, then the parameters, and is called with `call.ind`. Stage 2 adds the per-closure
types and monomorphized calls of [fn.pos.1]; the behaviour programs see is the same.

- **Function types** are interned like generic instances: kind, parameter types and
  modes, result. A `fn` value may be used where a `mut fn` or `once fn` is expected,
  not the other way round ([fn.type.2], [fn.type.4]).
- **Lambdas** are checked as functions of their own inside the enclosing scope. Their
  parameter types and modes come from the target type (a parameter, a typed local, a
  field, a return type), or are written (E0330 otherwise); the result comes from the
  target or from the body ([fn.lam.1], [fn.lam.2]). In a generic call, a lambda is
  checked after the other arguments, so `Map(x, y => y * 2)` learns `y`'s type from `x`
  and the result type from the body.
- **Captures** are found as the body is checked: a local of an enclosing function used
  inside the lambda is captured (each local records its position on the locals stack).
  Changing a captured place, `ref`-passing it or calling a `mut fn` capture makes the
  lambda a `mut fn` (E0331 if the target is a `fn`).
- **Capture modes** ([fn.cap.1]): a lambda passed directly to a function-typed parameter
  borrows: its environment holds pointers to the captured variables, in a stack slot of
  the caller, so `Each(4, n => total += n)` changes `total`. Every other lambda, and any
  lambda written `move`, copies its captures into a heap environment; a lambda that
  captures nothing has a null environment and allocates nothing.
- **Lambda bodies** become EIR functions named after the enclosing function
  (`@__main.lambda0`); a lambda in a generic body is compiled once per instance of that
  body. A named function used as a value goes through a thunk (`@Double.fv`) that drops
  `env` and calls it.

Until the borrow checker (M2.10), nothing stops a callee from storing a function-typed
parameter that borrows its caller's variables; M2.10 reports that as E0504
([fn.cap.2]).

## Ownership (M2.10)

Chapter 5 for Envo-S1 ([s1.own.*]), in four parts:

- **`Copy` and drops** (`check/own.envo`). A type is `Copy` by [type.copy.1]: primitives,
  `str`, shared views, raw pointers, fieldless enums, and arrays and structs of `Copy`
  values that do not implement `IDrop`. Function values are moved. A type parameter is
  `Copy` only under a `where T : Copy` bound, so a generic body that copies a `T` says so.
  A type *needs a drop* when it, a field or an element implements the prelude's `IDrop`.
- **The move checker** (`check/move.envo`) runs over each body after type checking. It
  follows the structured control flow with a state per tracked place: a local that is not
  `Copy`, or one first-level field of one (a partial move). Where paths meet, a place moved
  on one of them is *maybe moved*; a loop body is rechecked from the join of its entry and
  its back edges until that join is stable. Using a moved place is E0501. Moving out of an
  `in` or `ref` parameter or receiver, an array element, a temporary's field or a lambda's
  capture is E0502. Each move of a whole local is recorded for lowering.
- **Drops** (`lower/drop.envo`). Each local whose type needs a drop gets a drop flag, set
  when it is initialized and cleared where it is moved, so conditional moves need no
  analysis at run time. Leaving a scope (the end of a block, `break`, `continue`,
  `return`, the end of a function or of `__main`) drops the live locals it owns, newest
  first: the type's `Drop`, then its fields in declaration order ([own.drop.1]). An
  assignment drops the old value first; a temporary that needs a drop is dropped at the
  end of its statement. `Drop` methods are instantiated on demand during lowering.
- **Borrows** (`check/borrow.envo`). Borrows created by a call last for the call: a local
  passed `ref`, or captured by a lambda argument that changes it, may not be used any
  other way in that call (E0503), and a local the call borrows may not be moved by it
  (E0504). A function-typed parameter may hold a lambda that borrows its caller's
  variables, so it may only be called or passed to a function-typed parameter; returning
  it, storing it, or passing it to anything else is E0507, found by following which
  parameters' borrows each value may carry. `from` clauses must name borrowed parameters
  or `this` (E0508), and a function with one may return only borrows of those (E0507).
  Without a clause the origins are inferred ([life.infer.2]); an Envo-S1 program exports
  nothing, so E0506 never applies.

Stage 1 accepts less than chapter 5 allows, never more ([s1.own.3]). Borrows held in
locals across statements (beyond the freezing above), disjoint field borrows, `once fn`
inference (a lambda moving a capture is E0502) and partial moves out of locals whose type
needs a drop are Stage 2's. Function values do not free their environments: the Stage 1
heap never frees.

## Enums (M2.11)

`check/enums.envo` and `lower/enums.envo`. An enum with a payload on any variant, or with
type parameters, is a *tagged enum* (`TYK_UNION`): a `u32` tag holding the variant's
index, then the payload of the variant it holds. In EIR it is `{ u32, [K x word] }`,
where `word` is the largest payload alignment and K words fit the largest payload; each
variant's payload is a struct of its fields laid over those words. Fieldless enums stay
integers, exactly as in Envo-Core, so Core programs are unchanged.

- **Values.** `Shape.Rect(1, 2)`, `Option<i64>.None`, or, where the expected type is
  known (an initializer, an argument, a `return`), just `Rect(1, 2)` or `None`
  ([item.enum.3]). Type arguments come from the expected type or from the payload.
- **`match`** in Envo-S1 form (a tagged scrutinee, guards, or a `match` expression)
  tests each arm's patterns in order, binds, checks the guard, and runs the arm; a failed
  guard goes on to the next arm, so the checker counts only unguarded arms for
  exhaustiveness (E0308) and duplicates (E0319). Core-form matches keep the `switch`.
- **Bindings** ([s1.expr.1]) copy `Copy` payloads. A payload that is not `Copy` is taken
  when the scrutinee is a local the function owns (that arm moves the local) or a
  temporary (the match holds it, and drops it unless an arm takes it); otherwise the
  binding is an `in` borrow of the payload, and the arm may not change or move the
  scrutinee (E0503, E0504). A payload cannot be taken out of a type that implements
  `IDrop` (E0502).
- **Drops** of a tagged value drop the active variant's payload fields.
- **Option and Result** are prelude enums with `IsSome`/`IsNone`, `Unwrap`, `UnwrapOr`,
  `IsOk`/`IsErr` and `UnwrapErr`. `T?` is `Option<T>`; `null` is `None` of the expected
  `T?` (E0335 without one). `a ?? b` takes `a` and gives its value or evaluates `b`.
  `e?` gives the value, or returns `None` (or `Err` with `e`'s error) early, running the
  drops of a `return`; the function's result must be optional (or a `Result` with the
  same error type), else E0317.
- **`c ? a : b`** evaluates one branch into a slot of the result type ([s1.expr.2]).

## Views (M2.12)

`check/views.envo` and `lower/views.envo` implement RFC 0002 and RFC 0004's views. `T[]`
and `mut T[]` share `str`'s representation `{ ptr, u64 }`; `mut T[]` is a separate
interned type that is not `Copy`, may be written through, converts to `T[]`, and is
reborrowed (not moved) when passed to a `mut T[]` parameter. Slicing checks its bounds in
`u64` (`lo <= hi <= length`, `..=` first checking `hi < length`) and, for `str`, that
both ends are character boundaries. `foreach` walks an index over the sequence (a
borrowed element is the element's address) or a counter over a range (`..=` stops at
`hi` without stepping past it, so `hi` may be the type's maximum).

Borrows of local storage are checked conservatively ([s1.own.3]): a view of a local array
or a `str` of a local `string` that is kept (not just passed to a call) freezes the local
for the rest of the function, entirely for a kept `mut T[]` (E0503); such a value cannot
be returned or stored outside the function (E0504); and a `str` of a temporary `string`
may only be passed straight to a call.

The prelude's `List<T>` and `string` are Envo-S1 code over raw memory. In `unsafe` code
a write through a raw pointer stores without dropping the old value (the memory may be
empty) and a read of a value that is not `Copy` takes it ([own.unsafe.1]); that is how
`List<T>` moves items in and out and how its `Drop` drops them. Names inside the
prelude always mean the prelude's own items, whatever a program defines.

## Namespaces (M2.12)

`check/names.envo`. A file's `namespace a.b;` puts its items in program scope as
`a.b.X`; files without one share the root. An unqualified name is looked up in the
file's namespace and those around it, then in the file's `use` imports, then in the
root. A qualified name in an expression (`a.b.F(x)`, `alias.T.Make()`) is resolved when it
is met, as long as its first name is not a local, and is then a plain name with its item
fixed; in a type, `a.b.T`. Private items (the default) are visible only in their
namespace (E0212); `public` and `internal` ones everywhere, since a program is one
package ([s1.item.2]).

## Executable images

Hardened since M13 (PLAN D68): the code (read and execute) and the data (read and write)
are on separate pages. Linux programs are position-independent (`ET_DYN`, an R+X and an R+W
`PT_LOAD`) and relocate their few 8-byte absolute addresses themselves with a 45-byte stub
at the entry; Windows programs have `.text`, `.data` and `.reloc` sections and
`DYNAMIC_BASE | HIGH_ENTROPY_VA`, so the loader places them anywhere. Headers are written
by Stage 1's own PE and ELF writers, with the import tables on Windows. Stage 2 writes the
same bytes. Builds are deterministic, so `envoc1` builds of a
program are byte-identical on every host.

## Testing

Every `core-run` and `core-multi` program is built with `envoc1`, run, and must print the
same output and exit with the same code as under `envoc0` (M2.7's definition of done).
Envo-S1 has no Stage 0 to compare with: `tests/spec/s1-run/` programs carry their expected
output, and `tests/spec/s1-types/` one expected error each (M2.8 onward).
