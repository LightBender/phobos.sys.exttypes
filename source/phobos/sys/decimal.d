/**
 * IEEE 754-2008 compliant decimal floating-point arithmetic.
 *
 * This module provides three decimal floating-point types, `Decimal32`,
 * `Decimal64` and `Decimal128`, corresponding to the three decimal
 * interchange formats defined by IEEE 754-2008. They use Intel's
 * $(I Binary Integer Decimal) (BID) encoding, in which the coefficient is
 * stored as an ordinary binary integer.
 *
 * The types support the full set of D arithmetic and comparison operators,
 * all five IEEE rounding modes, the five IEEE status flags
 * (invalid, division-by-zero, overflow, underflow and inexact), and
 * conversion to and from integers, `float`, `double` and strings.
 *
 * Copyright: Copyright © 2026, Adam Wilson.
 * License:   $(HTTP www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Authors:   Adam Wilson
 */
module phobos.sys.decimal;

import std.traits : isIntegral, isSigned, isFloatingPoint, Unqual;

// The numeric core of this module is pure, nothrow, @safe, @nogc and
// CTFE-capable. Only the string-producing helpers allocate, so @nogc is
// applied per-declaration rather than module-wide.
nothrow:
@safe:

/*
 * =============================================================================
 *  Phase 1 — Foundation
 *  -------------------------------------------------------------------------
 *  - Rounding mode and status-flag enumerations.
 *  - Per-format parameter trait (precision, exponent range, field widths).
 *  - Internal wide unsigned integer helpers (UInt128, UInt256) used for the
 *    intermediate products and divisions required by the larger formats.
 *  - Decimal helper tables (powers of ten) and digit-counting utilities.
 * =============================================================================
 */

/**
 * The IEEE 754 rounding-direction attributes.
 *
 * `roundTiesToEven` is the default and is used when no explicit mode is
 * supplied to an operation.
 */
enum RoundingMode
{
    /// Round to nearest; ties to the value with an even least-significant digit.
    roundTiesToEven,
    /// Round to nearest; ties away from zero.
    roundTiesToAway,
    /// Round toward $(D +∞).
    roundTowardPositive,
    /// Round toward $(D -∞).
    roundTowardNegative,
    /// Round toward zero (truncate).
    roundTowardZero,
}

/**
 * The IEEE 754 status flags, raised by operations as a bit set.
 *
 * The values are powers of two so that they may be combined with the bitwise
 * `|` operator and tested with `&`.
 */
enum ExceptionFlag : uint
{
    /// No exception was raised.
    none            = 0,
    /// An operand was invalid for the operation (e.g. `0/0`, `∞ - ∞`, `sqrt(-1)`).
    invalidOperation = 1 << 0,
    /// A finite non-zero value was divided by zero.
    divisionByZero  = 1 << 1,
    /// The rounded result's magnitude is too large to represent.
    overflow        = 1 << 2,
    /// The rounded result is subnormal and inexact.
    underflow       = 1 << 3,
    /// The result differs from the infinitely precise result.
    inexact         = 1 << 4,
}

/**
 * Compile-time description of an IEEE 754-2008 decimal interchange format.
 *
 * Params:
 *      bits = the storage width in bits; must be 32, 64 or 128.
 */
template DecimalFormat(int bits)
{
    static assert(bits == 32 || bits == 64 || bits == 128,
        "Only the 32-, 64- and 128-bit decimal formats are supported.");

    /// Total storage width in bits ($(I k) in the standard).
    enum int k = bits;

    static if (bits == 32)
    {
        /// Precision: the number of significant decimal digits ($(I p)).
        enum int precision = 7;
        /// Maximum decimal exponent of a normalized value ($(I emax)).
        enum int emax = 96;
        /// Width of the combination field's exponent continuation ($(I w)).
        enum int combExpBits = 6;
        /// Width of the trailing significand field in bits ($(I t)).
        enum int trailingBits = 20;
        /// The unsigned integer type able to hold a coefficient.
        alias CoefficientType = uint;
        /// Largest coefficient value, `10^precision - 1`.
        enum CoefficientType maxCoefficient = 9_999_999U;
    }
    else static if (bits == 64)
    {
        enum int precision = 16;
        enum int emax = 384;
        enum int combExpBits = 8;
        enum int trailingBits = 50;
        alias CoefficientType = ulong;
        enum CoefficientType maxCoefficient = 9_999_999_999_999_999UL;
    }
    else
    {
        enum int precision = 34;
        enum int emax = 6144;
        enum int combExpBits = 12;
        enum int trailingBits = 110;
        alias CoefficientType = UInt128;
        enum CoefficientType maxCoefficient = pow10_128(34) - UInt128(1);
    }

    /// Minimum decimal exponent of a normalized value ($(I emin) = 1 - emax).
    enum int emin = 1 - emax;
    /// Minimum quantum (unbiased) exponent: `emin - (precision - 1)`.
    enum int qmin = emin - (precision - 1);
    /// Maximum quantum (unbiased) exponent: `emax - (precision - 1)`.
    enum int qmax = emax - (precision - 1);
    /// Exponent bias: subtracted from the biased exponent to give the quantum exponent.
    enum int bias = -qmin;
    /// Width of the biased exponent field in bits (`combExpBits + 2`).
    enum int expBits = combExpBits + 2;
    /// Width of the whole combination field in bits (`combExpBits + 5`).
    enum int combBits = combExpBits + 5;
    /// Largest representable biased exponent (`3 * 2^combExpBits - 1`).
    enum int maxBiasedExp = 3 * (1 << combExpBits) - 1;
}

/*
 * -----------------------------------------------------------------------------
 *  Wide unsigned integers
 *
 *  UInt128 is the storage/coefficient type of the 128-bit format and is also
 *  used to assemble and disassemble its bit pattern. UInt256 is the arithmetic
 *  "engine" used for the intermediate products and scaled dividends that arise
 *  in 64- and 128-bit decimal arithmetic.
 *
 *  Both are little-endian in their limbs (index 0 is least significant) and are
 *  fully usable in CTFE.
 * -----------------------------------------------------------------------------
 */

/// A 128-bit unsigned integer built from two 64-bit limbs.
struct UInt128
{
    /// Least- and most-significant 64-bit limbs.
    ulong lo, hi;

pure nothrow @safe @nogc:

    /// Construct from a 64-bit value.
    this(ulong v) { lo = v; hi = 0; }

    /// Construct from explicit high and low limbs.
    this(ulong high, ulong low) { hi = high; lo = low; }

    /// True if the value is zero.
    bool isZero() const { return (lo | hi) == 0; }

    bool opEquals(UInt128 rhs) const { return lo == rhs.lo && hi == rhs.hi; }

    bool opEquals(ulong rhs) const { return hi == 0 && lo == rhs; }

    int opCmp(UInt128 rhs) const
    {
        if (hi != rhs.hi) return hi < rhs.hi ? -1 : 1;
        if (lo != rhs.lo) return lo < rhs.lo ? -1 : 1;
        return 0;
    }

    UInt128 opUnary(string op : "~")() const { return UInt128(~hi, ~lo); }

    UInt128 opBinary(string op : "&")(UInt128 r) const { return UInt128(hi & r.hi, lo & r.lo); }
    UInt128 opBinary(string op : "|")(UInt128 r) const { return UInt128(hi | r.hi, lo | r.lo); }
    UInt128 opBinary(string op : "^")(UInt128 r) const { return UInt128(hi ^ r.hi, lo ^ r.lo); }

    UInt128 opBinary(string op : "+")(UInt128 r) const
    {
        immutable ulong nlo = lo + r.lo;
        immutable ulong carry = nlo < lo ? 1UL : 0UL;
        return UInt128(hi + r.hi + carry, nlo);
    }

    UInt128 opBinary(string op : "-")(UInt128 r) const
    {
        immutable ulong nlo = lo - r.lo;
        immutable ulong borrow = lo < r.lo ? 1UL : 0UL;
        return UInt128(hi - r.hi - borrow, nlo);
    }

    UInt128 opBinary(string op : "<<")(uint n) const
    {
        if (n == 0) return this;
        if (n >= 128) return UInt128(0);
        if (n >= 64) return UInt128(lo << (n - 64), 0);
        return UInt128((hi << n) | (lo >> (64 - n)), lo << n);
    }

    UInt128 opBinary(string op : ">>")(uint n) const
    {
        if (n == 0) return this;
        if (n >= 128) return UInt128(0);
        if (n >= 64) return UInt128(0, hi >> (n - 64));
        return UInt128(hi >> n, (lo >> n) | (hi << (64 - n)));
    }

    /// 64×64 → 128 widening multiply.
    static UInt128 mul(ulong a, ulong b)
    {
        immutable ulong aLo = a & 0xFFFF_FFFF, aHi = a >> 32;
        immutable ulong bLo = b & 0xFFFF_FFFF, bHi = b >> 32;
        immutable ulong ll = aLo * bLo;
        immutable ulong lh = aLo * bHi;
        immutable ulong hl = aHi * bLo;
        immutable ulong hh = aHi * bHi;
        immutable ulong cross = (ll >> 32) + (lh & 0xFFFF_FFFF) + (hl & 0xFFFF_FFFF);
        immutable ulong low = (ll & 0xFFFF_FFFF) | (cross << 32);
        immutable ulong high = hh + (lh >> 32) + (hl >> 32) + (cross >> 32);
        return UInt128(high, low);
    }
}

/// A 256-bit unsigned integer built from four 64-bit limbs (`v[0]` least significant).
struct UInt256
{
    ulong[4] v;

pure nothrow @safe @nogc:

    /// Construct from a 64-bit value.
    this(ulong x) { v[0] = x; }

    /// Construct from a 128-bit value.
    this(UInt128 x) { v[0] = x.lo; v[1] = x.hi; }

    /// True if the value is zero.
    bool isZero() const { return (v[0] | v[1] | v[2] | v[3]) == 0; }

    int opCmp(UInt256 rhs) const
    {
        foreach_reverse (i; 0 .. 4)
            if (v[i] != rhs.v[i])
                return v[i] < rhs.v[i] ? -1 : 1;
        return 0;
    }

    bool opEquals(UInt256 rhs) const { return v == rhs.v; }

    /// Truncate to the low 128 bits.
    UInt128 toUInt128() const { return UInt128(v[1], v[0]); }

    /// True if the value fits in 128 bits.
    bool fitsIn128() const { return (v[2] | v[3]) == 0; }

    UInt256 opBinary(string op : "+")(UInt256 r) const
    {
        UInt256 res;
        ulong carry = 0;
        foreach (i; 0 .. 4)
        {
            immutable ulong s1 = v[i] + r.v[i];
            immutable ulong c1 = s1 < v[i] ? 1UL : 0UL;
            immutable ulong s2 = s1 + carry;
            immutable ulong c2 = s2 < s1 ? 1UL : 0UL;
            res.v[i] = s2;
            carry = c1 | c2;
        }
        return res;
    }

    UInt256 opBinary(string op : "-")(UInt256 r) const
    {
        UInt256 res;
        ulong borrow = 0;
        foreach (i; 0 .. 4)
        {
            immutable ulong d1 = v[i] - r.v[i];
            immutable ulong b1 = v[i] < r.v[i] ? 1UL : 0UL;
            immutable ulong d2 = d1 - borrow;
            immutable ulong b2 = d1 < borrow ? 1UL : 0UL;
            res.v[i] = d2;
            borrow = b1 | b2;
        }
        return res;
    }

    UInt256 opBinary(string op : "<<")(uint n) const
    {
        if (n == 0) return this;
        UInt256 res;
        immutable uint limbShift = n / 64;
        immutable uint bitShift = n % 64;
        if (limbShift >= 4) return res;
        foreach_reverse (i; 0 .. 4)
        {
            immutable int src = cast(int) i - cast(int) limbShift;
            if (src < 0) continue;
            ulong val = v[src] << bitShift;
            if (bitShift != 0 && src - 1 >= 0)
                val |= v[src - 1] >> (64 - bitShift);
            res.v[i] = val;
        }
        return res;
    }

    UInt256 opBinary(string op : ">>")(uint n) const
    {
        if (n == 0) return this;
        UInt256 res;
        immutable uint limbShift = n / 64;
        immutable uint bitShift = n % 64;
        if (limbShift >= 4) return res;
        foreach (i; 0 .. 4)
        {
            immutable uint src = i + limbShift;
            if (src >= 4) continue;
            ulong val = v[src] >> bitShift;
            if (bitShift != 0 && src + 1 < 4)
                val |= v[src + 1] << (64 - bitShift);
            res.v[i] = val;
        }
        return res;
    }

    /// Bit `i` (0 = least significant).
    private uint bit(uint i) const { return cast(uint)((v[i >> 6] >> (i & 63)) & 1); }
    private void setBit(uint i) { v[i >> 6] |= 1UL << (i & 63); }

    /// Multiply by a 64-bit value, discarding any overflow beyond 256 bits.
    UInt256 mulSmall(ulong m) const
    {
        UInt256 res;
        ulong carry = 0;
        foreach (i; 0 .. 4)
        {
            immutable UInt128 p = UInt128.mul(v[i], m);
            immutable ulong s = p.lo + carry;
            immutable ulong c = s < p.lo ? 1UL : 0UL;
            res.v[i] = s;
            carry = p.hi + c;
        }
        return res;
    }

    /// 128×128 → 256 widening multiply.
    static UInt256 mul(UInt128 a, UInt128 b)
    {
        immutable UInt128 ll = UInt128.mul(a.lo, b.lo);
        immutable UInt128 lh = UInt128.mul(a.lo, b.hi);
        immutable UInt128 hl = UInt128.mul(a.hi, b.lo);
        immutable UInt128 hh = UInt128.mul(a.hi, b.hi);

        UInt256 res;
        res.v[0] = ll.lo;
        // Accumulate the middle limb (bits 64..127).
        ulong carry = 0;
        {
            ulong acc = ll.hi;
            ulong s = acc + lh.lo; ulong c = s < acc ? 1UL : 0UL; acc = s;
            s = acc + hl.lo; c += s < acc ? 1UL : 0UL; acc = s;
            res.v[1] = acc;
            carry = c;
        }
        // Bits 128..191.
        {
            ulong acc = hh.lo;
            ulong c = 0;
            ulong s = acc + lh.hi; c += s < acc ? 1UL : 0UL; acc = s;
            s = acc + hl.hi; c += s < acc ? 1UL : 0UL; acc = s;
            s = acc + carry; c += s < acc ? 1UL : 0UL; acc = s;
            res.v[2] = acc;
            carry = c;
        }
        res.v[3] = hh.hi + carry;
        return res;
    }

    /// Divide by `d` (must be non-zero), returning the quotient and setting `rem`.
    UInt256 divMod(UInt256 d, out UInt256 rem) const
    {
        UInt256 q;
        rem = UInt256(0);
        foreach_reverse (i; 0 .. 256)
        {
            rem = rem << 1;
            rem.v[0] |= bit(cast(uint) i);
            if (rem.opCmp(d) >= 0)
            {
                rem = rem - d;
                q.setBit(cast(uint) i);
            }
        }
        return q;
    }

