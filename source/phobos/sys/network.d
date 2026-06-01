/**
 * Value types for representing and storing network addresses.
 *
 * This module provides compact, fixed-size value types for IPv4 and IPv6
 * addresses (including CIDR network prefixes) and for IEEE EUI-48 ("MAC") and
 * EUI-64 hardware addresses. The types are intended purely for representation
 * and storage: every address is held as its raw bytes in network byte order,
 * which keeps them small, portable and trivially comparable.
 *
 * The provided types are:
 *
 * $(UL
 *   $(LI `IPv4Address` and `IPv6Address` — the two concrete IP versions.)
 *   $(LI `IPAddress` — a tagged value holding either version.)
 *   $(LI `IPv4Network`, `IPv6Network` and `IPNetwork` — CIDR prefixes.)
 *   $(LI `MACAddress` (EUI-48) and `EUI64Address` (EUI-64).)
 * )
 *
 * All of the core operations — construction, parsing, formatting, comparison
 * and the various predicates — are `pure nothrow @safe @nogc` and usable in
 * CTFE. Only `toString` allocates.
 *
 * Copyright: Copyright © 2026, Adam Wilson.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Adam Wilson
 */
module phobos.sys.network;

// The address types are pure, nothrow, @safe, @nogc and CTFE-capable. Only the
// string-producing `toString` helpers allocate, so `nothrow` and `@nogc` are
// applied per-declaration rather than module-wide.
@safe:

/*
 * =============================================================================
 *  ASCII helpers
 *  -------------------------------------------------------------------------
 *  Small character utilities used by the parsers and formatters. They avoid
 *  any dependency on the standard library so that the module is easy to drop
 *  into the forthcoming Phobos 3.
 * =============================================================================
 */

/// The value 0..15 of an ASCII hexadecimal digit, or -1 if `c` is not one.
private int hexValue(char c) pure nothrow @nogc
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

/// The lower-case hexadecimal digit for a value 0..15.
private char hexDigit(uint v) pure nothrow @nogc
{
    return cast(char)(v < 10 ? '0' + v : 'a' + (v - 10));
}

/// Write the decimal representation of `v` (0..255) into `dst`, returning the
/// number of characters written.
private int writeDecimal(uint v, scope char[] dst) pure nothrow @nogc
{
    char[3] tmp = void;
    int n = 0;
    do
    {
        tmp[n++] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v != 0);
    foreach_reverse (i; 0 .. n)
        dst[n - 1 - i] = tmp[i];
    return n;
}

/// Write a 16-bit IPv6 group as lower-case hexadecimal without leading zeroes,
/// returning the number of characters written.
private int writeGroup(ushort g, scope char[] dst) pure nothrow @nogc
{
    int n = 0;
    bool started = false;
    foreach_reverse (shift; 0 .. 4)
    {
        immutable nibble = (g >> (shift * 4)) & 0xF;
        if (nibble != 0 || started || shift == 0)
        {
            dst[n++] = hexDigit(nibble);
            started = true;
        }
    }
    return n;
}

// FNV-1a hashing constants used by the `toHash` implementations.
private enum ulong fnvBasis = 1_469_598_103_934_665_603UL;
private enum ulong fnvPrime = 1_099_511_628_211UL;

/*
 * =============================================================================
 *  IPv4Address
 * =============================================================================
 */

/**
 * A 32-bit IPv4 address stored as four octets in network byte order.
 */
struct IPv4Address
{
    /// The four octets, most-significant first (network byte order).
    private ubyte[4] _octets;

    /**
     * Convert to the canonical dotted-decimal string, e.g. `"192.0.2.1"`.
     */
    string toString() const pure @safe
    {
        char[15] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from four octets in network order.
    this(ubyte a, ubyte b, ubyte c, ubyte d)
    {
        _octets = [a, b, c, d];
    }

    /// Construct from an array of four octets in network order.
    this(ubyte[4] octets)
    {
        _octets = octets;
    }

    /// Construct from a 32-bit host-order value (the most-significant byte
    /// becomes the first octet).
    this(uint value)
    {
        _octets[0] = cast(ubyte)(value >> 24);
        _octets[1] = cast(ubyte)(value >> 16);
        _octets[2] = cast(ubyte)(value >> 8);
        _octets[3] = cast(ubyte)value;
    }

    /// The four octets in network byte order.
    ubyte[4] octets() const { return _octets; }

    /// The address as a 32-bit host-order integer.
    uint asUint() const
    {
        return (cast(uint)_octets[0] << 24) | (cast(uint)_octets[1] << 16)
             | (cast(uint)_octets[2] << 8) | cast(uint)_octets[3];
    }

    /// The all-zeroes address, `0.0.0.0`.
    static IPv4Address unspecified() { return IPv4Address(0, 0, 0, 0); }

    /// The loopback address, `127.0.0.1`.
    static IPv4Address loopback() { return IPv4Address(127, 0, 0, 1); }

    /// The limited broadcast address, `255.255.255.255`.
    static IPv4Address broadcast() { return IPv4Address(255, 255, 255, 255); }

    /// `true` if this is the unspecified address `0.0.0.0`.
    bool isUnspecified() const { return asUint() == 0; }

    /// `true` if this address is in the loopback block `127.0.0.0/8`.
    bool isLoopback() const { return _octets[0] == 127; }

    /// `true` if this address is in a private-use block (`10/8`, `172.16/12`
    /// or `192.168/16`).
    bool isPrivate() const
    {
        if (_octets[0] == 10) return true;
        if (_octets[0] == 172 && (_octets[1] & 0xF0) == 16) return true;
        if (_octets[0] == 192 && _octets[1] == 168) return true;
        return false;
    }

    /// `true` if this address is in a link-local block `169.254/16`.
    bool isLinkLocal() const { return _octets[0] == 169 && _octets[1] == 254; }

    /// `true` if this address is in the multicast block `224/4`.
    bool isMulticast() const { return (_octets[0] & 0xF0) == 0xE0; }

    /**
     * Write the dotted-decimal form into `dst`, returning the number of
     * characters written. `dst` must be at least 15 characters long.
     */
    package int formatTo(scope char[] dst) const
    {
        int n = 0;
        foreach (i; 0 .. 4)
        {
            if (i != 0) dst[n++] = '.';
            n += writeDecimal(_octets[i], dst[n .. $]);
        }
        return n;
    }

    /**
     * Parse a dotted-decimal IPv4 address such as `"192.0.2.1"`. Each octet
     * must be one to three decimal digits in the range 0..255; redundant
     * leading zeroes are rejected. Returns `true` on success.
     */
    static bool fromString(scope const(char)[] s, out IPv4Address result)
    {
        ubyte[4] octets;
        size_t i = 0;
        immutable n = s.length;
        foreach (part; 0 .. 4)
        {
            if (part != 0)
            {
                if (i >= n || s[i] != '.') return false;
                ++i;
            }
            if (i >= n || s[i] < '0' || s[i] > '9') return false;
            immutable bool leadingZero = s[i] == '0';
            uint value = 0;
            int digits = 0;
            while (i < n && s[i] >= '0' && s[i] <= '9')
            {
                value = value * 10 + (s[i] - '0');
                ++i;
                ++digits;
                if (value > 255 || digits > 3) return false;
            }
            if (digits > 1 && leadingZero) return false;
            octets[part] = cast(ubyte)value;
        }
        if (i != n) return false;
        result = IPv4Address(octets);
        return true;
    }

    /// Equality compares the raw octets.
    bool opEquals(const IPv4Address rhs) const { return _octets == rhs._octets; }

    /// Ordering is by unsigned numeric value.
    int opCmp(const IPv4Address rhs) const
    {
        immutable a = asUint(), b = rhs.asUint();
        return a < b ? -1 : (a > b ? 1 : 0);
    }

    /// Hashes the raw octets.
    size_t toHash() const @trusted { return asUint(); }
}

/*
 * =============================================================================
 *  IPv6Address
 * =============================================================================
 */

/**
 * A 128-bit IPv6 address stored as sixteen octets in network byte order.
 *
 * Parsing accepts the full RFC 4291 text syntax, including `::` zero
 * compression and an embedded dotted-decimal IPv4 tail (e.g.
 * `"::ffff:192.0.2.1"`). Formatting produces the RFC 5952 canonical form:
 * lower-case, with leading zeroes suppressed and the longest run of zero
 * groups compressed to `::`.
 */
struct IPv6Address
{
    /// The sixteen octets, most-significant first (network byte order).
    private ubyte[16] _bytes;

