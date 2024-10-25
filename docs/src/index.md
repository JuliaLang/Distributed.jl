# [Distributed Computing](@id man-distributed)

```@docs
DistributedNext
DistributedNext.addprocs
DistributedNext.nprocs
DistributedNext.nworkers
DistributedNext.procs()
DistributedNext.procs(::Integer)
DistributedNext.workers
DistributedNext.rmprocs
DistributedNext.interrupt
DistributedNext.myid
DistributedNext.pmap
DistributedNext.RemoteException
DistributedNext.ProcessExitedException
DistributedNext.Future
DistributedNext.RemoteChannel
DistributedNext.fetch(::DistributedNext.Future)
DistributedNext.fetch(::RemoteChannel)
DistributedNext.remotecall(::Any, ::Integer, ::Any...)
DistributedNext.remotecall_wait(::Any, ::Integer, ::Any...)
DistributedNext.remotecall_fetch(::Any, ::Integer, ::Any...)
DistributedNext.remote_do(::Any, ::Integer, ::Any...)
DistributedNext.put!(::RemoteChannel, ::Any...)
DistributedNext.put!(::DistributedNext.Future, ::Any)
DistributedNext.take!(::RemoteChannel, ::Any...)
DistributedNext.isready(::RemoteChannel, ::Any...)
DistributedNext.isready(::DistributedNext.Future)
DistributedNext.AbstractWorkerPool
DistributedNext.WorkerPool
DistributedNext.CachingPool
DistributedNext.default_worker_pool
DistributedNext.clear!
DistributedNext.remote
DistributedNext.remotecall(::Any, ::AbstractWorkerPool, ::Any...)
DistributedNext.remotecall_wait(::Any, ::AbstractWorkerPool, ::Any...)
DistributedNext.remotecall_fetch(::Any, ::AbstractWorkerPool, ::Any...)
DistributedNext.remote_do(::Any, ::AbstractWorkerPool, ::Any...)
DistributedNext.@spawn
DistributedNext.@spawnat
DistributedNext.@fetch
DistributedNext.@fetchfrom
DistributedNext.@distributed
DistributedNext.@everywhere
DistributedNext.remoteref_id
DistributedNext.channel_from_id
DistributedNext.worker_id_from_socket
DistributedNext.cluster_cookie()
DistributedNext.cluster_cookie(::Any)
```

## Cluster Manager Interface

This interface provides a mechanism to launch and manage Julia workers on different cluster environments.
There are two types of managers present in Base: `LocalManager`, for launching additional workers on the
same host, and `SSHManager`, for launching on remote hosts via `ssh`. TCP/IP sockets are used to connect
and transport messages between processes. It is possible for Cluster Managers to provide a different transport.

```@docs
DistributedNext.ClusterManager
DistributedNext.WorkerConfig
DistributedNext.launch
DistributedNext.manage
DistributedNext.kill(::ClusterManager, ::Int, ::WorkerConfig)
DistributedNext.connect(::ClusterManager, ::Int, ::WorkerConfig)
DistributedNext.init_worker
DistributedNext.start_worker
DistributedNext.process_messages
DistributedNext.default_addprocs_params
```
