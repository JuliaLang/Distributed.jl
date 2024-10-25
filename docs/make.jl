import Revise
import Changelog
using DistributedNext
import Documenter
using Documenter: Remotes, DocMeta, makedocs, deploydocs

DocMeta.setdocmeta!(DistributedNext, :DocTestSetup, :(using DistributedNext); recursive=true)

# Always trigger a revise to pick up the latest docstrings. This is useful when
# working with servedocs(). If you are using servedocs(), run it like this:
#
# julia> servedocs(; include_dirs=["src"], skip_files=["docs/src/changelog.md"])
#
# Otherwise it'll get into an infinite loop as the changelog is constantly
# regenerated and triggering LiveServer.
Revise.revise()

# Build the changelog. Note that _changelog.md is the source and changelog.md is
# the destination. It's named that way for the vain reason of a nicer URL.
Changelog.generate(
    Changelog.Documenter(),
    joinpath(@__DIR__, "src/_changelog.md"),
    joinpath(@__DIR__, "src/changelog.md"),
    repo="JuliaParallel/DistributedNext.jl"
)

makedocs(;
         repo = Remotes.GitHub("JuliaParallel", "DistributedNext.jl"),
         format = Documenter.HTML(
             prettyurls=get(ENV, "CI", "false") == "true",
             size_threshold_warn=500_000,
             size_threshold=600_000),
         modules = [DistributedNext],
         sitename = "DistributedNext",
         pages = [
             "DistributedNext" => "index.md",
             "changelog.md"
         ],
         warnonly = [:missing_docs, :cross_references],
         )

deploydocs(repo = "github.com/JuliaParallel/DistributedNext.jl.git")
