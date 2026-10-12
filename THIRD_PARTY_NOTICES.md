# Third-party notices

emvnc is licensed under the Apache License 2.0 (see `LICENSE`). It includes or links the following
third-party software. All licenses below are compatible with distributing emvnc under Apache 2.0.

| Component | Version | License | Use |
|---|---|---|---|
| RoyalVNCKit | fork of `090b96ed` | MIT | VNC/RFB protocol engine (vendored and patched in `Packages/RoyalVNCKit`) |
| CryptoSwift (royalapplications fork) | `a59b4d91` | zlib-style with attribution clause | Big-number arithmetic for ARD / MS-Logon II Diffie-Hellman, AES-ECB in RoyalVNCKit |
| D3DES | 5.09 (VNC variant) | Public domain | DES for VNC Password authentication |
| zlib | system | zlib | Provided by macOS; not redistributed |

---

## RoyalVNCKit — MIT License

MIT License

Copyright (c) 2025 Royal Apps

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

---

## CryptoSwift

Copyright (C) 2014-3099 Marcin Krzyżanowski <marcin.krzyzanowski@gmail.com>
This software is provided 'as-is', without any express or implied warranty.

In no event will the authors be held liable for any damages arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,including commercial applications, and to alter it and redistribute it freely, subject to the following restrictions:

- The origin of this software must not be misrepresented; you must not claim that you wrote the original software. If you use this software in a product, an acknowledgment in the product documentation is required.
- Altered source versions must be plainly marked as such, and must not be misrepresented as being the original software.
- This notice may not be removed or altered from any source or binary distribution.
- Redistributions of any form whatsoever must retain the following acknowledgment: 'This product includes software developed by the "Marcin Krzyzanowski" (http://krzyzanowskim.com/).'

---

## D3DES

From `Packages/RoyalVNCKit/Sources/d3des/d3des.c`:

```
This is D3DES (V5.09) by Richard Outerbridge with the double and
triple-length support removed for use in VNC.  Also the bytebit[] array
has been reversed so that the most significant bit in each byte of the
key is ignored, not the least significant.

These changes are Copyright (C) 1998 Olivetti & Oracle Research Laboratory

This software is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

D3DES (V5.09) -
A portable, public domain, version of the Data Encryption Standard.
Written with Symantec's THINK (Lightspeed) C by Richard Outerbridge.
Copyright (c) 1988,1989,1990,1991,1992 by Richard Outerbridge.
```
