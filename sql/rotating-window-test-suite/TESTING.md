# Testing

This directory separates three different goals.

## 1. `tests/integration_tests.sql`

Automated functional tests.

It validates the main invariants of the current implementation:

```text
register
bootstrap
mixed incremental
DELETE-only incremental
zero-change incremental
window_size = 1 rotation
FULL semantics
usp_get_dirty_class
post-FINALIZE operational staging cleanup
refresh_run audit history preservation
```

For a successful `FINALIZE`, the tests also verify the staging lifecycle:

```text
PREPARED
    -> refresh_run_row / refresh_run_delete / refresh_run_dirty_class
       are available to the run

COMPLETED
    -> the three operational staging tables contain no rows for that RunId
    -> refresh_run remains as lightweight audit history
```

The script uses isolated objects and the process:

```text
test_rotating_ci
```

It is rerunnable: previous state for that process is cleaned at the start.

A successful execution reaches:

```text
ALL AUTOMATED INTEGRATION TESTS PASSED
```

Any violated assertion raises a `570xx` error.

---

## 2. `tests/break_tests.sql`

Negative and fault-injection tests.

These tests intentionally perform operations that should fail or stress failure semantics:

```text
invalid total_classes
invalid window size
unknown process
Incremental before Bootstrap
Full before Bootstrap
second PREPARED run
Bootstrap with populated memory
invalid per-run window override
change total_classes with populated memory
request of a non-dirty class
double FINALIZE
simulated consumer failure with PREPARED retry
source mutation between PREPARE and FINALIZE
successful FINALIZE cleanup of operational staging
injected failure during FINALIZE after staging cleanup
rollback restoration of the PREPARED staging
retry of the same RunId after the injected failure
```

A test passes when the framework rejects the invalid operation with the expected error or preserves its state after the injected failure.

The rollback test temporarily creates:

```text
dbo.trg_test_force_finalize_failure
```

on `dbo.refresh_run`.

The trigger throws when the run is being marked `COMPLETED`, after the updated
`FINALIZE` has already promoted `class_memory` and deleted the operational
staging inside the transaction.

The test then verifies that rollback restores:

```text
refresh_run.status = PREPARED
class_memory
refresh_process state
refresh_run_row
refresh_run_delete
refresh_run_dirty_class
```

The same `RunId` is then finalized successfully and the temporary trigger is
dropped.

Run this file only in a development/test database.

---

## 3. `benchmarks/benchmark_v2_fixed.sql`

Parameterized performance benchmark with separated workloads.

Default configuration:

```text
BaseRows              = 100,000
TotalClasses          = 100
WindowSize            = 10

A APPEND-ONLY
InsertRows            = 5,000

B APPEND-HEAVY
InsertRows            = 5,000
UpdateRows            = 100
DeleteRows            = 10

C HIGH-CHURN
InsertRows            = 5,000
UpdateRows            = 5,000
DeleteRows            = 1,000

D ROTATING CYCLE
Runs                  = 10
InsertRowsPerRun      = 5,000
```

It measures elapsed time separately for:

```text
source generation
BOOTSTRAP prepare
BOOTSTRAP finalize
source mutation
INCREMENTAL prepare
INCREMENTAL finalize
FULL prepare
FULL finalize
```

With the current implementation, `FINALIZE` time includes:

```text
promotion of refresh_run_row into class_memory
process-state update
cleanup of refresh_run_row
cleanup of refresh_run_delete
cleanup of refresh_run_dirty_class
marking refresh_run as COMPLETED
```

Therefore timings produced after this lifecycle change should not be compared
directly with old benchmark results obtained before staging cleanup was part of
`FINALIZE`.

It also reports:

```text
run rows
dirty classes
INSERT / UPDATE / DELETE counts
rows per class
min / max / average class size
max-min class-size spread
```

Suggested scales:

```text
10k
100k
500k
1M
```

Run each scale multiple times and report the median rather than a single observation.

For meaningful published results, record:

```text
SQL Server version and edition
CPU
RAM
storage
dataset size
total_classes
insert_window_size
INSERT / UPDATE / DELETE volumes
```

`SET STATISTICS TIME` and `SET STATISTICS IO` are included but commented out.

---

## Not yet fully automated

Some areas require a multi-session or external-consumer harness and should remain explicit future work:

```text
true concurrent PREPARE attempts from separate SQL sessions
application-lock contention timing
consumer failure after only some Power BI partitions were refreshed
real Power BI / Fabric timeout and retry behavior
network/API failures
long-running transaction interruption / server restart
performance under concurrent workload
```

These are different from algorithmic correctness and should be tested before claiming production readiness.
