using Aqua
using Distributed

Aqua.test_all(
    Distributed,
    # This should be excluded, but it's not clear how to do that on Aqua's API
    # given it's not-defined. (The Julia Base ambiguity test does it something like this)
    # ambiguities=(exclude=[GlobalRef(Distributed, :cluster_manager)])
)
