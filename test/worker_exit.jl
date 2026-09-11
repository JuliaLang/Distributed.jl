# This file is a part of Julia. License is MIT: https://julialang.org/license

@testset "Worker exits when reporting master disconnection fails" begin
    w = Distributed.worker_from_id(only(addprocs(1)))
    proc = w.config.process
    try
        # Suppress the expected disconnection error on the master.
        Distributed.set_worker_state(w, Distributed.W_TERMINATING)

        # Simulate the master dying: close the output pipe before the connection,
        # so the worker's fatal error report fails when it tries to write to it.
        close(proc.out)
        close(w.r_stream)
        @test timedwait(() -> process_exited(proc), 30) == :ok
        @test proc.exitcode == 1
    finally
        # Reap the worker even if it fails to exit on its own.
        if process_running(proc)
            kill(proc)
        end
        wait(proc)
    end
end