    /**
     * Convert to the RFC 5952 canonical text form.
     */
    string toString() const pure @safe
    {
        char[45] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from sixteen octets in network order.
    this(ubyte[16] bytes)
    {
        _bytes = bytes;
    }

    /// Construct from eight 16-bit groups in network order (most-significant
    /// group first).
    this(ushort[8] groups)
    {
        foreach (i; 0 .. 8)
        {
            _bytes[i * 2] = cast(ubyte)(groups[i] >> 8);
            _bytes[i * 2 + 1] = cast(ubyte)groups[i];
        }
    }

    /// The sixteen octets in network byte order.
    ubyte[16] bytes() const { return _bytes; }

    /// The 16-bit group at index `i` (0..7), in host order.
    ushort group(size_t i) const
    {
        return cast(ushort)((cast(ushort)_bytes[i * 2] << 8) | _bytes[i * 2 + 1]);
    }

    /// The all-zeroes address, `::`.
    static IPv6Address unspecified() { return IPv6Address.init; }

    /// The loopback address, `::1`.
    static IPv6Address loopback()
    {
        ubyte[16] b;
        b[15] = 1;
        return IPv6Address(b);
    }

    /// `true` if this is the unspecified address `::`.
    bool isUnspecified() const
    {
        foreach (b; _bytes) if (b != 0) return false;
        return true;
    }

    /// `true` if this is the loopback address `::1`.
    bool isLoopback() const
    {
        foreach (i; 0 .. 15) if (_bytes[i] != 0) return false;
        return _bytes[15] == 1;
    }

    /// `true` if this address is in the multicast block `ff00::/8`.
    bool isMulticast() const { return _bytes[0] == 0xFF; }

    /// `true` if this address is in the link-local unicast block `fe80::/10`.
    bool isLinkLocal() const { return _bytes[0] == 0xFE && (_bytes[1] & 0xC0) == 0x80; }

    /// `true` if this address is an IPv4-mapped address `::ffff:0:0/96`.
    bool isV4Mapped() const
    {
        foreach (i; 0 .. 10) if (_bytes[i] != 0) return false;
        return _bytes[10] == 0xFF && _bytes[11] == 0xFF;
    }

    /// The embedded IPv4 address of an IPv4-mapped address. The caller must
    /// ensure `isV4Mapped` is `true`.
    IPv4Address toV4() const
    {
        return IPv4Address(_bytes[12], _bytes[13], _bytes[14], _bytes[15]);
    }

    /**
     * Write the RFC 5952 canonical text form into `dst`, returning the number
     * of characters written. `dst` must be at least 45 characters long.
     */
    package int formatTo(scope char[] dst) const
    {
        // IPv4-mapped addresses use the mixed `::ffff:a.b.c.d` notation.
        if (isV4Mapped())
        {
            static immutable string prefix = "::ffff:";
            int n = 0;
            foreach (c; prefix) dst[n++] = c;
            n += toV4().formatTo(dst[n .. $]);
            return n;
        }

        // Locate the longest run of consecutive zero groups (length >= 2).
        int bestStart = -1, bestLen = 0;
        int curStart = -1, curLen = 0;
        foreach (i; 0 .. 8)
        {
            if (group(i) == 0)
            {
                if (curStart < 0) { curStart = i; curLen = 1; }
                else ++curLen;
                if (curLen > bestLen) { bestLen = curLen; bestStart = curStart; }
            }
            else
            {
                curStart = -1;
                curLen = 0;
            }
        }
        if (bestLen < 2) bestStart = -1;

        int n = 0;
        // Groups before the compressed run, separated by ':'.
        foreach (i; 0 .. (bestStart < 0 ? 8 : bestStart))
        {
            if (i != 0) dst[n++] = ':';
            n += writeGroup(group(i), dst[n .. $]);
        }
        if (bestStart < 0)
            return n;

        // The compressed run renders as "::"; the two colons also serve as the
        // separators on either side.
        dst[n++] = ':';
        dst[n++] = ':';

        // Groups after the run; the first needs no leading separator.
        bool first = true;
        foreach (i; (bestStart + bestLen) .. 8)
        {
            if (!first) dst[n++] = ':';
            n += writeGroup(group(i), dst[n .. $]);
            first = false;
        }
        return n;
    }

    /**
     * Parse an RFC 4291 IPv6 address, supporting `::` zero compression and an
     * embedded dotted-decimal IPv4 tail. Returns `true` on success.
     */
    static bool fromString(scope const(char)[] s, out IPv6Address result)
    {
        immutable n = s.length;
        if (n == 0) return false;

        ushort[8] groups;
        int count = 0;          // groups filled so far (before any "::")
        int gapAt = -1;         // index where "::" appeared, or -1
        size_t i = 0;

        // A leading "::" is a special case.
        if (n >= 2 && s[0] == ':' && s[1] == ':')
        {
            gapAt = 0;
            i = 2;
            if (i == n)
            {
                result = IPv6Address.init;
                return true;
            }
        }
        else if (s[0] == ':')
        {
            return false; // a single leading colon is invalid
        }

        for (;;)
        {
            // Try to read a group: either hex, or an embedded IPv4 tail.
            // First, detect an IPv4 tail by scanning for a '.' before the next ':'.
            size_t j = i;
            bool hasDot = false;
            while (j < n && s[j] != ':')
            {
                if (s[j] == '.') { hasDot = true; break; }
                ++j;
            }

            if (hasDot)
            {
                // Consume to end-of-string or next colon (there should be none).
                size_t k = i;
                while (k < n && s[k] != ':') ++k;
                IPv4Address v4;
                if (!IPv4Address.fromString(s[i .. k], v4)) return false;
                if (count > 6) return false;
                immutable o = v4.octets();
                groups[count++] = cast(ushort)((o[0] << 8) | o[1]);
                groups[count++] = cast(ushort)((o[2] << 8) | o[3]);
                i = k;
                break; // an IPv4 tail must be last
            }

            // Read 1..4 hex digits.
            int value = 0, digits = 0;
            while (i < n && hexValue(s[i]) >= 0)
            {
                value = (value << 4) | hexValue(s[i]);
                ++i;
                ++digits;
                if (digits > 4) return false;
            }
            if (digits == 0) return false;
            if (count >= 8) return false;
            groups[count++] = cast(ushort)value;

            if (i == n) break;
            if (s[i] != ':') return false;
            ++i;
            if (i < n && s[i] == ':')
            {
                if (gapAt >= 0) return false; // only one "::" allowed
                gapAt = count;
                ++i;
                if (i == n) break; // trailing "::"
            }
            else if (i == n)
            {
                return false; // a trailing single ':' is invalid
            }
        }

        // Assemble the final group array, expanding the "::" gap if present.
        ushort[8] outGroups;
        if (gapAt < 0)
        {
            if (count != 8) return false;
            outGroups = groups;
        }
        else
        {
            if (count >= 8) return false; // gap must represent >= 1 zero group
            immutable int zeros = 8 - count;
            foreach (g; 0 .. gapAt) outGroups[g] = groups[g];
            foreach (g; gapAt .. count) outGroups[g + zeros] = groups[g];
        }
        result = IPv6Address(outGroups);
        return true;
    }

    /// Equality compares the raw octets.
    bool opEquals(const IPv6Address rhs) const { return _bytes == rhs._bytes; }

    /// Ordering is lexicographic over the octets, i.e. by numeric value.
    int opCmp(const IPv6Address rhs) const
    {
        foreach (i; 0 .. 16)
        {
            if (_bytes[i] != rhs._bytes[i])
                return _bytes[i] < rhs._bytes[i] ? -1 : 1;
        }
        return 0;
    }

    /// Hashes the raw octets.
    size_t toHash() const @trusted
    {
        size_t h = fnvBasis & size_t.max;
        foreach (b; _bytes)
        {
            h ^= b;
            h *= fnvPrime;
        }
        return h;
    }
}

/*
 * =============================================================================
 *  IPAddress
 * =============================================================================
 */

/// The address family held by an `IPAddress` or `IPNetwork`.
enum IPFamily : ubyte
{
    /// No address (a default-constructed value).
    none,
    /// An IPv4 address.
    v4,
    /// An IPv6 address.
    v6,
}

/**
 * A tagged value holding either an IPv4 or an IPv6 address.
 *
 * Both versions share a single sixteen-byte buffer; an IPv4 address occupies
 * the first four bytes. The active version is recorded by `family`.
 */
struct IPAddress
{
    private IPFamily _family;
    private ubyte[16] _store;

