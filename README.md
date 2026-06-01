# Phobos ExtTypes (`phobos-sys-exttypes`)

A collection of compact, storage-oriented value types for the D programming language. This project provides zero-dependency implementations of common data types designed for eventual integration into the upcoming Phobos 3 standard library. 

The types in this library prioritize efficient storage, fast parsing, and maximum compatibility with D's functional attributes (`@safe`, `pure`, `nothrow`, `@nogc`, and `CTFE`).

## Features

- **Decimal**: IEEE 754-2008 compliant decimal floating-point arithmetic (`Decimal32`, `Decimal64`, `Decimal128`) using BID encoding.
- **Network Addresses**: Value types for IP and hardware addresses, including `IPv4Address`, `IPv6Address`, `IPAddress` (tagged union), CIDR networks (`IPv4Network`, `IPv6Network`), `MACAddress` (EUI-48), and `EUI64Address`. 
- **SemVer**: A fully-compliant Semantic Versioning 2.0.0 type (`SemVer`) that provides correct precedence ordering, fast parsing, and formatting.

## Installation

Add this project as a dependency to your DUB project via the command line:

```bash
dub add phobos-sys-exttypes
```

Or manually add it to your `dub.sdl`:
```sdl
dependency "phobos-sys-exttypes" version="~>0.1.0"
```

Or `dub.json`:
```json
"dependencies": {
    "phobos-sys-exttypes": "~>0.1.0"
}
```

## Examples

### Decimal Floating-Point

```d
import phobos.sys.decimal;

void main() {
    Decimal64 d1, d2;
    Decimal64.fromString("123.45", d1);
    Decimal64.fromString("0.05", d2);
    
    Decimal64 sum = d1 + d2;
    assert(sum.toString() == "123.50");
}
```

### Network Addresses

```d
import phobos.sys.network;

void main() {
    // IPv4
    auto localhost = IPv4Address(127, 0, 0, 1);
    assert(localhost.isLoopback());

    // IPv6 parsing with zero compression
    IPv6Address ip6;
    if (IPv6Address.fromString("2001:db8::1", ip6)) {
        assert(ip6.toString() == "2001:db8::1");
    }

    // MAC Addresses
    MACAddress mac;
    MACAddress.fromString("00:1A:2B:3C:4D:5E", mac);
    assert(mac.toEUI64().toString() == "02:1a:2b:ff:fe:3c:4d:5e");
}
```

### Semantic Versioning

```d
import phobos.sys.semver;

void main() {
    SemVer v1, v2;
    SemVer.fromString("1.0.0-rc.1", v1);
    SemVer.fromString("1.0.0", v2);
    
    // Precedence comparison
    assert(v1 < v2);
    
    // Construct manually
    auto v3 = SemVer(2, 0, 0, "alpha.1", "build.123");
    assert(v3.toString() == "2.0.0-alpha.1+build.123");
}
```

## Contribution Guidelines

Contributions are welcome! If you'd like to improve the library, please keep the following guidelines in mind:

1. **No standard library dependencies:** The core implementations should not depend on `std.*` modules to keep it easy to integrate into Phobos v3.
2. **Strict attributes:** Attempt to make functions `@safe pure nothrow @nogc` and CTFE-compatible wherever possible. (e.g., `toString()` generally allocates, but `fromString()` and core operations should not).
3. **Tests & Coverage:** Maintain high test coverage using D's built-in `unittest` blocks. New features require tests.
4. **AI/LLM Contributions:** **Any LLM (Large Language Model) based contributions must include the Prompt used to generate the contribution in the `PROMPTS.txt` file.**

To submit a contribution:
1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-new-feature`)
3. Commit your changes. (If using an LLM, remember to update `PROMPTS.txt`)
4. Push to the branch (`git push origin feature/my-new-feature`)
5. Open a Pull Request

## License

This project is licensed under the Boost Software License 1.0 (BSL-1.0). See the [LICENSE](LICENSE) file for details.
