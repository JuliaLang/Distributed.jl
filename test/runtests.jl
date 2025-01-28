# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test
using Distributed

# On GitHub Actions CI (on the Distributed.jl repo): yes we run Aqua.
# On Base Julia Buildkite CI (on the JuliaLang/julia repo): no Aqua
# When the user manually runs `make test-Distributed` locally: no Aqua
if Base.get_bool_env("GITHUB_ACTIONS", false)
    @testset "Aqua.jl tests" begin
        include("aqua.jl")
    end
end

# Run the distributed test outside of the main driver since it needs its own
# set of dedicated workers.
include(joinpath(Sys.BINDIR, "..", "share", "julia", "test", "testenv.jl"))
disttestfile = joinpath(@__DIR__, "distributed_exec.jl")

@testset let cmd = `$test_exename $test_exeflags $disttestfile`
    @test success(pipeline(cmd; stdout=stdout, stderr=stderr)) && ccall(:jl_running_on_valgrind,Cint,()) == 0
end

include("managers.jl")