    /**
     * Convert to text using the appropriate version's canonical form. A
     * value with no address yields the empty string.
     */
    string toString() const pure @safe
    {
        final switch (_family)
        {
            case IPFamily.none: return null;
            case IPFamily.v4:   return toV4().toString();
            case IPFamily.v6:   return toV6().toString();
        }
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from an IPv4 address.
    this(IPv4Address addr)
    {
        _family = IPFamily.v4;
        _store[0 .. 4] = addr.octets();
    }

    /// Construct from an IPv6 address.
    this(IPv6Address addr)
    {
        _family = IPFamily.v6;
        _store = addr.bytes();
    }

    /// The address family currently held.
    IPFamily family() const { return _family; }

    /// `true` if an IPv4 address is held.
    bool isV4() const { return _family == IPFamily.v4; }

    /// `true` if an IPv6 address is held.
    bool isV6() const { return _family == IPFamily.v6; }

    /// The held IPv4 address. The caller must ensure `isV4` is `true`.
    IPv4Address toV4() const
    {
        assert(_family == IPFamily.v4, "IPAddress does not hold an IPv4 address");
        return IPv4Address(_store[0 .. 4]);
    }

    /// The held IPv6 address. The caller must ensure `isV6` is `true`.
    IPv6Address toV6() const
    {
        assert(_family == IPFamily.v6, "IPAddress does not hold an IPv6 address");
        return IPv6Address(_store);
    }

    /**
     * Parse an IPv4 or IPv6 address. A string containing a colon is parsed as
     * IPv6, otherwise as IPv4. Returns `true` on success.
     */
    static bool fromString(scope const(char)[] s, out IPAddress result)
    {
        bool hasColon = false;
        foreach (c; s) if (c == ':') { hasColon = true; break; }
        if (hasColon)
        {
            IPv6Address v6;
            if (!IPv6Address.fromString(s, v6)) return false;
            result = IPAddress(v6);
        }
        else
        {
            IPv4Address v4;
            if (!IPv4Address.fromString(s, v4)) return false;
            result = IPAddress(v4);
        }
        return true;
    }

    /// Equality requires the same family and address.
    bool opEquals(const IPAddress rhs) const
    {
        return _family == rhs._family && _store == rhs._store;
    }

    /// Ordering is by family first, then by address value.
    int opCmp(const IPAddress rhs) const
    {
        if (_family != rhs._family)
            return _family < rhs._family ? -1 : 1;
        foreach (i; 0 .. 16)
        {
            if (_store[i] != rhs._store[i])
                return _store[i] < rhs._store[i] ? -1 : 1;
        }
        return 0;
    }

    /// Hashes the family and address bytes.
    size_t toHash() const @trusted
    {
        size_t h = (fnvBasis ^ _family) & size_t.max;
        foreach (b; _store)
        {
            h ^= b;
            h *= fnvPrime;
        }
        return h;
    }
}

/*
 * =============================================================================
 *  CIDR network prefixes
 * =============================================================================
 */

/**
 * An IPv4 CIDR network: a base address together with a prefix length of
 * 0..32 bits.
 *
 * The base address is stored exactly as supplied; host bits below the prefix
 * are not cleared. Use `networkAddress` to obtain the masked base, or
 * `isCanonical` to test whether the stored address already has its host bits
 * clear.
 */
struct IPv4Network
{
    private IPv4Address _address;
    private ubyte _prefix;

    /// Convert to `"address/prefix"` form, e.g. `"192.0.2.0/24"`.
    string toString() const pure @safe
    {
        char[19] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from a base address and a prefix length (0..32). The prefix
    /// is clamped to 32.
    this(IPv4Address address, ubyte prefix)
    {
        _address = address;
        _prefix = prefix > 32 ? 32 : prefix;
    }

    /// The stored base address, exactly as supplied.
    IPv4Address address() const { return _address; }

    /// The prefix length in bits (0..32).
    ubyte prefix() const { return _prefix; }

    /// The netmask derived from the prefix length, e.g. `255.255.255.0`.
    IPv4Address netmask() const
    {
        immutable uint mask = _prefix == 0 ? 0 : (0xFFFFFFFFu << (32 - _prefix));
        return IPv4Address(mask);
    }

    /// The host mask (the bitwise complement of the netmask).
    IPv4Address hostmask() const { return IPv4Address(~netmask().asUint()); }

    /// The network (base) address with host bits cleared.
    IPv4Address networkAddress() const
    {
        return IPv4Address(_address.asUint() & netmask().asUint());
    }

    /// The broadcast address (the network address with all host bits set).
    IPv4Address broadcast() const
    {
        return IPv4Address(networkAddress().asUint() | ~netmask().asUint());
    }

    /// `true` if the stored address already has its host bits clear.
    bool isCanonical() const { return _address == networkAddress(); }

    /// `true` if `addr` lies within this network.
    bool contains(IPv4Address addr) const
    {
        immutable uint mask = netmask().asUint();
        return (addr.asUint() & mask) == (_address.asUint() & mask);
    }

    /// Write the `"address/prefix"` form into `dst`, returning the number of
    /// characters written. `dst` must be at least 18 characters long.
    package int formatTo(scope char[] dst) const
    {
        int n = _address.formatTo(dst);
        dst[n++] = '/';
        n += writeDecimal(_prefix, dst[n .. $]);
        return n;
    }

    /// Parse `"address/prefix"`. The prefix must be 0..32. Returns `true` on
    /// success.
    static bool fromString(scope const(char)[] s, out IPv4Network result)
    {
        size_t slash = size_t.max;
        foreach (i, c; s) if (c == '/') { slash = i; break; }
        if (slash == size_t.max) return false;
        IPv4Address addr;
        if (!IPv4Address.fromString(s[0 .. slash], addr)) return false;
        uint prefix;
        if (!parsePrefix(s[slash + 1 .. $], 32, prefix)) return false;
        result = IPv4Network(addr, cast(ubyte)prefix);
        return true;
    }

    /// Equality requires the same address and prefix.
    bool opEquals(const IPv4Network rhs) const
    {
        return _prefix == rhs._prefix && _address == rhs._address;
    }

    /// Ordering is by address, then prefix length.
    int opCmp(const IPv4Network rhs) const
    {
        immutable c = _address.opCmp(rhs._address);
        if (c != 0) return c;
        return _prefix < rhs._prefix ? -1 : (_prefix > rhs._prefix ? 1 : 0);
    }

    /// Hashes the address and prefix.
    size_t toHash() const @trusted
    {
        return _address.toHash() * fnvPrime ^ _prefix;
    }
}

/**
 * An IPv6 CIDR network: a base address together with a prefix length of
 * 0..128 bits. Host bits are stored as supplied; see `IPv4Network` for the
 * semantics of `networkAddress` and `isCanonical`.
 */
struct IPv6Network
{
    private IPv6Address _address;
    private ubyte _prefix;

