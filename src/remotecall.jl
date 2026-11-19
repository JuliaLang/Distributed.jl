# This file is a part of Julia. License is MIT: https://julialang.org/license

import Base: eltype

abstract type AbstractRemoteRef end

# Not a `WeakKeyDict`: its keys hash like the objects they point to, so once the GC clears
# them they all hash alike, and growing a table full of collected references takes
# quadratic time. Keyed by RRID instead, with `finalize_ref` removing each entry.
mutable struct ClientRefs
    const lock::ReentrantLock
    const refs::Dict{RRID, WeakRef}
    # finalizers that found `lock` taken, and whether a task is running them
    deferred::Vector{AbstractRemoteRef}
    draining::Bool
    const deferred_lock::Threads.SpinLock
end
ClientRefs() = ClientRefs(ReentrantLock(), Dict{RRID, WeakRef}(), AbstractRemoteRef[], false,
                          Threads.SpinLock())
Base.lock(c::ClientRefs) = lock(c.lock)
Base.lock(f, c::ClientRefs) = lock(f, c.lock)
Base.unlock(c::ClientRefs) = unlock(c.lock)
Base.trylock(c::ClientRefs) = trylock(c.lock)
Base.islocked(c::ClientRefs) = islocked(c.lock)
Base.isempty(c::ClientRefs) = @lock c isempty(c.refs)

# the live reference registered for `rrid`, if any; call with the lock held
function client_ref(rrid::RRID)
    wr = get(client_refs.refs, rrid, nothing)
    return wr === nothing ? nothing : wr.value
end

"""
    client_refs

Tracks whether a particular `AbstractRemoteRef`
(identified by its RRID) exists on this worker.

The `client_refs` lock is also used to synchronize access to `.refs` and associated `clientset` state.
"""
const client_refs = ClientRefs()

"""
    Future(w::Int, rrid::RRID, v::Union{Some, Nothing}=nothing)

A `Future` is a placeholder for a single computation
of unknown termination status and time.
For multiple potential computations, see `RemoteChannel`.
See `remoteref_id` for identifying an `AbstractRemoteRef`.
"""
mutable struct Future <: AbstractRemoteRef
    where::Int
    whence::Int
    id::Int
    lock::ReentrantLock
    @atomic v::Union{Some{Any}, Nothing}
    pins::Int # owner calls in flight, guarded by `lock`; see `pin_future`

    Future(w::Int, rrid::RRID, v::Union{Some, Nothing}=nothing) =
        (r = new(w,rrid.whence,rrid.id,ReentrantLock(),v,0); return test_existing_ref(r))

    Future(t::NTuple{4, Any}) = new(t[1],t[2],t[3],ReentrantLock(),t[4],0)  # Useful for creating dummy, zeroed-out instances
end

"""
    RemoteChannel(pid::Integer=myid())

Make a reference to a `Channel{Any}(1)` on process `pid`.
The default `pid` is the current process.

    RemoteChannel(f::Function, pid::Integer=myid())

Create references to remote channels of a specific size and type. `f` is a function that
when executed on `pid` must return an implementation of an `AbstractChannel`.

For example, `RemoteChannel(()->Channel{Int}(10), pid)`, will return a reference to a
channel of type `Int` and size 10 on `pid`.

The default `pid` is the current process.
"""
mutable struct RemoteChannel{T<:AbstractChannel} <: AbstractRemoteRef
    where::Int
    whence::Int
    id::Int

    function RemoteChannel{T}(w::Int, rrid::RRID) where T<:AbstractChannel
        r = new(w, rrid.whence, rrid.id)
        return test_existing_ref(r)
    end

    function RemoteChannel{T}(t::Tuple) where T<:AbstractChannel
        return new(t[1],t[2],t[3])
    end
end