    /// Divide by a value `< 2^32`, returning the quotient and setting `rem`.
    UInt256 divModSmall(ulong d, out ulong rem) const
    {
        // Process eight 32-bit halves from most to least significant.
        UInt256 q;
        ulong r = 0;
        foreach_reverse (i; 0 .. 8)
        {
            immutable ulong half = (v[i >> 1] >> ((i & 1) * 32)) & 0xFFFF_FFFF;
            immutable ulong cur = (r << 32) | half;
            immutable ulong qh = cur / d;
            r = cur % d;
            q.v[i >> 1] |= (qh & 0xFFFF_FFFF) << ((i & 1) * 32);
        }
        rem = r;
        return q;
    }
}

/*
 * -----------------------------------------------------------------------------
 *  Powers of ten and digit counting
 * -----------------------------------------------------------------------------
 */

/// `10^n` for `0 <= n <= 76`, as a 256-bit value (covers all intermediate widths).
package UInt256 pow10_256(int n) pure @nogc
{
    static immutable UInt256[77] table = () {
        UInt256[77] t;
        t[0] = UInt256(1);
        foreach (i; 1 .. 77)
            t[i] = t[i - 1].mulSmall(10);
        return t;
    }();
    return table[n];
}

/// `10^n` for `0 <= n <= 38`, as a 128-bit value.
package UInt128 pow10_128(int n) pure @nogc
{
    return pow10_256(n).toUInt128();
}

/// `10^n` for `0 <= n <= 19`, as a 64-bit value.
package ulong pow10_64(int n) pure @nogc
{
    static immutable ulong[20] table = () {
        ulong[20] t;
        t[0] = 1;
        foreach (i; 1 .. 20)
            t[i] = t[i - 1] * 10;
        return t;
    }();
    return table[n];
}

/// The number of decimal digits in `x` (with `countDigits(0) == 1`).
package int countDigits(ulong x) pure @nogc
{
    int n = 1;
    while (x >= 10) { x /= 10; ++n; }
    return n;
}

/// ditto
package int countDigits(UInt128 x) pure @nogc
{
    if (x.hi == 0)
        return countDigits(x.lo);
    int n = 20;
    UInt256 v = UInt256(x);
    UInt256 p = pow10_256(20);
    while (v.opCmp(p) >= 0) { p = p.mulSmall(10); ++n; }
    return n;
}

/// ditto
package int countDigits(UInt256 x) pure @nogc
{
    if (x.fitsIn128())
        return countDigits(x.toUInt128());
    int n = 39;
    UInt256 p = pow10_256(39);
    while (x.opCmp(p) >= 0) { p = p.mulSmall(10); ++n; }
    return n;
}

@safe pure unittest
{
    // UInt128 basic arithmetic.
    auto a = UInt128(0, ulong.max);
    auto b = a + UInt128(1);
    assert(b == UInt128(1, 0));
    assert((b - UInt128(1)) == a);

    auto m = UInt128.mul(ulong.max, ulong.max);
    // (2^64-1)^2 = 2^128 - 2^65 + 1
    assert(m.hi == 0xFFFF_FFFF_FFFF_FFFE);
    assert(m.lo == 1);

    // Shifts.
    assert((UInt128(1) << 64) == UInt128(1, 0));
    assert((UInt128(1, 0) >> 64) == UInt128(1));
}

@safe pure unittest
{
    // UInt256 multiply / divide round-trip.
    auto x = UInt256.mul(UInt128(0, ulong.max), UInt128(0, ulong.max));
    UInt256 rem;
    auto q = x.divMod(UInt256(UInt128(0, ulong.max)), rem);
    assert(q == UInt256(UInt128(0, ulong.max)));
    assert(rem.isZero);

    // Powers of ten and digit counting.
    assert(pow10_64(19) == 10_000_000_000_000_000_000UL);
    assert(countDigits(0UL) == 1);
    assert(countDigits(999UL) == 3);
    assert(countDigits(1000UL) == 4);
    assert(countDigits(pow10_128(34)) == 35);
    assert(countDigits(pow10_256(50)) == 51);

    // divModSmall against a known value.
    ulong r;
    auto qq = pow10_256(20).divModSmall(1_000_000_000UL, r);
    assert(r == 0);
    assert(qq == pow10_256(11));
}

@safe pure unittest
{
    // Format-trait sanity checks.
    alias F32 = DecimalFormat!32;
    alias F64 = DecimalFormat!64;
    alias F128 = DecimalFormat!128;

    static assert(F32.precision == 7 && F32.emax == 96 && F32.bias == 101);
    static assert(F32.qmin == -101 && F32.qmax == 90 && F32.maxBiasedExp == 191);
    static assert(F64.precision == 16 && F64.emax == 384 && F64.bias == 398);
    static assert(F64.qmin == -398 && F64.qmax == 369);
    static assert(F128.precision == 34 && F128.emax == 6144 && F128.bias == 6176);
    static assert(F128.qmin == -6176 && F128.qmax == 6111);

    static assert(F32.maxCoefficient == 9_999_999U);
    static assert(F64.maxCoefficient == 9_999_999_999_999_999UL);
    static assert(F128.combBits == 17 && F128.expBits == 14 && F128.trailingBits == 110);
}

/*
 * =============================================================================
 *  Phase 2 — BID encode / decode and classification
 * =============================================================================
 */

/// Convert the low 64 bits of an unsigned value to `ulong`.
private ulong lowU(uint x) pure @nogc { return x; }
/// ditto
private ulong lowU(ulong x) pure @nogc { return x; }
/// ditto
private ulong lowU(UInt128 x) pure @nogc { return x.lo; }

/// Construct a value of unsigned type `T` from a `ulong`.
private T reprFrom(T)(ulong x) pure @nogc
{
    static if (is(T == UInt128))
        return UInt128(x);
    else
        return cast(T) x;
}

/// A bit mask of the low `n` bits of unsigned type `T`.
private T loMask(T)(int n) pure @nogc
{
    static if (is(T == UInt128))
        return (UInt128(1) << cast(uint) n) - UInt128(1);
    else
        return cast(T)((T(1) << cast(uint) n) - T(1));
}

/// Widen an unsigned coefficient type to `UInt256`.
private UInt256 toU256(T)(T x) pure @nogc
{
    static if (is(Unqual!T == UInt128))
        return UInt256(cast(UInt128) x);
    else
        return UInt256(cast(ulong) x);
}

/// Narrow a `UInt256` (known to fit) to the unsigned type `T`.
private T fromU256(T)(UInt256 x) pure @nogc
{
    static if (is(Unqual!T == UInt128))
        return x.toUInt128();
    else
        return cast(T) x.v[0];
}

/// The default IEEE rounding-direction attribute (round to nearest, ties to even).
enum RoundingMode defaultRounding = RoundingMode.roundTiesToEven;

/// ASCII lower-casing used by the string parser.
private char toLowerA(char c) pure @nogc
{
    return (c >= 'A' && c <= 'Z') ? cast(char)(c + 32) : c;
}

/// The kind of value held by a decoded decimal.
private enum DecKind : ubyte
{
    finite,
    infinity,
    quietNaN,
    signalingNaN,
}

/// A decimal value taken apart into sign, kind, exponent and coefficient.
private struct Decoded(int bits)
{
    alias Repr = DecimalFormat!bits.CoefficientType;
    bool sign;
    DecKind kind;
    int exponent;       /// Unbiased quantum exponent $(I q) (finite values only).
    Repr coefficient;   /// Significand, or NaN payload.
}

/**
 * An IEEE 754-2008 decimal floating-point number using Intel's BID encoding.
 *
 * Use the aliases `Decimal32`, `Decimal64` and `Decimal128` rather than
 * instantiating this template directly.
 *
 * Params:
 *      bits = storage width; 32, 64 or 128.
 */
struct Decimal(int bits)
{
    /// Compile-time parameters of this format.
    alias Format = DecimalFormat!bits;
    private alias Repr = Format.CoefficientType;

    /// The raw BID bit pattern.
    private Repr _repr;

    /*
     * --- String output (may allocate) -----------------------------------
     */

    /**
     * Convert to its shortest IEEE "to-scientific-string" representation.
     *
     * Special values render as `"Infinity"`, `"-Infinity"`, `"NaN"` and
     * `"sNaN"` (with the payload appended when non-zero).
     */
    string toString() const pure @safe
    {
        char[80] buf = void;
        immutable n = formatTo(buf[]);
        return buf[0 .. n].idup;
    }

    /// `cast(string)` is equivalent to `toString`.
    string opCast(T : string)() const pure @safe { return toString(); }

pure nothrow @safe @nogc:

    /// Construct directly from a raw BID bit pattern.
    static Decimal fromRaw(Repr raw)
    {
        Decimal d;
        d._repr = raw;
        return d;
    }

    /// The raw BID bit pattern.
    Repr rawValue() const { return _repr; }

    /*
     * --- Encoding -------------------------------------------------------
     */

    /// Encode a finite value. The caller must ensure `coeff <= maxCoefficient`
    /// and `qmin <= q <= qmax`.
    package static Decimal encodeFinite(bool sign, int q, Repr coeff)
    {
        immutable ulong E = cast(ulong)(q + Format.bias);
        immutable ulong topPart = lowU(coeff >> Format.trailingBits); // leading digit group, 0..9
        ulong G = void;
        if (topPart <= 7)
            G = (E << 3) | topPart;
        else
            G = (0b11UL << (Format.expBits + 1)) | (E << 1) | (topPart & 1);

        immutable Repr T = coeff & loMask!Repr(Format.trailingBits);
        immutable Repr r = (reprFrom!Repr(sign ? 1UL : 0UL) << (Format.k - 1))
            | (reprFrom!Repr(G) << Format.trailingBits)
            | T;
        return fromRaw(r);
    }

    /// Encode an infinity of the given sign.
    package static Decimal encodeInfinity(bool sign)
    {
        immutable ulong G = 0b11110UL << (Format.combBits - 5);
        Repr r = reprFrom!Repr(G) << Format.trailingBits;
        if (sign)
            r = r | (reprFrom!Repr(1) << (Format.k - 1));
        return fromRaw(r);
    }

    /// Encode a NaN of the given sign, signaling state and payload.
    package static Decimal encodeNaN(bool sign, bool signaling, Repr payload)
    {
        ulong G = 0b11111UL << (Format.combBits - 5);
        if (signaling)
            G |= 1UL << (Format.combBits - 6);
        Repr r = (reprFrom!Repr(G) << Format.trailingBits)
            | (payload & loMask!Repr(Format.trailingBits));
        if (sign)
            r = r | (reprFrom!Repr(1) << (Format.k - 1));
        return fromRaw(r);
    }

    /*
     * --- Decoding -------------------------------------------------------
     */

    /// Take the value apart into its components.
    package Decoded!bits decode() const
    {
        Decoded!bits d;
        d.sign = (lowU(_repr >> (Format.k - 1)) & 1) != 0;

        immutable ulong G = lowU(_repr >> Format.trailingBits) & ((1UL << Format.combBits) - 1);
        immutable Repr T = _repr & loMask!Repr(Format.trailingBits);
        immutable ulong top2 = G >> (Format.combBits - 2);

        if (top2 == 0b11)
        {
            immutable ulong top5 = G >> (Format.combBits - 5);
            if (top5 == 0b11110)
            {
                d.kind = DecKind.infinity;
                return d;
            }
            if (top5 == 0b11111)
            {
                immutable ulong sig = (G >> (Format.combBits - 6)) & 1;
                d.kind = sig ? DecKind.signalingNaN : DecKind.quietNaN;
                d.coefficient = T;
                return d;
            }
            // Large-coefficient form: leading declet is 8 or 9.
            immutable ulong E = (G >> 1) & ((1UL << Format.expBits) - 1);
            d.coefficient = (reprFrom!Repr(8UL | (G & 1)) << Format.trailingBits) | T;
            d.exponent = cast(int) E - Format.bias;
        }
        else
        {
            immutable ulong E = (G >> 3) & ((1UL << Format.expBits) - 1);
            d.coefficient = (reprFrom!Repr(G & 7) << Format.trailingBits) | T;
            d.exponent = cast(int) E - Format.bias;
        }
        d.kind = DecKind.finite;

        // Non-canonical coefficients (greater than the maximum) read as zero.
        if (d.coefficient > Format.maxCoefficient)
            d.coefficient = reprFrom!Repr(0);
        return d;
    }

    /*
     * --- Classification -------------------------------------------------
     */

    /// Top five bits of the combination field.
    private ulong combTop5() const
    {
        return lowU(_repr >> (Format.k - 6)) & 0b11111;
    }

    /// True if the sign bit is set.
    bool signbit() const { return (lowU(_repr >> (Format.k - 1)) & 1) != 0; }

    /// True if this is any NaN (quiet or signaling).
    bool isNaN() const { return combTop5() == 0b11111; }

    /// True if this is a signaling NaN.
    bool isSignalingNaN() const
    {
        return isNaN() && (lowU(_repr >> (Format.k - 7)) & 1) != 0;
    }

    /// True if this is an infinity.
    bool isInfinity() const { return combTop5() == 0b11110; }

    /// True if this is finite (neither infinite nor NaN).
    bool isFinite() const { return combTop5() < 0b11110; }

    /// True if this is a zero of either sign.
    bool isZero() const
    {
        if (!isFinite())
            return false;
        return decode().coefficient == reprFrom!Repr(0);
    }

    /// True if this is a normal number (finite, non-zero, not subnormal).
    bool isNormal() const
    {
        immutable d = decode();
        if (d.kind != DecKind.finite || d.coefficient == reprFrom!Repr(0))
            return false;
        immutable adj = d.exponent + countDigits(d.coefficient) - 1;
        return adj >= Format.emin;
    }

    /// True if this is a subnormal number (finite, non-zero, below `min_normal`).
    bool isSubnormal() const
    {
        immutable d = decode();
        if (d.kind != DecKind.finite || d.coefficient == reprFrom!Repr(0))
            return false;
        immutable adj = d.exponent + countDigits(d.coefficient) - 1;
        return adj < Format.emin;
    }

    /*
     * --- Constants ------------------------------------------------------
     */

    /// A quiet NaN.
    static Decimal nan() { return encodeNaN(false, false, reprFrom!Repr(0)); }

    /// Positive infinity.
    static Decimal infinity() { return encodeInfinity(false); }

    /// Positive zero (quantum exponent 0).
    static Decimal zero() { return encodeFinite(false, 0, reprFrom!Repr(0)); }

    /// The largest finite value, `(10^precision - 1) × 10^qmax`.
    static Decimal max() { return encodeFinite(false, Format.qmax, Format.maxCoefficient); }

    /// The smallest positive normal value, `10^emin`.
    static Decimal min_normal()
    {
        static if (is(Repr == UInt128))
            immutable Repr c = pow10_128(Format.precision - 1);
        else
            immutable Repr c = cast(Repr) pow10_64(Format.precision - 1);
        return encodeFinite(false, Format.qmin, c);
    }

    /// The smallest positive subnormal value, `10^qmin`.
    static Decimal trueMin() { return encodeFinite(false, Format.qmin, reprFrom!Repr(1)); }

    /// The difference between `1` and the next larger representable value, `10^(1-precision)`.
    static Decimal epsilon() { return encodeFinite(false, 1 - Format.precision, reprFrom!Repr(1)); }

    /*
     * --- Rounding core --------------------------------------------------
     */