    /// Convert to `"address/prefix"` form, e.g. `"2001:db8::/32"`.
    string toString() const pure @safe
    {
        char[50] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from a base address and a prefix length (0..128). The prefix
    /// is clamped to 128.
    this(IPv6Address address, ubyte prefix)
    {
        _address = address;
        _prefix = prefix > 128 ? 128 : prefix;
    }

    /// The stored base address, exactly as supplied.
    IPv6Address address() const { return _address; }

    /// The prefix length in bits (0..128).
    ubyte prefix() const { return _prefix; }

    /// The netmask derived from the prefix length.
    IPv6Address netmask() const
    {
        ubyte[16] m;
        int bits = _prefix;
        foreach (i; 0 .. 16)
        {
            if (bits >= 8) { m[i] = 0xFF; bits -= 8; }
            else if (bits > 0) { m[i] = cast(ubyte)(0xFF << (8 - bits)); bits = 0; }
            else m[i] = 0;
        }
        return IPv6Address(m);
    }

    /// The host mask (the bitwise complement of the netmask).
    IPv6Address hostmask() const
    {
        ubyte[16] m = netmask().bytes();
        foreach (ref b; m) b = cast(ubyte)~b;
        return IPv6Address(m);
    }

    /// The network (base) address with host bits cleared.
    IPv6Address networkAddress() const
    {
        ubyte[16] a = _address.bytes();
        immutable ubyte[16] m = netmask().bytes();
        foreach (i; 0 .. 16) a[i] &= m[i];
        return IPv6Address(a);
    }

    /// `true` if the stored address already has its host bits clear.
    bool isCanonical() const { return _address == networkAddress(); }

    /// `true` if `addr` lies within this network.
    bool contains(IPv6Address addr) const
    {
        immutable ubyte[16] m = netmask().bytes();
        immutable ubyte[16] a = addr.bytes();
        immutable ubyte[16] b = _address.bytes();
        foreach (i; 0 .. 16)
            if ((a[i] & m[i]) != (b[i] & m[i])) return false;
        return true;
    }

    /// Write the `"address/prefix"` form into `dst`, returning the number of
    /// characters written. `dst` must be at least 49 characters long.
    package int formatTo(scope char[] dst) const
    {
        int n = _address.formatTo(dst);
        dst[n++] = '/';
        n += writeDecimal(_prefix, dst[n .. $]);
        return n;
    }

    /// Parse `"address/prefix"`. The prefix must be 0..128. Returns `true` on
    /// success.
    static bool fromString(scope const(char)[] s, out IPv6Network result)
    {
        size_t slash = size_t.max;
        foreach (i, c; s) if (c == '/') { slash = i; break; }
        if (slash == size_t.max) return false;
        IPv6Address addr;
        if (!IPv6Address.fromString(s[0 .. slash], addr)) return false;
        uint prefix;
        if (!parsePrefix(s[slash + 1 .. $], 128, prefix)) return false;
        result = IPv6Network(addr, cast(ubyte)prefix);
        return true;
    }

    /// Equality requires the same address and prefix.
    bool opEquals(const IPv6Network rhs) const
    {
        return _prefix == rhs._prefix && _address == rhs._address;
    }

    /// Ordering is by address, then prefix length.
    int opCmp(const IPv6Network rhs) const
    {
        immutable c = _address.opCmp(rhs._address);
        if (c != 0) return c;
        return _prefix < rhs._prefix ? -1 : (_prefix > rhs._prefix ? 1 : 0);
    }

    /// Hashes the address and prefix.
    size_t toHash() const @trusted
    {
        return _address.toHash() * fnvPrime ^ _prefix;
    }
}

/// Parse a decimal prefix length 0..`max` from `s`, with no leading zeroes
/// (other than `"0"` itself) and no trailing characters.
private bool parsePrefix(scope const(char)[] s, uint max, out uint value) pure nothrow @nogc
{
    if (s.length == 0) return false;
    if (s.length > 1 && s[0] == '0') return false;
    uint v = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9') return false;
        v = v * 10 + (c - '0');
        if (v > max) return false;
    }
    value = v;
    return true;
}

/**
 * A tagged CIDR network holding either an IPv4 or an IPv6 prefix.
 */
struct IPNetwork
{
    private IPFamily _family;
    private ubyte[16] _store;
    private ubyte _prefix;

