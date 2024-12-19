# Distributed

The `Distributed` package provides functionality for creating and controlling
multiple Julia processes remotely, and for performing distributed and parallel
computing. It uses network sockets or other supported interfaces to communicate
between Julia processes, and relies on Julia's `Serialization` stdlib package to
transform Julia objects into a format that can be transferred between processes
efficiently. It provides a full set of utilities to create and destroy new Julia
processes and add them to a "cluster" (a collection of Julia processes connected
together), as well as functions to perform Remote Procedure Calls (RPC) between
the processes within a cluster. See the `API` section for details.

This package ships as part of the Julia stdlib.

## Using development versions of this package

### On Julia 1.11+
In Julia 1.11 Distributed was excised from the default system image and became
more of an independent package. As such, to use a different version it's enough
to just `dev` it explicitly:
```julia-repl
pkg> dev https://github.com/JuliaLang/Distributed.jl.git
```

### On older Julia versions
To use a newer version of this package on older Julia versions, you need to build
Julia from scratch. The build process is the same as any other build except that
you need to change the commit used in `stdlib/Distributed.version`.

It's also possible to load a development version of the package using [the trick
used in the Section named "Using the development version of Pkg.jl" in the
`Pkg.jl`
repo](https://github.com/JuliaLang/Pkg.jl#using-the-development-version-of-pkgjl),
but the capabilities are limited as all other packages will depend on the stdlib
version of the package and will not work with the modified package.

## API

The public API of `Distributed` consists of a variety of functions for various
tasks; for creating and destroying processes within a cluster:

- `addprocs` - create one or more Julia processes and connect them to the cluster
- `rmprocs` - shutdown and remove one or more Julia processes from the cluster

For controlling other processes via RPC:

- `remotecall` - call a function on another process and return a `Future` referencing the result of that call
- `Future` - an object that references the result of a `remotecall` that hasn't
  yet completed - use `fetch` to return the call's result, or `wait` to just
  wait for the remote call to finish.
- `remotecall_fetch` - the same as `fetch(remotecall(...))`
- `remotecall_wait` - the same as `wait(remotecall(...))`
- `remote_do` - like `remotecall`, but does not provide a way to access the result of the call
- `@spawnat` - like `remotecall`, but in macro form
- `@spawn` - like `@spawn`, but the target process is picked automatically
- `@fetch` - macro equivalent of `fetch(@spawn expr)`
- `@fetchfrom` - macro equivalent of `fetch(@spawnat p expr)`
- `myid` - returns the `Int` identifier of the process calling it
- `nprocs` - returns the number of processes in the cluster
- `nworkers` - returns the number of worker processes in the cluster
- `procs` - returns the set of IDs for processes in the cluster
- `workers` - returns the set of IDs for worker processes in the cluster
- `interrupt` - interrupts the specified process

For communicating between processes in the style of a channel or stream:

- `RemoteChannel` - a `Channel`-like object that can be `put!` to or `take!` from any process

For controlling multiple processes at once:

- `WorkerPool` - a collection of processes than can be passed instead a process ID to certain APIs
- `CachingPool` - like `WorkerPool`, but caches functions (including closures which capture large data) on each process
- `@everywhere` - runs a block of code on all (or a subset of all) processes and waits for them all to complete
- `pmap` - performs a `map` operation where each element may be computed on another process
- `@distributed` - implements a `for`-loop where each iteration may be computed on another process

### Process Identifiers

Julia processes connected with `Distributed` are all assigned a cluster-unique
`Int` identifier, starting from `1`. The first Julia process within a cluster is
given ID `1`, while other processes added via `addprocs` get incrementing IDs
(`2`, `3`, etc.). Functions and macros which communicate from one process to
another usually take one or more identifiers to determine which process they
target - for example, `remotecall_fetch(myid, 2)` calls `myid()` on process 2.

**Note:** Only process 1 (often called the "head", "primary", or "master") may
add or remove processes, and manages the rest of the cluster. Other processes
(called "workers" or "worker processes") may still call functions on each other
and send and receive data, but `addprocs`/`rmprocs` on worker processes will
fail with an error.
