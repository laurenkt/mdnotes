# ADR-0003: nvALT search semantics, not ranking

Status: accepted, 2026-09-06

## Decision
Every query word must be a case-insensitive substring of the title or body. Title matches
first, then by modified date. No tokeniser, stemming, ranking, or fuzzy matching. `#tag` is an
ordinary word.

## Why
Predictability and speed. Results never reorder surprisingly as you type, the index is a flat
array of lowercase strings that fits in memory for any plausible library, and tags need no
special query syntax. Ranked search would need tuning and tests for relevance that nobody asked for.

## Consequences
Very large libraries (hundreds of thousands of notes) would eventually need an inverted index;
that is a future ADR, and the `SearchIndex` snapshot API is designed so the implementation can
be swapped.
