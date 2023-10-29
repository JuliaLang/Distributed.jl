using Distributed
using Documenter: DocMeta, makedocs, deploydocs

DocMeta.setdocmeta!(Distributed, :DocTestSetup, :(using Distributed); recursive=true)

makedocs(;
    modules = [Distributed],
    sitename = "Distributed",
    pages = Any[
        "Distributed" => "index.md",
    ],
    checkdocs = :exports,
    warnonly = [:cross_references],
)

deploydocs(repo = "github.com/JuliaLang/Distributed.jl.git")
