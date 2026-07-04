# Vendored Tree-sitter grammars

This directory contains a trimmed copy of the Tree-sitter grammars used by df.

Kept files per grammar:

- `src/parser.c`
- `src/scanner.c` / `src/scanner.cc` if the grammar has an external scanner
- `src/tree_sitter/` headers needed to compile the generated parser/scanner
- `queries/highlights.scm` for syntax highlighting queries

Vendored grammars:

- `tree-sitter-zig` from `https://github.com/tree-sitter-grammars/tree-sitter-zig`
- `tree-sitter-c` from `https://github.com/tree-sitter/tree-sitter-c`
- `tree-sitter-rust` from `https://github.com/tree-sitter/tree-sitter-rust`

The nested upstream `.git` directories are intentionally removed so jj/git tracks
these as normal vendored source files.