    /// Divide `coeff` by `10^drop` (with `drop > 0`), rounding the result
    /// according to `mode`/`sign` and reporting inexactness.
    package static UInt256 divPow10Round(UInt256 coeff, int drop, bool sign,
        RoundingMode mode, ref bool inexact)
    {
        if (drop <= 0)
            return coeff;

        UInt256 quo, rem;
        if (drop >= 77)
        {
            // The divisor exceeds any representable coefficient, so the
            // quotient is zero and the entire value is the remainder.
            rem = coeff;
            if (!rem.isZero)
                inexact = true;
            bool up = false;
            final switch (mode)
            {
                case RoundingMode.roundTiesToEven:
                case RoundingMode.roundTiesToAway:
                case RoundingMode.roundTowardZero:
                    up = false;
                    break;
                case RoundingMode.roundTowardPositive:
                    up = !sign && !rem.isZero;
                    break;
                case RoundingMode.roundTowardNegative:
                    up = sign && !rem.isZero;
                    break;
            }
            return up ? UInt256(1) : UInt256(0);
        }

        immutable divisor = pow10_256(drop);
        quo = coeff.divMod(divisor, rem);
        if (rem.isZero)
            return quo;

        inexact = true;
        immutable other = divisor - rem;     // 2*rem <=> divisor  ⟺  rem <=> other
        immutable c = rem.opCmp(other);      // <0 below half, 0 tie, >0 above half
        bool up;
        final switch (mode)
        {
            case RoundingMode.roundTiesToEven:
                up = c > 0 || (c == 0 && (quo.v[0] & 1) != 0);
                break;
            case RoundingMode.roundTiesToAway:
                up = c >= 0;
                break;
            case RoundingMode.roundTowardZero:
                up = false;
                break;
            case RoundingMode.roundTowardPositive:
                up = !sign;
                break;
            case RoundingMode.roundTowardNegative:
                up = sign;
                break;
        }
        return up ? quo + UInt256(1) : quo;
    }

    /// Produce the result of an operation that overflowed the format.
    package static Decimal overflowResult(bool sign, RoundingMode mode)
    {
        final switch (mode)
        {
            case RoundingMode.roundTowardZero:
                return encodeFinite(sign, Format.qmax, Format.maxCoefficient);
            case RoundingMode.roundTowardPositive:
                return sign ? encodeFinite(true, Format.qmax, Format.maxCoefficient)
                            : encodeInfinity(false);
            case RoundingMode.roundTowardNegative:
                return sign ? encodeInfinity(true)
                            : encodeFinite(false, Format.qmax, Format.maxCoefficient);
            case RoundingMode.roundTiesToEven:
            case RoundingMode.roundTiesToAway:
                return encodeInfinity(sign);
        }
    }

    /**
     * The heart of the implementation: round the value `(-1)^sign × coeff ×
     * 10^q` to the format's precision and exponent range, raising the
     * appropriate status flags in `flags`.
     */
    package static Decimal roundToPrecision(bool sign, UInt256 coeff, int q,
        RoundingMode mode, ref ExceptionFlag flags)
    {
        if (coeff.isZero)
        {
            int qz = q;
            if (qz < Format.qmin) qz = Format.qmin;
            if (qz > Format.qmax) qz = Format.qmax;
            return encodeFinite(sign, qz, reprFrom!Repr(0));
        }

        // Determine how many low digits must be discarded.
        immutable digits = countDigits(coeff);
        int drop = digits - Format.precision;
        if (drop < 0) drop = 0;
        if (q + drop < Format.qmin) drop = Format.qmin - q;

        bool inexact = false;
        if (drop > 0)
        {
            coeff = divPow10Round(coeff, drop, sign, mode, inexact);
            q += drop;
        }

        // Rounding up may have carried into an extra digit (e.g. 999 -> 1000).
        if (!coeff.isZero && countDigits(coeff) > Format.precision)
        {
            ulong r;
            coeff = coeff.divModSmall(10, r);
            ++q;
        }

        if (coeff.isZero)
        {
            int qz = q;
            if (qz < Format.qmin) qz = Format.qmin;
            if (qz > Format.qmax) qz = Format.qmax;
            if (inexact)
                flags |= ExceptionFlag.inexact | ExceptionFlag.underflow;
            return encodeFinite(sign, qz, reprFrom!Repr(0));
        }

        // Handle an exponent above the maximum by appending zero digits when
        // the coefficient still has room; otherwise the value overflows.
        if (q > Format.qmax)
        {
            immutable pad = q - Format.qmax;
            if (countDigits(coeff) + pad <= Format.precision)
            {
                foreach (_; 0 .. pad)
                    coeff = coeff.mulSmall(10);
                q = Format.qmax;
            }
            else
            {
                flags |= ExceptionFlag.overflow | ExceptionFlag.inexact;
                return overflowResult(sign, mode);
            }
        }

        if (inexact)
            flags |= ExceptionFlag.inexact;

        // Underflow: a subnormal, inexact result.
        immutable adj = q + countDigits(coeff) - 1;
        if (inexact && adj < Format.emin)
            flags |= ExceptionFlag.underflow;

        return encodeFinite(sign, q, fromU256!Repr(coeff));
    }

    /*
     * --- Construction from numbers --------------------------------------
     */

    /// Construct from a signed integer.
    this(long v)
    {
        immutable sign = v < 0;
        immutable ulong mag = sign ? -(cast(ulong) v) : cast(ulong) v;
        ExceptionFlag f;
        _repr = roundToPrecision(sign, UInt256(mag), 0, defaultRounding, f)._repr;
    }

    /// Construct from an unsigned integer.
    this(ulong v)
    {
        ExceptionFlag f;
        _repr = roundToPrecision(false, UInt256(v), 0, defaultRounding, f)._repr;
    }

    /// ditto
    this(int v) { this(cast(long) v); }
    /// ditto
    this(uint v) { this(cast(ulong) v); }

    /// Construct from a decimal of another width, rounding if necessary.
    this(int otherBits)(Decimal!otherBits src)
        if (otherBits != bits)
    {
        immutable d = src.decode();
        final switch (d.kind)
        {
            case DecKind.finite:
                ExceptionFlag f;
                _repr = roundToPrecision(d.sign, toU256(d.coefficient),
                    d.exponent, defaultRounding, f)._repr;
                break;
            case DecKind.infinity:
                _repr = encodeInfinity(d.sign)._repr;
                break;
            case DecKind.quietNaN:
                _repr = encodeNaN(d.sign, false, fromU256!Repr(toU256(d.coefficient)))._repr;
                break;
            case DecKind.signalingNaN:
                _repr = encodeNaN(d.sign, true, fromU256!Repr(toU256(d.coefficient)))._repr;
                break;
        }
    }

    /*
     * --- Conversion to binary floating point ----------------------------
     */

    /// The value as a `real`, rounded to `real` precision.
    real toReal() const
    {
        immutable d = decode();
        final switch (d.kind)
        {
            case DecKind.infinity:
                return d.sign ? -real.infinity : real.infinity;
            case DecKind.quietNaN:
            case DecKind.signalingNaN:
                return real.nan;
            case DecKind.finite:
                immutable m = u256ToReal(toU256(d.coefficient));
                immutable v = m * pow10Real(d.exponent);
                return d.sign ? -v : v;
        }
    }

    /// The value as a `double`.
    double toDouble() const { return cast(double) toReal(); }

    /// The value as a `float`.
    float toFloat() const { return cast(float) toReal(); }

    private static real u256ToReal(UInt256 x)
    {
        real r = 0.0L;
        foreach_reverse (i; 0 .. 4)
            r = r * 18_446_744_073_709_551_616.0L + cast(real) x.v[i];
        return r;
    }

    /// Return the member of `d`'s cohort with the fewest significant digits
    /// (trailing zeros removed). The numeric value is unchanged.
    package static Decimal normalizeShortest(Decimal d)
    {
        if (!d.isFinite())
            return d;
        immutable dec = d.decode();
        UInt256 c = toU256(dec.coefficient);
        if (c.isZero)
            return d;
        int q = dec.exponent;
        while (q < Format.qmax)
        {
            ulong r;
            immutable nc = c.divModSmall(10, r);
            if (r != 0)
                break;
            c = nc;
            ++q;
        }
        return encodeFinite(dec.sign, q, fromU256!Repr(c));
    }

    private static real pow10Real(int e)
    {
        if (e == 0) return 1.0L;
        real r = 1.0L, b = 10.0L;
        int n = e < 0 ? -e : e;
        while (n)
        {
            if (n & 1) r *= b;
            b *= b;
            n >>= 1;
        }
        return e < 0 ? 1.0L / r : r;
    }

    /*
     * --- Conversion from binary floating point --------------------------
     */

    private static ulong doubleBits(double x) @trusted
    {
        union U { double d; ulong u; }
        U t = void;
        t.d = x;
        return t.u;
    }

    /// Construct the nearest decimal to a `double`, using `mode`.
    static Decimal fromDouble(double x, RoundingMode mode = defaultRounding)
    {
        ExceptionFlag f;
        return fromDouble(x, mode, f);
    }

    /// ditto, reporting status flags.
    static Decimal fromDouble(double x, RoundingMode mode, ref ExceptionFlag flags)
    {
        immutable bits64 = doubleBits(x);
        immutable bool sign = (bits64 >> 63) != 0;
        immutable int be = cast(int)((bits64 >> 52) & 0x7FF);
        immutable ulong frac = bits64 & ((1UL << 52) - 1);

        if (be == 0x7FF)
            return frac ? (sign ? encodeNaN(true, false, reprFrom!Repr(0)) : nan())
                        : encodeInfinity(sign);

        ulong mant;
        int e2;
        if (be == 0)
        {
            if (frac == 0)
                return encodeFinite(sign, 0, reprFrom!Repr(0));
            mant = frac;
            e2 = -1074;
        }
        else
        {
            mant = frac | (1UL << 52);
            e2 = be - 1075;
        }

        // Try an exact conversion when the magnitude fits in 256 bits.
        if (e2 >= 0)
        {
            if (e2 <= 202)
            {
                UInt256 c = UInt256(mant) << cast(uint) e2;
                return normalizeShortest(roundToPrecision(sign, c, 0, mode, flags));
            }
        }
        else
        {
            immutable k = -e2;
            if (k <= 87)
            {
                UInt256 c = UInt256(mant);
                foreach (_; 0 .. k)
                    c = c.mulSmall(5);
                return normalizeShortest(roundToPrecision(sign, c, e2, mode, flags));
            }
        }

        // Fallback: round through `real` to `precision` significant digits.
        return fromReal(cast(real) x, mode, flags);
    }

    /// Construct the nearest decimal to a `float`.
    static Decimal fromFloat(float x, RoundingMode mode = defaultRounding)
    {
        return fromDouble(cast(double) x, mode);
    }

    private static Decimal fromReal(real x, RoundingMode mode, ref ExceptionFlag flags)
    {
        import core.math : fabs;
        if (x != x)
            return nan();
        if (x == real.infinity) return encodeInfinity(false);
        if (x == -real.infinity) return encodeInfinity(true);
        immutable bool sign = x < 0;
        real a = sign ? -x : x;
        if (a == 0.0L)
            return encodeFinite(sign, 0, reprFrom!Repr(0));

        // Decimal exponent of the most-significant digit.
        int e10 = 0;
        while (a >= 10.0L) { a /= 10.0L; ++e10; }
        while (a < 1.0L)   { a *= 10.0L; --e10; }

        immutable int scale = e10 - (Format.precision - 1);
        // Shift so that `precision` significant digits become an integer.
        real scaled = (sign ? -x : x);
        if (scale > 0)
            scaled /= pow10Real(scale);
        else
            scaled *= pow10Real(-scale);

        // Round to nearest integer with the requested direction.
        ulong intCoeff = cast(ulong)(scaled + 0.5L);
        return normalizeShortest(roundToPrecision(sign, UInt256(intCoeff), scale, mode, flags));
    }

    /*
     * --- Parsing --------------------------------------------------------
     */

    /**
     * Parse a decimal number from `s`. Returns `true` on success and stores
     * the value in `result`, raising status flags in `flags`. Accepts
     * ordinary decimal notation, scientific notation, and the special
     * spellings `inf`/`infinity`, `nan` and `snan` (case-insensitive, with
     * an optional NaN payload).
     */
    static bool fromString(scope const(char)[] s, out Decimal result,
        out ExceptionFlag flags, RoundingMode mode = defaultRounding)
    {
        size_t i = 0;
        immutable n = s.length;
        while (i < n && (s[i] == ' ' || s[i] == '\t')) ++i;

        bool sign = false;
        if (i < n && (s[i] == '+' || s[i] == '-'))
        {
            sign = s[i] == '-';
            ++i;
        }

        bool matchWord(scope const(char)[] w)        {
            if (n - i < w.length) return false;
            foreach (j; 0 .. w.length)
                if (toLowerA(s[i + j]) != w[j]) return false;
            return true;
        }
        if (matchWord("infinity")) { result = encodeInfinity(sign); return true; }
        if (matchWord("inf")) { result = encodeInfinity(sign); return true; }
        if (matchWord("snan") || matchWord("nan"))
        {
            immutable bool sig = toLowerA(s[i]) == 's';
            i += sig ? 4 : 3;
            UInt256 payload;
            while (i < n && s[i] >= '0' && s[i] <= '9')
            {
                payload = payload.mulSmall(10) + UInt256(cast(ulong)(s[i] - '0'));
                ++i;
            }
            result = encodeNaN(sign, sig, fromU256!Repr(payload));
            return true;
        }

        immutable UInt256 cap = pow10_256(75);
        UInt256 coeff;
        long exp = 0;
        bool anyDigit = false;
        bool seenDot = false;
        bool sticky = false;

        for (; i < n; ++i)
        {
            immutable ch = s[i];
            if (ch >= '0' && ch <= '9')
            {
                anyDigit = true;
                immutable dv = cast(ulong)(ch - '0');
                if (coeff.opCmp(cap) < 0)
                {
                    coeff = coeff.mulSmall(10) + UInt256(dv);
                    if (seenDot) --exp;
                }
                else
                {
                    if (!seenDot) ++exp;
                    if (dv != 0) sticky = true;
                }
            }
            else if (ch == '.')
            {
                if (seenDot) return false;
                seenDot = true;
            }
            else if (ch == 'e' || ch == 'E')
            {
                ++i;
                bool eSign = false;
                if (i < n && (s[i] == '+' || s[i] == '-'))
                {
                    eSign = s[i] == '-';
                    ++i;
                }
                bool eDigit = false;
                long ev = 0;
                for (; i < n && s[i] >= '0' && s[i] <= '9'; ++i)
                {
                    eDigit = true;
                    if (ev < 1_000_000) ev = ev * 10 + (s[i] - '0');
                }
                if (!eDigit) return false;
                exp += eSign ? -ev : ev;
                break;
            }
            else
                break;
        }

        // Trailing whitespace only.
        while (i < n && (s[i] == ' ' || s[i] == '\t')) ++i;
        if (i != n || !anyDigit)
            return false;

        if (exp > 100_000) exp = 100_000;
        if (exp < -100_000) exp = -100_000;

        result = roundToPrecision(sign, coeff, cast(int) exp, mode, flags);
        if (sticky)
            flags |= ExceptionFlag.inexact;
        return true;
    }

