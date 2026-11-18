using Distributed: Distributed

using JET: JET
using Serialization: Serialization
using Test: Test, @testset

# We don't want to fail PkgEval because of a JET failure
# Therefore, we don't put the JET tests in the regular Distributed test suite
# Instead, we put it in a separate CI job, which runs on the Distributed repo

@testset "JET" begin
    ignored_modules = (
        # We will ignore Base:
        Base,

        # The compiler is a separate root module, not a submodule of Base, but
        # it is reached through Base's backtrace handling:
        Base.Compiler,

        # We'll ignore the Serialization stdlib:
        Serialization,
    )
    JET.test_package(Distributed; ignored_modules)
end
