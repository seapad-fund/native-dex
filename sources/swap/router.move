/// Router v2 for Liquidity Pool, similar to Uniswap router.
module hyperex::router {

    use hyperex::coin_helper::{Self};
    use hyperex::curves;
    use hyperex::math;
    use hyperex::stable_curve;
    use hyperex::liquidity_pool;
    use sui::coin::{Coin, CoinMetadata};
    use sui::coin;
    use sui::tx_context::TxContext;
    use hyperex::liquidity_pool::{LiquidityPool, Pools};
    use hyperex::global_config::GlobalConfig;
    use hyperex::dao_storage::{Storages, Storage};
    use hyperex::lp_coin::LP;
    use hyperex::pool_coin;
    use hyperex::dao_storage;

    // Errors codes.

    /// Wrong amount used.
    const ERR_WRONG_AMOUNT: u64 = 200;
    /// Wrong reserve used.
    const ERR_WRONG_RESERVE: u64 = 201;
    /// Insufficient amount in Y reserves.
    const ERR_INSUFFICIENT_Y_AMOUNT: u64 = 202;
    /// Insufficient amount in X reserves.
    const ERR_INSUFFICIENT_X_AMOUNT: u64 = 203;
    /// Overlimit of X coins to swap.
    const ERR_OVERLIMIT_X: u64 = 204;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 205;
    /// Needed amount in great than maximum.
    const ERR_COIN_VAL_MAX_LESS_THAN_NEEDED: u64 = 206;
    /// Marks the unreachable place in code
    const ERR_UNREACHABLE: u64 = 207;
    /// Provided coins amount cannot be converted without the overflow at the current price
    const ERR_COIN_CONVERSION_OVERFLOW: u64 = 208;
    /// Wrong order of coin parameters.
    const ERR_WRONG_COIN_ORDER: u64 = 208;

    // Consts
    const MAX_U64: u128 = 18446744073709551615;

    // Public functions.