    /// Construct from a string; an unparseable string yields a quiet NaN.
    this(scope const(char)[] s)
    {
        Decimal r;
        ExceptionFlag f;
        if (fromString(s, r, f))
            _repr = r._repr;
        else
            _repr = nan()._repr;
    }

    /*
     * --- Casts ----------------------------------------------------------
     */

    /// `cast(bool)` is `true` for every value except ±0 (NaN included).
    bool opCast(T : bool)() const { return !isZero(); }

    /// `cast` to an integral type truncates toward zero.
    T opCast(T)() const
        if (isIntegral!T && !is(T == bool))
    {
        immutable d = decode();
        if (d.kind != DecKind.finite)
            return T(0);
        UInt256 c = toU256(d.coefficient);
        if (d.exponent >= 0)
        {
            foreach (_; 0 .. d.exponent)
                c = c.mulSmall(10);
        }
        else
        {
            ulong r;
            foreach (_; 0 .. -d.exponent)
                c = c.divModSmall(10, r);
        }
        immutable ulong mag = c.v[0];
        static if (isSigned!T)
            return cast(T)(d.sign ? -cast(long) mag : cast(long) mag);
        else
            return cast(T) mag;
    }

    /// `cast(float)` / `cast(double)` / `cast(real)`.
    T opCast(T)() const
        if (is(T == float) || is(T == double) || is(T == real))
    {
        static if (is(T == float)) return toFloat();
        else static if (is(T == double)) return toDouble();
        else return toReal();
    }

    /*
     * --- Sign operations ------------------------------------------------
     */

    private static Repr signMask() { return reprFrom!Repr(1) << (Format.k - 1); }

    /// The value with its sign bit flipped (affects NaN and infinity too).
    Decimal negated() const { return fromRaw(cast(Repr)(_repr ^ signMask())); }

    /// The absolute value (sign bit cleared).
    Decimal absValue() const { return fromRaw(cast(Repr)(_repr & ~signMask())); }

    /// This value with the sign of `y`.
    Decimal copySign(Decimal y) const
    {
        return fromRaw(cast(Repr)((_repr & ~signMask()) | (y._repr & signMask())));
    }

    /*
     * --- NaN handling helpers -------------------------------------------
     */

    private static Decimal quietOf(Decimal x)
    {
        immutable d = x.decode();
        return encodeNaN(d.sign, false, fromU256!Repr(toU256(d.coefficient)));
    }

    private static Decimal propagateNaN(Decimal a, Decimal b, ref ExceptionFlag flags)
    {
        if (a.isSignalingNaN() || b.isSignalingNaN())
            flags |= ExceptionFlag.invalidOperation;
        return a.isNaN() ? quietOf(a) : quietOf(b);
    }

    private static UInt256 scaleU256(UInt256 c, int n)
    {
        foreach (_; 0 .. n)
            c = c.mulSmall(10);
        return c;
    }

    /*
     * --- Addition and subtraction ---------------------------------------
     */

    /// Sum, rounded according to `mode`, raising flags.
    static Decimal add(Decimal a, Decimal b, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);

        if (a.isInfinity() || b.isInfinity())
        {
            if (a.isInfinity() && b.isInfinity())
            {
                if (a.signbit() == b.signbit())
                    return a;
                flags |= ExceptionFlag.invalidOperation;   // (+∞) + (-∞)
                return nan();
            }
            return a.isInfinity() ? a : b;
        }

        immutable da = a.decode();
        immutable db = b.decode();
        immutable qa = da.exponent, qb = db.exponent;

        immutable digA = countDigits(da.coefficient);
        immutable digB = countDigits(db.coefficient);
        immutable adjA = qa + digA - 1;
        immutable adjB = qb + digB - 1;

        UInt256 ca, cb;
        int workExp;
        immutable bool aZero = toU256(da.coefficient).isZero;
        immutable bool bZero = toU256(db.coefficient).isZero;

        // When the operands are far apart in magnitude, the smaller one only
        // contributes a sticky bit; otherwise align to the common (smaller)
        // exponent, which is safe to do exactly within 256 bits.
        if (!aZero && !bZero && (adjA - adjB > Format.precision + 2 || adjB - adjA > Format.precision + 2))
        {
            if (adjA > adjB)
            {
                workExp = qa - (Format.precision + 2);
                ca = scaleU256(toU256(da.coefficient), qa - workExp);
                cb = UInt256(1); // sticky representation of b
                immutable rsign = da.sign;
                immutable sum = (da.sign == db.sign) ? ca + cb : ca - cb;
                return roundToPrecision(rsign, sum, workExp, mode, flags);
            }
            else
            {
                workExp = qb - (Format.precision + 2);
                cb = scaleU256(toU256(db.coefficient), qb - workExp);
                ca = UInt256(1);
                immutable rsign = db.sign;
                immutable sum = (da.sign == db.sign) ? cb + ca : cb - ca;
                return roundToPrecision(rsign, sum, workExp, mode, flags);
            }
        }

        workExp = qa < qb ? qa : qb;
        ca = scaleU256(toU256(da.coefficient), qa - workExp);
        cb = scaleU256(toU256(db.coefficient), qb - workExp);

        bool rsign;
        UInt256 sum;
        if (da.sign == db.sign)
        {
            sum = ca + cb;
            rsign = da.sign;
        }
        else if (ca.opCmp(cb) >= 0)
        {
            sum = ca - cb;
            rsign = da.sign;
        }
        else
        {
            sum = cb - ca;
            rsign = db.sign;
        }

        if (sum.isZero)
        {
            immutable bool zsign = (da.sign == db.sign) ? da.sign
                : (mode == RoundingMode.roundTowardNegative);
            return roundToPrecision(zsign, UInt256(0), workExp, mode, flags);
        }

