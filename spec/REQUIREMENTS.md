# pngdec — Requirements

A Go command-line tool that reports the chunk structure of a PNG file as JSON.

`pngdec` is a **structural** decoder. It parses the PNG container: the signature and
the sequence of chunks. It does not decompress image data, does not validate pixel
formats, and does not render anything. A file whose chunk structure is intact is
well-formed for this tool's purposes even if the image it encodes is nonsense.

## Invocation

    pngdec <file>    read the named file
    pngdec -         read the whole of standard input

Exactly one argument is required.

## PNG container format

A PNG file is an 8-byte signature followed by a sequence of chunks.

Signature: `89 50 4E 47 0D 0A 1A 0A` (hex).

Each chunk is:

| Field  | Size    | Meaning |
|--------|---------|---------|
| length | 4 bytes | big-endian unsigned; the size of `data`, NOT including type or CRC |
| type   | 4 bytes | four ASCII letters (`A`-`Z` or `a`-`z`) |
| data   | length  | payload |
| crc    | 4 bytes | big-endian CRC-32 (IEEE, the same polynomial as Go's `hash/crc32.ChecksumIEEE`) computed over `type` followed by `data`, and NOT over `length` |

## Output

On every run that reaches the parser, write to stdout a single JSON object followed by
one newline. The JSON must be **compact**: no spaces, no indentation, no newlines
inside it. Keys must appear in exactly this order, and no other keys may appear:

    {"valid":<bool>,"size":<int>,"signature_valid":<bool>,"chunks":[...],"errors":[...]}

- `valid` — true if and only if the file is well-formed (defined below).
- `size` — the total number of input bytes read.
- `signature_valid` — true if and only if the first 8 bytes are the PNG signature.
- `chunks` — an ordered array, in file order, of every chunk that was parsed
  successfully. A chunk whose parse failed is not included.
- `errors` — an ordered array of strings. Empty if and only if `valid` is true.
  Each string must begin `offset <N>: ` where `<N>` is the decimal byte offset
  in the input at which the problem was detected. The rest of the message is free-form.

Each element of `chunks` is an object with keys in exactly this order and no others:

    {"type":"<string>","offset":<int>,"length":<int>,"crc":"<string>","crc_valid":<bool>}

- `type` — the four type bytes as a string.
- `offset` — the byte offset of the start of this chunk, i.e. of its `length` field.
  The first chunk of a file with a valid signature is therefore at offset 8.
- `length` — the declared length, as an integer.
- `crc` — the stored CRC as exactly 8 lowercase hexadecimal digits, no `0x` prefix,
  zero-padded. For example `"a8a24f1b"`.
- `crc_valid` — true if and only if the stored CRC equals the CRC computed over
  `type` and `data`.

Partial output is required: when the file is malformed, emit the chunks that were
parsed successfully before the failure, with `valid` false and the failure described
in `errors`. Do not emit an empty `chunks` array just because the file is bad.

## Well-formed

A file is well-formed if and only if all of the following hold:

1. The first 8 bytes are the PNG signature.
2. Every chunk parses completely: its declared length does not exceed the bytes
   remaining after its type field, and its 4 CRC bytes are present.
3. Every chunk type is four ASCII letters.
4. Every chunk's stored CRC matches the computed CRC.
5. The first chunk is `IHDR` and its declared length is exactly 13.
6. The last chunk is `IEND` and its declared length is exactly 0.
7. There are no bytes after the `IEND` chunk's CRC.

Notes that follow from the above and are deliberately called out, because they are
easy to get wrong:

- A zero-length `IDAT` chunk is well-formed. Zero is a legal declared length.
- Chunk data may contain NUL bytes anywhere, including a `tEXt` chunk with several.
  Data is bytes, never a NUL-terminated string, and `length` must report the full
  declared length regardless of NUL content.
- Multiple `IDAT` chunks are well-formed.
- An unrecognised chunk type is well-formed as long as it is four ASCII letters.
  `pngdec` has no list of known chunk types beyond `IHDR` and `IEND`.
- A declared length of `0xFFFFFFFF` is malformed on any real file, because it
  exceeds the bytes remaining. `pngdec` must report it and exit, and must not
  attempt to allocate a buffer of that size.

## Exit codes

| Code | When |
|------|------|
| 0 | The file is well-formed. |
| 2 | The file was read but is malformed. JSON still goes to stdout; a diagnostic naming the decimal byte offset of the first problem also goes to stderr. |
| 1 | Usage error (wrong number of arguments) or I/O error (file does not exist, is a directory, cannot be read). Nothing is written to stdout; a diagnostic goes to stderr. |

A zero-byte file is malformed, not an I/O error: exit 2, with `size` 0,
`signature_valid` false, an empty `chunks` array, and an error at offset 0.

## Deliverables

1. Go source in the current directory. Module name `pngdec`. A single `main`
   package. Go standard library only — no third-party dependencies, no `go get`.
2. A test suite.
3. A `Makefile` with a `build` target that produces the binary at `./pngdec`,
   and a `test` target that runs the suite. Both must succeed.

## Test requirements

These are requirements, not suggestions. They exist so that any suite can be run
against any binary.

1. **All test fixtures must be constructed in code** as byte slices. Do not create
   a `testdata/` directory. Do not read fixture files from disk. A test file must be
   self-contained.
2. **Tests must exercise the built binary as a subprocess.** The binary path is the
   value of the `PNGDEC_BIN` environment variable, defaulting to `./pngdec`.
3. **Tests must not build the binary.** No `go build` from `TestMain`, no
   `exec.Command("make")`. Assume the binary already exists at that path.
4. **Tests must not import the `pngdec` package** or call its functions directly.
   Everything is observed through the subprocess: stdout, stderr, exit code.
