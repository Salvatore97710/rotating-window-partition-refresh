# Rotating Window Partition Refresh

Reference implementation of a **stable-class** refresh strategy designed primarily for **append-heavy** sources and consumers, such as Power BI, that can overwrite entire partitions.

## Project status

This repository is a **reference implementation / personal project in the prototype stage**.

The goal is to demonstrate and validate the proposed partitioning and refresh mechanism, with particular focus on:

- stable assignment of keys to classes;
- controlled distribution of new records through a rotating window;
- adaptive window selection based on INSERT batch size;
- limiting the number of classes made dirty by INSERTs;
- consistent handling of INSERT, UPDATE, and DELETE operations;
- separation between PREPARE, consumer refresh, and FINALIZE;
- preserving invariants over time.

The project should primarily be evaluated in terms of model correctness, invariants, trade-offs, and the quality of the reference implementation.

**Production readiness is a separate goal**. This repository is not a ready-to-use enterprise solution: it includes functional tests, negative/fault-injection tests, and an initial exploratory benchmark, while concurrency, scaling, and repeated benchmarks on different hardware still require further investigation.

---

# When to use this strategy

The strategy is designed primarily for **large, predominantly append-only fact tables**, where:

- a unique and stable `source_key` exists;
- there is no useful natural key for building balanced partitions;
- a reliable creation or last-update timestamp is available;
- INSERTs are much more frequent than UPDATEs and DELETEs;
- the downstream consumer can overwrite entire partitions;
- the problem is not only to identify the delta, but to control **which and how many partitions must be regenerated**.

The timestamp is used to detect change, but it is not the primary partitioning criterion.

Each key receives a stable technical class:

```text
source_key
    |
    v
stable class_id
```

The delta determines which classes are dirty; the consumer overwrites only those partitions.

## The problem

With very large datasets, a single change may require overwriting the entire partition that contains it:

```text
1 UPDATE
   |
   v
dirty class
   |
   v
overwrite entire partition
```

If the partition is very large, the cost can be high even when the delta is minimal.

With technical classes:

```text
time
-> detects change

class_id
-> controls refresh
```

The goal is to maintain partitions over time that are:

```text
stable
+
reasonably balanced
+
more predictable in refresh cost
```

---

# Core idea

Each `source_key` receives a `class_id` and keeps it once classified.

The delta is not used to send only changed rows: it is used to determine **which classes must be fully regenerated**.

The two main controls are:

```text
total_classes
    -> overall partitioning granularity

default_insert_window_size
    -> maximum/fallback window automatically used by INSERTs
       when no smaller threshold applies
```

An **optional adaptive policy** can be added to reduce the window for smaller batches. An explicit override passed to an individual Incremental run still takes precedence over the policy.

The algorithm distinguishes three modes:

```text
BOOTSTRAP
INCREMENTAL
FULL
```

## Initial configuration

After installing the SQL objects, the configuration flow is:

```text
usp_register_refresh_process
        |
        v
refresh_process
(process_id, total_classes, default window)
        |
        v
usp_set_insert_window_policy   [optional]
        |
        v
refresh_process_insert_threshold
(current process policy)
```

`usp_set_insert_window_policy` must therefore be executed **after** `usp_register_refresh_process`, because it reads `default_insert_window_size` from the process and validates thresholds against it. If no policy is configured, Incremental runs continue to use the default exactly as in the previous version.

---

# 1. Bootstrap

Bootstrap is executed when no class memory exists yet.

The initial population is distributed across:

```text
1 .. total_classes
```

using:

```text
class_id =
(technical_offset % total_classes) + 1
```

The technical numbering has no business meaning; it is used only to distribute the initial population across the class space.

All classes become dirty:

```text
DIRTY_BOOTSTRAP =
1 .. total_classes
```

After downstream success, `FINALIZE` makes the first `class_memory` official.

---

# 2. Incremental

Incremental compares the current snapshot with the previous stable memory and identifies:

```text
INSERT
UPDATE
DELETE
UNCHANGED
```

## INSERT

A new key does not yet have a class.

Before assignment, the framework counts the INSERTs in the run and determines an **effective window**. Precedence is:

```text
1. per-run @InsertWindowSize override, if provided
2. first policy threshold that contains InsertCount
3. default_insert_window_size as fallback
```

Example:

```text
total_classes              = 100
default_insert_window_size = 10

policy:
INSERT <=    500 -> window 1
INSERT <=  5,000 -> window 4
INSERT <= 20,000 -> window 7
otherwise         -> window 10
```

A run with 300 INSERTs uses one class; a run with 3,000 INSERTs uses 4; a run with 50,000 INSERTs falls back to the default 10.

Once the effective window `w` has been resolved, INSERTs are assigned only to classes inside the current rotating window and distributed cyclically:

```text
class_id =
(
    (
        window_start_class - 1
        + (local_offset % w)
    )
    % total_classes
) + 1
```

The next run's starting point advances by `w` only when the run contains at least one INSERT.

Rotation prevents the same classes from always receiving new records, while the adaptive policy avoids involving the maximum window when the batch is small.

## Configuring the adaptive policy

The policy is stored in:

```text
refresh_process_insert_threshold
```

Each row represents an upper batch-size bound:

```text
process_id | max_insert_count | insert_window_size
-----------|------------------|-------------------
7          | 500              | 1
7          | 5000             | 4
7          | 20000            | 7
```

With `default_insert_window_size = 10`, the semantics are:

```text
INSERT <=    500 -> 1 class
INSERT <=  5,000 -> 4 classes
INSERT <= 20,000 -> 7 classes
otherwise         -> 10 classes
```

The configuration is set after `usp_register_refresh_process` through:

```sql
EXEC dbo.usp_set_insert_window_policy
    @ProcessName = N'my_process',
    @Policy = N'500:1,5000:4,20000:7';
```

The format is:

```text
max_insert_count:insert_window_size,...
```

The number of thresholds is arbitrary: it is not necessary to configure every value from `1` to `m-1`. The stored procedure validates that thresholds are positive, unique, and increasing, and that windows are positive, unique, increasing, and smaller than the default.

A new call fully replaces the process's previous policy; the table therefore stores **only the current configuration**, not policy history. `NULL` or an empty string removes the adaptive policy.

If `default_insert_window_size` is changed, the policy must be configured again immediately after `usp_register_refresh_process`, because the new default becomes the new automatic/fallback limit.

---

## UPDATE

If a key already exists but its timestamp has changed:

```text
change_type = UPDATE
class_id    = historical class
```

The class is not recalculated and becomes dirty.

## DELETE

A DELETE is detected when a `source_key` that existed in the previous memory no longer exists in the current snapshot.

The deleted key does not enter the new snapshot; its historical class becomes dirty so that the consumer can overwrite that partition and effectively remove the record downstream.

The DELETE is also recorded separately for audit purposes.

## UNCHANGED

If the key and timestamp have not changed:

```text
change_type = UNCHANGED
```

the class remains unchanged and does not become dirty.

## Incremental dirty classes

```text
DIRTY_INCREMENTAL =
    INSERT_CLASSES
    UNION
    UPDATE_CLASSES
    UNION
    DELETE_CLASSES
```

The total number of dirty classes can therefore exceed the run's **effective window**: the rotating window limits only the spread of INSERTs, while UPDATEs and DELETEs may dirty historical classes outside the window.

---

# 3. Full

Full does not assign new classes.

It works only on keys already present in the previous memory:

```text
current_snapshot
INNER JOIN
class_memory
ON source_key
```

Each known key keeps its historical `class_id`.

All classes become dirty:

```text
DIRTY_FULL =
1 .. total_classes
```

A new key present in the source but not yet classified:

```text
DOES NOT receive a class_id
DOES NOT enter the FULL run
```

It will be classified by a subsequent Incremental run.

A deleted key does not enter the new Full snapshot and, because all classes are overwritten, disappears downstream.

---

# Rotating window, adaptive policy, and granularity

Without a rotating window, distributing each new batch across the full class space can quickly increase the number of partitions involved.

With:

```text
total_classes = 100
```

a global distribution may produce:

```text
10 INSERTs  -> up to 10 dirty classes
50 INSERTs  -> up to 50 dirty classes
100 INSERTs -> up to 100 dirty classes
```

With:

```text
default_insert_window_size = 10
```

INSERTs from the same run can instead involve at most 10 classes in automatic mode, and even fewer when a policy threshold returns a smaller effective window.

## Effective-window trade-off

The effective window `w` controls a trade-off between **current-run cost** and **growth of individual partitions**.

With `I` new records and effective window `w`:

```text
dirty classes caused by INSERTs <= min(I, w)

average new records per active class ~= I / w
```