    /// Convert to `"address/prefix"` form; an empty value yields the empty
    /// string.
    string toString() const pure @safe
    {
        final switch (_family)
        {
            case IPFamily.none: return null;
            case IPFamily.v4:   return toV4().toString();
            case IPFamily.v6:   return toV6().toString();
        }
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from an IPv4 network.
    this(IPv4Network net)
    {
        _family = IPFamily.v4;
        _store[0 .. 4] = net.address().octets();
        _prefix = net.prefix();
    }

    /// Construct from an IPv6 network.
    this(IPv6Network net)
    {
        _family = IPFamily.v6;
        _store = net.address().bytes();
        _prefix = net.prefix();
    }

    /// The address family currently held.
    IPFamily family() const { return _family; }

    /// `true` if an IPv4 network is held.
    bool isV4() const { return _family == IPFamily.v4; }

    /// `true` if an IPv6 network is held.
    bool isV6() const { return _family == IPFamily.v6; }

    /// The prefix length in bits.
    ubyte prefix() const { return _prefix; }

    /// The held IPv4 network. The caller must ensure `isV4` is `true`.
    IPv4Network toV4() const
    {
        assert(_family == IPFamily.v4, "IPNetwork does not hold an IPv4 network");
        return IPv4Network(IPv4Address(_store[0 .. 4]), _prefix);
    }

    /// The held IPv6 network. The caller must ensure `isV6` is `true`.
    IPv6Network toV6() const
    {
        assert(_family == IPFamily.v6, "IPNetwork does not hold an IPv6 network");
        return IPv6Network(IPv6Address(_store), _prefix);
    }

    /**
     * Parse an IPv4 or IPv6 CIDR network. A string containing a colon before
     * the slash is parsed as IPv6, otherwise as IPv4. Returns `true` on
     * success.
     */
    static bool fromString(scope const(char)[] s, out IPNetwork result)
    {
        bool hasColon = false;
        foreach (c; s)
        {
            if (c == '/') break;
            if (c == ':') { hasColon = true; break; }
        }
        if (hasColon)
        {
            IPv6Network v6;
            if (!IPv6Network.fromString(s, v6)) return false;
            result = IPNetwork(v6);
        }
        else
        {
            IPv4Network v4;
            if (!IPv4Network.fromString(s, v4)) return false;
            result = IPNetwork(v4);
        }
        return true;
    }

    /// Equality requires the same family, address and prefix.
    bool opEquals(const IPNetwork rhs) const
    {
        return _family == rhs._family && _prefix == rhs._prefix
            && _store == rhs._store;
    }

    /// Ordering is by family, then address, then prefix length.
    int opCmp(const IPNetwork rhs) const
    {
        if (_family != rhs._family)
            return _family < rhs._family ? -1 : 1;
        foreach (i; 0 .. 16)
        {
            if (_store[i] != rhs._store[i])
                return _store[i] < rhs._store[i] ? -1 : 1;
        }
        return _prefix < rhs._prefix ? -1 : (_prefix > rhs._prefix ? 1 : 0);
    }

    /// Hashes the family, address and prefix.
    size_t toHash() const @trusted
    {
        size_t h = (fnvBasis ^ _family) & size_t.max;
        foreach (b; _store)
        {
            h ^= b;
            h *= fnvPrime;
        }
        return h ^ _prefix;
    }
}

/*
 * =============================================================================
 *  Hardware (MAC) addresses
 * =============================================================================
 */

/// Parse a hardware address into exactly `dst.length` bytes. Accepts three
/// textual forms: colon-separated (`aa:bb:...`), hyphen-separated
/// (`aa-bb-...`) and dotted-quad-nibble (`aabb.ccdd....`). Returns `true` on
/// success.
private bool parseHexBytes(scope const(char)[] s, scope ubyte[] dst) pure nothrow @nogc
{
    immutable need = dst.length;
    immutable n = s.length;

    // Detect the separator (the first non-hex character).
    char sep = 0;
    foreach (c; s)
        if (hexValue(c) < 0) { sep = c; break; }

    if (sep == '.')
    {
        // Groups of four hex digits separated by '.'.
        if (need % 2 != 0) return false;
        immutable groups = need / 2;
        size_t i = 0;
        foreach (g; 0 .. groups)
        {
            if (g != 0)
            {
                if (i >= n || s[i] != '.') return false;
                ++i;
            }
            ushort v = 0;
            foreach (k; 0 .. 4)
            {
                if (i >= n) return false;
                immutable d = hexValue(s[i]);
                if (d < 0) return false;
                v = cast(ushort)((v << 4) | d);
                ++i;
            }
            dst[g * 2] = cast(ubyte)(v >> 8);
            dst[g * 2 + 1] = cast(ubyte)v;
        }
        return i == n;
    }
    else if (sep == ':' || sep == '-')
    {
        // Groups of two hex digits separated by sep.
        size_t i = 0;
        foreach (g; 0 .. need)
        {
            if (g != 0)
            {
                if (i >= n || s[i] != sep) return false;
                ++i;
            }
            if (i >= n) return false;
            immutable hi = hexValue(s[i]);
            if (hi < 0 || i + 1 >= n) return false;
            immutable lo = hexValue(s[i + 1]);
            if (lo < 0) return false;
            dst[g] = cast(ubyte)((hi << 4) | lo);
            i += 2;
        }
        return i == n;
    }
    else if (sep == 0)
    {
        // Bare hexadecimal, no separators.
        if (n != need * 2) return false;
        foreach (g; 0 .. need)
        {
            immutable hi = hexValue(s[g * 2]);
            immutable lo = hexValue(s[g * 2 + 1]);
            if (hi < 0 || lo < 0) return false;
            dst[g] = cast(ubyte)((hi << 4) | lo);
        }
        return true;
    }
    return false;
}

/// Write `src` as lower-case colon-separated hex into `dst`, returning the
/// number of characters written.
private int formatHexBytes(scope const(ubyte)[] src, scope char[] dst) pure nothrow @nogc
{
    int n = 0;
    foreach (i, b; src)
    {
        if (i != 0) dst[n++] = ':';
        dst[n++] = hexDigit(b >> 4);
        dst[n++] = hexDigit(b & 0xF);
    }
    return n;
}

/**
 * An IEEE EUI-48 hardware address (a 48-bit "MAC" address) stored as six
 * octets in transmission order.
 *
 * Parsing accepts colon-, hyphen- and dotted-quad-nibble notation; formatting
 * produces the canonical lower-case colon form, e.g. `"01:23:45:67:89:ab"`.
 */
struct MACAddress
{
    /// The six octets in transmission order.
    private ubyte[6] _octets;

    /// Convert to canonical lower-case colon form.
    string toString() const pure @safe
    {
        char[17] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from six octets.
    this(ubyte[6] octets) { _octets = octets; }

    /// The six octets in transmission order.
    ubyte[6] octets() const { return _octets; }

    /// The broadcast address `ff:ff:ff:ff:ff:ff`.
    static MACAddress broadcast() { return MACAddress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]); }

    /// `true` if the group bit (the least-significant bit of the first octet)
    /// is set, marking a group (multicast) address.
    bool isMulticast() const { return (_octets[0] & 0x01) != 0; }

    /// `true` if this is an individual (unicast) address.
    bool isUnicast() const { return !isMulticast(); }

    /// `true` if the locally-administered bit (bit 1 of the first octet) is set.
    bool isLocal() const { return (_octets[0] & 0x02) != 0; }

    /// `true` if the address is universally administered (the U/L bit clear).
    bool isUniversal() const { return !isLocal(); }

    /// `true` if this is the broadcast address.
    bool isBroadcast() const
    {
        foreach (b; _octets) if (b != 0xFF) return false;
        return true;
    }

    /**
     * Convert to an EUI-64 address by inserting `FF:FE` in the middle and
     * inverting the U/L bit, per the IEEE mapping.
     */
    EUI64Address toEUI64() const
    {
        ubyte[8] b;
        b[0] = _octets[0] ^ 0x02;
        b[1] = _octets[1];
        b[2] = _octets[2];
        b[3] = 0xFF;
        b[4] = 0xFE;
        b[5] = _octets[3];
        b[6] = _octets[4];
        b[7] = _octets[5];
        return EUI64Address(b);
    }

    /// Write the canonical form into `dst`, returning the number of characters
    /// written. `dst` must be at least 17 characters long.
    package int formatTo(scope char[] dst) const
    {
        return formatHexBytes(_octets[], dst);
    }

    /// Parse a 48-bit MAC address. Returns `true` on success.
    static bool fromString(scope const(char)[] s, out MACAddress result)
    {
        ubyte[6] octets;
        if (!parseHexBytes(s, octets[])) return false;
        result = MACAddress(octets);
        return true;
    }

    /// Equality compares the raw octets.
    bool opEquals(const MACAddress rhs) const { return _octets == rhs._octets; }

    /// Ordering is lexicographic over the octets.
    int opCmp(const MACAddress rhs) const
    {
        foreach (i; 0 .. 6)
            if (_octets[i] != rhs._octets[i])
                return _octets[i] < rhs._octets[i] ? -1 : 1;
        return 0;
    }