function test_existing_ref(r::AbstractRemoteRef)
    # Look up and insert atomically: concurrent arrivals of one reference must
    # share one object, as the owner tracks a single client bit per process.
    found = lock(client_refs) do
        rrid = remoteref_id(r)
        found = client_ref(rrid)
        if found === nothing
            client_refs.refs[rrid] = WeakRef(r)
            finalizer(finalize_ref, r)
        end
        found
    end
    if found !== nothing
        @assert r.where > 0
        if isa(r, Future)
            # this is only for copying the reference from Future to RemoteRef (just created)
            fv_cache = @atomic :acquire found.v
            rv_cache = @atomic :monotonic r.v
            if fv_cache === nothing && rv_cache !== nothing
                # we have recd the value from another source, probably a deserialized ref, send a del_client message
                unregister = @lock found.lock begin
                    _, ok = @atomicreplace found.v nothing => rv_cache
                    ok && found.pins == 0
                end
                unregister && send_del_client(r)
            end
        end
        return found::typeof(r)
    end
    return r
end

function finalize_ref(r::AbstractRemoteRef)
    r.where > 0 || return nothing # the finalizer was called manually
    if trylock(client_refs.lock) # trylock doesn't call wait which causes yields
        try
            finalize_ref_locked(r)
        finally
            unlock(client_refs.lock)
        end
    else
        # Re-registering the finalizer would postpone this to the next GC, and under
        # contention, over and over. Defer to a task instead.
        start = @lock client_refs.deferred_lock begin
            push!(client_refs.deferred, r)
            start = !client_refs.draining
            client_refs.draining = true
            start
        end
        if start
            # shielded from cancellation: if it never drains, nothing would start another
            t = Base.ScopedValues.with(Base.CANCEL_TOKEN => nothing) do
                Threads.@spawn drain_deferred_finalizers()
            end
            errormonitor(t)
        end
    end
    nothing
end

# Runs deferred finalizers until none are left. Taking `client_refs` per batch rather than
# for the whole backlog lets other tasks register and look up references in between.
function drain_deferred_finalizers()
    try
        drain_deferred_finalizers_loop()
    catch
        # let the next deferral start a new drainer rather than queue forever
        @lock client_refs.deferred_lock client_refs.draining = false
        rethrow()
    end
end

function drain_deferred_finalizers_loop()
    while true
        rs = @lock client_refs.deferred_lock begin
            rs = client_refs.deferred
            if isempty(rs)
                client_refs.draining = false
                return
            end
            client_refs.deferred = AbstractRemoteRef[]
            rs
        end
        for batch in Iterators.partition(rs, 1000)
            lock(client_refs) do
                for r in batch
                    try
                        finalize_ref_locked(r)
                    catch err
                        # as for a failing finalizer: report it and carry on with the others
                        @error "Error finalizing a remote reference" exception=(err, catch_backtrace())
                    end
                end
            end
            yield()
        end
    end
end

function finalize_ref_locked(r::AbstractRemoteRef)
    r.where > 0 || return
    # The GC clears the weak reference before running this finalizer, so an entry for
    # this RRID can belong to a replacement object that arrived since. It keeps its
    # entry, and this process's client registration if it needs it.
    rrid = remoteref_id(r)
    other = client_ref(rrid)
    other === r && (other = nothing)
    other === nothing && delete!(client_refs.refs, rrid)
    if other === nothing || !needs_client(other)
        if isa(r, RemoteChannel)
            send_del_client_no_lock(r)
        else
            # send_del_client only if the reference has not been set
            v_cache = @atomic :monotonic r.v
            v_cache === nothing && send_del_client_no_lock(r)
        end
    end
    isa(r, Future) && @atomic :monotonic r.v = nothing
    r.where = 0
    return
end

# A Future depends on the owner until it has a cached value and no owner calls in flight
# (see `pin_future`). If it arrived cached, it never registered as a client either.
needs_client(r::Future) = (@atomic :acquire r.v) === nothing || r.pins > 0
needs_client(::RemoteChannel) = true

