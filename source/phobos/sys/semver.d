/**
 * A value type for representing and storing Semantic Versioning 2.0.0 numbers.
 *
 * This module provides a single compact value type, `SemVer`, that models a
 * version number exactly as defined by the $(HTTP semver.org, Semantic
 * Versioning 2.0.0) specification: a `major.minor.patch` core, an optional
 * dot-separated pre-release tag and optional dot-separated build metadata.
 *
 * The type is intended purely for representation and storage. The numeric
 * core is held as three unsigned integers and the textual pre-release and
 * build portions are stored verbatim (in their canonical, validated form),
 * which keeps the type small and makes parsing and comparison fast.
 *
 * Ordering follows the SemVer precedence rules to the letter:
 *
 * $(UL
 *   $(LI The `major`, `minor` and `patch` numbers are compared numerically.)
 *   $(LI A version carrying a pre-release tag has $(I lower) precedence than
 *        the otherwise identical normal version.)
 *   $(LI Pre-release identifiers are compared field by field; purely numeric
 *        identifiers are compared numerically and rank below alphanumeric
 *        ones, and a larger set of fields wins when all preceding fields are
 *        equal.)
 *   $(LI Build metadata is ignored when determining precedence, but it is
 *        preserved and reproduced by `toString`.)
 * )
 *
 * Every operation other than `toString` and `fromString` is
 * `pure nothrow @safe @nogc` and usable in CTFE; the two exceptions allocate
 * only the returned / stored string.
 *
 * The implementation deliberately avoids the standard library so that it can
 * be dropped into the forthcoming Phobos 3 with minimal friction.
 *
 * Copyright: Copyright © 2026, Adam Wilson.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Adam Wilson
 */
module phobos.sys.semver;

// Only `toString` (which allocates the result) and `fromString` (which stores
// copies of the pre-release / build text) are non-`@nogc`; everything else is
// pure, nothrow, @safe, @nogc and CTFE-capable. Attributes are therefore
// applied per-declaration rather than module-wide.
@safe:

/*
 * =============================================================================
 *  ASCII / parsing helpers
 *  -------------------------------------------------------------------------
 *  Small character and integer utilities used by the parser, the formatter
 *  and the precedence comparison. They have no dependency on the standard
 *  library.
 * =============================================================================
 */

// FNV-1a hashing constants used by `SemVer.toHash`.
private enum ulong fnvBasis = 1_469_598_103_934_665_603UL;
private enum ulong fnvPrime = 1_099_511_628_211UL;

/// Whether `c` is an ASCII decimal digit.
private bool isDigit(char c) pure nothrow @nogc
{
    return c >= '0' && c <= '9';
}