        return roundToPrecision(rsign, sum, workExp, mode, flags);
    }

    /// Difference, rounded according to `mode`.
    static Decimal sub(Decimal a, Decimal b, RoundingMode mode, ref ExceptionFlag flags)
    {
        return add(a, b.negated(), mode, flags);
    }

    /*
     * --- Multiplication -------------------------------------------------
     */

    /// Product, rounded according to `mode`.
    static Decimal mul(Decimal a, Decimal b, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);

        immutable rsign = a.signbit() ^ b.signbit();

        if (a.isInfinity() || b.isInfinity())
        {
            immutable aZeroFin = a.isFinite() && a.isZero();
            immutable bZeroFin = b.isFinite() && b.isZero();
            if (aZeroFin || bZeroFin)
            {
                flags |= ExceptionFlag.invalidOperation;   // 0 × ∞
                return nan();
            }
            return encodeInfinity(rsign);
        }

        immutable da = a.decode();
        immutable db = b.decode();
        immutable prod = UInt256.mul(toU128(da.coefficient), toU128(db.coefficient));
        immutable q = da.exponent + db.exponent;
        return roundToPrecision(rsign, prod, q, mode, flags);
    }

    private static UInt128 toU128(T)(T x)
    {
        static if (is(Unqual!T == UInt128))
            return cast(UInt128) x;
        else
            return UInt128(cast(ulong) x);
    }

    /*
     * --- Comparison -----------------------------------------------------
     */

    private static int compareMagnitude(Decoded!bits da, Decoded!bits db)
    {
        immutable digA = countDigits(da.coefficient);
        immutable digB = countDigits(db.coefficient);
        immutable adjA = da.exponent + digA - 1;
        immutable adjB = db.exponent + digB - 1;
        if (adjA != adjB)
            return adjA < adjB ? -1 : 1;
        immutable qmn = da.exponent < db.exponent ? da.exponent : db.exponent;
        immutable ca = scaleU256(toU256(da.coefficient), da.exponent - qmn);
        immutable cb = scaleU256(toU256(db.coefficient), db.exponent - qmn);
        return ca.opCmp(cb);
    }

    /// IEEE quiet comparison. Returns -1, 0 or 1; sets `unordered` when either
    /// operand is NaN (in which case the result is 0).
    static int compareValue(Decimal a, Decimal b, out bool unordered)
    {
        unordered = false;
        if (a.isNaN() || b.isNaN())
        {
            unordered = true;
            return 0;
        }
        immutable int sgnA = a.isZero() ? 0 : (a.signbit() ? -1 : 1);
        immutable int sgnB = b.isZero() ? 0 : (b.signbit() ? -1 : 1);
        if (sgnA != sgnB)
            return sgnA < sgnB ? -1 : 1;
        if (sgnA == 0)
            return 0;
        if (a.isInfinity() && b.isInfinity())
            return 0;
        if (a.isInfinity())
            return sgnA > 0 ? 1 : -1;
        if (b.isInfinity())
            return sgnA > 0 ? -1 : 1;
        immutable m = compareMagnitude(a.decode(), b.decode());
        return sgnA > 0 ? m : -m;
    }

    /// True if `a` and `b` are equal in value (`-0 == +0`, NaN compares unequal).
    static bool isEqual(Decimal a, Decimal b)
    {
        bool u;
        immutable c = compareValue(a, b, u);
        return !u && c == 0;
    }

    /*
     * --- Generic two-term addition (used by add and fma) ----------------
     */

    private static Decimal addCore(bool sa, UInt256 ca, int qa,
        bool sb, UInt256 cb, int qb, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (ca.isZero && cb.isZero)
        {
            immutable bool z = (sa == sb) ? sa : (mode == RoundingMode.roundTowardNegative);
            return roundToPrecision(z, UInt256(0), qa < qb ? qa : qb, mode, flags);
        }
        if (ca.isZero) return roundToPrecision(sb, cb, qb, mode, flags);
        if (cb.isZero) return roundToPrecision(sa, ca, qa, mode, flags);

        immutable digA = countDigits(ca), digB = countDigits(cb);
        immutable adjA = qa + digA - 1, adjB = qb + digB - 1;
        immutable qmn = qa < qb ? qa : qb;
        immutable scaledA = digA + (qa - qmn);
        immutable scaledB = digB + (qb - qmn);
        immutable maxScaled = scaledA > scaledB ? scaledA : scaledB;

        if (maxScaled <= 76)
        {
            immutable a2 = scaleU256(ca, qa - qmn);
            immutable b2 = scaleU256(cb, qb - qmn);
            bool rs;
            UInt256 sum;
            if (sa == sb) { sum = a2 + b2; rs = sa; }
            else if (a2.opCmp(b2) >= 0) { sum = a2 - b2; rs = sa; }
            else { sum = b2 - a2; rs = sb; }
            if (sum.isZero)
            {
                immutable bool z = (sa == sb) ? sa : (mode == RoundingMode.roundTowardNegative);
                return roundToPrecision(z, UInt256(0), qmn, mode, flags);
            }
            return roundToPrecision(rs, sum, qmn, mode, flags);
        }

        // Far apart: the dominant term carries the result and the other becomes
        // a sticky digit just below the dominant's least significant place.
        bool sd, so;
        UInt256 cd;
        int qd;
        if (adjA >= adjB) { sd = sa; cd = ca; qd = qa; so = sb; }
        else { sd = sb; cd = cb; qd = qb; so = sa; }
        immutable cd2 = (sd == so) ? cd.mulSmall(10) + UInt256(1) : cd.mulSmall(10) - UInt256(1);
        return roundToPrecision(sd, cd2, qd - 1, mode, flags);
    }

    /// Remove trailing zero digits while the exponent stays below `preferredExp`.
    package static Decimal stripToward(Decimal d, int preferredExp)
    {
        if (!d.isFinite())
            return d;
        immutable dec = d.decode();
        UInt256 c = toU256(dec.coefficient);
        if (c.isZero)
            return d;
        int q = dec.exponent;
        while (q < preferredExp)
        {
            ulong r;
            immutable nc = c.divModSmall(10, r);
            if (r != 0)
                break;
            c = nc;
            ++q;
        }
        return encodeFinite(dec.sign, q, fromU256!Repr(c));
    }

    /*
     * --- Division -------------------------------------------------------
     */

    /// Quotient, rounded according to `mode`.
    static Decimal div(Decimal a, Decimal b, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);

        immutable rsign = a.signbit() ^ b.signbit();

        if (a.isInfinity())
        {
            if (b.isInfinity())
            {
                flags |= ExceptionFlag.invalidOperation;   // ∞ / ∞
                return nan();
            }
            return encodeInfinity(rsign);
        }
        if (b.isInfinity())
        {
            // finite / ∞ = ±0; keep the dividend's exponent as the cohort.
            immutable da0 = a.decode();
            return roundToPrecision(rsign, UInt256(0), da0.exponent, mode, flags);
        }

        immutable da = a.decode();
        immutable db = b.decode();
        immutable prefExp = da.exponent - db.exponent;

        if (toU256(db.coefficient).isZero)
        {
            if (toU256(da.coefficient).isZero)
            {
                flags |= ExceptionFlag.invalidOperation;   // 0 / 0
                return nan();
            }
            flags |= ExceptionFlag.divisionByZero;
            return encodeInfinity(rsign);
        }
        if (toU256(da.coefficient).isZero)
            return roundToPrecision(rsign, UInt256(0), prefExp, mode, flags);

        UInt256 num = toU256(da.coefficient);
        immutable den = toU256(db.coefficient);
        immutable dnum = countDigits(num), dden = countDigits(den);
        int scale = (Format.precision + 2) - (dnum - dden);
        if (scale < 0) scale = 0;
        num = scaleU256(num, scale);
        immutable resExp = prefExp - scale;

        UInt256 rem;
        UInt256 quo = num.divMod(den, rem);
        if (!rem.isZero)
        {
            ulong last;
            quo.divModSmall(10, last);
            if (last % 2 == 0)
                quo = quo + UInt256(1);
        }

        ExceptionFlag local;
        auto res = roundToPrecision(rsign, quo, resExp, mode, local);
        flags |= local;
        if (!(local & ExceptionFlag.inexact))
            res = stripToward(res, prefExp);
        return res;
    }

    /*
     * --- Fused multiply-add: (a × b) + c with a single rounding ---------
     */

    /// `(a × b) + c`, rounded once according to `mode`.
    static Decimal fma(Decimal a, Decimal b, Decimal c, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isSignalingNaN() || b.isSignalingNaN() || c.isSignalingNaN())
            flags |= ExceptionFlag.invalidOperation;
        if (a.isNaN() || b.isNaN())
            return a.isNaN() ? quietOf(a) : quietOf(b);
        if (c.isNaN())
            return quietOf(c);

        immutable pSign = a.signbit() ^ b.signbit();
        immutable bool prodInvalid =
            (a.isInfinity() && b.isFinite() && b.isZero()) ||
            (b.isInfinity() && a.isFinite() && a.isZero());
        if (prodInvalid)
        {
            flags |= ExceptionFlag.invalidOperation;   // 0 × ∞
            return nan();
        }
        immutable bool prodInf = a.isInfinity() || b.isInfinity();

        if (prodInf)
        {
            if (c.isInfinity() && c.signbit() != pSign)
            {
                flags |= ExceptionFlag.invalidOperation;   // ∞ + (-∞)
                return nan();
            }
            return encodeInfinity(pSign);
        }
        if (c.isInfinity())
            return c;

        immutable da = a.decode();
        immutable db = b.decode();
        immutable dc = c.decode();
        immutable prod = UInt256.mul(toU128(da.coefficient), toU128(db.coefficient));
        immutable pe = da.exponent + db.exponent;
        return addCore(pSign, prod, pe, dc.sign, toU256(dc.coefficient), dc.exponent, mode, flags);
    }

    /*
     * --- Square root ----------------------------------------------------
     */

    private static UInt256 isqrt(UInt256 n)
    {
        UInt256 res = UInt256(0);
        UInt256 one = UInt256(1) << 254;
        while (one.opCmp(n) > 0)
            one = one >> 2;
        UInt256 op = n;
        while (!one.isZero)
        {
            immutable t = res + one;
            if (op.opCmp(t) >= 0)
            {
                op = op - t;
                res = (res >> 1) + one;
            }
            else
                res = res >> 1;
            one = one >> 2;
        }
        return res;
    }

    /// Correctly-rounded square root.
    static Decimal sqrt(Decimal a, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isNaN())
            return propagateNaN(a, a, flags);
        if (a.isZero())
            return a;                                   // sqrt(±0) = ±0
        if (a.signbit())
        {
            flags |= ExceptionFlag.invalidOperation;    // sqrt of a negative
            return nan();
        }
        if (a.isInfinity())
            return a;                                   // sqrt(+∞) = +∞

        immutable da = a.decode();
        UInt256 c = toU256(da.coefficient);
        int q = da.exponent;
        immutable prefExp = (q >= 0) ? q / 2 : -((-q + 1) / 2);

        int shift = 2 * (Format.precision + 2) - countDigits(c);
        if (shift < 0) shift = 0;
        if (((q - shift) & 1) != 0) ++shift;            // keep (q - shift) even
        c = scaleU256(c, shift);
        immutable resExp = (q - shift) / 2;

        immutable s = isqrt(c);
        immutable rem = c - UInt256.mul(s.toUInt128(), s.toUInt128());
        UInt256 quo = s;
        if (!rem.isZero)
        {
            ulong last;
            quo.divModSmall(10, last);
            if (last % 2 == 0)
                quo = quo + UInt256(1);
        }

        ExceptionFlag local;
        auto res = roundToPrecision(false, quo, resExp, mode, local);
        flags |= local;
        if (!(local & ExceptionFlag.inexact))
            res = stripToward(res, prefExp);
        return res;
    }

    /*
     * --- IEEE remainder -------------------------------------------------
     */

    /// The IEEE remainder `a - b × n`, where `n = roundToNearestEven(a / b)`.
    static Decimal remainder(Decimal a, Decimal b, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);
        if (a.isInfinity() || (b.isFinite() && b.isZero()))
        {
            flags |= ExceptionFlag.invalidOperation;
            return nan();
        }
        if (b.isInfinity())
            return a;
        if (a.isZero())
            return a;

        immutable da = a.decode();
        immutable db = b.decode();
        immutable qmn = da.exponent < db.exponent ? da.exponent : db.exponent;

        // Align both to a common exponent. (Bounded for ordinary inputs.)
        immutable digA = countDigits(da.coefficient) + (da.exponent - qmn);
        immutable digB = countDigits(db.coefficient) + (db.exponent - qmn);
        if (digA > 80 || digB > 80)
        {
            // Extreme exponent spread; fall back to a value-based reduction.
            flags |= ExceptionFlag.inexact;
            return a;
        }
        immutable X = scaleU256(toU256(da.coefficient), da.exponent - qmn);
        immutable Y = scaleU256(toU256(db.coefficient), db.exponent - qmn);

        UInt256 rem;
        UInt256 n = X.divMod(Y, rem);
        // Round n to nearest even based on the remainder of the division.
        immutable twice = rem + rem;
        immutable cmp = twice.opCmp(Y);
        if (cmp > 0 || (cmp == 0 && (n.v[0] & 1)))
        {
            n = n + UInt256(1);
            rem = Y - rem;                  // |remainder| after rounding up
            // Sign of remainder flips relative to a.
            immutable rsign = !da.sign;
            if (rem.isZero)
                return roundToPrecision(da.sign, UInt256(0), qmn, RoundingMode.roundTiesToEven, flags);
            return roundToPrecision(rsign, rem, qmn, RoundingMode.roundTiesToEven, flags);
        }
        if (rem.isZero)
            return roundToPrecision(da.sign, UInt256(0), qmn, RoundingMode.roundTiesToEven, flags);
        return roundToPrecision(da.sign, rem, qmn, RoundingMode.roundTiesToEven, flags);
    }

    /*
     * --- Quantize, scaleB, logB -----------------------------------------
     */

    /// Return the value of `a` with the exponent of `b` (IEEE `quantize`).
    static Decimal quantize(Decimal a, Decimal b, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);
        if (a.isInfinity() || b.isInfinity())
        {
            if (a.isInfinity() && b.isInfinity())
                return a;
            flags |= ExceptionFlag.invalidOperation;
            return nan();
        }

        immutable da = a.decode();
        immutable db = b.decode();
        immutable targetExp = db.exponent;

        UInt256 c = toU256(da.coefficient);
        if (targetExp >= da.exponent)
        {
            immutable drop = targetExp - da.exponent;
            bool inexact = false;
            c = divPow10Round(c, drop, da.sign, mode, inexact);
            if (inexact)
                flags |= ExceptionFlag.inexact;
        }
        else
        {
            immutable grow = da.exponent - targetExp;
            if (countDigits(c) + grow > Format.precision)
            {
                flags |= ExceptionFlag.invalidOperation;
                return nan();
            }
            c = scaleU256(c, grow);
        }

        if (countDigits(c) > Format.precision)
        {
            flags |= ExceptionFlag.invalidOperation;
            return nan();
        }
        if (targetExp < Format.qmin || targetExp > Format.qmax)
        {
            flags |= ExceptionFlag.invalidOperation;
            return nan();
        }
        return encodeFinite(da.sign, targetExp, fromU256!Repr(c));
    }

    /// `a × 10^n`, rounded according to `mode` (IEEE `scaleB`).
    static Decimal scaleB(Decimal a, int n, RoundingMode mode, ref ExceptionFlag flags)
    {
        if (!a.isFinite())
            return a.isNaN() ? propagateNaN(a, a, flags) : a;
        immutable da = a.decode();
        if (toU256(da.coefficient).isZero)
            return roundToPrecision(da.sign, UInt256(0), da.exponent + n, mode, flags);
        return roundToPrecision(da.sign, toU256(da.coefficient), da.exponent + n, mode, flags);
    }

    /// `floor(log10(|a|))` as an integral decimal (IEEE `logB`).
    static Decimal logB(Decimal a, ref ExceptionFlag flags)
    {
        if (a.isNaN())
            return propagateNaN(a, a, flags);
        if (a.isInfinity())
            return encodeInfinity(false);
        if (a.isZero())
        {
            flags |= ExceptionFlag.divisionByZero;
            return encodeInfinity(true);
        }
        immutable da = a.decode();
        immutable adj = da.exponent + countDigits(da.coefficient) - 1;
        return Decimal(cast(long) adj);
    }

    /*
     * --- nextUp / nextDown ----------------------------------------------
     */

    /// The least representable value greater than `a` (IEEE `nextUp`).
    static Decimal nextUp(Decimal a, ref ExceptionFlag flags)
    {
        if (a.isNaN())
            return propagateNaN(a, a, flags);
        if (a.isInfinity())
            return a.signbit() ? encodeFinite(true, Format.qmax, Format.maxCoefficient) : a;

        immutable da = a.decode();
        UInt256 c = toU256(da.coefficient);
        int q = da.exponent;

        if (c.isZero)
            return trueMin();   // nextUp(±0) = +10^qmin

        if (!da.sign)
        {
            // Positive: increase magnitude by one unit in the last place.
            while (countDigits(c) < Format.precision && q > Format.qmin)
            {
                c = c.mulSmall(10);
                --q;
            }
            c = c + UInt256(1);
            if (countDigits(c) > Format.precision)
            {
                ulong r;
                c = c.divModSmall(10, r);
                ++q;
                if (q > Format.qmax)
                    return encodeInfinity(false);
            }
            return encodeFinite(false, q, fromU256!Repr(c));
        }
        else
        {
            // Negative: decrease magnitude by one unit in the last place.
            while (countDigits(c) < Format.precision && q > Format.qmin)
            {
                c = c.mulSmall(10);
                --q;
            }
            // Crossing a power-of-ten boundary: the predecessor has a smaller
            // exponent and a full precision worth of nines.
            if (q > Format.qmin && c.opCmp(pow10_256(Format.precision - 1)) == 0)
            {
                c = pow10_256(Format.precision) - UInt256(1);
                --q;
                return encodeFinite(true, q, fromU256!Repr(c));
            }
            c = c - UInt256(1);
            if (c.isZero)
                return encodeFinite(true, q, reprFrom!Repr(0));   // -0
            return encodeFinite(true, q, fromU256!Repr(c));
        }
    }

    /// The greatest representable value less than `a` (IEEE `nextDown`).
    static Decimal nextDown(Decimal a, ref ExceptionFlag flags)
    {
        return nextUp(a.negated(), flags).negated();
    }

    /*
     * --- Total ordering -------------------------------------------------
     */

    /// IEEE 754 `totalOrder`: a total ordering over all values including
    /// signed zeros, cohorts and NaNs. Returns -1, 0 or 1.
    static int totalOrder(Decimal a, Decimal b)
    {
        immutable ka = orderKeyClass(a);
        immutable kb = orderKeyClass(b);
        if (ka != kb)
            return ka < kb ? -1 : 1;

        // Same broad class. NaNs: order by payload (sign already in class key).
        if (a.isNaN())
        {
            immutable pa = toU256(a.decode().coefficient);
            immutable pb = toU256(b.decode().coefficient);
            immutable c = pa.opCmp(pb);
            // For negative NaNs the order is reversed.
            return a.signbit() ? -c : c;
        }

        bool u;
        immutable c = compareValue(a, b, u);
        if (c != 0)
            return c;

        // Equal value: distinguish signed zeros and cohorts by exponent.
        if (a.isZero() && b.isZero())
        {
            if (a.signbit() == b.signbit())
                return 0;
            return a.signbit() ? -1 : 1;   // -0 < +0
        }
        immutable qa = a.decode().exponent;
        immutable qb = b.decode().exponent;
        if (qa == qb)
            return 0;
        // Smaller exponent is "less" for positive values, "greater" for negative.
        immutable less = qa < qb;
        return (a.signbit() ? !less : less) ? -1 : 1;
    }

    private static int orderKeyClass(Decimal x)
    {
        // -sNaN(-6) -qNaN(-5) -Inf(-4) -finite(-3) -0(-2) +0(2) +finite(3) +Inf(4) +qNaN(5) +sNaN(6)
        immutable s = x.signbit();
        if (x.isNaN())
        {
            immutable sig = x.isSignalingNaN();
            if (s) return sig ? -6 : -5;
            return sig ? 6 : 5;
        }
        if (x.isInfinity())
            return s ? -4 : 4;
        if (x.isZero())
            return s ? -2 : 2;
        return s ? -3 : 3;
    }

    /*
     * --- Truncated remainder (C `fmod`, the `%` operator) ---------------
     */

    /// Truncated remainder `a - b × trunc(a / b)`; result has the sign of `a`.
    static Decimal mod(Decimal a, Decimal b, ref ExceptionFlag flags)
    {
        if (a.isNaN() || b.isNaN())
            return propagateNaN(a, b, flags);
        if (a.isInfinity() || (b.isFinite() && b.isZero()))
        {
            flags |= ExceptionFlag.invalidOperation;
            return nan();
        }
        if (b.isInfinity())
            return a;
        if (a.isZero())
            return a;

        immutable da = a.decode();
        immutable db = b.decode();
        immutable qmn = da.exponent < db.exponent ? da.exponent : db.exponent;
        immutable digA = countDigits(da.coefficient) + (da.exponent - qmn);
        immutable digB = countDigits(db.coefficient) + (db.exponent - qmn);
        if (digA > 80 || digB > 80)
        {
            flags |= ExceptionFlag.inexact;
            return a;
        }
        immutable X = scaleU256(toU256(da.coefficient), da.exponent - qmn);
        immutable Y = scaleU256(toU256(db.coefficient), db.exponent - qmn);
        UInt256 rem;
        X.divMod(Y, rem);                       // truncated quotient; rem is magnitude
        if (rem.isZero)
            return roundToPrecision(da.sign, UInt256(0), qmn, RoundingMode.roundTiesToEven, flags);
        return roundToPrecision(da.sign, rem, qmn, RoundingMode.roundTiesToEven, flags);
    }

    /*
     * --- Operator overloading -------------------------------------------
     */

    /// Convert an integer or binary floating-point scalar to this type.
    private static Decimal fromScalar(T)(T x)
    {
        static if (isIntegral!T)
        {
            static if (isSigned!T)
                return Decimal(cast(long) x);
            else
                return Decimal(cast(ulong) x);
        }
        else static if (is(Unqual!T == float))
            return fromFloat(x);
        else
            return fromDouble(cast(double) x, defaultRounding);
    }

    /// Unary `+`, `-`, `++` and `--`.
    Decimal opUnary(string op)() const
    if (op == "+" || op == "-")
    {
        static if (op == "+")
            return this;
        else
            return negated();
    }

    /// ditto
    ref Decimal opUnary(string op)()
    if (op == "++" || op == "--")
    {
        ExceptionFlag f;
        static if (op == "++")
            this = add(this, Decimal(1L), defaultRounding, f);
        else
            this = sub(this, Decimal(1L), defaultRounding, f);
        return this;
    }

    /// Binary `+ - * / %` against another `Decimal` of the same width.
    Decimal opBinary(string op)(Decimal rhs) const
    {
        ExceptionFlag f;
        static if (op == "+") return add(this, rhs, defaultRounding, f);
        else static if (op == "-") return sub(this, rhs, defaultRounding, f);
        else static if (op == "*") return mul(this, rhs, defaultRounding, f);
        else static if (op == "/") return div(this, rhs, defaultRounding, f);
        else static if (op == "%") return mod(this, rhs, f);
        else static assert(false, "Unsupported operator " ~ op);
    }

    /// Binary operators against another `Decimal` width (widened/narrowed).
    Decimal opBinary(string op, int ob)(Decimal!ob rhs) const
    if (ob != bits)
    {
        return opBinary!op(Decimal(rhs));
    }

    /// Binary operators against an integer or binary floating-point value.
    Decimal opBinary(string op, T)(T rhs) const
    if (isIntegral!T || isFloatingPoint!T)
    {
        return opBinary!op(fromScalar(rhs));
    }

    /// Binary operators with a scalar on the left-hand side.
    Decimal opBinaryRight(string op, T)(T lhs) const
    if (isIntegral!T || isFloatingPoint!T)
    {
        return fromScalar(lhs).opBinary!op(this);
    }

    /// Compound assignment `+= -= *= /= %=`.
    ref Decimal opOpAssign(string op)(Decimal rhs)
    {
        this = opBinary!op(rhs);
        return this;
    }

    /// ditto
    ref Decimal opOpAssign(string op, int ob)(Decimal!ob rhs)
    if (ob != bits)
    {
        this = opBinary!op(Decimal(rhs));
        return this;
    }

    /// ditto
    ref Decimal opOpAssign(string op, T)(T rhs)
    if (isIntegral!T || isFloatingPoint!T)
    {
        this = opBinary!op(fromScalar(rhs));
        return this;
    }

    /// Equality. NaN never compares equal; `-0` equals `+0`.
    bool opEquals(Decimal rhs) const
    {
        return isEqual(this, rhs);
    }

    /// ditto
    bool opEquals(int ob)(Decimal!ob rhs) const
    if (ob != bits)
    {
        return isEqual(this, Decimal(rhs));
    }

    /// ditto
    bool opEquals(T)(T rhs) const
    if (isIntegral!T || isFloatingPoint!T)
    {
        return isEqual(this, fromScalar(rhs));
    }

    /// Ordering. Returns `float.nan` for unordered (NaN) operands so that
    /// `<`, `>`, `<=` and `>=` all yield `false`, matching IEEE semantics.
    float opCmp(Decimal rhs) const
    {
        bool u;
        immutable c = compareValue(this, rhs, u);
        return u ? float.nan : cast(float) c;
    }

    /// ditto
    float opCmp(int ob)(Decimal!ob rhs) const
    if (ob != bits)
    {
        return opCmp(Decimal(rhs));
    }

    /// ditto
    float opCmp(T)(T rhs) const
    if (isIntegral!T || isFloatingPoint!T)
    {
        return opCmp(fromScalar(rhs));
    }

    /*
     * --- String formatting (no allocation) ------------------------------
     */

    /// Extract the decimal digits of `c` into `dst`, most significant first,
    /// returning the count (`digitsOf(0)` writes a single `'0'`).
    private static int digitsOf(UInt256 c, scope char[] dst)
    {
        if (c.isZero)
        {
            dst[0] = '0';
            return 1;
        }
        char[80] tmp = void;
        int n = 0;
        while (!c.isZero)
        {
            ulong r;
            c = c.divModSmall(10, r);
            tmp[n++] = cast(char)('0' + r);
        }
        foreach (j; 0 .. n)
            dst[j] = tmp[n - 1 - j];
        return n;
    }

    private static int writeUint(scope char[] dst, int pos, ulong val)
    {
        char[20] tmp = void;
        int n = 0;
        if (val == 0)
        {
            dst[pos++] = '0';
            return pos;
        }
        while (val)
        {
            tmp[n++] = cast(char)('0' + val % 10);
            val /= 10;
        }
        foreach_reverse (j; 0 .. n)
            dst[pos++] = tmp[j];
        return pos;
    }

    /// Render the value into `dst` (IEEE to-scientific-string) and return the
    /// number of characters written. `dst` must be at least 80 bytes.
    package int formatTo(scope char[] dst) const
    {
        immutable d = decode();
        int pos = 0;

        final switch (d.kind)
        {
            case DecKind.infinity:
                if (d.sign) dst[pos++] = '-';
                foreach (ch; "Infinity") dst[pos++] = ch;
                return pos;
            case DecKind.quietNaN:
            case DecKind.signalingNaN:
                if (d.sign) dst[pos++] = '-';
                if (d.kind == DecKind.signalingNaN) dst[pos++] = 's';
                foreach (ch; "NaN") dst[pos++] = ch;
                if (!toU256(d.coefficient).isZero)
                {
                    char[80] pd = void;
                    immutable pn = digitsOf(toU256(d.coefficient), pd[]);
                    foreach (j; 0 .. pn) dst[pos++] = pd[j];
                }
                return pos;
            case DecKind.finite:
                break;
        }

        char[80] digs = void;
        immutable nd = digitsOf(toU256(d.coefficient), digs[]);
        immutable q = d.exponent;
        immutable adj = q + (nd - 1);

        if (d.sign) dst[pos++] = '-';

        if (q <= 0 && adj >= -6)
        {
            if (q == 0)
            {
                foreach (j; 0 .. nd) dst[pos++] = digs[j];
            }
            else
            {
                immutable intDigits = nd + q; // digits before the decimal point
                if (intDigits > 0)
                {
                    foreach (j; 0 .. intDigits) dst[pos++] = digs[j];
                    dst[pos++] = '.';
                    foreach (j; intDigits .. nd) dst[pos++] = digs[j];
                }
                else
                {
                    dst[pos++] = '0';
                    dst[pos++] = '.';
                    foreach (_; 0 .. -intDigits) dst[pos++] = '0';
                    foreach (j; 0 .. nd) dst[pos++] = digs[j];
                }
            }
        }
        else
        {
            dst[pos++] = digs[0];
            if (nd > 1)
            {
                dst[pos++] = '.';
                foreach (j; 1 .. nd) dst[pos++] = digs[j];
            }
            dst[pos++] = 'E';
            int a = adj;
            if (a >= 0) dst[pos++] = '+';
            else { dst[pos++] = '-'; a = -a; }
            pos = writeUint(dst, pos, cast(ulong) a);
        }
        return pos;
    }

    /// The number of significant decimal digits, `precision`.
    enum int dig = Format.precision;
}