"""
    Future(pid::Integer=myid())

Create a `Future` on process `pid`.
The default `pid` is the current process.
"""
Future(pid::Integer=myid()) = Future(pid, RRID())
Future(w::LocalProcess) = Future(w.id)
Future(w::Worker) = Future(w.id)

RemoteChannel(pid::Integer=myid()) = RemoteChannel{Channel{Any}}(pid, RRID())

function RemoteChannel(f::Function, pid::Integer=myid())
    remotecall_fetch(pid, f, RRID()) do f, rrid
        rv=lookup_ref(rrid, f)
        RemoteChannel{typeof(rv.c)}(myid(), rrid)
    end
end

Base.eltype(::Type{RemoteChannel{T}}) where {T} = eltype(T)

hash(r::AbstractRemoteRef, h::UInt) = hash(r.whence, hash(r.id, h))
==(r::AbstractRemoteRef, s::AbstractRemoteRef) = (r.whence==s.whence && r.id==s.id)

"""
    remoteref_id(r::AbstractRemoteRef) -> RRID

`Future`s and `RemoteChannel`s are identified by fields:

* `where` - refers to the node where the underlying object/storage
  referred to by the reference actually exists.

* `whence` - refers to the node the remote reference was created from.
  Note that this is different from the node where the underlying object
  referred to actually exists. For example calling `RemoteChannel(2)`
  from the master process would result in a `where` value of 2 and
  a `whence` value of 1.

* `id` is unique across all references created from the worker specified by `whence`.

Taken together,  `whence` and `id` uniquely identify a reference across all workers.

`remoteref_id` is a low-level API which returns a `RRID`
object that wraps `whence` and `id` values of a remote reference.
"""
remoteref_id(r::AbstractRemoteRef) = RRID(r.whence, r.id)

"""
    channel_from_id(id) -> c

A low-level API which returns the backing `AbstractChannel` for an `id` returned by
[`remoteref_id`](@ref).
The call is valid only on the node where the backing channel exists.
"""
function channel_from_id(id)
    rv = lock(client_refs) do
        return get(PGRP.refs, id, false)
    end
    if rv === false
        throw(ErrorException("Local instance of remote reference not found"))
    end
    return rv.c
end

# Once this process holds a Future's value it unregisters from the owner, which may then
# drop the RemoteValue. An owner call already under way would find no entry, create an
# empty one and block on it forever. Such calls therefore pin the Future, and this process
# unregisters only once the value is cached and no pins remain.
# Returns false, without pinning, if the value is already cached.
function pin_future(r::Future)
    @lock r.lock begin
        (@atomic :monotonic r.v) === nothing || return false
        r.pins += 1
    end
    return true
end

function unpin_future(r::Future)
    unregister = @lock r.lock begin
        r.pins -= 1
        r.pins == 0 && (@atomic :monotonic r.v) !== nothing
    end
    unregister && send_del_client(r)
    nothing
end

lookup_ref(rrid::RRID, f=def_rv_channel) = lookup_ref(PGRP, rrid, f)
function lookup_ref(pg, rrid, f)
    return lock(client_refs) do
        rv = get(pg.refs, rrid, false)
        if rv === false
            # first we've heard of this ref
            rv = RemoteValue(invokelatest(f))
            pg.refs[rrid] = rv
            push!(rv.clientset, rrid.whence)
        end
        return rv
    end::RemoteValue
end

"""
    isready(rr::Future)

Determine whether a [`Future`](@ref) has a value stored to it.

If the argument `Future` is owned by a different node, this call will block to wait for the answer.
It is recommended to wait for `rr` in a separate task instead
or to use a local [`Channel`](@ref) as a proxy:

```julia
p = 1
f = Future(p)
errormonitor(@async put!(f, remotecall_fetch(long_computation, p)))
isready(f)  # will not block
```
"""
function isready(rr::Future)
    v_cache = @atomic rr.v
    v_cache === nothing || return true

    pin_future(rr) || return true
    try
        return GC.@preserve rr begin # see `call_on_owner`
            rid = remoteref_id(rr)
            if rr.where == myid()
                isready(lookup_ref(rid).c)
            else
                remotecall_fetch(rid->isready(lookup_ref(rid).c), rr.where, rid)
            end
        end
    finally
        unpin_future(rr)
    end
