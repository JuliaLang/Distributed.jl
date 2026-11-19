using Test
using Distributed
using Base.Iterators: product

exeflags = ("--startup-file=no",
            "--check-bounds=yes",
            "--depwarn=error",
            "--threads=2")

function call_on(f, wid, tid)
    remotecall(wid) do
        t = Task(f)
        ccall(:jl_set_task_tid, Cvoid, (Any, Cint), t, tid - 1)
        schedule(t)
        @assert Threads.threadid(t) == tid
        t
    end
end

# Run function on process holding the data to only serialize the result of f.
# This becomes useful for things that cannot be serialized (e.g. running tasks)
# or that would be unnecessarily big if serialized.
fetch_from_owner(f, rr) = remotecall_fetch(f ∘ fetch, rr.where, rr)

isdone(rr) = fetch_from_owner(istaskdone, rr)
isfailed(rr) = fetch_from_owner(istaskfailed, rr)

@testset "RemoteChannel allows put!/take! from thread other than 1" begin
    ws = ts = product(1:2, 1:2)

    # We want (the default) laziness, so that we wait for `Worker.c_state`!
    procs_added = addprocs(2; exeflags, lazy=true)

    @testset "from worker $w1 to $w2 via 1" for (w1, w2) in ws
        @testset "from thread $w1.$t1 to $w2.$t2" for (t1, t2) in ts
            p1 = procs_added[w1]
            p2 = procs_added[w2]
            chan_id = first(procs_added)
            chan = RemoteChannel(chan_id)
            send = call_on(p1, t1) do
                put!(chan, nothing)
            end
            recv = call_on(p2, t2) do
                take!(chan)
            end

            # Wait on the spawned tasks on the owner. Note that we use
            # timedwait() instead of @sync to avoid deadlocks.
            t1 = Threads.@spawn fetch_from_owner(wait, recv)
            t2 = Threads.@spawn fetch_from_owner(wait, send)
            @test timedwait(() -> istaskdone(t1), 60) == :ok
            @test timedwait(() -> istaskdone(t2), 60) == :ok

            # Check the tasks
            @test isdone(send)
            @test isdone(recv)

            @test !isfailed(send)
            @test !isfailed(recv)
        end
    end

    rmprocs(procs_added)
end

@testset "Concurrent construction of one remote reference" begin
    pid = only(addprocs(1; exeflags=(exeflags[1:end-1]..., "--threads=4")))
    ndups = remotecall_fetch(pid) do
        n = Threads.nthreads()
        count(1:1000) do _
            rrid = Distributed.RRID()
            arrived = Threads.Atomic{Int}(0)
            rs = Vector{Any}(undef, n)
            Threads.@threads :static for i in 1:n
                Threads.atomic_add!(arrived, 1)
                while arrived[] < n
                    GC.safepoint()
                end
                # what deserializing a reference does
                rs[i] = Future(myid(), rrid)
            end
            any(r -> r !== rs[1], rs)
        end
    end
    @test ndups == 0
    rmprocs(pid)
end
