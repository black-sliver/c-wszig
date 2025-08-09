# c-wszig

C bindings for zig websocket (Client only)

This should hopefully be a drop-in replacement for [c-wspp](https://github.com/black-sliver/c-wspp),
which is also why the symbols start with `wspp_`.

## Naming

The build/release workflow renames the files to what the dynamic loader in c-wspp-websocket-sharp expects.

## API

See [c-wspp#API](https://github.com/black-sliver/c-wspp?tab=readme-ov-file#api) for now.

## Supported Platforms

| OS        | Arch    | Status         |
|-----------|---------|----------------|
| Windows   | x86     | ✅ Tested       |
| Windows   | x86_64  | ✅ Tested       |
| Windows   | aarch64 | ☐ Possible[^1] |
| Linux-gnu | x86     | ❌ Failing[^2]  |
| Linux-gnu | x86_64  | ✅ Tested       |
| Linux-gnu | aarch64 | ☐ Possible[^1] |
| Macos     | x86     | ❌ No[^3]       |
| Macos     | x86_64  | ❔ Untested     |
| Macos     | aarch64 | ☐ Possible[^1] |
| Macos     | fat     | ☐ Possible[^1] |

[^1]: we don't build it, but the target is supported by Zig; feel free to open an issue.
Fat macOS binaries have to be bundled with `lipo -create`.

[^2]: currently unsupported because the build fails.

[^3]: 32bit macOS is basically not supported anywhere anymore. If this is for a game,
consider running the Windows version in Wine.