    /// Register new liquidity pool for `X`/`Y` pair on signer address with `LP` coin.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public fun register_pool<X, Y, Curve>(witness: LP<X, Y, Curve>,
                                          config: &GlobalConfig,
                                          pools: &mut Pools,
                                          daos: &mut Storages,
                                          metaX: &CoinMetadata<X>,
                                          metaY: &CoinMetadata<Y>,
                                          ctx: &mut TxContext) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        liquidity_pool::register<X, Y, Curve>(witness, config, pools, daos, metaX, metaY, ctx);
    }

    /// Add liquidity to pool `X`/`Y` with rationality checks.
    /// * `coin_x` - coin X to add as liquidity.
    /// * `min_coin_x_val` - minimum amount of coin X to add as liquidity.
    /// * `coin_y` - coin Y to add as liquidity.
    /// * `min_coin_y_val` - minimum amount of coin Y to add as liquidity.
    /// Returns remainders of coins X and Y, and LP coins: `(Coin<X>, Coin<Y>, Coin<LP<X, Y, Curve>>)`.
    ///
    /// Note: X, Y generic coin parameters must be sorted.
    public fun add_liquidity<X, Y, Curve>(
        coin_x: Coin<X>,
        min_coin_x_val: u64,
        coin_y: Coin<Y>,
        min_coin_y_val: u64,
        timestamp_ms: u64,
        config: &GlobalConfig,
        pools: &mut Pools,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>, pool_coin::Coin<LP<X, Y, Curve>>) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);

        let coin_x_val = coin::value(&coin_x);
        let coin_y_val = coin::value(&coin_y);

        assert!(coin_x_val >= min_coin_x_val, ERR_INSUFFICIENT_X_AMOUNT);
        assert!(coin_y_val >= min_coin_y_val, ERR_INSUFFICIENT_Y_AMOUNT);

        let (optimal_x, optimal_y) =
            calc_optimal_coin_values<X, Y, Curve>(
                coin_x_val,
                coin_y_val,
                min_coin_x_val,
                min_coin_y_val,
                config,
                pools
            );

        let coin_x_opt = coin::split(&mut coin_x, optimal_x, ctx);
        let coin_y_opt = coin::split(&mut coin_y, optimal_y, ctx);

        let lp_coins = liquidity_pool::mint<X, Y, Curve>(coin_x_opt, coin_y_opt, timestamp_ms, config, pools, ctx);
        (coin_x, coin_y, lp_coins)
    }

    /// Burn liquidity coins `LP` and get coins `X` and `Y` back.
    /// * `lp_coins` - `LP` coins to burn.
    /// * `min_x_out_val` - minimum amount of `X` coins must be out.
    /// * `min_y_out_val` - minimum amount of `Y` coins must be out.
    /// Returns both `Coin<X>` and `Coin<Y>`: `(Coin<X>, Coin<Y>)`.
    ///
    /// Note: X, Y generic coin parameteres should be sorted.
    public fun remove_liquidity<X, Y, Curve>(
        lp_coins: pool_coin::Coin<LP<X, Y, Curve>>,
        min_x_out_val: u64,
        min_y_out_val: u64,
        pools: &mut Pools,
        timestamp_ms: u64,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        let pool = liquidity_pool::getPool<X, Y, Curve>(pools);
        let (x_out, y_out) = liquidity_pool::burn<X, Y, Curve>(lp_coins, pool, timestamp_ms, ctx);

        assert!(
            coin::value(&x_out) >= min_x_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        assert!(
            coin::value(&y_out) >= min_y_out_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM
        );
        (x_out, y_out)
    }

    /// Swap exact amount of coin `X` for coin `Y`.
    /// * `coin_in` - coin X to swap.
    /// * `coin_out_min_val` - minimum amount of coin Y to get out.
    /// Returns `Coin<Y>`.
    public fun swap_exact_coin_for_coin<X, Y, Curve>(
        coin_in: Coin<X>,
        coin_out_min_val: u64,
        timestamp_ms: u64,
        config: &GlobalConfig,
        pools: &mut Pools,
        daos: &mut Storages,
        ctx: &mut TxContext
    ): Coin<Y> {
        let coin_in_val = coin::value(&coin_in);
        let coin_out_val = get_amount_out<X, Y, Curve>(coin_in_val, config, pools);

        assert!(
            coin_out_val >= coin_out_min_val,
            ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM,
        );

        let coin_out = swap_coin_for_coin_unchecked<X, Y, Curve>(coin_in, coin_out_val, timestamp_ms, config, pools, daos, ctx);
        coin_out
    }

    /// Swap max coin amount `X` for exact coin `Y`.
    /// * `coin_max_in` - maximum amount of coin X to swap to get `coin_out_val` of coins Y.
    /// * `coin_out_val` - exact amount of coin Y to get.
    /// Returns remainder of `coin_max_in` as `Coin<X>` and `Coin<Y>`: `(Coin<X>, Coin<Y>)`.
    public fun swap_coin_for_exact_coin<X, Y, Curve>(
        coin_max_in: Coin<X>,
        coin_out_val: u64,
        timestamp_ms: u64,
        config: &GlobalConfig,
        pools: &mut Pools,
        daos: &mut Storages,
        ctx: &mut TxContext
    ): (Coin<X>, Coin<Y>) {
        let coin_in_val_needed = get_amount_in<X, Y, Curve>(coin_out_val, config, pools);

        let coin_val_max = coin::value(&coin_max_in);
        assert!(
            coin_in_val_needed <= coin_val_max,
            ERR_COIN_VAL_MAX_LESS_THAN_NEEDED
        );

        let coin_in = coin::split(&mut coin_max_in, coin_in_val_needed, ctx);
        let coin_out = swap_coin_for_coin_unchecked<X, Y, Curve>(coin_in, coin_out_val, timestamp_ms, config, pools, daos, ctx);

        (coin_max_in, coin_out)
    }

    /// Swap coin `X` for coin `Y` WITHOUT CHECKING input and output amount.
    /// So use the following function only on your own risk.
    /// * `coin_in` - coin X to swap.
    /// * `coin_out_val` - amount of coin Y to get out.
    /// Returns `Coin<Y>`.
    public fun swap_coin_for_coin_unchecked<X, Y, Curve>(
        coin_in: Coin<X>,
        coin_out_val: u64,
        timestamp_ms: u64,
        config: &GlobalConfig,
        pools: &mut Pools,
        daos: &mut Storages,
        ctx: &mut TxContext,
    ): Coin<Y> {
        let (zero, coin_out);
        if (coin_helper::is_sorted<X, Y>()) {
            (zero, coin_out) = liquidity_pool::swap<X, Y, Curve>(
                coin_in,
                0,
                coin::zero(ctx),
                coin_out_val,
                timestamp_ms,
                config,
                liquidity_pool::getPool<X, Y, Curve>(pools),
                dao_storage::getDao<X, Y, Curve>(daos),
                ctx);
        }
        else {
            (coin_out, zero) = liquidity_pool::swap<Y, X, Curve>(
                coin::zero(ctx),
                coin_out_val,
                coin_in,
                0,
                timestamp_ms,
                config,
                liquidity_pool::getPool<Y, X, Curve>(pools),
                dao_storage::getDao<Y, X, Curve>(daos),
                ctx);
        };

        coin::destroy_zero(zero);

        coin_out
    }

    // Getters.

    /// Get decimals scales for stable curve, for uncorrelated curve would return zeros.
    /// Returns `X` and `Y` coins decimals scales.
    public fun get_decimals_scales<X, Y, Curve>(pools: &mut Pools): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            liquidity_pool::get_decimals_scales<X, Y, Curve>(liquidity_pool::getPool<X, Y, Curve>(pools))
        } else {
            let (y, x) = liquidity_pool::get_decimals_scales<Y, X, Curve>(liquidity_pool::getPool<Y, X, Curve>(pools));
            (x, y)
        }
    }

    /// Get current cumulative prices in liquidity pool `X`/`Y`.
    /// Returns (X price, Y price, block_timestamp).
    public fun get_cumulative_prices<X, Y, Curve>(config: &GlobalConfig, pool: &LiquidityPool<X, Y, Curve>): (u128, u128, u64) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        liquidity_pool::get_cumulative_prices<X, Y, Curve>(config, pool)
    }

    /// Get reserves of liquidity pool (`X` and `Y`).
    /// Returns current reserves (`X`, `Y`).
    public fun get_reserves_size<X, Y, Curve>(config: &GlobalConfig, pools: &mut Pools): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            liquidity_pool::get_reserves_size<X, Y, Curve>(config, liquidity_pool::getPool<X, Y, Curve>(pools))
        } else {
            let (y_res, x_res) = liquidity_pool::get_reserves_size<Y, X, Curve>(config, liquidity_pool::getPool<Y, X, Curve>(pools));
            (x_res, y_res)
        }
    }

    /// Get fee for specific pool together with denominator (numerator, denominator).
    public fun get_fees_config<X, Y, Curve>(pools: &mut Pools): (u64, u64) {
        if (coin_helper::is_sorted<X, Y>()) {
            liquidity_pool::get_fees_config<X, Y, Curve>(liquidity_pool::getPool<X, Y, Curve>(pools))
        } else {
            liquidity_pool::get_fees_config<Y, X, Curve>(liquidity_pool::getPool<Y, X, Curve>(pools))
        }
    }

    /// Get fee for specific pool.
    public fun get_fee<X, Y, Curve>(pool: &LiquidityPool<X, Y, Curve>): u64 {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        liquidity_pool::get_fee<X, Y, Curve>(pool)
    }

    /// Get DAO fee for specific pool together with denominator (numerator, denominator).
    public fun get_dao_fees_config<X, Y, Curve>(pool: &LiquidityPool<X, Y, Curve>): (u64, u64) {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        liquidity_pool::get_dao_fees_config<X, Y, Curve>(pool)
    }

    /// Get DAO fee for specific pool.
    public fun get_dao_fee<X, Y, Curve>(pool: &LiquidityPool<X, Y, Curve>): u64 {
        assert!(coin_helper::is_sorted<X, Y>(), ERR_WRONG_COIN_ORDER);
        liquidity_pool::get_dao_fee<X, Y, Curve>(pool)
    }

    /// Check swap for pair `X` and `Y` exists.
    /// If pool exists returns true, otherwise false.
    public fun is_swap_exists<X, Y, Curve>(pools: &Pools): bool {
        if (coin_helper::is_sorted<X, Y>()) {
            liquidity_pool::is_pool_exists<X, Y, Curve>(pools)
        } else {
            liquidity_pool::is_pool_exists<Y, X, Curve>(pools)
        }
    }

    // Math.

    /// Calculate optimal amounts of `X`, `Y` coins to add as a new liquidity.
    /// * `x_desired` - provided value of coins `X`.
    /// * `y_desired` - provided value of coins `Y`.
    /// * `x_min` - minimum of coins X expected.
    /// * `y_min` - minimum of coins Y expected.
    /// Returns both `X` and `Y` coins amounts.
    public fun calc_optimal_coin_values<X, Y, Curve>(
        x_desired: u64,
        y_desired: u64,
        x_min: u64,
        y_min: u64,
        config: &GlobalConfig,
        pools: &mut Pools
    ): (u64, u64) {
        let (reserves_x, reserves_y) = get_reserves_size<X, Y, Curve>(config, pools);

        if (reserves_x == 0 && reserves_y == 0) {
            return (x_desired, y_desired)
        } else {
            let y_returned = convert_with_current_price(x_desired, reserves_x, reserves_y);
            if (y_returned <= y_desired) {
                // amount of `y` received from `x_desired` on a current price is less than `y_desired`
                assert!(y_returned >= y_min, ERR_INSUFFICIENT_Y_AMOUNT);
                return (x_desired, y_returned)
            } else {
                // not enough in `y_desired`, use it as a cap
                let x_returned = convert_with_current_price(y_desired, reserves_y, reserves_x);
                // ERR_OVERLIMIT_X should never occur here, added just in case
                assert!(x_returned <= x_desired, ERR_OVERLIMIT_X);
                assert!(x_returned >= x_min, ERR_INSUFFICIENT_X_AMOUNT);
                return (x_returned, y_desired)
            }
        }
    }

    /// Return amount of liquidity (LP) need for `coin_in`.
    /// * `coin_in` - amount to swap.
    /// * `reserve_in` - reserves of coin to swap.
    /// * `reserve_out` - reserves of coin to get.
    public fun convert_with_current_price(coin_in: u64, reserve_in: u64, reserve_out: u64): u64 {
        assert!(coin_in > 0, ERR_WRONG_AMOUNT);
        assert!(reserve_in > 0 && reserve_out > 0, ERR_WRONG_RESERVE);

        // exchange_price = reserve_out / reserve_in_size
        // amount_returned = coin_in_val * exchange_price
        let res = (coin_in as u128) * (reserve_out as u128) / (reserve_in as u128);
        assert!(res <= MAX_U64, ERR_COIN_CONVERSION_OVERFLOW);
        (res as u64)
    }

    /// Convert `LP` coins to `X` and `Y` coins, useful to calculate amount the user recieve after removing liquidity.
    /// * `lp_to_burn_val` - amount of `LP` coins to burn.
    /// Returns both `X` and `Y` coins amounts.
    public fun get_reserves_for_lp_coins<X, Y, Curve>(
        lp_to_burn_val: u64,
        config: &GlobalConfig,
        pools: &mut Pools
    ): (u64, u64) {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, Curve>(config, pools);
        let lp_coins_total = liquidity_pool::getLPSupply<X, Y, Curve>(pools);

        let x_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (x_reserve as u128), (lp_coins_total as u128));
        let y_to_return_val = math::mul_div_u128((lp_to_burn_val as u128), (y_reserve as u128), (lp_coins_total as u128));

        assert!(x_to_return_val > 0 && y_to_return_val > 0, ERR_WRONG_AMOUNT);

        (x_to_return_val, y_to_return_val)
    }

    /// Get amount out for `amount_in` of X coins (see generic).
    /// So if Coins::USDC is X and Coins::USDT is Y, it will get amount of USDT you will get after swap `amount_x` USDC.
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_x` - amount to swap.
    /// Returns amount of `Y` coins getting after swap.
    public fun get_amount_out<X, Y, Curve>(amount_in: u64,  config: &GlobalConfig, pools: &mut Pools): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, Curve>(config, pools);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, Curve>(pools);
        get_coin_out_with_fees<X, Y, Curve>(
            amount_in,
            reserve_x,
            reserve_y,
            scale_x,
            scale_y,
            pools
        )
    }

    /// Get amount in for `amount_out` of X coins (see generic).
    /// So if Coins::USDT is X and Coins::USDC is Y, you pass how much USDC you want to get and
    /// it returns amount of USDT you have to swap (include fees).
    /// !Important!: This function can eat a lot of gas if you querying it for stable curve pool, so be aware.
    /// We recommend to do implement such kind of logic offchain.
    /// * `amount_x` - amount to swap.
    /// Returns amount of `X` coins needed.
    public fun get_amount_in<X, Y, Curve>(amount_out: u64,  config: &GlobalConfig, pools: &mut Pools): u64 {
        let (reserve_x, reserve_y) = get_reserves_size<X, Y, Curve>(config, pools);
        let (scale_x, scale_y) = get_decimals_scales<X, Y, Curve>(pools);
        get_coin_in_with_fees<X, Y, Curve>(
            amount_out,
            reserve_y,
            reserve_x,
            scale_y,
            scale_x,
            pools
        )
    }

    // Private functions (contains part of math).

    /// Get coin amount out by passing amount in (include fees). Pass all data manually.
    /// * `coin_in` - exactly amount of coins to swap.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `scale_in` - 10 pow by decimals amount of coin we going to swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we going to get.
    /// Returns amount of coins out after swap.
    fun get_coin_out_with_fees<X, Y, Curve>(
        coin_in: u64,
        reserve_in: u64,
        reserve_out: u64,
        scale_in: u64,
        scale_out: u64,
        pools: &mut Pools
    ): u64 {
        let (fee_pct, fee_scale) = get_fees_config<X, Y, Curve>(pools);
        let fee_multiplier = fee_scale - fee_pct;

        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);

        if (curves::is_stable<Curve>()) {
            let coin_in_val_scaled = math::mul_to_u128(coin_in, fee_multiplier);
            let coin_in_val_after_fees = if (coin_in_val_scaled % (fee_scale as u128) != 0) {
                (coin_in_val_scaled / (fee_scale as u128)) + 1
            } else {
                coin_in_val_scaled / (fee_scale as u128)
            };

            (stable_curve::coin_out(
                coin_in_val_after_fees,
                scale_in,
                scale_out,
                reserve_in_u128,
                reserve_out_u128
            ) as u64)
        } else if (curves::is_uncorrelated<Curve>()) {
            let coin_in_val_after_fees = math::mul_to_u128(coin_in, fee_multiplier);
            let new_reserve_in = math::mul_to_u128(reserve_in, fee_scale) + coin_in_val_after_fees;

            // Multiply coin_in by the current exchange rate:
            // current_exchange_rate = reserve_out / reserve_in
            // amount_in_after_fees * current_exchange_rate -> amount_out
            math::mul_div_u128(coin_in_val_after_fees,
                reserve_out_u128,
                new_reserve_in)
        } else {
            abort ERR_UNREACHABLE
        }
    }

    /// Get coin amount in by amount out. Pass all data manually.
    /// * `coin_out` - exactly amount of coins we want to get.
    /// * `reserve_out` - reserves of coin we are going to get.
    /// * `reserve_in` - reserves of coin we are going to swap.
    /// * `scale_in` - 10 pow by decimals amount of coin we swap.
    /// * `scale_out` - 10 pow by decimals amount of coin we get.
    ///
    /// This computation is a reverse of get_coin_out formula for uncorrelated assets:
    ///     y = x * (fee_scale - fee_pct) * ry / (rx + x * (fee_scale - fee_pct))
    ///
    /// solving it for x returns this formula:
    ///     x = y * rx / ((ry - y) * (fee_scale - fee_pct)) or
    ///     x = y * rx * (fee_scale) / ((ry - y) * (fee_scale - fee_pct)) which implemented in this function
    ///
    ///  For stable curve math described in `coin_in` func into `../libs/StableCurve.move`.
    ///
    /// Returns amount of coins needed for swap.
    fun get_coin_in_with_fees<X, Y, Curve>(
        coin_out: u64,
        reserve_out: u64,
        reserve_in: u64,
        scale_out: u64,
        scale_in: u64,
        pools: &mut Pools
    ): u64 {
        assert!(reserve_out > coin_out, ERR_INSUFFICIENT_Y_AMOUNT);

        let (fee_pct, fee_scale) = get_fees_config<X, Y, Curve>(pools);
        let fee_multiplier = fee_scale - fee_pct;

        let coin_out_u128 = (coin_out as u128);
        let reserve_in_u128 = (reserve_in as u128);
        let reserve_out_u128 = (reserve_out as u128);

        if (curves::is_stable<Curve>()) {
            let coin_in = (stable_curve::coin_in(
                coin_out_u128,
                scale_out,
                scale_in,
                reserve_out_u128,
                reserve_in_u128,
            ) as u64) + 1;
            math::mul_div(coin_in, fee_scale, fee_multiplier) + 1

        } else if (curves::is_uncorrelated<Curve>()) {
            let new_reserves_out = (reserve_out_u128 - coin_out_u128) * (fee_multiplier as u128);

            // coin_out * reserve_in * fee_scale / new reserves out
            let coin_in = math::mul_div_u128(
                coin_out_u128,
                reserve_in_u128 * (fee_scale as u128),
                new_reserves_out
            ) + 1;
            coin_in
        } else {
            abort ERR_UNREACHABLE
        }
    }

    #[test_only]
    public fun current_price<X, Y, Curve>(config: &GlobalConfig, pools: &mut Pools): u128 {
        let (x_reserve, y_reserve) = get_reserves_size<X, Y, Curve>(config, pools);
        ((x_reserve / y_reserve) as u128)
    }
}