end

"""
    isready(rr::RemoteChannel, args...)

Determine whether a [`RemoteChannel`](@ref) has a value stored to it.
Note that this function can cause race conditions, since by the
time you receive its result it may no longer be true. However,
it can be safely used on a [`Future`](@ref) since they are assigned only once.
"""
function isready(rr::RemoteChannel, args...)
    return GC.@preserve rr begin # see `call_on_owner`
        rid = remoteref_id(rr)
        if rr.where == myid()
            isready(lookup_ref(rid).c, args...)
        else
            remotecall_fetch(rid->isready(lookup_ref(rid).c, args...), rr.where, rid)
        end
    end
end

del_client(rr::AbstractRemoteRef) = del_client(remoteref_id(rr), myid())

del_client(id, client) = del_client(PGRP, id, client)
function del_client(pg, id, client)
    lock(client_refs) do
        _del_client(pg, id, client)
    end
    nothing
end

function _del_client(pg, id, client)
    rv = get(pg.refs, id, false)
    if rv !== false
        delete!(rv.clientset, client)
        if isempty(rv.clientset)
            delete!(pg.refs, id)
            #print("$(myid()) collected $id\n")
        end
    end
    nothing
end

function del_clients(pairs::Vector)
    for p in pairs
        del_client(p[1], p[2])
    end
end

# The task below is coalescing the `flush_gc_msgs` call
# across multiple producers, see `send_del_client`,
# and `send_add_client`.
# XXX: Is this worth the additional complexity?
#      `flush_gc_msgs` has to iterate over all connected workers.
const any_gc_flag = Threads.Condition()
gc_msgs_task::Union{Task, Nothing} = nothing

function start_gc_msgs_task()
    # shielded from cancellation: the exit hook waits for this task to flush and stop
    t = Base.ScopedValues.with(Base.CANCEL_TOKEN => nothing) do
        @async begin
            while !shutting_down[]
                lock(any_gc_flag) do
                    # this might miss events
                    wait(any_gc_flag)
                end
                # Use invokelatest() so that custom message transport streams
                # for workers can be defined in a newer world age than the Task
                # which runs the loop here.
                invokelatest(flush_gc_msgs) # handles throws internally
            end
        end
    end
    global gc_msgs_task = errormonitor(t)
end

# Function can be called within a finalizer
function send_del_client(rr)
    if rr.where == myid()
        del_client(rr)
    elseif id_in_procs(rr.where) # process only if a valid worker
        process_worker(rr)
    end
end

function send_del_client_no_lock(rr)
    # for gc context to avoid yields
    if rr.where == myid()
        _del_client(PGRP, remoteref_id(rr), myid())
    elseif id_in_procs(rr.where) # process only if a valid worker
        process_worker(rr)
    end
end

function publish_del_msg!(w::Worker, msg)
    @lock w.msg_lock begin
        push!(w.del_msgs, msg)
        @atomic w.gcflag = true
    end
    lock(any_gc_flag) do
        notify(any_gc_flag)
    end
end

function process_worker(rr)
    w = worker_from_id(rr.where)::Worker
    msg = (remoteref_id(rr), myid())

    # Needs to acquire a lock on the del_msg queue
    T = @async begin
        publish_del_msg!($w, $msg)
    end
    Base.errormonitor(T)

    return
end

function add_client(id, client)
    lock(client_refs) do
        rv = lookup_ref(id)
        push!(rv.clientset, client)
    end
    nothing
end

