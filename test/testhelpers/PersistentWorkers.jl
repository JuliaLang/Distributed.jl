module PersistentWorkers

using Distributed: Distributed, ClusterManager, WorkerConfig, worker_from_id, set_worker_state, W_TERMINATED
using Sockets: InetAddr, localhost

export PersistentWorkerManager, start_worker_loop

struct PersistentWorkerManager{IP} <: Distributed.ClusterManager
    addr::InetAddr{IP}
end

PersistentWorkerManager(host, port::Integer) = PersistentWorkerManager(InetAddr(host, port))
PersistentWorkerManager(port::Integer) = PersistentWorkerManager(localhost, port)

function Distributed.launch(cm::PersistentWorkerManager, ::Dict, launched::Array, launch_ntfy::Base.GenericCondition{Base.AlwaysLockedST})
    (; host, port) = cm.addr
    wc = WorkerConfig()
    wc.io = nothing
    wc.host = string(host)
    wc.bind_addr = string(host)
    wc.port = Int(port)
    push!(launched, wc)
    notify(launch_ntfy)
    return nothing
end

function Distributed.manage(::PersistentWorkerManager, ::Int, ::WorkerConfig, ::Symbol) end

# don't actually kill the worker, just close the streams
function Base.kill(::PersistentWorkerManager, pid::Int, ::WorkerConfig)
    w = worker_from_id(pid)
    close(w.r_stream)
    close(w.w_stream)
    set_worker_state(w, W_TERMINATED)
    return nothing
end

using Distributed: LPROC, init_worker, process_messages, cluster_cookie
using Sockets: IPAddr, listen, listenany, accept

function start_worker_loop(host::IPAddr, port::Union{Nothing, Integer}; cluster_cookie=cluster_cookie())
    init_worker(cluster_cookie)
    LPROC.bind_addr = string(host)
    if port === nothing
        port_hint = 9000 + (getpid() % 1000)
        port, sock = listenany(host, UInt16(port_hint))
    else
        sock = listen(host, port)
    end
    LPROC.bind_port = port
    t = let sock=sock
        @async while isopen(sock)
            client = accept(sock)
            process_messages(client, client, true)
        end
    end
    errormonitor(t)
    @info "Listening on $host:$port, cluster_cookie=$cluster_cookie"
    return t, host, port
end

function start_worker_loop((; host, port)::InetAddr; cluster_cookie=cluster_cookie())
    return start_worker_loop(host, port; cluster_cookie)
end

function start_worker_loop(port::Union{Nothing, Integer}=nothing; cluster_cookie=cluster_cookie())
    return start_worker_loop(localhost, port; cluster_cookie)
end

end