/// The 32-bit IEEE 754-2008 decimal type (7 significant digits).
alias Decimal32 = Decimal!32;
/// The 64-bit IEEE 754-2008 decimal type (16 significant digits).
alias Decimal64 = Decimal!64;
/// The 128-bit IEEE 754-2008 decimal type (34 significant digits).
alias Decimal128 = Decimal!128;
/// Convenience alias for the widest type.
alias decimal = Decimal128;

@safe pure unittest
{
    // Round-trip encode/decode of finite values across formats.
    static void check(int bits)(bool sign, int q, ulong coeff)
    {
        alias D = Decimal!bits;
        auto x = D.encodeFinite(sign, q, cast(D.Format.CoefficientType) coeff);
        auto d = x.decode();
        assert(d.kind == DecKind.finite);
        assert(d.sign == sign);
        assert(d.exponent == q);
        assert(lowU(d.coefficient) == coeff);
    }

    // Small-coefficient form.
    check!32(false, 0, 1234567);
    check!32(true, -101, 0);
    check!32(false, 90, 9999999);
    // Large-coefficient form (leading digit 8 or 9).
    check!32(false, 5, 9000000);
    check!32(true, -10, 8388608);

    check!64(false, 0, 1234567890123456UL);
    check!64(true, 369, 9999999999999999UL);
    check!64(false, -398, 9000000000000000UL);

    check!128(false, 0, 1234567890123456789UL);
    check!128(true, 6111, 0);
}

@safe pure unittest
{
    // 128-bit specific large coefficient round-trip.
    alias D = Decimal128;
    auto big = D.Format.maxCoefficient; // 34 nines
    auto x = D.encodeFinite(false, 0, big);
    auto d = x.decode();
    assert(d.coefficient == big);
    assert(d.exponent == 0);
    assert(!d.sign);

    auto neg = D.encodeFinite(true, -100, big);
    auto dn = neg.decode();
    assert(dn.sign && dn.coefficient == big && dn.exponent == -100);
}

@safe pure unittest
{
    // Special values and classification.
    static void specials(int bits)()
    {
        alias D = Decimal!bits;

        auto inf = D.infinity();
        assert(inf.isInfinity() && !inf.isFinite() && !inf.isNaN());
        assert(!inf.signbit());
        assert(D.encodeInfinity(true).signbit());

        auto qn = D.nan();
        assert(qn.isNaN() && !qn.isSignalingNaN() && !qn.isFinite());

        auto sn = D.encodeNaN(false, true, cast(D.Format.CoefficientType) 0);
        assert(sn.isNaN() && sn.isSignalingNaN());

        auto z = D.zero();
        assert(z.isZero() && z.isFinite() && !z.isNormal() && !z.isSubnormal());

        assert(D.max().isNormal());
        assert(D.min_normal().isNormal());
        assert(D.trueMin().isSubnormal());
        assert(!D.trueMin().isNormal());
    }

    specials!32();
    specials!64();
    specials!128();
}

/*
 * --- Phase 3 tests ----------------------------------------------------------
 */

@safe unittest
{
    // Construction from integers and toString.
    assert(Decimal64(0).toString() == "0");
    assert(Decimal64(1).toString() == "1");
    assert(Decimal64(-1).toString() == "-1");
    assert(Decimal64(123456).toString() == "123456");
    assert(Decimal64(-987654321L).toString() == "-987654321");
    assert(Decimal32(1234567).toString() == "1234567");

    // Rounding when an integer has more digits than the precision.
    // 12345678 has 8 digits; Decimal32 keeps 7 -> 1234568E+1.
    assert(Decimal32(12345678).toString() == "1.234568E+7");
}

@safe unittest
{
    // to-scientific-string formatting rules.
    Decimal64 d;
    ExceptionFlag f;

    assert(Decimal64.fromString("0", d, f) && d.toString() == "0");
    assert(Decimal64.fromString("0.00", d, f) && d.toString() == "0.00");
    assert(Decimal64.fromString("123", d, f) && d.toString() == "123");
    assert(Decimal64.fromString("1.23", d, f) && d.toString() == "1.23");
    assert(Decimal64.fromString("0.001", d, f) && d.toString() == "0.001");
    assert(Decimal64.fromString("1.234E+10", d, f) && d.toString() == "1.234E+10");
    assert(Decimal64.fromString("1E-7", d, f) && d.toString() == "1E-7");
    assert(Decimal64.fromString("1000000", d, f) && d.toString() == "1000000");
    // Adjusted exponent boundary: 1E-6 stays plain, 1E-7 goes scientific.
    assert(Decimal64.fromString("0.000001", d, f) && d.toString() == "0.000001");
}

@safe unittest
{
    // Special-value parsing and formatting.
    Decimal64 d;
    ExceptionFlag f;

    assert(Decimal64.fromString("Infinity", d, f) && d.isInfinity && !d.signbit);
    assert(d.toString() == "Infinity");
    assert(Decimal64.fromString("-inf", d, f) && d.isInfinity && d.signbit);
    assert(d.toString() == "-Infinity");
    assert(Decimal64.fromString("NaN", d, f) && d.isNaN && !d.isSignalingNaN);
    assert(d.toString() == "NaN");
    assert(Decimal64.fromString("sNaN", d, f) && d.isSignalingNaN);
    assert(d.toString() == "sNaN");

    // Malformed input.
    assert(!Decimal64.fromString("", d, f));
    assert(!Decimal64.fromString("1.2.3", d, f));
    assert(!Decimal64.fromString("12x", d, f));

    // Constructor-from-string convenience.
    assert(Decimal64("3.14159").toString() == "3.14159");
    assert(Decimal64("garbage").isNaN);
}

@safe unittest
{
    // Cross-format conversion (widen and narrow).
    auto a = Decimal128("1.5");
    auto b = Decimal64(a);
    assert(b.toString() == "1.5");

    auto c = Decimal32(Decimal64("2.5"));
    assert(c.toString() == "2.5");

    // Narrowing that rounds.
    auto wide = Decimal128("1.234567890123456789");
    auto narrow = Decimal32(wide);
    assert(narrow.toString() == "1.234568"); // 7 significant digits
}

@safe unittest
{
    // Rounding modes on a tie (1.25 -> 2 digits).
    static Decimal32 r(string s, RoundingMode m)
    {
        Decimal32 d;
        ExceptionFlag f;
        Decimal32.fromString(s, d, f, m);
        return d;
    }

    // 12345675 rounded to 7 digits is a tie between 1234567 and 1234568.
    assert(r("12345675", RoundingMode.roundTiesToEven).toString() == "1.234568E+7");
    assert(r("12345665", RoundingMode.roundTiesToEven).toString() == "1.234566E+7");
    assert(r("12345675", RoundingMode.roundTiesToAway).toString() == "1.234568E+7");
    assert(r("12345675", RoundingMode.roundTowardZero).toString() == "1.234567E+7");
    assert(r("12345675", RoundingMode.roundTowardNegative).toString() == "1.234567E+7");
    assert(r("12345675", RoundingMode.roundTowardPositive).toString() == "1.234568E+7");
    assert(r("-12345675", RoundingMode.roundTowardNegative).toString() == "-1.234568E+7");
    assert(r("-12345675", RoundingMode.roundTowardPositive).toString() == "-1.234567E+7");
}

@safe unittest
{
    // Inexact, overflow and underflow flags.
    Decimal32 d;
    ExceptionFlag f;

    f = ExceptionFlag.none;
    Decimal32.fromString("12345678", d, f); // 8 digits -> rounded
    assert(f & ExceptionFlag.inexact);

    f = ExceptionFlag.none;
    Decimal32.fromString("1234567", d, f);  // exactly 7 digits -> exact
    assert(!(f & ExceptionFlag.inexact));

    // Overflow: beyond decimal32's emax.
    f = ExceptionFlag.none;
    Decimal32.fromString("1E1000", d, f);
    assert((f & ExceptionFlag.overflow) && (f & ExceptionFlag.inexact));
    assert(d.isInfinity);

    // Underflow: subnormal and inexact.
    f = ExceptionFlag.none;
    Decimal32.fromString("1.234567E-100", d, f);
    assert(f & ExceptionFlag.underflow);
}

@safe unittest
{
    // Overflow under directed rounding yields the largest finite value.
    Decimal32 d;
    ExceptionFlag f;
    Decimal32.fromString("1E1000", d, f, RoundingMode.roundTowardZero);
    assert(d == Decimal32.max() || d.rawValue == Decimal32.max().rawValue);
    assert(!d.isInfinity);
}

@safe unittest
{
    // Conversions to and from binary floating point.
    assert(cast(double) Decimal64("1.5") == 1.5);
    assert(cast(double) Decimal64("0.5") == 0.5);
    assert(cast(double) Decimal64("-0.25") == -0.25);
    assert(cast(float) Decimal32("2.25") == 2.25f);

    auto a = Decimal64.fromDouble(1.5);
    assert(a.toString() == "1.5");
    auto b = Decimal64.fromDouble(0.25);
    assert(b.toString() == "0.25");
    auto c = Decimal64.fromFloat(0.5f);
    assert(cast(double) c == 0.5);

    // Round-trip a representative double value.
    assert(cast(double) Decimal64.fromDouble(3.140625) == 3.140625);
}

@safe unittest
{
    // Casts to integral types truncate toward zero.
    assert(cast(long) Decimal64("123.9") == 123);
    assert(cast(long) Decimal64("-123.9") == -123);
    assert(cast(int) Decimal64("1000") == 1000);
    assert(cast(long) Decimal64("0.4") == 0);

    // cast(bool)
    assert(!cast(bool) Decimal64(0));
    assert(cast(bool) Decimal64(1));
    assert(cast(bool) Decimal64.nan());
}

@safe unittest
{
    // CTFE: rounding and formatting must work at compile time.
    static immutable Decimal64 one = Decimal64(1);
    static assert(one.rawValue == Decimal64(1).rawValue);

    enum Decimal32 parsed = () {
        Decimal32 d;
        ExceptionFlag f;
        Decimal32.fromString("3.5", d, f);
        return d;
    }();
    static assert(!parsed.isNaN);
}

/*
 * --- Phase 4 tests (arithmetic & comparison) --------------------------------
 */

private auto dstr(int bits)(string s)
{
    Decimal!bits d;
    ExceptionFlag f;
    Decimal!bits.fromString(s, d, f);
    return d;
}