    /// Hashes the raw octets.
    size_t toHash() const @trusted
    {
        size_t h = fnvBasis & size_t.max;
        foreach (b; _octets) { h ^= b; h *= fnvPrime; }
        return h;
    }
}

/**
 * An IEEE EUI-64 hardware address stored as eight octets in transmission
 * order. Parsing and formatting mirror `MACAddress`.
 */
struct EUI64Address
{
    /// The eight octets in transmission order.
    private ubyte[8] _octets;

    /// Convert to canonical lower-case colon form.
    string toString() const pure @safe
    {
        char[23] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct from eight octets.
    this(ubyte[8] octets) { _octets = octets; }

    /// The eight octets in transmission order.
    ubyte[8] octets() const { return _octets; }

    /// `true` if the group bit (the least-significant bit of the first octet)
    /// is set, marking a group (multicast) address.
    bool isMulticast() const { return (_octets[0] & 0x01) != 0; }

    /// `true` if this is an individual (unicast) address.
    bool isUnicast() const { return !isMulticast(); }

    /// `true` if the locally-administered bit (bit 1 of the first octet) is set.
    bool isLocal() const { return (_octets[0] & 0x02) != 0; }

    /// `true` if the address is universally administered (the U/L bit clear).
    bool isUniversal() const { return !isLocal(); }

    /// Write the canonical form into `dst`, returning the number of characters
    /// written. `dst` must be at least 23 characters long.
    package int formatTo(scope char[] dst) const
    {
        return formatHexBytes(_octets[], dst);
    }

    /// Parse a 64-bit EUI-64 address. Returns `true` on success.
    static bool fromString(scope const(char)[] s, out EUI64Address result)
    {
        ubyte[8] octets;
        if (!parseHexBytes(s, octets[])) return false;
        result = EUI64Address(octets);
        return true;
    }

    /// Equality compares the raw octets.
    bool opEquals(const EUI64Address rhs) const { return _octets == rhs._octets; }

    /// Ordering is lexicographic over the octets.
    int opCmp(const EUI64Address rhs) const
    {
        foreach (i; 0 .. 8)
            if (_octets[i] != rhs._octets[i])
                return _octets[i] < rhs._octets[i] ? -1 : 1;
        return 0;
    }

    /// Hashes the raw octets.
    size_t toHash() const @trusted
    {
        size_t h = fnvBasis & size_t.max;
        foreach (b; _octets) { h ^= b; h *= fnvPrime; }
        return h;
    }
}

/*
 * =============================================================================
 *  Unit tests
 * =============================================================================
 */

// IPv4Address: construction, accessors and predicates.
@safe pure nothrow @nogc unittest
{
    auto a = IPv4Address(192, 0, 2, 1);
    assert(a.octets() == [192, 0, 2, 1]);
    assert(a.asUint() == 0xC0000201);
    assert(IPv4Address(0xC0000201u) == a);
    assert(IPv4Address([ubyte(192), 0, 2, 1]) == a);

    assert(IPv4Address.unspecified().isUnspecified());
    assert(IPv4Address.loopback().isLoopback());
    assert(IPv4Address(255, 255, 255, 255) == IPv4Address.broadcast());

    assert(IPv4Address(10, 1, 2, 3).isPrivate());
    assert(IPv4Address(172, 16, 0, 1).isPrivate());
    assert(IPv4Address(172, 32, 0, 1).isPrivate() == false);
    assert(IPv4Address(192, 168, 1, 1).isPrivate());
    assert(IPv4Address(8, 8, 8, 8).isPrivate() == false);
    assert(IPv4Address(169, 254, 1, 1).isLinkLocal());
    assert(IPv4Address(224, 0, 0, 1).isMulticast());
    assert(IPv4Address(192, 0, 2, 1).isMulticast() == false);
}

// IPv4Address: parsing and formatting.
@safe unittest
{
    IPv4Address a;
    assert(IPv4Address.fromString("192.0.2.1", a) && a == IPv4Address(192, 0, 2, 1));
    assert(IPv4Address.fromString("0.0.0.0", a) && a.isUnspecified());
    assert(IPv4Address.fromString("255.255.255.255", a));
    assert(a.toString() == "255.255.255.255");
    assert(IPv4Address(192, 0, 2, 1).toString() == "192.0.2.1");
    assert(cast(string) IPv4Address(1, 2, 3, 4) == "1.2.3.4");

    // Rejections.
    assert(!IPv4Address.fromString("192.0.2", a));
    assert(!IPv4Address.fromString("192.0.2.1.5", a));
    assert(!IPv4Address.fromString("256.0.0.1", a));
    assert(!IPv4Address.fromString("192.00.2.1", a));   // leading zero
    assert(!IPv4Address.fromString("192.0.2.", a));
    assert(!IPv4Address.fromString(".0.2.1", a));
    assert(!IPv4Address.fromString("192.0.2.1 ", a));
    assert(!IPv4Address.fromString("1234.0.0.1", a));
    assert(!IPv4Address.fromString("a.b.c.d", a));
}

// IPv4Address: ordering and hashing.
@safe pure nothrow @nogc unittest
{
    assert(IPv4Address(1, 0, 0, 0) < IPv4Address(2, 0, 0, 0));
    assert(IPv4Address(1, 0, 0, 0) > IPv4Address(0, 255, 255, 255));
    assert(IPv4Address(1, 2, 3, 4).opCmp(IPv4Address(1, 2, 3, 4)) == 0);
    assert(IPv4Address(1, 2, 3, 4).toHash() == IPv4Address(1, 2, 3, 4).toHash());
}

// IPv6Address: construction and predicates.
@safe pure nothrow @nogc unittest
{
    auto a = IPv6Address([ushort(0x2001), 0x0db8, 0, 0, 0, 0, 0, 1]);
    assert(a.group(0) == 0x2001);
    assert(a.group(7) == 1);
    assert(a.bytes()[0] == 0x20 && a.bytes()[1] == 0x01);

    assert(IPv6Address.unspecified().isUnspecified());
    assert(IPv6Address.loopback().isLoopback());
    assert(!IPv6Address.loopback().isUnspecified());

    assert(IPv6Address([ushort(0xff02), 0, 0, 0, 0, 0, 0, 1]).isMulticast());
    assert(IPv6Address([ushort(0xfe80), 0, 0, 0, 0, 0, 0, 1]).isLinkLocal());
    assert(a.isMulticast() == false);
}

// IPv6Address: parsing.
@safe pure nothrow unittest
{
    IPv6Address a;
    assert(IPv6Address.fromString("2001:db8::1", a));
    assert(a == IPv6Address([ushort(0x2001), 0x0db8, 0, 0, 0, 0, 0, 1]));

    assert(IPv6Address.fromString("::", a) && a.isUnspecified());
    assert(IPv6Address.fromString("::1", a) && a.isLoopback());
    assert(IPv6Address.fromString("2001:db8::", a));
    assert(IPv6Address.fromString("0:0:0:0:0:0:0:0", a) && a.isUnspecified());
    assert(IPv6Address.fromString("fe80::1", a) && a.isLinkLocal());

    // Embedded IPv4 and v4-mapped.
    assert(IPv6Address.fromString("::ffff:192.0.2.1", a));
    assert(a.isV4Mapped());
    assert(a.toV4() == IPv4Address(192, 0, 2, 1));
    assert(IPv6Address.fromString("2001:db8::192.0.2.1", a));

    // Rejections.
    assert(!IPv6Address.fromString("2001:db8::1::2", a)); // two "::"
    assert(!IPv6Address.fromString("2001:db8:0:0:0:0:0:0:1", a)); // 9 groups
    assert(!IPv6Address.fromString("2001:db8", a));        // too few, no "::"
    assert(!IPv6Address.fromString(":1", a));              // bad leading colon
    assert(!IPv6Address.fromString("2001:db8::1:", a));    // trailing colon
    assert(!IPv6Address.fromString("12345::", a));         // group too long
    assert(!IPv6Address.fromString("xyz::", a));
    assert(!IPv6Address.fromString("", a));
    assert(!IPv6Address.fromString("::ffff:300.0.2.1", a)); // bad v4 tail
}

// IPv6Address: RFC 5952 formatting.
@safe unittest
{
    IPv6Address a;
    assert(IPv6Address.fromString("2001:db8::1", a) && a.toString() == "2001:db8::1");
    assert(IPv6Address.fromString("::", a) && a.toString() == "::");
    assert(IPv6Address.fromString("::1", a) && a.toString() == "::1");
    assert(IPv6Address.fromString("2001:db8::", a) && a.toString() == "2001:db8::");
    assert(IPv6Address.fromString("2001:0db8:0000:0000:0000:0000:0000:0001", a));
    assert(a.toString() == "2001:db8::1");
    // Longest run wins; leftmost on ties.
    assert(IPv6Address.fromString("1:0:0:1:0:0:0:1", a) && a.toString() == "1:0:0:1::1");
    assert(IPv6Address.fromString("1:0:0:0:2:0:0:3", a) && a.toString() == "1::2:0:0:3");
    // Single zero group is not compressed.
    assert(IPv6Address.fromString("1:2:3:4:5:6:0:8", a) && a.toString() == "1:2:3:4:5:6:0:8");
    // v4-mapped output.
    assert(IPv6Address.fromString("::ffff:192.0.2.1", a));
    assert(a.toString() == "::ffff:192.0.2.1");
    assert(cast(string) IPv6Address.loopback() == "::1");
}

// IPv6Address: ordering and hashing.
@safe pure nothrow @nogc unittest
{
    auto lo = IPv6Address.loopback();
    auto hi = IPv6Address([ushort(0x2001), 0, 0, 0, 0, 0, 0, 0]);
    assert(lo < hi);
    assert(hi > lo);
    assert(lo.opCmp(lo) == 0);
    assert(lo.toHash() == IPv6Address.loopback().toHash());
    assert(lo.toHash() != hi.toHash());
}

// IPAddress: tagged union behaviour.
@safe unittest
{
    auto v4 = IPAddress(IPv4Address(192, 0, 2, 1));
    assert(v4.family() == IPFamily.v4);
    assert(v4.isV4() && !v4.isV6());
    assert(v4.toV4() == IPv4Address(192, 0, 2, 1));
    assert(v4.toString() == "192.0.2.1");

    auto v6 = IPAddress(IPv6Address.loopback());
    assert(v6.family() == IPFamily.v6);
    assert(v6.isV6());
    assert(v6.toV6() == IPv6Address.loopback());
    assert(v6.toString() == "::1");

    IPAddress none;
    assert(none.family() == IPFamily.none);
    assert(none.toString() is null);

    IPAddress p;
    assert(IPAddress.fromString("192.0.2.1", p) && p == v4);
    assert(IPAddress.fromString("::1", p) && p == v6);
    assert(!IPAddress.fromString("not-an-address", p));
    assert(!IPAddress.fromString("::xyz", p));

    assert(v4 != v6);
    assert(v4 < v6);                 // v4 family sorts before v6
    assert(v4.opCmp(v4) == 0);
    // Same-family ordering by address bytes.
    assert(IPAddress(IPv4Address(1, 0, 0, 0)) < IPAddress(IPv4Address(2, 0, 0, 0)));
    assert(IPAddress(IPv6Address.loopback()) < IPAddress(IPv6Address([ushort(0x2001), 0, 0, 0, 0, 0, 0, 0])));
    assert(v4.toHash() == IPAddress(IPv4Address(192, 0, 2, 1)).toHash());
    assert(v4.toHash() != v6.toHash());
    assert(cast(string) v6 == "::1");
}

// IPv4Network: masks, membership and parsing.
@safe unittest
{
    IPv4Network net;
    assert(IPv4Network.fromString("192.168.1.0/24", net));
    assert(net.address() == IPv4Address(192, 168, 1, 0));
    assert(net.prefix() == 24);
    assert(net.netmask() == IPv4Address(255, 255, 255, 0));
    assert(net.hostmask() == IPv4Address(0, 0, 0, 255));
    assert(net.networkAddress() == IPv4Address(192, 168, 1, 0));
    assert(net.broadcast() == IPv4Address(192, 168, 1, 255));
    assert(net.isCanonical());
    assert(net.contains(IPv4Address(192, 168, 1, 200)));
    assert(!net.contains(IPv4Address(192, 168, 2, 1)));
    assert(net.toString() == "192.168.1.0/24");

    // Host bits preserved (store-as-is).
    assert(IPv4Network.fromString("192.168.1.5/24", net));
    assert(!net.isCanonical());
    assert(net.networkAddress() == IPv4Address(192, 168, 1, 0));
    assert(net.toString() == "192.168.1.5/24");

    // Prefix 0 and 32 edge cases.
    assert(IPv4Network.fromString("0.0.0.0/0", net));
    assert(net.netmask() == IPv4Address(0, 0, 0, 0));
    assert(net.contains(IPv4Address(8, 8, 8, 8)));
    assert(IPv4Network.fromString("10.0.0.1/32", net));
    assert(net.netmask() == IPv4Address(255, 255, 255, 255));
    assert(net.broadcast() == IPv4Address(10, 0, 0, 1));

    // Clamping and rejections.
    assert(IPv4Network(IPv4Address(1, 2, 3, 4), 40).prefix() == 32);
    assert(!IPv4Network.fromString("192.168.1.0", net));   // no slash
    assert(!IPv4Network.fromString("192.168.1.0/33", net)); // bad prefix
    assert(!IPv4Network.fromString("192.168.1.0/", net));
    assert(!IPv4Network.fromString("192.168.1.0/01", net)); // leading zero
    assert(!IPv4Network.fromString("bad/24", net));

    auto n2 = IPv4Network(IPv4Address(192, 168, 1, 0), 24);
    assert(n2 == IPv4Network(IPv4Address(192, 168, 1, 0), 24));
    assert(n2 < IPv4Network(IPv4Address(192, 168, 1, 0), 25));
    assert(n2 < IPv4Network(IPv4Address(192, 168, 2, 0), 24));
    assert(n2.opCmp(n2) == 0);
    assert(n2.toHash() == IPv4Network(IPv4Address(192, 168, 1, 0), 24).toHash());
    assert(cast(string) n2 == "192.168.1.0/24");
}

// IPv6Network: masks, membership and parsing.
@safe unittest
{
    IPv6Network net;
    assert(IPv6Network.fromString("2001:db8::/32", net));
    assert(net.prefix() == 32);
    assert(net.isCanonical());
    assert(net.networkAddress() == net.address());
    IPv6Address inside, outside;
    assert(IPv6Address.fromString("2001:db8::dead:beef", inside));
    assert(IPv6Address.fromString("2001:db9::1", outside));
    assert(net.contains(inside));
    assert(!net.contains(outside));
    assert(net.toString() == "2001:db8::/32");

    immutable ubyte[16] full = net.netmask().bytes();
    assert(full[0] == 0xFF && full[3] == 0xFF && full[4] == 0x00);
    immutable ubyte[16] host = net.hostmask().bytes();
    assert(host[0] == 0x00 && host[4] == 0xFF && host[15] == 0xFF);

    // Non-canonical, prefix 0 and 128.
    assert(IPv6Network.fromString("2001:db8::1/32", net) && !net.isCanonical());
    assert(IPv6Network.fromString("::/0", net) && net.contains(outside));
    assert(IPv6Network.fromString("2001:db8::1/128", net) && net.isCanonical());

    assert(IPv6Network(IPv6Address.loopback(), 200).prefix() == 128);
    assert(!IPv6Network.fromString("2001:db8::", net));
    assert(!IPv6Network.fromString("2001:db8::/129", net));
    assert(!IPv6Network.fromString("xyz::/32", net));

    auto a = IPv6Network(IPv6Address.loopback(), 64);
    assert(a == IPv6Network(IPv6Address.loopback(), 64));
    assert(a < IPv6Network(IPv6Address.loopback(), 65));
    assert(a.opCmp(a) == 0);
    assert(a.toHash() == IPv6Network(IPv6Address.loopback(), 64).toHash());
    assert(cast(string) a == "::1/64");
}

// IPNetwork: tagged behaviour.
@safe unittest
{
    auto v4 = IPNetwork(IPv4Network(IPv4Address(10, 0, 0, 0), 8));
    assert(v4.isV4() && v4.family() == IPFamily.v4 && v4.prefix() == 8);
    assert(v4.toV4().contains(IPv4Address(10, 1, 2, 3)));
    assert(v4.toString() == "10.0.0.0/8");

    auto v6 = IPNetwork(IPv6Network(IPv6Address.loopback(), 128));
    assert(v6.isV6() && v6.family() == IPFamily.v6);
    assert(v6.toV6().address() == IPv6Address.loopback());
    assert(v6.toString() == "::1/128");

    IPNetwork none;
    assert(none.family() == IPFamily.none && none.toString() is null);

    IPNetwork p;
    assert(IPNetwork.fromString("10.0.0.0/8", p) && p == v4);
    assert(IPNetwork.fromString("::1/128", p) && p == v6);
    assert(!IPNetwork.fromString("10.0.0.0", p));
    assert(!IPNetwork.fromString("::1/200", p));

    assert(v4 != v6);
    assert(v4 < v6);
    assert(v4.opCmp(v4) == 0);
    // Same-family ordering by address bytes.
    assert(IPNetwork(IPv4Network(IPv4Address(1, 0, 0, 0), 8)) < IPNetwork(IPv4Network(IPv4Address(2, 0, 0, 0), 8)));
    assert(v4.toHash() == IPNetwork(IPv4Network(IPv4Address(10, 0, 0, 0), 8)).toHash());
    assert(v4.toHash() != v6.toHash());
    assert(cast(string) v6 == "::1/128");
}

// MACAddress: parsing, formatting, predicates and EUI-64 conversion.
@safe unittest
{
    MACAddress m;
    assert(MACAddress.fromString("01:23:45:67:89:ab", m));
    assert(m.octets() == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab]);
    assert(m.toString() == "01:23:45:67:89:ab");
    assert(cast(string) m == "01:23:45:67:89:ab");