function add_clients(pairs::Vector)
    for p in pairs
        add_client(p[1], p[2]...)
    end
end

function send_add_client(rr::AbstractRemoteRef, i)
    if rr.where == myid()
        add_client(remoteref_id(rr), i)
    elseif (i != rr.where) && id_in_procs(rr.where)
        # don't need to send add_client if the message is already going
        # to the processor that owns the remote ref. it will add_client
        # itself inside deserialize().
        w = worker_from_id(rr.where)
        @lock w.msg_lock begin
            push!(w.add_msgs, (remoteref_id(rr), i))
            @atomic w.gcflag = true
        end
        lock(any_gc_flag) do
            notify(any_gc_flag)
        end
    end
end

channel_type(rr::RemoteChannel{T}) where {T} = T

function serialize(s::ClusterSerializer, f::Future)
    v_cache = @atomic f.v
    if v_cache === nothing
        p = worker_id_from_socket(s.io)
        (p !== f.where) && send_add_client(f, p)
    end
    invoke(serialize, Tuple{ClusterSerializer, Any}, s, f)
end

function serialize(s::ClusterSerializer, rr::RemoteChannel)
    p = worker_id_from_socket(s.io)
    (p !== rr.where) && send_add_client(rr, p)
    invoke(serialize, Tuple{ClusterSerializer, Any}, s, rr)
end

function deserialize(s::ClusterSerializer, t::Type{<:Future})
    fc = invoke(deserialize, Tuple{ClusterSerializer, DataType}, s, t) # deserialized copy
    f2 = Future(fc.where, RRID(fc.whence, fc.id), fc.v) # ctor adds to client_refs table

    # 1) send_add_client() is not executed when the ref is being serialized
    #    to where it exists, hence do it here.
    # 2) If we have received a 'fetch'ed Future or if the Future ctor found an
    #    already 'fetch'ed instance in client_refs (Issue #25847), we should not
    #    track it in the backing RemoteValue store.
    f2v_cache = @atomic f2.v
    if f2.where == myid() && f2v_cache === nothing
        add_client(remoteref_id(f2), myid())
    end
    f2
end

function deserialize(s::ClusterSerializer, t::Type{<:RemoteChannel})
    rr = invoke(deserialize, Tuple{ClusterSerializer, DataType}, s, t)
    if rr.where == myid()
        # send_add_client() is not executed when the ref is being
        # serialized to where it exists
        add_client(remoteref_id(rr), myid())
    end
    # call ctor to make sure this rr gets added to the client_refs table
    RemoteChannel{channel_type(rr)}(rr.where, RRID(rr.whence, rr.id))
end

# Future and RemoteChannel are serializable only in a running cluster.
# Serialize zeroed-out values to non ClusterSerializer objects
function serialize(s::AbstractSerializer, ::Future)
    zero_fut = Future((0,0,0,nothing))
    invoke(serialize, Tuple{AbstractSerializer, Any}, s, zero_fut)
end

function serialize(s::AbstractSerializer, ::RemoteChannel{T}) where T
    zero_rc = RemoteChannel{T}((0,0,0))
    invoke(serialize, Tuple{AbstractSerializer, Any}, s, zero_rc)
end


# make a thunk to call f on args in a way that simulates what would happen if
# the function were sent elsewhere
function local_remotecall_thunk(f, args, kwargs)
    return ()->invokelatest(f, args...; kwargs...)
end

function remotecall(f, w::LocalProcess, args...; kwargs...)
    rr = Future(w)
    schedule_call(remoteref_id(rr), local_remotecall_thunk(f, args, kwargs))
    return rr
end

function remotecall(f, w::Worker, args...; kwargs...)
    rr = Future(w)
    send_msg(w, MsgHeader(remoteref_id(rr)), CallMsg{:call}(f, args, kwargs))
    return rr
end

