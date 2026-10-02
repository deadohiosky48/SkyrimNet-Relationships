# Prisma UI public API header (vendored, unmodified)

`PrismaUI_API.h` is copied **unmodified** from Prisma UI's repository:

- Repository: `https://github.com/PrismaUI-SKSE/PrismaUI`
- File: `src/PrismaUI_API.h`
- Commit: `d2ba59d` (2026-02-18), the header shipped with Prisma UI 1.5.0 and 1.5.1

The header invites it ("Copy this file into your own project if you wish to use
this API"), and the Prisma UI License beside it (`LICENSE.md`, Section 2.4)
allows distributing the original unmodified with that licence included. It is
**not MIT**, unlike the Meridian headers: **never edit it**, because the
licence forbids publishing a modified version (Section 3.2), and keep
`LICENSE.md` with it.

Our adapter, `native/src/PrismaHost.cpp`, is written from this header and
Prisma UI's public API documentation (`prismaui.dev`) only. Nothing else from
Prisma UI is in this repository, and we never ship `PrismaUI.dll` or its
Ultralight libraries: players install Prisma UI themselves.