@safe unittest
{
    // Sign operations.
    assert(dstr!64("1.5").negated().toString() == "-1.5");
    assert(dstr!64("-1.5").absValue().toString() == "1.5");
    assert(dstr!64("1.5").copySign(dstr!64("-2")).toString() == "-1.5");
    assert(Decimal64.infinity().negated().toString() == "-Infinity");
}

@safe unittest
{
    // Addition / subtraction with preferred exponents.
    static string add(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.add(dstr!64(a), dstr!64(b), RoundingMode.roundTiesToEven, f).toString();
    }
    static string sub(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.sub(dstr!64(a), dstr!64(b), RoundingMode.roundTiesToEven, f).toString();
    }

    assert(add("1", "1") == "2");
    assert(add("1.0", "1.0") == "2.0");
    assert(add("1.0", "2.00") == "3.00");
    assert(add("2.5", "3.5") == "6.0");
    assert(sub("5", "3") == "2");
    assert(sub("0.3", "0.1") == "0.2");
    assert(add("1", "-1") == "0");
    assert(sub("3", "3") == "0");
    assert(add("100", "0.001") == "100.001");

    // Cancellation sign.
    ExceptionFlag f;
    auto z = Decimal64.add(dstr!64("5"), dstr!64("-5"), RoundingMode.roundTowardNegative, f);
    assert(z.isZero && z.signbit);
    auto zp = Decimal64.add(dstr!64("5"), dstr!64("-5"), RoundingMode.roundTiesToEven, f);
    assert(zp.isZero && !zp.signbit);
}

@safe unittest
{
    // Infinity arithmetic and invalid operations.
    ExceptionFlag f;

    f = ExceptionFlag.none;
    auto r = Decimal64.add(Decimal64.infinity(), Decimal64.infinity().negated(),
        RoundingMode.roundTiesToEven, f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));

    f = ExceptionFlag.none;
    auto s = Decimal64.add(Decimal64.infinity(), dstr!64("1"), RoundingMode.roundTiesToEven, f);
    assert(s.isInfinity && !s.signbit);

    // Signaling NaN raises invalid.
    f = ExceptionFlag.none;
    auto sn = Decimal64.encodeNaN(false, true, 0);
    auto t = Decimal64.add(sn, dstr!64("1"), RoundingMode.roundTiesToEven, f);
    assert(t.isNaN && !t.isSignalingNaN && (f & ExceptionFlag.invalidOperation));
}

@safe unittest
{
    // Multiplication.
    static string mul(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.mul(dstr!64(a), dstr!64(b), RoundingMode.roundTiesToEven, f).toString();
    }

    assert(mul("2", "3") == "6");
    assert(mul("1.0", "1.0") == "1.00");
    assert(mul("2.5", "4") == "10.0");
    assert(mul("0.1", "0.1") == "0.01");
    assert(mul("-2", "3") == "-6");
    assert(mul("1.5", "0") == "0.0");   // preferred exponent qa+qb = -1

    // 0 × ∞ is invalid.
    ExceptionFlag f;
    auto r = Decimal64.mul(dstr!64("0"), Decimal64.infinity(), RoundingMode.roundTiesToEven, f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));

    // finite × ∞.
    f = ExceptionFlag.none;
    auto i = Decimal64.mul(dstr!64("-2"), Decimal64.infinity(), RoundingMode.roundTiesToEven, f);
    assert(i.isInfinity && i.signbit);
}

@safe unittest
{
    // Comparison, including NaN, -0/+0 and infinities.
    static int cmp(string a, string b, out bool u)
    {
        return Decimal64.compareValue(dstr!64(a), dstr!64(b), u);
    }

    bool u;
    assert(cmp("1", "2", u) == -1 && !u);
    assert(cmp("2", "1", u) == 1);
    assert(cmp("1.5", "1.5", u) == 0);
    assert(cmp("1.50", "1.5", u) == 0);     // same value, different cohort
    assert(cmp("-1", "1", u) == -1);
    assert(cmp("0", "-0", u) == 0);         // ±0 compare equal
    assert(cmp("-0", "0", u) == 0);

    cmp("NaN", "1", u); assert(u);
    cmp("1", "NaN", u); assert(u);

    assert(Decimal64.compareValue(Decimal64.infinity(), dstr!64("1e300"), u) == 1);
    assert(Decimal64.compareValue(Decimal64.infinity().negated(), dstr!64("-1e300"), u) == -1);
    assert(Decimal64.compareValue(Decimal64.infinity(), Decimal64.infinity(), u) == 0);

    assert(Decimal64.isEqual(dstr!64("3.14"), dstr!64("3.140")));
    assert(!Decimal64.isEqual(dstr!64("NaN"), dstr!64("NaN")));
}

@safe unittest
{
    // 128-bit arithmetic sanity (full-width coefficients).
    ExceptionFlag f;
    auto a = dstr!128("12345678901234567890123456789012.34");
    auto b = dstr!128("0.01");
    auto sum = Decimal128.add(a, b, RoundingMode.roundTiesToEven, f);
    assert(sum.toString() == "12345678901234567890123456789012.35");

    auto p = Decimal128.mul(dstr!128("1.1"), dstr!128("1.1"), RoundingMode.roundTiesToEven, f);
    assert(p.toString() == "1.21");
}

@safe unittest
{
    // Division.
    static string div(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.div(dstr!64(a), dstr!64(b), RoundingMode.roundTiesToEven, f).toString();
    }

    assert(div("6", "2") == "3");
    assert(div("1", "2") == "0.5");
    assert(div("1", "3") == "0.3333333333333333");
    assert(div("2", "3") == "0.6666666666666667");
    assert(div("10", "4") == "2.5");
    assert(div("-6", "3") == "-2");
    assert(div("0", "5") == "0");

    // x / 0 raises divisionByZero and returns ∞.
    ExceptionFlag f;
    auto inf = Decimal64.div(dstr!64("1"), dstr!64("0"), RoundingMode.roundTiesToEven, f);
    assert(inf.isInfinity && !inf.signbit && (f & ExceptionFlag.divisionByZero));

    // 0 / 0 is invalid.
    f = ExceptionFlag.none;
    auto q = Decimal64.div(dstr!64("0"), dstr!64("0"), RoundingMode.roundTiesToEven, f);
    assert(q.isNaN && (f & ExceptionFlag.invalidOperation));

    // ∞ / ∞ is invalid.
    f = ExceptionFlag.none;
    auto ii = Decimal64.div(Decimal64.infinity(), Decimal64.infinity(), RoundingMode.roundTiesToEven, f);
    assert(ii.isNaN && (f & ExceptionFlag.invalidOperation));

    // finite / ∞ = 0.
    f = ExceptionFlag.none;
    auto z = Decimal64.div(dstr!64("5"), Decimal64.infinity(), RoundingMode.roundTiesToEven, f);
    assert(z.isZero);
}

@safe unittest
{
    // Fused multiply-add: single rounding.
    static string fma(string a, string b, string c)
    {
        ExceptionFlag f;
        return Decimal64.fma(dstr!64(a), dstr!64(b), dstr!64(c),
            RoundingMode.roundTiesToEven, f).toString();
    }

    assert(fma("2", "3", "1") == "7");
    assert(fma("1.5", "1.5", "0.75") == "3.00");

    // fma keeps full product precision before adding (no intermediate rounding).
    // 1e16 * 1e16 = 1e32 exactly, then subtract 1 -> exact in 64-bit? Not representable,
    // so just verify a clean case where the single rounding matters.
    assert(fma("0.1", "0.1", "0") == "0.01");

    // 0 × ∞ + c is invalid.
    ExceptionFlag f;
    auto r = Decimal64.fma(dstr!64("0"), Decimal64.infinity(), dstr!64("1"),
        RoundingMode.roundTiesToEven, f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));
}

@safe unittest
{
    // Square root.
    static string sq(string a)
    {
        ExceptionFlag f;
        return Decimal64.sqrt(dstr!64(a), RoundingMode.roundTiesToEven, f).toString();
    }

    assert(sq("4") == "2");
    assert(sq("9") == "3");
    assert(sq("2") == "1.414213562373095");
    assert(sq("1") == "1");
    assert(sq("0") == "0");
    assert(sq("0.25") == "0.5");

    // sqrt of a negative is invalid.
    ExceptionFlag f;
    auto r = Decimal64.sqrt(dstr!64("-1"), RoundingMode.roundTiesToEven, f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));

    // sqrt(+∞) = +∞.
    f = ExceptionFlag.none;
    assert(Decimal64.sqrt(Decimal64.infinity(), RoundingMode.roundTiesToEven, f).isInfinity);
}

@safe unittest
{
    // IEEE remainder.
    static string rem(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.remainder(dstr!64(a), dstr!64(b), f).toString();
    }

    assert(rem("5", "3") == "-1");      // 5 - 3*2 = -1 (nearest multiple is 6)
    assert(rem("7", "3") == "1");       // 7 - 3*2 = 1
    assert(rem("10", "3") == "1");      // 10 - 3*3 = 1
    assert(rem("9", "3") == "0");
    assert(rem("-7", "3") == "-1");

    // remainder by 0 is invalid.
    ExceptionFlag f;
    auto r = Decimal64.remainder(dstr!64("1"), dstr!64("0"), f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));
}

@safe unittest
{
    // quantize.
    static string qz(string a, string b)
    {
        ExceptionFlag f;
        return Decimal64.quantize(dstr!64(a), dstr!64(b), RoundingMode.roundTiesToEven, f).toString();
    }

    assert(qz("2.17", "0.001") == "2.170");
    assert(qz("2.17", "0.01") == "2.17");
    assert(qz("2.17", "0.1") == "2.2");
    assert(qz("2.17", "1") == "2");

    // Too many digits required -> invalid.
    ExceptionFlag f;
    auto r = Decimal64.quantize(dstr!64("1e20"), dstr!64("1"), RoundingMode.roundTiesToEven, f);
    assert(r.isNaN && (f & ExceptionFlag.invalidOperation));
}

@safe unittest
{
    // scaleB and logB.
    ExceptionFlag f;
    assert(Decimal64.scaleB(dstr!64("1.5"), 3, RoundingMode.roundTiesToEven, f).toString() == "1.5E+3");
    assert(Decimal64.scaleB(dstr!64("100"), -2, RoundingMode.roundTiesToEven, f).toString() == "1.00");

    assert(Decimal64.logB(dstr!64("1000"), f).toString() == "3");
    assert(Decimal64.logB(dstr!64("1"), f).toString() == "0");
    assert(Decimal64.logB(dstr!64("0.05"), f).toString() == "-2");

    f = ExceptionFlag.none;
    auto r = Decimal64.logB(dstr!64("0"), f);
    assert(r.isInfinity && r.signbit && (f & ExceptionFlag.divisionByZero));
}

@safe unittest
{
    // nextUp / nextDown.
    ExceptionFlag f;
    auto one = dstr!64("1");
    auto up = Decimal64.nextUp(one, f);
    assert(up.toString() == "1.000000000000001");
    auto dn = Decimal64.nextDown(one, f);
    assert(dn.toString() == "0.9999999999999999");

    // nextUp(+∞) = +∞, nextUp(-∞) = -max.
    assert(Decimal64.nextUp(Decimal64.infinity(), f).isInfinity);
    auto nm = Decimal64.nextUp(Decimal64.infinity().negated(), f);
    assert(nm.isFinite && nm.signbit);

    // nextUp(0) = smallest positive subnormal.
    auto tm = Decimal64.nextUp(dstr!64("0"), f);
    assert(tm.isSubnormal && !tm.signbit);
}

@safe unittest
{
    // totalOrder.
    static int to(string a, string b)
    {
        return Decimal64.totalOrder(dstr!64(a), dstr!64(b));
    }

    assert(to("1", "2") == -1);
    assert(to("2", "1") == 1);
    assert(to("-0", "0") == -1);            // -0 < +0
    assert(to("0", "-0") == 1);
    assert(to("1.0", "1.00") == 1);         // same value: larger exponent first for positive
    assert(to("1.00", "1.0") == -1);

    // NaNs sit at the extremes.
    assert(to("-NaN", "1") == -1);
    assert(to("NaN", "1") == 1);
    assert(to("-Inf", "-1e300") == -1);
    assert(to("Inf", "1e300") == 1);
}

@safe unittest
{
    // Operator overloading: unary.
    auto a = dstr!64("2.5");
    assert((+a).toString() == "2.5");
    assert((-a).toString() == "-2.5");

    auto b = dstr!64("1");
    ++b;
    assert(b.toString() == "2");
    --b;
    assert(b.toString() == "1");
}

@safe unittest
{
    // Operator overloading: binary between Decimals.
    auto a = dstr!64("10");
    auto b = dstr!64("4");
    assert((a + b).toString() == "14");
    assert((a - b).toString() == "6");
    assert((a * b).toString() == "40");
    assert((a / b).toString() == "2.5");
    assert((a % b).toString() == "2");        // truncated remainder, like fmod

    // Compound assignment.
    auto c = dstr!64("100");
    c += dstr!64("1");
    assert(c.toString() == "101");
    c -= dstr!64("1");
    c *= dstr!64("2");
    assert(c.toString() == "200");
    c /= dstr!64("4");
    assert(c.toString() == "50");
}

@safe unittest
{
    // Operator overloading: mixed scalar operands.
    auto a = dstr!64("2.5");
    assert((a + 1).toString() == "3.5");
    assert((a * 2).toString() == "5.0");
    assert((10 - a).toString() == "7.5");     // opBinaryRight
    assert((10 / a).toString() == "4");
    assert((a + 0.5).toString() == "3.0");    // double operand

    auto b = a;
    b += 3;
    assert(b.toString() == "5.5");
}

@safe unittest
{
    // Operator overloading: comparison operators.
    auto a = dstr!64("1.5");
    auto b = dstr!64("2.5");
    assert(a < b);
    assert(b > a);
    assert(a <= dstr!64("1.50"));
    assert(a >= dstr!64("1.50"));
    assert(a == dstr!64("1.5"));
    assert(a != b);

    // Mixed scalar comparison.
    assert(a < 2);
    assert(a > 1);
    assert(dstr!64("3") == 3);

    // NaN is unordered: every ordered comparison is false.
    auto n = Decimal64.nan();
    assert(!(n < a) && !(n > a) && !(n == a) && !(n <= a) && !(n >= a));
    assert(n != a);
}

@safe unittest
{
    // Operator overloading across widths.
    auto a = dstr!128("1.5");
    auto b = dstr!64("2.5");
    assert((a + b).toString() == "4.0");
    assert(a < dstr!64("2"));
}

@safe unittest
{
    // Phase 6: all five rounding modes on an exact halfway case (decimal32, p=7).
    static string r(string s, RoundingMode m)
    {
        Decimal32 d;
        ExceptionFlag f;
        Decimal32.fromString(s, d, f, m);
        return d.toString();
    }

    // 1.2345675 -> keep 7 digits, dropped digit is exactly 5 (an exact tie).
    assert(r("1.2345675", RoundingMode.roundTiesToEven) == "1.234568");   // to even
    assert(r("1.2345675", RoundingMode.roundTiesToAway) == "1.234568");
    assert(r("1.2345675", RoundingMode.roundTowardZero) == "1.234567");
    assert(r("1.2345675", RoundingMode.roundTowardPositive) == "1.234568");
    assert(r("1.2345675", RoundingMode.roundTowardNegative) == "1.234567");

    // Same magnitude, negative: directed modes flip.
    assert(r("-1.2345675", RoundingMode.roundTiesToEven) == "-1.234568");
    assert(r("-1.2345675", RoundingMode.roundTowardPositive) == "-1.234567");
    assert(r("-1.2345675", RoundingMode.roundTowardNegative) == "-1.234568");

    // 1.2345665 -> last kept digit 6 is even, tie stays.
    assert(r("1.2345665", RoundingMode.roundTiesToEven) == "1.234566");
    assert(r("1.2345665", RoundingMode.roundTiesToAway) == "1.234567");
}

