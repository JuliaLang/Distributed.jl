```@meta
CurrentModule = DistributedNext
```

# Changelog

This documents notable changes in DistributedNext.jl. The format is based on
[Keep a Changelog](https://keepachangelog.com).

## Unreleased

### Fixed
- Fixed behaviour of `isempty(::RemoteChannel)`, which previously had the
  side-effect of taking an element from the channel ([#3]).

### Changed
- Added a `project` argument to [`addprocs(::AbstractVector)`](@ref) to specify
  the project of a remote worker ([#2]).
