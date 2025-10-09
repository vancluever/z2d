# Zig 0.14.1-vendored compress library

This is a "vendored" version of the Zig 0.14.1 stdlib compression library, that
needs to exist here after the removal of the deflate functionality from the
stdlib. For details, see <https://github.com/ziglang/zig/pull/24614>.

Efforts have been made to prune the code here, so only as much as we need to do
PNG compression should remain (in addition to some code to support tests that
I've decided to keep). I'm hoping that we don't have to do this for long and
compression will return within a reasonable time frame. At that point this code
will be removed and PNG compression will be adapted to fully use the new I/O
framework.

## License

```
The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