Therefore:

```text
smaller w
-> fewer dirty classes
-> more localized current run
-> more INSERTs per active class
-> faster growth of individual partitions

larger w
-> more dirty classes
-> broader current run
-> fewer INSERTs per active class
-> more distributed growth
```

The choice therefore depends on the desired trade-off between:

```text
immediate refresh cost
vs
control over growth of individual partitions
```

In practice:

```text
few INSERTs
-> smaller window
-> fewer partitions to overwrite

many INSERTs
-> larger window
-> more partitions involved
-> fewer new records concentrated in each partition
```

In the extreme case of one new record per run, a policy such as:

```text
1:1
```

automatically resolves the window to `1` and progressively visits all classes without requiring an override on every run.

The starting class of the next run is:

```text
next_start =
((current_start - 1 + effective_window_size) % total_classes) + 1
```

## `total_classes`

`total_classes` controls overall granularity.

More classes mean smaller average partitions for the same population size.

Changing `total_classes`, however, changes the class space of already classified records; with populated memory it therefore requires an explicit repartition and a new Bootstrap.

---

# Class stability

Rotation affects only the assignment of **new** keys.

```text
INSERT
-> new class from the rotating window

UPDATE
-> keeps historical class

UNCHANGED
-> keeps historical class

DELETE
-> uses historical class to determine the dirty partition

FULL
-> keeps historical class
```

The strategy therefore combines:

```text
stability of each individual key
+
rotation of the entry point for new records
```

---

# Operational flow

```text
                     PROCESS
                        |
                  memory exists?
                    |             |
                   NO            YES
                    |             |
                    v             v
               BOOTSTRAP      choose mode
                                |       |
                          INCREMENTAL   FULL
                                |       |
                    ------------+-------+
                               |
                               v
                            PREPARE
                               |
                               v
                         PREPARED RUN
                               |
                               v
                         dirty classes
                               |
                               v
                    overwrite downstream
                               |
                     consumer successful?
                           |        |
                          NO       YES
                           |        |
                           |        v
                           |     FINALIZE
                           |        |
                           v        v
                     retry same   COMPLETED
                       run_id      new memory
```

## PREPARE

Each mode creates a new `run_id` with status `PREPARED`.

The run contains:

```text
classified snapshot
dirty classes
INSERT / UPDATE / DELETE counts
effective window resolved for the run
rotating-window state
```

`PREPARE` does not yet make the new memory official.

For an Incremental run, the relevant internal sequence is:

```text
current snapshot
    -> recognize already-known keys
    -> count INSERTs
    -> resolve effective window
    -> assign new keys
    -> build dirty classes
    -> PREPARED RUN
```

## Consumer

The consumer reads the dirty classes and, for each one, retrieves all current rows belonging to that `class_id`.

The downstream partition is overwritten in full. The consumer receives the complete current class, not only the changed records.

A dirty class may also contain zero rows; in that case the partition must be cleared.

## FINALIZE

`FINALIZE` is executed only after all downstream overwrites succeed.

It promotes:

```text
refresh_run_row
        |
        v
class_memory
```

updates `last_successful_run_id`, and moves the run from:

```text
PREPARED -> COMPLETED
```

For a successfully completed Incremental run it also promotes:

```text
candidate_next_window_start
        |
        v
next_window_start_class
```

Bootstrap and Full do not advance the rotating window.

A successful FINALIZE removes operational staging:

```text
refresh_run_row
refresh_run_delete
refresh_run_dirty_class
```

while `refresh_run` remains as lightweight history.

## Failure and retry

If the consumer fails:

```text
DO NOT run FINALIZE
DO NOT modify class_memory
DO NOT advance the rotating window
```

The run remains `PREPARED`.

A retry must use the same `run_id` and therefore the same materialized snapshot; a new PREPARE must not be created.

---

# Tests and benchmark

The repository includes:

- automated functional tests;
- negative and fault-injection tests;
- an exploratory benchmark covering both the fixed-window baseline and the adaptive policy.

The benchmark is not a production-capacity claim; it is meant to observe prototype behavior on a single machine and compare different refresh patterns.

## Exploratory benchmark

Common configuration:

```text
initial rows                      = 100,000
total_classes                     = 100
default_insert_window_size        = 10
```

Three scenarios were executed.

### Scenario A — Append-only

After Bootstrap, the following are added:

```text
INSERT = 5,000
UPDATE = 0
DELETE = 0
```

