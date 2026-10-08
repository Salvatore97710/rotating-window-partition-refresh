# Rotating Window Partition Refresh

Reference implementation of a **stable-class** refresh strategy designed mainly for **append-heavy** sources and consumers, such as Power BI, that can overwrite entire partitions.

## Project status

This repository is a **reference implementation / personal project in a prototypal stage**.

The goal is to demonstrate and validate the proposed partitioning and refresh mechanism, with particular attention to:

- stability of key-to-class assignment;
- controlled distribution of new records through a rotating window;
- limiting the number of classes made dirty by INSERTs;
- consistent handling of INSERT, UPDATE, and DELETE;
- separation between PREPARE, consumer refresh, and FINALIZE;
- preservation of invariants over time.

The project should mainly be evaluated in terms of model correctness, invariants, trade-offs, and quality of the reference implementation.

**Production readiness is a separate goal**. The repository is not an enterprise-ready solution: functional tests, negative/fault-injection tests, and a first exploratory benchmark are included, but concurrency, scaling, and repeated benchmarks on different hardware still need further investigation.

---

# When to use this strategy

The strategy is designed mainly for **large and predominantly append-only fact tables**, where:

- a unique and stable `source_key` exists;
- there is no natural key useful for building balanced partitions;
- a reliable creation or last-update timestamp is available;
- INSERTs are much more frequent than UPDATEs and DELETEs;
- the downstream consumer can overwrite entire partitions;
- the problem is not only finding the delta, but controlling **which and how many partitions must be regenerated**.

The timestamp is used to detect change, but it is not the main partitioning criterion.

Each key instead receives a stable technical class:

```text
source_key
    |
    v
stable class_id
```

The delta determines which classes are dirty; the consumer overwrites only those partitions.

## The problem

With very large datasets, a single modification may require overwriting the entire partition that contains it:

```text
1 UPDATE
   |
   v
dirty class
   |
   v
overwrite of the entire partition
```

If the partition is very large, the cost can be high even when the actual delta is minimal.

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
with more predictable refresh costs
```

---

# Core idea

Each `source_key` receives a `class_id` and, once classified, keeps it.

The delta is not used to send only changed rows: it is used to determine **which classes must be regenerated in full**.

The two main control parameters are:

```text
total_classes
    -> overall partitioning granularity

insert_window_size
    -> maximum number of classes usable by INSERTs in one run
```

The algorithm distinguishes three modes:

```text
BOOTSTRAP
INCREMENTAL
FULL
```

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

The technical numbering has no business meaning: it is used only to distribute the initial population across the class space.

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

INSERTs are assigned only to the classes included in the current rotating window.

Example:

```text
total_classes      = 100
insert_window_size = 10

run 1  -> classes 1..10
run 2  -> classes 11..20
run 3  -> classes 21..30
...
run 10 -> classes 91..100
run 11 -> classes 1..10
```

Within the window, INSERTs are distributed cyclically:

```text
class_id =
(
    (
        window_start_class - 1
        + (local_offset % insert_window_size)
    )
    % total_classes
) + 1
```

This limits the maximum number of classes made dirty by INSERTs.

With:

```text
insert_window_size = 10
```

even a very large batch can use at most 10 classes.

Rotation prevents the same classes from always receiving new records.

## UPDATE

If a key already exists but the timestamp has changed:

```text
change_type = UPDATE
class_id    = historical class
```

The class is not recalculated and becomes dirty.

## DELETE

A DELETE is detected when a `source_key` present in the previous memory no longer exists in the current snapshot.

The deleted key does not enter the new snapshot; its historical class becomes dirty, so the consumer can overwrite that partition and effectively remove the record downstream.

The DELETE is also recorded separately for audit.

## UNCHANGED

If the key and timestamp have not changed:

```text
change_type = UNCHANGED
```

the class remains unchanged and does not become dirty.

## Dirty classes in Incremental

```text
DIRTY_INCREMENTAL =
    INSERT_CLASSES
    UNION
    UPDATE_CLASSES
    UNION
    DELETE_CLASSES
```

The number of dirty classes can therefore exceed `insert_window_size`: the rotating window limits only INSERT dispersion.

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
DOES NOT enter FULL
```

It will be classified by a subsequent Incremental.

A deleted key does not enter the new Full snapshot and, because all classes are overwritten, disappears downstream.

---

# Rotating window and granularity

Without a rotating window, distributing every new batch across the whole class space can quickly increase the number of partitions involved.

With:

```text
total_classes = 100
```

a global distribution can produce:

```text
10 INSERTs  -> up to 10 dirty classes
50 INSERTs  -> up to 50 dirty classes
100 INSERTs -> up to 100 dirty classes
```

With:

```text
insert_window_size = 10
```

INSERTs from the same run can instead involve at most 10 classes.