"""
    remotecall(f, id::Integer, args...; kwargs...) -> Future

Call a function `f` asynchronously on the given arguments on the specified process.
Return a [`Future`](@ref).
Keyword arguments, if any, are passed through to `f`.
"""
remotecall(f, id::Integer, args...; kwargs...) = remotecall(f, worker_from_id(id), args...; kwargs...)

function remotecall_fetch(f, w::LocalProcess, args...; kwargs...)
    v=run_work_thunk(local_remotecall_thunk(f,args, kwargs), false)
    return isa(v, RemoteException) ? throw(v) : v
end

function remotecall_fetch(f, w::Worker, args...; kwargs...)
    # can be weak, because the program will have no way to refer to the Ref
    # itself, it only gets the result.
    oid = RRID()
    rv = lookup_ref(oid)
    rv.waitingfor = w.id
    send_msg(w, MsgHeader(RRID(0,0), oid), CallMsg{:call_fetch}(f, args, kwargs))
    v = take!(rv)
    lock(client_refs) do
        delete!(PGRP.refs, oid)
    end
    return isa(v, RemoteException) ? throw(v) : v
end

"""
    remotecall_fetch(f, id::Integer, args...; kwargs...)

Perform `fetch(remotecall(...))` in one message.
Keyword arguments, if any, are passed through to `f`.
Any remote exceptions are captured in a
[`RemoteException`](@ref) and thrown.

See also [`fetch`](@ref) and [`remotecall`](@ref).

# Examples
```julia-repl
\$ julia -p 2

julia> remotecall_fetch(sqrt, 2, 4)
2.0

julia> remotecall_fetch(sqrt, 2, -4)
ERROR: On worker 2:
DomainError with -4.0:
sqrt was called with a negative real argument but will only return a complex result if called with a complex argument. Try sqrt(Complex(x)).
...
```
"""
remotecall_fetch(f, id::Integer, args...; kwargs...) =
    remotecall_fetch(f, worker_from_id(id), args...; kwargs...)

remotecall_wait(f, w::LocalProcess, args...; kwargs...) = wait(remotecall(f, w, args...; kwargs...))

function remotecall_wait(f, w::Worker, args...; kwargs...)
    prid = RRID()
    rv = lookup_ref(prid)
    rv.waitingfor = w.id
    rr = Future(w)
    send_msg(w, MsgHeader(remoteref_id(rr), prid), CallWaitMsg(f, args, kwargs))
    v = fetch(rv.c)
    lock(client_refs) do
        delete!(PGRP.refs, prid)
    end
    isa(v, RemoteException) && throw(v)
    return rr
end

"""
    remotecall_wait(f, id::Integer, args...; kwargs...)

Perform a faster `wait(remotecall(...))` in one message on the `Worker` specified by worker id `id`.
Keyword arguments, if any, are passed through to `f`.

See also [`wait`](@ref) and [`remotecall`](@ref).
"""
remotecall_wait(f, id::Integer, args...; kwargs...) =
    remotecall_wait(f, worker_from_id(id), args...; kwargs...)

function remote_do(f, w::LocalProcess, args...; kwargs...)
    # the LocalProcess version just performs in local memory what a worker
    # does when it gets a :do message.
    # same for other messages on LocalProcess.
    thk = local_remotecall_thunk(f, args, kwargs)
    schedule(Task(thk))
    nothing
end

function remote_do(f, w::Worker, args...; kwargs...)
    send_msg(w, MsgHeader(), RemoteDoMsg(f, args, kwargs))
    nothing
end


