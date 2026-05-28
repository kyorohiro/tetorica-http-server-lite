Tiny portable HTTP server for Tetorica mDrop.

Supports:

- Static file hosting

- Directory listing

- HTTP Range requests

- Portable web apps


# ZIG Version

```
% zig version  
0.15.2
```

# install  zig

```
brew install zig@0.15.2
```

```
zig build -Dtarget=x86_64-windows-gnu --prefix zig-out/x86_64-windows-gnu
zig build -Dtarget=aarch64-windows-gnu --prefix zig-out/aarch64-windows-gnu
zig build -Dtarget=x86_64-linux-musl --prefix zig-out/x86_64-linux-musl
zig build -Dtarget=aarch64-linux-musl --prefix zig-out/aarch64-linux-musl
zig build -Dtarget=aarch64-macos --prefix zig-out/aarch64-macos
zig build -Dtarget=x86_64-macos --prefix zig-out/x86_64-macos
```

```
zig build-exe src/main.zig -O ReleaseSmall -fstrip
```


```
lipo -create \
  zig-out/aarch64-macos/bin/server \
  zig-out/x86_64-macos/bin/server \
  -output server-macos-universal
```
