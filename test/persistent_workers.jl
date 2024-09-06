include("testhelpers/PersistentWorkers.jl")
using .PersistentWorkers
using Test
using Random
using Distributed

@testset "PersistentWorkers.jl" begin
    cookie = randstring(16)
    port = rand(9128:9999) # TODO: make sure port is available?
    worker = run(
        `$(Base.julia_exename()) --startup=no --project=$(dirname(@__DIR__)) -L testhelpers/PersistentWorkers.jl
        -e "using .PersistentWorkers; wait(start_worker_loop($port; cluster_cookie=$(repr(cookie)))[1])"`;
        wait=false)
    try
    cluster_cookie(cookie)
    sleep(1)

    p = addprocs(PersistentWorkerManager(port))[]
    @test procs() == [1, p]
    @test workers() == [p]
    @test remotecall_fetch(myid, p) == p
    rmprocs(p)
    @test procs() == [1]
    @test workers() == [1]
    @test process_running(worker)
    # this shouldn't error
    @everywhere 1+1

    # try the same thing again for the same worker
    p = addprocs(PersistentWorkerManager(port))[]
    @test procs() == [1, p]
    @test workers() == [p]
    @test remotecall_fetch(myid, p) == p
    rmprocs(p)
    @test procs() == [1]
    @test workers() == [1]
    @test process_running(worker)
    # this shouldn't error
    @everywhere 1+1
    finally
        kill(worker)
    end
end