"""
    remote_do(f, id::Integer, args...; kwargs...) -> nothing

Executes `f` on worker `id` asynchronously.
Unlike [`remotecall`](@ref), it does not store the
result of computation, nor is there a way to wait for its completion.

A successful invocation indicates that the request has been accepted for execution on
the remote node.

While consecutive `remotecall`s to the same worker are serialized in the order they are
invoked, the order of executions on the remote worker is undetermined. For example,
`remote_do(f1, 2); remotecall(f2, 2); remote_do(f3, 2)` will serialize the call
to `f1`, followed by `f2` and `f3` in that order. However, it is not guaranteed that `f1`
is executed before `f3` on worker 2.

Any exceptions thrown by `f` are printed to [`stderr`](@ref) on the remote worker.

Keyword arguments, if any, are passed through to `f`.
"""
remote_do(f, id::Integer, args...; kwargs...) = remote_do(f, worker_from_id(id), args...; kwargs...)

# have the owner of rr call f on it
function call_on_owner(f, rr::AbstractRemoteRef, args...)
    # `f` only gets the id: keep `rr` alive until it returns, or its finalizer
    # could delete the owner's value and `f` would create and wait on a fresh one.
    GC.@preserve rr begin
        rid = remoteref_id(rr)
        if rr.where == myid()
            f(rid, args...)
        else
            remotecall_fetch(f, rr.where, rid, args...)
        end
    end
end

function wait_ref(rid, caller, args...)
    v = fetch_ref(rid, args...)
    if isa(v, RemoteException)
        if myid() == caller
            throw(v)
        else
            return v
        end
    end
    nothing
end

"""
    wait(r::Future)

Wait for a value to become available for the specified [`Future`](@ref).
"""
function wait(r::Future)
    v_cache = @atomic r.v
    v_cache !== nothing && return r
    pin_future(r) || return r
    try
        call_on_owner(wait_ref, r, myid())
    finally
        unpin_future(r)
    end
    r
end

"""
    wait(r::RemoteChannel, args...)

Wait for a value to become available on the specified [`RemoteChannel`](@ref).
"""
wait(r::RemoteChannel, args...) = (call_on_owner(wait_ref, r, myid(), args...); r)

"""
    fetch(x::Future)

Wait for and get the value of a [`Future`](@ref). The fetched value is cached locally.
Further calls to `fetch` on the same reference return the cached value. If the remote value
is an exception, throws a [`RemoteException`](@ref) which captures the remote exception and backtrace.
"""
function fetch(r::Future)
    v_cache = @atomic r.v
    v_cache !== nothing && return something(v_cache)

    pin_future(r) || return something(@atomic r.v)
    try
        v_local = call_on_owner(fetch_ref, r)
        # A concurrent put! or fetch may have cached first; return the cached value then.
        v_old, status = @lock r.lock begin
            @atomicreplace r.v nothing => Some(v_local)
        end
        # remote calls getting the value from `call_on_owner` used to return the value directly without wrapping it in `Some(x)`
        # so we're doing the same thing here
        return status ? v_local : something(v_old)
    finally
        unpin_future(r)
    end
end

fetch_ref(rid, args...) = fetch(lookup_ref(rid).c, args...)

"""
    fetch(c::RemoteChannel)

Wait for and get a value from a [`RemoteChannel`](@ref). Exceptions raised are the
same as for a [`Future`](@ref). Does not remove the item fetched.
"""
fetch(r::RemoteChannel, args...) = call_on_owner(fetch_ref, r, args...)::eltype(r)

isready(rv::RemoteValue, args...) = isready(rv.c, args...)

"""
    put!(rr::Future, v)

Store a value to a [`Future`](@ref) `rr`.
`Future`s are write-once remote references.
A `put!` on an already set `Future` throws an `Exception`.
All asynchronous remote calls return `Future`s and set the
value to the return value of the call upon completion.
"""
function put!(r::Future, v)
    if r.where == myid()
        rid = remoteref_id(r)
        rv = lookup_ref(rid)
        isready(rv) && error("Future can be set only once")
        unregister = @lock r.lock begin
            put!(rv, v) # this notifies the tasks waiting on the channel in fetch
            set_future_cache(r, v) # set the cache before leaving the lock, so that the notified tasks already see it cached
            r.pins == 0
        end
        unregister && del_client(rid, myid())
    else
        @lock r.lock begin # same idea as above if there were any local tasks fetching on this Future
            call_on_owner(put_future, r, v, myid(), r.pins == 0)
            set_future_cache(r, v)
        end
    end
    r
