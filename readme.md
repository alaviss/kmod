### Linux's libkmod high-level wrapper in Nim

Documentation is currently missing, but the API does not stray too far from
libkmod's own API, so their documentation can be used.
(not available pre-built online, but one can read the
[documentation in libkmod c sources][0])

Differences from libkmod's C API:
- No resource cleanup needed! These are automatically done via destructors.
- Most get/set APIs are implemented as getter/setter.
- Logging APIs are not available.
- Lists are typesafe! With iterators support so they can be easily iterated over.

Examples can be found in the `examples/` folder.

#### Dependencies

This wrapper depends on the existance of `libkmod` headers in the system.
Consult your distribution's package repository for them (`libkmod-dev` on
Debian-based distribution).

#### Licenses

This wrapper is licensed under the `ISC` (to allow static linking), but the
actual `libkmod` library is licensed under `LGPL-2.1`.

[0]: https://git.kernel.org/pub/scm/utils/kernel/kmod/kmod.git/tree/libkmod
