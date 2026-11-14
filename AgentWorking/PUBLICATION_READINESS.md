# ZeroPage source preview

The 0.1.0 source preview is based on a separate snapshot of the compiler, runtime, fixtures, examples, and documentation. The development checkout and its history are kept separate. The public repository includes the root and vendored license notices.

The normal setup uses pinned Zig and 64tass on PATH. The small-demo gate also uses Bash, Perl, and c1541. The Zig package allowlist includes the scripts and sample apps used by its build targets. The [sample disk guide](../docs/sample-disks.md) documents how to reproduce the committed D64s. Tests, disk rebuilds, and emulator output go under ignored paths.

For future release work, verify fresh macOS and Linux clones and run the optional full VICE gate when the external harness is configured. See [Testing](../docs/testing.md) for the required tools.