    // Alternative input forms produce the same value.
    MACAddress m2, m3, m4;
    assert(MACAddress.fromString("01-23-45-67-89-AB", m2) && m2 == m);
    assert(MACAddress.fromString("0123.4567.89ab", m3) && m3 == m);
    assert(MACAddress.fromString("0123456789ab", m4) && m4 == m);

    // Predicates.
    assert(MACAddress([0x01, 0, 0, 0, 0, 0]).isMulticast());
    assert(MACAddress([0x02, 0, 0, 0, 0, 0]).isUnicast());
    assert(MACAddress([0x02, 0, 0, 0, 0, 0]).isLocal());
    assert(MACAddress([0x00, 0, 0, 0, 0, 0]).isUniversal());
    assert(MACAddress.broadcast().isBroadcast());
    assert(MACAddress.broadcast().isMulticast());
    assert(!m.isBroadcast());

    // EUI-64 conversion: FF-FE insertion and U/L flip.
    auto e = MACAddress([0x00, 0x1a, 0x2b, 0x3c, 0x4d, 0x5e]).toEUI64();
    assert(e.octets() == [0x02, 0x1a, 0x2b, 0xff, 0xfe, 0x3c, 0x4d, 0x5e]);

    // Rejections.
    MACAddress bad;
    assert(!MACAddress.fromString("01:23:45:67:89", bad));     // too few
    assert(!MACAddress.fromString("01:23:45:67:89:ab:cd", bad)); // too many
    assert(!MACAddress.fromString("01:23:45:67:89:zz", bad));   // bad hex
    assert(!MACAddress.fromString("0123.4567.89", bad));        // short dotted group
    assert(!MACAddress.fromString("01:23:45:67:89:a", bad));    // short final group