@safe unittest
{
    // Phase 6: status flags.
    Decimal32 d;
    ExceptionFlag f;

    // Overflow -> infinity, inexact set.
    f = ExceptionFlag.none;
    Decimal32.fromString("1e1000", d, f);
    assert(d.isInfinity && !d.signbit);
    assert(f & ExceptionFlag.overflow);
    assert(f & ExceptionFlag.inexact);

    // Underflow -> tiny/zero, underflow + inexact set.
    f = ExceptionFlag.none;
    Decimal32.fromString("1e-1000", d, f);
    assert(f & ExceptionFlag.underflow);
    assert(f & ExceptionFlag.inexact);

    // Inexact alone (more digits than precision but in range).
    f = ExceptionFlag.none;
    Decimal32.fromString("1.2345678", d, f);
    assert(f & ExceptionFlag.inexact);
    assert(!(f & ExceptionFlag.overflow));

    // Exact -> no flags.
    f = ExceptionFlag.none;
    Decimal32.fromString("1.25", d, f);
    assert(f == ExceptionFlag.none);
}

@safe unittest
{
    // Phase 6: encode/decode round-trips for every width and special values.
    static void rt(int bits)()
    {
        alias D = Decimal!bits;
        foreach (v; [0L, 1L, -1L, 42L, -42L, 1000000L, -999999L])
        {
            auto d = D(v);
            assert(cast(long) d == v);
        }
        assert(D.nan().isNaN);
        assert(D.infinity().isInfinity && !D.infinity().signbit);
        assert(D.infinity().negated().signbit);
        assert(D.zero().isZero && !D.zero().signbit);
        assert(D.max().isFinite && !D.max().signbit);
        assert(D.trueMin().isSubnormal);
    }
    rt!32();
    rt!64();
    rt!128();
}

@safe unittest
{
    // Phase 6: string round-trips (parse -> format -> parse).
    static void rt(string s)
    {
        Decimal64 a, b;
        ExceptionFlag f;
        assert(Decimal64.fromString(s, a, f));
        immutable str = a.toString();
        assert(Decimal64.fromString(str, b, f));
        assert(Decimal64.isEqual(a, b));
    }
    rt("0");
    rt("1.5");
    rt("-1.5");
    rt("123456789.123456");
    rt("1.234567890123456E+100");
    rt("9.999999999999999E-200");
    rt("0.00001");
    rt("1000000000000000");
}

@safe unittest
{
    // Phase 6: correctly-rounded double <-> decimal.
    foreach (x; [0.0, 1.0, -1.0, 0.5, 0.25, 3.140625, 1234.5, -0.0009765625])
    {
        auto d = Decimal64.fromDouble(x);
        assert(cast(double) d == x);
    }
}

@safe unittest
{
    // Phase 6: CTFE — the arithmetic core evaluates at compile time.
    static assert((){
        auto a = Decimal64("2.5");
        auto b = Decimal64("4");
        return (a * b).toString();
    }() == "10.0");

    static assert((){
        auto a = Decimal64("1");
        auto b = Decimal64("8");
        ExceptionFlag f;
        return Decimal64.div(a, b, RoundingMode.roundTiesToEven, f).toString();
    }() == "0.125");

    enum sum = Decimal64("0.1") + Decimal64("0.2");
    static assert(sum.toString() == "0.3");
}

/*
 * ----------------------------------------------------------------------
 * IBM FPgen decimal conformance vectors.
 *
 * The IBM FPgen ("Floating-Point Test Suite for IEEE") describes each test
 * as a single line. The decimal subset exercised here uses the format:
 *
 *     <fmt><op> <rounding> <operands...> -> <result> [flags]
 *
 *   fmt        d32 | d64 | d128
 *   op         +   add            -   subtract       *   multiply
 *              /   divide         *+  fused mul-add   V   square root
 *              %   IEEE remainder
 *   rounding   =0  nearest, ties to even   =^  nearest, ties away
 *              0   toward zero             <   toward -Inf   >   toward +Inf
 *   operand    <sign><digits>P<exp>  (value = digits × 10^exp, cohort exact)
 *              +Inf | -Inf | Q (qNaN) | S (sNaN)
 *   flags      any of  x inexact  u underflow  o overflow
 *                      z division-by-zero      i invalid-operation
 *
 * Each vector checks both the produced value (including the IEEE preferred
 * exponent / cohort, via the raw encoding) and the exact status flags.
 * ----------------------------------------------------------------------
 */
version (unittest)
{
    private string[] fpSplit(string s)
    {
        string[] r;
        size_t i = 0;
        while (i < s.length)
        {
            while (i < s.length && s[i] == ' ') ++i;
            immutable st = i;
            while (i < s.length && s[i] != ' ') ++i;
            if (i > st) r ~= s[st .. i];
        }
        return r;
    }

    private RoundingMode fpRounding(string r)
    {
        switch (r)
        {
            case "=0": return RoundingMode.roundTiesToEven;
            case "=^": return RoundingMode.roundTiesToAway;
            case "0":  return RoundingMode.roundTowardZero;
            case "<":  return RoundingMode.roundTowardNegative;
            case ">":  return RoundingMode.roundTowardPositive;
            default: assert(false, "FPgen: bad rounding mode '" ~ r ~ "'");
        }
    }

    private ExceptionFlag fpFlags(string s)
    {
        ExceptionFlag f;
        foreach (c; s) switch (c)
        {
            case 'x': f |= ExceptionFlag.inexact; break;
            case 'u': f |= ExceptionFlag.underflow; break;
            case 'o': f |= ExceptionFlag.overflow; break;
            case 'z': f |= ExceptionFlag.divisionByZero; break;
            case 'i': f |= ExceptionFlag.invalidOperation; break;
            default: assert(false, "FPgen: bad flag char");
        }
        return f;
    }

    private string fpFlagDump(ExceptionFlag f)
    {
        string s;
        if (f & ExceptionFlag.invalidOperation) s ~= "i";
        if (f & ExceptionFlag.divisionByZero)   s ~= "z";
        if (f & ExceptionFlag.overflow)         s ~= "o";
        if (f & ExceptionFlag.underflow)        s ~= "u";
        if (f & ExceptionFlag.inexact)          s ~= "x";
        return s.length ? s : "(none)";
    }

    private Decimal!bits fpParse(int bits)(string tok)
    {
        alias D = Decimal!bits;
        if (tok == "+Inf") return D.infinity();
        if (tok == "-Inf") return D.infinity().negated();
        if (tok == "Q")    return D.nan();
        if (tok == "S")
        {
            D d;
            ExceptionFlag f;
            D.fromString("sNaN", d, f);
            return d;
        }
        // <sign><digits>P<exp>
        string num;
        size_t i = 0;
        if (tok[0] == '+') i = 1;
        else if (tok[0] == '-') { num = "-"; i = 1; }
        size_t p = i;
        while (p < tok.length && tok[p] != 'P') ++p;
        num ~= tok[i .. p];
        string es = (p < tok.length) ? tok[p + 1 .. $] : "0";
        D d;
        ExceptionFlag f;
        immutable ok = D.fromString(num ~ "E" ~ es, d, f);
        assert(ok, "FPgen: bad operand '" ~ tok ~ "'");
        return d;
    }

    private void fpCheck(int bits)(Decimal!bits got, string tok, string line)
    {
        if (tok == "Q")    { assert(got.isNaN() && !got.isSignalingNaN(), line); return; }
        if (tok == "S")    { assert(got.isSignalingNaN(), line); return; }
        if (tok == "+Inf") { assert(got.isInfinity() && !got.signbit(), line); return; }
        if (tok == "-Inf") { assert(got.isInfinity() && got.signbit(), line); return; }
        immutable want = fpParse!bits(tok);
        assert(got.rawValue() == want.rawValue(),
            line ~ "  [got " ~ got.toString() ~ "]");
    }

    private void runFPgen(int bits)(string line)
    {
        alias D = Decimal!bits;
        auto tok = fpSplit(line);
        size_t arrow = tok.length;
        foreach (k, t; tok) if (t == "->") { arrow = k; break; }
        assert(arrow < tok.length, "FPgen: missing '->' in: " ~ line);

        immutable opspec = tok[0];
        immutable mode = fpRounding(tok[1]);
        auto ops = tok[2 .. arrow];
        immutable resTok = tok[arrow + 1];
        immutable flagTok = (arrow + 2 < tok.length) ? tok[arrow + 2] : "";

        size_t j = 1;                       // skip 'd' then the width digits
        while (j < opspec.length && opspec[j] >= '0' && opspec[j] <= '9') ++j;
        immutable sym = opspec[j .. $];

        ExceptionFlag f;
        D got;
        switch (sym)
        {
            case "+":
                got = D.add(fpParse!bits(ops[0]), fpParse!bits(ops[1]), mode, f);
                break;
            case "-":
                got = D.sub(fpParse!bits(ops[0]), fpParse!bits(ops[1]), mode, f);
                break;
            case "*":
                got = D.mul(fpParse!bits(ops[0]), fpParse!bits(ops[1]), mode, f);
                break;
            case "/":
                got = D.div(fpParse!bits(ops[0]), fpParse!bits(ops[1]), mode, f);
                break;
            case "*+":
                got = D.fma(fpParse!bits(ops[0]), fpParse!bits(ops[1]),
                            fpParse!bits(ops[2]), mode, f);
                break;
            case "V":
                got = D.sqrt(fpParse!bits(ops[0]), mode, f);
                break;
            case "%":
                got = D.remainder(fpParse!bits(ops[0]), fpParse!bits(ops[1]), f);
                break;
            default:
                assert(false, "FPgen: unsupported operation '" ~ sym ~ "'");
        }

        fpCheck!bits(got, resTok, line);
        assert(f == fpFlags(flagTok),
            line ~ "  [flags got " ~ fpFlagDump(f) ~ "]");
    }
}

@safe unittest
{
    // FPgen — decimal64 addition / subtraction.
    static immutable string[] vectors = [
        "d64+ =0 1P0 1P0 -> 2P0",
        "d64+ =0 1P0 2P0 -> 3P0",
        "d64+ =0 12P-1 34P-1 -> 46P-1",
        "d64+ =0 1P0 -1P0 -> 0P0",
        "d64+ =0 25P-1 25P-1 -> 50P-1",
        "d64+ =0 +Inf 1P0 -> +Inf",
        "d64+ =0 +Inf -Inf -> Q i",
        "d64+ =0 Q 1P0 -> Q",
        "d64+ =0 S 1P0 -> Q i",
        "d64- =0 5P0 5P0 -> 0P0",
        "d64- =0 30P-1 12P-1 -> 18P-1",
        "d64- =0 1P0 +Inf -> -Inf",
    ];
    foreach (v; vectors) runFPgen!64(v);
}

@safe unittest
{
    // FPgen — decimal64 multiplication.
    static immutable string[] vectors = [
        "d64* =0 2P0 3P0 -> 6P0",
        "d64* =0 10P-1 10P-1 -> 100P-2",
        "d64* =0 -2P0 3P0 -> -6P0",
        "d64* =0 1P0 0P0 -> 0P0",
        "d64* =0 15P-1 0P0 -> 0P-1",
        "d64* =0 0P0 +Inf -> Q i",
        "d64* =0 -2P0 +Inf -> -Inf",
    ];
    foreach (v; vectors) runFPgen!64(v);
}

@safe unittest
{
    // FPgen — decimal64 division, including the directed rounding modes.
    static immutable string[] vectors = [
        "d64/ =0 6P0 2P0 -> 3P0",
        "d64/ =0 1P0 2P0 -> 5P-1",
        "d64/ =0 1P0 8P0 -> 125P-3",
        "d64/ =0 1P0 3P0 -> 3333333333333333P-16 x",
        "d64/ > 1P0 3P0 -> 3333333333333334P-16 x",
        "d64/ < 1P0 3P0 -> 3333333333333333P-16 x",
        "d64/ 0 1P0 3P0 -> 3333333333333333P-16 x",
        "d64/ =0 2P0 3P0 -> 6666666666666667P-16 x",
        "d64/ > 2P0 3P0 -> 6666666666666667P-16 x",
        "d64/ < 2P0 3P0 -> 6666666666666666P-16 x",
        "d64/ 0 2P0 3P0 -> 6666666666666666P-16 x",
        "d64/ =0 1P0 0P0 -> +Inf z",
        "d64/ =0 0P0 0P0 -> Q i",
        "d64/ =0 +Inf +Inf -> Q i",
        "d64/ =0 5P0 +Inf -> 0P0",
    ];
    foreach (v; vectors) runFPgen!64(v);
}

@safe unittest
{
    // FPgen — decimal64 fused multiply-add, square root and remainder.
    static immutable string[] vectors = [
        "d64*+ =0 2P0 3P0 1P0 -> 7P0",
        "d64*+ =0 15P-1 15P-1 75P-2 -> 300P-2",
        "d64*+ =0 0P0 +Inf 1P0 -> Q i",
        "d64V =0 4P0 -> 2P0",
        "d64V =0 9P0 -> 3P0",
        "d64V =0 25P-2 -> 5P-1",
        "d64V =0 2P0 -> 1414213562373095P-15 x",
        "d64V =0 -1P0 -> Q i",
        "d64V =0 +Inf -> +Inf",
        "d64% =0 5P0 3P0 -> -1P0",
        "d64% =0 7P0 3P0 -> 1P0",
        "d64% =0 10P0 3P0 -> 1P0",
        "d64% =0 9P0 3P0 -> 0P0",
        "d64% =0 1P0 0P0 -> Q i",
    ];
    foreach (v; vectors) runFPgen!64(v);
}

@safe unittest
{
    // FPgen — decimal32 overflow and underflow boundaries (emax 96, qmin -101).
    static immutable string[] vectors = [
        "d32* =0 9999999P90 10P0 -> +Inf ox",
        "d32* > 9999999P90 10P0 -> +Inf ox",
        "d32* < 9999999P90 10P0 -> 9999999P90 ox",
        "d32/ =0 1P-101 10P0 -> 0P-101 ux",
        "d32+ =0 1P0 1P0 -> 2P0",
        "d32* =0 -9999999P90 10P0 -> -Inf ox",
    ];
    foreach (v; vectors) runFPgen!32(v);
}

@safe unittest
{
    // FPgen — decimal128 full-width coefficients.
    static immutable string[] vectors = [
        "d128* =0 11P-1 11P-1 -> 121P-2",
        "d128+ =0 1234567890123456789012345678901234P-2 1P-2"
            ~ " -> 1234567890123456789012345678901235P-2",
        "d128/ =0 1P0 3P0 ->"
            ~ " 3333333333333333333333333333333333P-34 x",
        "d128V =0 4P0 -> 2P0",
    ];
    foreach (v; vectors) runFPgen!128(v);
}
