# This file is a part of Julia. License is MIT: https://julialang.org/license

using Test
using Distributed

# only run these if Aqua is installed. i.e. Pkg.test has installed it, or it is provided as a shared package
if Base.locate_package(Base.PkgId(Base.UUID("4c88cf16-eb10-579e-8560-4a9242c79595"), "Aqua")) isa String
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
