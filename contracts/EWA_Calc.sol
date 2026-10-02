// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/// @title EWA_Calc — shared calculator library for the EWA satellite system
/// @notice Single audited home for every repeated math pattern in the
///         satellites: basis-point math, WAD fixed-point, full-precision
///         mulDiv, Babylonian sqrt, overflow-safe helpers.
///
///         Why a library and not a deployed contract:
///         `internal` functions are inlined at compile time — zero extra
///         gas per call, zero deployment, zero external trust. A deployed
///         calculator would charge gas on every call and add a dependency
///         every satellite must hardcode anyway.
///
///         Replaces the ad-hoc `(a * b) / 10000` / `(a * b) / 1e18`
///         scattered across the suite (93 + 148 occurrences), which can
///         overflow on `a * b` and always round down silently.
///
///         Usage: `using EWA_Calc for uint256;` then `amount.mulBps(2500)`.
library EWA_Calc {
    uint256 internal constant BPS = 10000;
    uint256 internal constant WAD = 1e18;

    error DenominatorZero();
    error MulDivOverflow();

    // ------------------------------------------------------------------
    // Full-precision multiplication-division (512-bit product)
    // ------------------------------------------------------------------
    /// @notice Computes floor(a * b / denominator) with full precision.
    /// @dev 512-bit product, so `a * b` never overflows silently.
    ///      Reverts on division by zero or if the result overflows uint256.
    ///      (Uniswap V3 FullMath construction — battle-tested.)
    function mulDiv(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        unchecked {
            // 512-bit multiply [prod1 prod0] = a * b
            uint256 prod0;
            uint256 prod1;
            assembly {
                let mm := mulmod(a, b, not(0))
                prod0 := mul(a, b)
                prod1 := sub(sub(mm, prod0), lt(mm, prod0))
            }

            // Fast path: no overflow of the 256-bit product.
            if (prod1 == 0) {
                if (denominator == 0) revert DenominatorZero();
                assembly {
                    result := div(prod0, denominator)
                }
                return result;
            }

            // Result would overflow uint256 unless denominator > prod1.
            if (denominator == 0) revert DenominatorZero();
            if (denominator <= prod1) revert MulDivOverflow();

            // Make division exact: subtract remainder from [prod1 prod0].
            uint256 remainder;
            assembly {
                remainder := mulmod(a, b, denominator)
                prod1 := sub(prod1, gt(remainder, prod0))
                prod0 := sub(prod0, remainder)
            }

            // Factor powers of two out of denominator.
            uint256 twos = denominator & (~denominator + 1);
            assembly {
                denominator := div(denominator, twos)
                prod0 := div(prod0, twos)
                twos := add(div(sub(0, twos), twos), 1)
            }
            prod0 |= prod1 * twos;

            // Newton-Raphson inverse of denominator mod 2^256.
            uint256 inverse = (3 * denominator) ^ 2;
            inverse *= 2 - denominator * inverse; // 2^-1
            inverse *= 2 - denominator * inverse; // 2^-2
            inverse *= 2 - denominator * inverse; // 2^-4
            inverse *= 2 - denominator * inverse; // 2^-8
            inverse *= 2 - denominator * inverse; // 2^-16
            inverse *= 2 - denominator * inverse; // 2^-32
            inverse *= 2 - denominator * inverse; // 2^-64
            inverse *= 2 - denominator * inverse; // 2^-128

            result = prod0 * inverse;
            return result;
        }
    }

    /// @notice Computes ceil(a * b / denominator) with full precision.
    function mulDivUp(uint256 a, uint256 b, uint256 denominator)
        internal
        pure
        returns (uint256 result)
    {
        result = mulDiv(a, b, denominator);
        unchecked {
            if (mulmod(a, b, denominator) > 0) {
                if (result == type(uint256).max) revert MulDivOverflow();
                result += 1;
            }
        }
    }

    // ------------------------------------------------------------------
    // Basis points (per-10000)
    // ------------------------------------------------------------------
    /// @notice floor(amount * bps / 10000). `bps` may exceed 10000 for boosts.
    function mulBps(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDiv(amount, bps, BPS);
    }

    /// @notice ceil(amount * bps / 10000).
    function mulBpsUp(uint256 amount, uint256 bps) internal pure returns (uint256) {
        return mulDivUp(amount, bps, BPS);
    }

    // ------------------------------------------------------------------
    // WAD fixed-point (1e18)
    // ------------------------------------------------------------------
    /// @notice floor(a * b / 1e18).
    function wadMul(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, b, WAD);
    }

    /// @notice floor(a * 1e18 / b).
    function wadDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return mulDiv(a, WAD, b);
    }

    // ------------------------------------------------------------------
    // Roots and helpers
    // ------------------------------------------------------------------
    /// @notice floor(sqrt(y)) via Babylonian iteration.
    function sqrt(uint256 y) internal pure returns (uint256 z) {
        unchecked {
            if (y > 3) {
                z = y;
                uint256 x = y / 2 + 1;
                while (x < z) {
                    z = x;
                    x = (y / x + x) / 2;
                }
            } else if (y != 0) {
                z = 1;
            }
        }
    }

    /// @notice Overflow-safe average: (a & b) + (a ^ b) / 2.
    function avg(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return (a & b) + (a ^ b) / 2;
        }
    }

    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    /// @notice Absolute difference, no underflow.
    function absDiff(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    /// @notice Clamp value into [lo, hi]. Reverts if lo > hi.
    function clamp(uint256 v, uint256 lo, uint256 hi) internal pure returns (uint256) {
        require(lo <= hi, "EWA_Calc: bad bounds");
        if (v < lo) return lo;
        if (v > hi) return hi;
        return v;
    }
}
