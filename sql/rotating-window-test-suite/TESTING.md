# Testing

This directory separates three different goals.

## 1. `tests/integration_tests.sql`

Automated functional tests.

It validates the main invariants of the current implementation:

```text
register
adaptive insert-window policy setup
bootstrap
mixed incremental with default window fallback
DELETE-only incremental
zero-change incremental
automatic window_size = 1 rotation from threshold policy
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

The process is configured with:

```text
default_insert_window_size = 2
policy = 1:1
```

so a single INSERT automatically resolves to an effective window of `1`, while larger batches fall back to the default `2`.

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
malformed adaptive policy
adaptive policy window not smaller than default
failed policy replacement preserves the previous configuration
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

## 3. `benchmarks/benchmark.sql`

Parameterized performance benchmark focused on the current fixed-vs-adaptive rotating-window behavior.

Default configuration:

```text
BaseRows                       = 100,000
TotalClasses                   = 100
WindowSize                     = 10

A MASSIVE APPEND-ONLY
InsertRows                     = 5,000
UpdateRows                     = 0
DeleteRows                     = 0

B APPEND-HEAVY
InsertRows                     = 5,000
UpdateRows                     = 10
DeleteRows                     = 10

C ADAPTIVE WINDOW
Runs                           = 10
DefaultBatchInsertRows         = 5,000
ThresholdBatchInsertRows       = 500
ThresholdMaxInsertRows         = 500
ThresholdWindowSize            = 1
```

Scenario C alternates large and small INSERT-only batches on the same process:

```text
5,000 INSERTs -> no threshold match -> effective window 10
500 INSERTs   -> threshold 500:1    -> effective window 1
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

The Full comparison is used in scenarios A and B. Scenario C instead keeps one process alive for 10 consecutive Incremental runs so the benchmark can observe the adaptive window decision and pointer progression over time.

With the current implementation, `FINALIZE` time includes:

```text
promotion of refresh_run_row into class_memory
process-state update
cleanup of refresh_run_row
cleanup of refresh_run_delete
cleanup of refresh_run_dirty_class
marking refresh_run as COMPLETED
```

It also reports:

```text
run rows
dirty classes
INSERT / UPDATE / DELETE counts
rows per class
min / max / average class size
max-min class-size spread
```

For the adaptive scenario it additionally reports:

```text
run number
batch mode
inserted rows
window_start_class
effective_window_size
candidate_next_start
prepare time
finalize time
```

The benchmark contains assertions that verify the expected adaptive behavior, including the default/threshold effective-window sequence and pointer advancement by the effective window used by each run.

Run each configuration multiple times and report the median rather than a single observation.

For meaningful published results, record:

```text
SQL Server version and edition
CPU
RAM
storage
dataset size
total_classes
default_insert_window_size
adaptive threshold policy
INSERT / UPDATE / DELETE volumes
```

`SET STATISTICS TIME` and `SET STATISTICS IO` are included but commented out.

---
