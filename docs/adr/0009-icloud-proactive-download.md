# ADR-0009: Proactive iCloud download and an eviction bar, no body cache

Status: accepted, 2026-09-07

## Decision
The app requests a download for every dataless note at launch, after scans, and on watcher
events, and repeats the request when a note is re-evicted (L-9). While any note is dataless a
non-dismissable bar under the search field says so, with free space and a Storage Settings
button when the disk is nearly full (L-10). No on-disk body cache is added; PF-7 stands.

## Why
v1 only requested a download when a note was opened, so an evicted library could not be
searched. The owner's boot volume had under 1 GB free with Optimize Mac Storage on, which
makes macOS evict aggressively and re-evict recently downloaded files. The app cannot prevent
that; it can make sure the request is always outstanding and tell the user why search is
incomplete. A body cache was considered and rejected by the owner: it hides the underlying
disk problem and duplicates the library.

## Consequences
Search remains incomplete while the OS refuses to keep files resident. The bar is the
signal. Download requests are rate-limited per note so a permanently full disk does not
produce a request storm.