The Incremental run uses the default window of `10`.

Observed result:

```text
PREPARE   = 2.320 s
FINALIZE  = 2.175 s
-------------------
total     = 4.495 s

dirty classes = 10 out of 100
```

Observed final distribution:

```text
min rows per class = 1,000
max rows per class = 1,500
average            = 1,050
spread             = 500
```

This scenario shows the base behavior of the rotating window: a large import of new records is confined to the classes in the current window rather than involving the full partition space.

### Scenario B — Append-heavy

After Bootstrap, the following are applied:

```text
INSERT = 5,000
UPDATE = 10
DELETE = 10
```

Observed result:

```text
PREPARE   = 14.356 s
FINALIZE  = 1.359 s
-------------------
total     = 15.715 s

dirty classes = 20 out of 100
```

The window continues to limit the spread of INSERTs, while UPDATEs and DELETEs may dirty historical classes outside the current window.

Observed final distribution:

```text
min rows per class = 999
max rows per class = 1,500
average            = 1,049.90
spread             = 501
```

### Scenario C — Adaptive window

The adaptive scenario configures:

```text
default_insert_window_size = 10

policy:
INSERT <= 500 -> window 1
otherwise     -> window 10
```

After a single Bootstrap, 10 consecutive Incremental runs are executed, alternating:

```text
5,000 INSERTs -> default window = 10
500 INSERTs   -> threshold window = 1
```

The observed sequence of effective windows is:

```text
10, 1, 10, 1, 10, 1, 10, 1, 10, 1
```

and the pointer advances each time by the effective window actually used:

```text
run 1  -> start 1  -> next 11
run 2  -> start 11 -> next 12
run 3  -> start 12 -> next 22
run 4  -> start 22 -> next 23
...
run 10 -> start 55 -> next 56
```

Observed timings:

```text
run 1   default    5,000 INSERTs  = 4.614 s
run 2   threshold    500 INSERTs  = 6.225 s
run 3   default    5,000 INSERTs  = 7.633 s
run 4   threshold    500 INSERTs  = 4.687 s
run 5   default    5,000 INSERTs  = 5.264 s
run 6   threshold    500 INSERTs  = 9.121 s
run 7   default    5,000 INSERTs  = 11.595 s
run 8   threshold    500 INSERTs  = 3.385 s
run 9   default    5,000 INSERTs  = 5.214 s
run 10  threshold    500 INSERTs  = 6.500 s
```

Total for the 10 Incremental runs:

```text
64.238 s
```

Average per run:

```text
6.424 s
```

The benchmark shows that the policy is actually resolved at runtime according to batch size and that `refresh_run.insert_window_size` stores the effective window used by each run.

### Bootstrap and Full reference timings

Different timings were observed across scenarios in the same execution, with the first Bootstrap being substantially slower than the others. Because that first value is plausibly affected by cold cache, compilation, and initial database state, only the best observed timings are reported here as an exploratory reference:

```text
best Bootstrap
PREPARE   = 2.359 s
FINALIZE  = 1.101 s
-------------------
total     = 3.460 s

best Full
PREPARE   = 1.442 s
FINALIZE  = 2.454 s
-------------------
total     = 3.896 s
```

These timings should not be interpreted as guaranteed performance. They are initial experimental evidence from the prototype on a single execution and a single machine.

A rigorous characterization would require:

```text
repeated runs
medians
larger datasets
different hardware
I/O and CPU measurements
```

The most important benchmark result is therefore not any single absolute timing, but the observed behavior of the invariants:

```text
append-only
-> 5,000 INSERTs confined to 10 classes

append-heavy
-> INSERTs confined to the window
-> UPDATEs/DELETEs may add historical dirty classes

adaptive
-> large batch -> window 10
-> small batch -> window 1
-> pointer advances consistently with the effective window
```

---

# Summary

The strategy combines four properties:

```text
STABLE CLASSES
each key keeps its partition

ADAPTIVE WINDOW
the batch determines how many classes to use within the configured default

ROTATING WINDOW
new records are distributed progressively

OVERWRITE BY CLASS
the delta determines which partitions to rebuild
```

The goal is not to achieve a perfectly uniform distribution on every individual run, but to maintain reasonably balanced partitions over time with a more predictable refresh cost.

> **PREPARE builds a candidate snapshot; the consumer updates the dirty classes; FINALIZE makes that snapshot the official process state.**