end

function set_future_cache(r::Future, v)
    _, ok = @atomicreplace r.v nothing => Some(v)
    ok || error("internal consistency error detected for Future")
end

function put_future(rid, v, caller, unregister::Bool)
    rv = lookup_ref(rid)
    isready(rv) && error("Future can be set only once")
    put!(rv, v)
    # The caller has the value and hence can be removed from the remote store,
    # unless it has owner calls in flight; it then unregisters when they finish.
    unregister && del_client(rid, caller)
    nothing
end


put!(rv::RemoteValue, args...) = put!(rv.c, args...)
function put_ref(rid, caller, args...)
    rv = lookup_ref(rid)
    put!(rv, args...)
    if myid() == caller && rv.synctake !== nothing
        # Wait till a "taken" value is serialized out - github issue #29932
        lock(rv.synctake::ReentrantLock)
        unlock(rv.synctake::ReentrantLock)
    end
    nothing
end

"""
    put!(rr::RemoteChannel, args...)

Store a set of values to the [`RemoteChannel`](@ref).
If the channel is full, blocks until space is available.
Return the first argument.
"""
put!(rr::RemoteChannel, args...) = (call_on_owner(put_ref, rr, myid(), args...); rr)

# take! is not supported on Future

take!(rv::RemoteValue, args...) = take!(rv.c, args...)
function take_ref(rid, caller, args...)
    rv = lookup_ref(rid)
    synctake = false
    if myid() != caller && rv.synctake !== nothing
        # special handling for local put! / remote take! on unbuffered channel
        # github issue #29932
        synctake = true
        lock(rv.synctake::ReentrantLock)
    end

    v = try
        take!(rv, args...)
    catch e
        # avoid unmatched unlock when exception occurs
        # github issue #33972
        synctake && unlock(rv.synctake::ReentrantLock)
        rethrow(e)
    end

    isa(v, RemoteException) && (myid() == caller) && throw(v)

    if synctake
        return SyncTake(v, rv)
    else
        return v
    end
end

"""
    take!(rr::RemoteChannel, args...)

Fetch value(s) from a [`RemoteChannel`](@ref) `rr`,
removing the value(s) in the process.
"""
take!(rr::RemoteChannel, args...) = call_on_owner(take_ref, rr, myid(), args...)::eltype(rr)

# close and isopen are not supported on Future

close_ref(rid) = (close(lookup_ref(rid).c); nothing)
close(rr::RemoteChannel) = call_on_owner(close_ref, rr)

isopen_ref(rid) = isopen(lookup_ref(rid).c)
isopen(rr::RemoteChannel) = call_on_owner(isopen_ref, rr)

isempty_ref(rid) = isempty(lookup_ref(rid).c)
Base.isempty(rr::RemoteChannel) = call_on_owner(isempty_ref, rr)

getindex(r::RemoteChannel) = fetch(r)
getindex(r::Future) = fetch(r)

getindex(r::Future, args...) = getindex(fetch(r), args...)
function getindex(r::RemoteChannel, args...)
    if r.where == myid()
        return getindex(fetch(r), args...)
    end
    return remotecall_fetch(getindex, r.where, r, args...)
end

function iterate(c::RemoteChannel, state=nothing)
    if isopen(c) || isready(c)
        try
            return (take!(c), nothing)
        catch e
            if isa(e, InvalidStateException) ||
                (isa(e, RemoteException) &&
                isa(e.captured.ex, InvalidStateException) &&
                e.captured.ex.state === :closed)
                return nothing
            end
            rethrow()
        end
    else
        return nothing
    end
end

IteratorSize(::Type{<:RemoteChannel}) = SizeUnknown()