## `insert_window_size` trade-off

`insert_window_size` controls a trade-off between **the cost of the current run** and **the growth of individual partitions**.

With `I` new records and window size `w`:

```text
dirty classes due to INSERTs <= min(I, w)

average new records per active class ≈ I / w
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
control over individual partition growth
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

In the extreme case of one new record per run, `insert_window_size = 1` makes it possible to visit all classes progressively.

The starting class of the next run is:

```text
next_start =
((current_start - 1 + insert_window_size) % total_classes) + 1
```

## `total_classes`

`total_classes` controls the overall granularity.

More classes mean, for the same population, smaller partitions on average.

Changing `total_classes`, however, changes the existing class space; with populated memory, it therefore requires an explicit repartition and a new Bootstrap.

---

# Class stability

Rotation concerns only the assignment of **new** keys.

```text
INSERT
-> new class from the rotating window

UPDATE
-> keeps the historical class

UNCHANGED
-> keeps the historical class

DELETE
-> uses the historical class to determine the dirty partition

FULL
-> keeps the historical class
```

The strategy therefore combines:

```text
stability of the individual key
+
rotation of the entry point for new records
```

---

# Operational flow

```text
                     PROCESS
                        |
                 memory already exists?
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
                    downstream overwrite
                               |
                     consumer succeeded?
                           |        |
                          NO       YES
                           |        |
                           |        v
                           |     FINALIZE
                           |        |
                           v        v
                     retry same    COMPLETED
                       run_id      new memory
```

## PREPARE

Each mode creates a new `run_id` in `PREPARED` state.

The run contains:

```text
classified snapshot
dirty classes
INSERT / UPDATE / DELETE counts
rotating-window state
```

`PREPARE` does not yet make the new memory official.

## Consumer

The consumer reads the dirty classes and, for each one, retrieves all current rows belonging to that `class_id`.

The downstream partition is overwritten in full. The consumer does not receive only the changed records.

A dirty class can also contain zero rows: in that case, the partition must be cleared.

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

For a successfully completed Incremental, it also promotes:

```text
candidate_next_window_start
        |
        v
next_window_start_class
```

Bootstrap and Full do not advance the rotating window.

A successful FINALIZE removes the operational staging:

```text
refresh_run_row
refresh_run_delete
refresh_run_dirty_class
```

while `refresh_run` remains as lightweight history.

## Failure and retry

If the consumer fails:

```text
DO NOT execute FINALIZE
DO NOT modify class_memory
DO NOT advance the rotating window
```

The run remains `PREPARED`.

The retry must use the same `run_id` and therefore the same materialized snapshot: a new PREPARE must not be created.

---

# Tests and benchmark

The repository includes:

- automated functional tests;
- negative and fault-injection tests;
- a first exploratory benchmark.

The benchmark is not a production-capacity claim: it is intended to observe prototype behavior.

## First exploratory benchmark

Configuration:

```text
initial rows         = 100,000
total_classes        = 100
insert_window_size   = 10
INSERTs per run      = 5,000
UPDATE                = 0
DELETE                = 0
consecutive runs     = 10
```

After ten runs, the source reached approximately 150,000 rows.

In the tenth run:

```text
PREPARE   = 2.451 s
FINALIZE  = 1.506 s
-------------------
total     = 3.957 s
```

The run made only:

```text
10 classes out of 100 dirty
```

During the cycle:

```text
run 1  -> classes 1..10
run 2  -> classes 11..20
...
run 10 -> classes 91..100
          next start = 1
```

After a single run:

```text
min rows per class = 1,000
max rows per class = 1,500
spread             = 500
```

After the full cycle:

```text
min rows per class = 1,500
max rows per class = 1,500
average            = 1,500
spread             = 0
```

In the measured scenario:

```text
5,000 INSERTs per run
        |
        v
10 dirty classes out of 100
        |
        v
progressive rotation
        |
        v
complete rebalancing after one cycle
```

The timings are **first experimental evidence for the prototype**, not a general performance guarantee. Timing outliers were also observed; rigorous characterization requires repeated runs, medians, larger datasets, and different hardware.

The downstream benefit comes mainly from the controlled number of dirty classes: in the measured append-only scenario, the consumer must overwrite 10 partitions instead of the full space of 100 classes.

---

# Summary

The strategy combines three properties:

```text
STABLE CLASSES
each key keeps its partition

ROTATING WINDOW
new records are distributed progressively

OVERWRITE BY CLASS
the delta determines which partitions to rebuild
```

The goal is not to obtain a perfectly uniform distribution in every single run, but to maintain reasonably balanced partitions over time with a more predictable refresh cost.

> **PREPARE builds a candidate snapshot; the consumer updates the dirty classes; FINALIZE makes that snapshot the official process state.**
