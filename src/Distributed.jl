# This file is a part of Julia. License is MIT: https://julialang.org/license

"""
Tools for distributed parallel processing.
"""
module Distributed

# imports for extension
import Base: getindex, wait, put!, take!, fetch, isready, push!, length,
             hash, ==, kill, close, isopen, showerror, iterate, IteratorSize

# imports for use
using Base: Process, Semaphore, JLOptions, buffer_writes, @async_unwrap,
            VERSION_STRING, binding_module, atexit, julia_exename,
            julia_cmd, AsyncGenerator, acquire, release, invokelatest,
            shell_escape_posixly, shell_escape_csh,
            shell_escape_wincmd, escape_microsoft_c_args,
            uv_error, something, notnothing, isbuffered, mapany, SizeUnknown
using Base.Threads: Event

using Serialization, Sockets
import Serialization: serialize, deserialize
import Sockets: connect, wait_connected

# NOTE: clusterserialize.jl imports additional symbols from Serialization for use

export
    @spawn,
    @spawnat,
    @fetch,
    @fetchfrom,
    @everywhere,
    @distributed,

    AbstractWorkerPool,
    addprocs,
    CachingPool,
    clear!,
    ClusterManager,
    default_worker_pool,
    init_worker,
    interrupt,
    launch,
    manage,
    myid,
    nprocs,
    nworkers,
    pmap,
    procs,
    remote,
    remotecall,
    remotecall_eval,
    remotecall_fetch,
    remotecall_wait,
    remote_do,
    rmprocs,
    workers,
    WorkerPool,
    RemoteChannel,
    Future,
    WorkerConfig,
    RemoteException,
    ProcessExitedException,

    process_messages,
    remoteref_id,
    channel_from_id,
    worker_id_from_socket,
    cluster_cookie,
    start_worker,

# Used only by shared arrays.
    check_same_host

function _require_callback(mod::Base.PkgId)
    if Base.toplevel_load[] && myid() == 1 && nprocs() > 1
        # broadcast top-level (e.g. from Main) import/using from node 1 (only)
        @sync for p in procs()
            p == 1 && continue
            # Extensions are already loaded on workers by their triggers being loaded
            # so no need to fire the callback upon extension being loaded on master.
            Base.loading_extension && continue
            @async_unwrap remotecall_wait(p) do
                Base.require(mod)
                nothing
            end
        end
    end
end

const REF_ID = Threads.Atomic{Int}(1)
next_ref_id() = Threads.atomic_add!(REF_ID, 1)

struct RRID
    whence::Int
    id::Int

    RRID() = RRID(myid(), next_ref_id())
    RRID(whence, id) = new(whence, id)
end

hash(r::RRID, h::UInt) = hash(r.whence, hash(r.id, h))
==(r::RRID, s::RRID) = (r.whence==s.whence && r.id==s.id)

include("clusterserialize.jl")
include("cluster.jl")   # cluster setup and management, addprocs
include("messages.jl")
include("process_messages.jl")  # process incoming messages
include("remotecall.jl")  # the remotecall* api
include("macros.jl")      # @spawn and friends
include("workerpool.jl")
include("pmap.jl")
include("managers.jl")    # LocalManager and SSHManager
include("precompile.jl")

function __init__()
    init_parallel()
end

end