/// Whether `c` is a legal SemVer identifier character: a digit, an ASCII
/// letter or a hyphen.
private bool isIdentChar(char c) pure nothrow @nogc
{
    return isDigit(c)
        || (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || c == '-';
}

/// Whether the identifier `id` is a non-empty run of decimal digits.
private bool isNumericIdentifier(scope const(char)[] id) pure nothrow @nogc
{
    if (id.length == 0) return false;
    foreach (c; id)
        if (!isDigit(c)) return false;
    return true;
}

/// The number of decimal digits needed to print `v`.
private size_t decimalLength(uint v) pure nothrow @nogc
{
    size_t n = 1;
    while (v >= 10) { v /= 10; ++n; }
    return n;
}

/// Write the decimal representation of `v` into `dst`, returning the number of
/// characters written.
private size_t writeUint(uint v, scope char[] dst) pure nothrow @nogc
{
    char[10] tmp = void;
    size_t k = 0;
    do
    {
        tmp[k++] = cast(char)('0' + v % 10);
        v /= 10;
    }
    while (v != 0);
    foreach (j; 0 .. k)
        dst[j] = tmp[k - 1 - j];
    return k;
}

/// Parse a SemVer numeric core component (major, minor or patch) starting at
/// `s[i]`, advancing `i` past it. Leading zeroes and values that overflow
/// `uint` are rejected. Returns `true` on success.
private bool parseNumericCore(scope const(char)[] s, ref size_t i, out uint value)
    pure nothrow @nogc
{
    if (i >= s.length || !isDigit(s[i])) return false;
    immutable bool leadingZero = s[i] == '0';
    ulong v = 0;
    size_t digits = 0;
    while (i < s.length && isDigit(s[i]))
    {
        v = v * 10 + (s[i] - '0');
        if (v > uint.max) return false;
        ++i;
        ++digits;
    }
    if (digits > 1 && leadingZero) return false;
    value = cast(uint) v;
    return true;
}

/// Validate a single pre-release identifier: it must be non-empty, consist
/// solely of identifier characters and, when purely numeric, carry no leading
/// zero.
private bool validatePrereleaseIdentifier(scope const(char)[] id) pure nothrow @nogc
{
    if (id.length == 0) return false;
    bool allDigits = true;
    foreach (c; id)
    {
        if (!isIdentChar(c)) return false;
        if (!isDigit(c)) allDigits = false;
    }
    if (allDigits && id.length > 1 && id[0] == '0') return false;
    return true;
}

/// Validate a complete pre-release tag (the text after `-`, without that
/// leading hyphen): a non-empty, dot-separated list of valid identifiers.
private bool validatePrerelease(scope const(char)[] s) pure nothrow @nogc
{
    if (s.length == 0) return false;
    size_t i = 0;
    for (;;)
    {
        size_t j = i;
        while (j < s.length && s[j] != '.') ++j;
        if (!validatePrereleaseIdentifier(s[i .. j])) return false;
        if (j >= s.length) return true;
        i = j + 1;
    }
}

/// Validate complete build metadata (the text after `+`, without that leading
/// plus): a non-empty, dot-separated list of non-empty identifiers. Unlike
/// pre-release identifiers, purely numeric build identifiers may carry leading
/// zeroes.
private bool validateBuild(scope const(char)[] s) pure nothrow @nogc
{
    if (s.length == 0) return false;
    size_t i = 0;
    for (;;)
    {
        size_t j = i;
        while (j < s.length && s[j] != '.') ++j;
        if (j == i) return false;
        foreach (c; s[i .. j])
            if (!isIdentChar(c)) return false;
        if (j >= s.length) return true;
        i = j + 1;
    }
}

/// Compare two single identifiers per the SemVer precedence rules: numeric
/// identifiers compare numerically and rank below alphanumeric ones, which
/// compare in ASCII order.
private int compareIdentifier(scope const(char)[] a, scope const(char)[] b)
    pure nothrow @nogc
{
    immutable bool an = isNumericIdentifier(a);
    immutable bool bn = isNumericIdentifier(b);
    if (an != bn) return an ? -1 : 1;       // numeric ranks below alphanumeric
    if (an && bn && a.length != b.length)   // no leading zeroes: longer is larger
        return a.length < b.length ? -1 : 1;
    immutable n = a.length < b.length ? a.length : b.length;
    foreach (k; 0 .. n)
        if (a[k] != b[k]) return a[k] < b[k] ? -1 : 1;
    if (a.length == b.length) return 0;
    return a.length < b.length ? -1 : 1;
}

/// Compare two pre-release tags per the SemVer precedence rules. An empty tag
/// (no pre-release) ranks $(I above) any non-empty tag.
private int comparePrerelease(scope const(char)[] a, scope const(char)[] b)
    pure nothrow @nogc
{
    if (a.length == 0 && b.length == 0) return 0;
    if (a.length == 0) return 1;            // a has no pre-release -> higher
    if (b.length == 0) return -1;

    size_t ia = 0, ib = 0;
    for (;;)
    {
        immutable bool aEnd = ia > a.length;
        immutable bool bEnd = ib > b.length;
        if (aEnd && bEnd) return 0;
        if (aEnd) return -1;               // fewer fields ranks lower
        if (bEnd) return 1;

        size_t ja = ia;
        while (ja < a.length && a[ja] != '.') ++ja;
        size_t jb = ib;
        while (jb < b.length && b[jb] != '.') ++jb;

        immutable c = compareIdentifier(a[ia .. ja], b[ib .. jb]);
        if (c != 0) return c;

        ia = ja + 1;
        ib = jb + 1;
    }
}

/*
 * =============================================================================
 *  SemVer
 * =============================================================================
 */

/**
 * A Semantic Versioning 2.0.0 version number.
 *
 * The `major`, `minor` and `patch` numbers are stored as `uint` (so each is
 * limited to the range `0 .. uint.max`). The optional pre-release tag and
 * build metadata are stored verbatim as their canonical dot-separated text,
 * without the leading `-` / `+` delimiters; an empty string denotes absence.
 *
 * Equality and ordering follow SemVer precedence, which means build metadata
 * is ignored when comparing two values even though it is preserved by
 * `toString`.
 */
struct SemVer
{
    private uint _major;
    private uint _minor;
    private uint _patch;
    private string _prerelease;
    private string _build;

    /**
     * Convert to the canonical SemVer text form, e.g.
     * `"1.2.3-alpha.1+build.7"`.
     */
    string toString() const pure @safe
    {
        auto buf = new char[formattedLength()];
        immutable n = formatTo(buf);
        return (() @trusted => cast(string) buf[0 .. n])();
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

    /**
     * Parse a SemVer 2.0.0 version string such as `"1.2.3-rc.1+build"`.
     *
     * The `major`, `minor` and `patch` fields must each be a non-negative
     * decimal integer without redundant leading zeroes. The optional
     * pre-release tag and build metadata are validated against the SemVer
     * grammar. Returns `true` on success, leaving `result` set to the parsed
     * value; on failure `result` is left in its default state and `false` is
     * returned.
     */
    static bool fromString(scope const(char)[] s, out SemVer result) @safe
    {
        size_t i = 0;
        uint major = void, minor = void, patch = void;

        if (!parseNumericCore(s, i, major)) return false;
        if (i >= s.length || s[i] != '.') return false;
        ++i;
        if (!parseNumericCore(s, i, minor)) return false;
        if (i >= s.length || s[i] != '.') return false;
        ++i;
        if (!parseNumericCore(s, i, patch)) return false;

        const(char)[] pre;
        const(char)[] build;

        if (i < s.length && s[i] == '-')
        {
            ++i;
            immutable start = i;
            while (i < s.length && s[i] != '+') ++i;
            pre = s[start .. i];
            if (!validatePrerelease(pre)) return false;
        }
        if (i < s.length && s[i] == '+')
        {
            ++i;
            build = s[i .. $];
            i = s.length;
            if (!validateBuild(build)) return false;
        }
        if (i != s.length) return false;

        result._major = major;
        result._minor = minor;
        result._patch = patch;
        result._prerelease = pre.length ? pre.idup : null;
        result._build = build.length ? build.idup : null;
        return true;
    }

pure nothrow @safe @nogc:

    /**
     * Construct from the numeric core only (no pre-release or build metadata).
     */
    this(uint major, uint minor, uint patch)
    {
        _major = major;
        _minor = minor;
        _patch = patch;
    }

    /**
     * Construct from all components. `prerelease` and `build` must already be
     * in canonical form: the dot-separated identifier text without the leading
     * `-` / `+` delimiters, or empty to denote absence.
     */
    this(uint major, uint minor, uint patch, string prerelease, string build = null)
    {
        assert(prerelease.length == 0 || validatePrerelease(prerelease),
            "invalid pre-release identifiers");
        assert(build.length == 0 || validateBuild(build),
            "invalid build metadata");
        _major = major;
        _minor = minor;
        _patch = patch;
        _prerelease = prerelease;
        _build = build;
    }

    /// The major version number.
    uint major() const { return _major; }

    /// The minor version number.
    uint minor() const { return _minor; }

    /// The patch version number.
    uint patch() const { return _patch; }

    /// The pre-release tag without its leading `-`, or an empty string when
    /// absent.
    string prerelease() const { return _prerelease; }

    /// The build metadata without its leading `+`, or an empty string when
    /// absent.
    string build() const { return _build; }

    /// Whether this is a pre-release version (i.e. it carries a pre-release
    /// tag).
    bool isPrerelease() const { return _prerelease.length != 0; }

    /// Whether this version carries build metadata.
    bool hasBuildMetadata() const { return _build.length != 0; }

    /// The number of characters `formatTo` (and `toString`) will produce.
    package size_t formattedLength() const
    {
        size_t n = decimalLength(_major) + decimalLength(_minor)
            + decimalLength(_patch) + 2;
        if (_prerelease.length) n += 1 + _prerelease.length;
        if (_build.length) n += 1 + _build.length;
        return n;
    }

    /**
     * Write the canonical text form into `dst`, returning the number of
     * characters written. `dst` must be at least `formattedLength` characters
     * long.
     */
    package size_t formatTo(scope char[] dst) const
    {
        size_t n = 0;
        n += writeUint(_major, dst[n .. $]);
        dst[n++] = '.';
        n += writeUint(_minor, dst[n .. $]);
        dst[n++] = '.';
        n += writeUint(_patch, dst[n .. $]);
        if (_prerelease.length)
        {
            dst[n++] = '-';
            foreach (c; _prerelease) dst[n++] = c;
        }
        if (_build.length)
        {
            dst[n++] = '+';
            foreach (c; _build) dst[n++] = c;
        }
        return n;
    }

    /// Equality follows SemVer precedence and therefore ignores build
    /// metadata.
    bool opEquals(const scope SemVer rhs) const
    {
        return _major == rhs._major
            && _minor == rhs._minor
            && _patch == rhs._patch
            && _prerelease == rhs._prerelease;
    }

    /// Ordering follows the SemVer precedence rules; build metadata is ignored.
    int opCmp(const scope SemVer rhs) const
    {
        if (_major != rhs._major) return _major < rhs._major ? -1 : 1;
        if (_minor != rhs._minor) return _minor < rhs._minor ? -1 : 1;
        if (_patch != rhs._patch) return _patch < rhs._patch ? -1 : 1;
        return comparePrerelease(_prerelease, rhs._prerelease);
    }

    /// Hashes the precedence-significant fields (build metadata is excluded so
    /// that the hash agrees with `opEquals`).
    size_t toHash() const
    {
        ulong h = fnvBasis;
        foreach (shift; 0 .. 4) h = (h ^ ((_major >> (shift * 8)) & 0xFF)) * fnvPrime;
        foreach (shift; 0 .. 4) h = (h ^ ((_minor >> (shift * 8)) & 0xFF)) * fnvPrime;
        foreach (shift; 0 .. 4) h = (h ^ ((_patch >> (shift * 8)) & 0xFF)) * fnvPrime;
        foreach (c; _prerelease) h = (h ^ cast(ubyte) c) * fnvPrime;
        return cast(size_t) h;
    }
}

/*
 * =============================================================================
 *  Unit tests
 * =============================================================================
 */

// SemVer: construction and accessors.
@safe pure nothrow @nogc unittest
{
    auto v = SemVer(1, 2, 3);
    assert(v.major == 1 && v.minor == 2 && v.patch == 3);
    assert(v.prerelease.length == 0 && v.build.length == 0);
    assert(!v.isPrerelease());
    assert(!v.hasBuildMetadata());

    auto p = SemVer(1, 0, 0, "alpha.1", "build.7");
    assert(p.isPrerelease());
    assert(p.hasBuildMetadata());
    assert(p.prerelease == "alpha.1");
    assert(p.build == "build.7");
}

// SemVer: parsing of valid version strings.
@safe unittest
{
    SemVer v;
    assert(SemVer.fromString("0.0.0", v) && v == SemVer(0, 0, 0));
    assert(SemVer.fromString("1.2.3", v) && v == SemVer(1, 2, 3));

    assert(SemVer.fromString("1.2.3-alpha", v));
    assert(v.prerelease == "alpha" && v.build.length == 0);

    assert(SemVer.fromString("1.2.3-alpha.1.0", v));
    assert(v.prerelease == "alpha.1.0");

    assert(SemVer.fromString("1.2.3+build.001", v));
    assert(v.build == "build.001" && v.prerelease.length == 0);

    assert(SemVer.fromString("1.2.3-rc.1+exp.sha.5114f85", v));
    assert(v.prerelease == "rc.1" && v.build == "exp.sha.5114f85");

    // Large but in-range numeric core.
    assert(SemVer.fromString("4294967295.0.0", v) && v.major == uint.max);
}

// SemVer: rejection of malformed version strings.
@safe unittest
{
    SemVer v;
    assert(!SemVer.fromString("", v));
    assert(!SemVer.fromString("1", v));
    assert(!SemVer.fromString("1.2", v));
    assert(!SemVer.fromString("1.2.3.4", v));
    assert(!SemVer.fromString("1.2.", v));
    assert(!SemVer.fromString("01.2.3", v));        // leading zero in core
    assert(!SemVer.fromString("1.02.3", v));
    assert(!SemVer.fromString("1.2.03", v));
    assert(!SemVer.fromString("v1.2.3", v));
    assert(!SemVer.fromString("1.2.3 ", v));
    assert(!SemVer.fromString("4294967296.0.0", v)); // overflows uint
    assert(!SemVer.fromString("1.2.3-", v));         // empty pre-release
    assert(!SemVer.fromString("1.2.3-alpha..1", v)); // empty identifier
    assert(!SemVer.fromString("1.2.3-01", v));       // numeric leading zero
    assert(!SemVer.fromString("1.2.3-al pha", v));   // invalid character
    assert(!SemVer.fromString("1.2.3+", v));         // empty build
    assert(!SemVer.fromString("1.2.3+build..1", v)); // empty build identifier
    assert(!SemVer.fromString("1.2.3+bu ild", v));
}

// SemVer: formatting round-trips.
@safe unittest
{
    assert(SemVer(1, 2, 3).toString() == "1.2.3");
    assert(SemVer(1, 0, 0, "alpha.1").toString() == "1.0.0-alpha.1");
    assert(SemVer(1, 0, 0, "", "build.7").toString() == "1.0.0+build.7");
    assert(SemVer(1, 2, 3, "rc.1", "exp.sha").toString() == "1.2.3-rc.1+exp.sha");
    assert(cast(string) SemVer(10, 20, 30) == "10.20.30");

    foreach (s; ["0.0.0", "1.2.3", "1.2.3-alpha", "1.2.3-alpha.1+build.001",
                 "4294967295.4294967295.4294967295"])
    {
        SemVer v;
        assert(SemVer.fromString(s, v));
        assert(v.toString() == s);
    }
}

// SemVer: precedence ordering (the chain from the specification).
@safe unittest
{
    static immutable order = [
        "1.0.0-alpha",
        "1.0.0-alpha.1",
        "1.0.0-alpha.beta",
        "1.0.0-beta",
        "1.0.0-beta.2",
        "1.0.0-beta.11",
        "1.0.0-rc.1",
        "1.0.0",
    ];

    foreach (i; 1 .. order.length)
    {
        SemVer a, b;
        assert(SemVer.fromString(order[i - 1], a));
        assert(SemVer.fromString(order[i], b));
        assert(a < b, order[i - 1] ~ " should precede " ~ order[i]);
        assert(b > a);
        assert(a != b);
        assert(a.opCmp(a) == 0);
    }

    assert(SemVer(1, 0, 0) < SemVer(2, 0, 0));
    assert(SemVer(1, 1, 0) < SemVer(1, 2, 0));
    assert(SemVer(1, 1, 1) < SemVer(1, 1, 2));

    // Alphanumeric identifier that is a prefix of another ranks lower.
    SemVer a, b;
    assert(SemVer.fromString("1.0.0-rc", a));
    assert(SemVer.fromString("1.0.0-rc1", b));
    assert(a < b);
}

// SemVer: build metadata is ignored for precedence, equality and hashing.
@safe unittest
{
    SemVer a, b;
    assert(SemVer.fromString("1.2.3+build.1", a));
    assert(SemVer.fromString("1.2.3+build.2", b));
    assert(a == b);
    assert(a.opCmp(b) == 0);
    assert(a.toHash() == b.toHash());
    // ...but the metadata itself is preserved.
    assert(a.build == "build.1" && b.build == "build.2");

    SemVer c;
    assert(SemVer.fromString("1.2.3", c));
    assert(c == a);
    assert(c.toHash() == a.toHash());
}

// SemVer: hashing agrees with equality and distinguishes pre-releases.
@safe unittest
{
    SemVer a, b;
    assert(SemVer.fromString("1.2.3-alpha", a));
    assert(SemVer.fromString("1.2.3-alpha", b));
    assert(a.toHash() == b.toHash());

    SemVer c;
    assert(SemVer.fromString("1.2.3-beta", c));
    assert(a != c);
}

// SemVer: usable at compile time.
@safe unittest
{
    static bool ctfe()
    {
        SemVer a, b;
        assert(SemVer.fromString("1.2.3-alpha.1+build", a));
        assert(a.major == 1 && a.minor == 2 && a.patch == 3);
        assert(a.prerelease == "alpha.1");
        assert(a.build == "build");
        assert(a.toString() == "1.2.3-alpha.1+build");
        assert(SemVer.fromString("1.2.3", b));
        assert(a < b);
        assert(!SemVer.fromString("1.2.3-01", a));
        return true;
    }
    static assert(ctfe());
}