    // Ordering and hashing.
    assert(MACAddress([0,0,0,0,0,1]) < MACAddress([0,0,0,0,0,2]));
    assert(m.opCmp(m) == 0);
    assert(m.toHash() == m2.toHash());
}

// EUI64Address: parsing, formatting, predicates.
@safe unittest
{
    EUI64Address e;
    assert(EUI64Address.fromString("01:23:45:67:89:ab:cd:ef", e));
    assert(e.octets() == [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef]);
    assert(e.toString() == "01:23:45:67:89:ab:cd:ef");
    assert(cast(string) e == "01:23:45:67:89:ab:cd:ef");

    EUI64Address e2, e3;
    assert(EUI64Address.fromString("01-23-45-67-89-AB-CD-EF", e2) && e2 == e);
    assert(EUI64Address.fromString("0123.4567.89ab.cdef", e3) && e3 == e);

    assert(EUI64Address([0x01, 0, 0, 0, 0, 0, 0, 0]).isMulticast());
    assert(EUI64Address([0x00, 0, 0, 0, 0, 0, 0, 0]).isUnicast());
    assert(EUI64Address([0x02, 0, 0, 0, 0, 0, 0, 0]).isLocal());
    assert(EUI64Address([0x00, 0, 0, 0, 0, 0, 0, 0]).isUniversal());

    assert(!EUI64Address.fromString("01:23:45:67:89:ab:cd", e2)); // too few
    assert(!EUI64Address.fromString("zz:23:45:67:89:ab:cd:ef", e2));

    assert(EUI64Address([0,0,0,0,0,0,0,1]) < EUI64Address([0,0,0,0,0,0,0,2]));
    assert(e.opCmp(e) == 0);
    assert(e.toHash() == e3.toHash());
}

// CTFE: the core operations work at compile time.
@safe pure nothrow @nogc unittest
{
    static IPv4Address ctfeV4()
    {
        IPv4Address a;
        assert(IPv4Address.fromString("192.0.2.1", a));
        return a;
    }
    static assert(ctfeV4() == IPv4Address(192, 0, 2, 1));

    static bool ctfeV6Roundtrip()
    {
        IPv6Address a;
        return IPv6Address.fromString("2001:db8::1", a)
            && a == IPv6Address([ushort(0x2001), 0x0db8, 0, 0, 0, 0, 0, 1]);
    }
    static assert(ctfeV6Roundtrip());

    static bool ctfeMac()
    {
        MACAddress m;
        return MACAddress.fromString("01:23:45:67:89:ab", m)
            && m.toEUI64().octets()[3] == 0xFF;
    }
    static assert(ctfeMac());
}

