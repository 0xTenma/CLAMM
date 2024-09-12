// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./interfaces/IERC20.sol";
import "./lib/Tick.sol";
import "./lib/TickMath.sol";
import "./lib/Position.sol";
import "./lib/SafeCast.sol";

function checkTicks(int24 tickLower, int24 tickUpper) pure {
    require(tickLower < tickUpper);
    require(tickLower >= TickMath.MIN_TICK);
    require(tickUpper <= TickMath.MAX_TICK);

}
contract CLAMM {
    using SafeCast for int256;
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Tick for mapping(int24 => Tick.Info);

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    uint128 public immutable maxLiquidityPerTick;

    /**
     * tick, price, tickspacing
     * python code:
     * tick = -200697
     * p = 1.0001 ** tick
     * decimals_0 = 1e18
     * decimals_1 = 1e6
     *
     * p * decimals_0 / decimals_1 
     *
     * tickSpacing: number of ticks to skip when the price moves
     */

    struct Slot0 {
        uint160 sqrtPriceX96;
        int24 tick;
        bool unlocked;
    }

    Slot0 public slot0;
    mapping (bytes32 => Position.Info) public positions;
    mapping (int24 => Tick.Info) public ticks;
    
    modifier lock() {
        require(slot0.unlocked, "locked");
        slot0.unlocked = false;
        _ ;
        slot0.unlocked = true;
    }

    struct ModifyPositionParams {
        address owner;
        int24 tickLower;
        int24 tickUpper;
        int128 liquidityDelta;
    }

    constructor(address _token0, address _token1, uint24 _fee, int24 _tickSpacing) {
        token0 = _token0;
        token1 = _token1;
        fee = _fee;
        tickSpacing = _tickSpacing;

        maxLiquidityPerTick = Tick.tickSpacingToMaxLiquidityPerTick(_tickSpacing);
    }

    function initialize(uint160 sqrtPriceX96) external {
        require(slot0.sqrtPriceX96 == 0, "already initialized");
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            unlocked: true
        });
    }
    /*
    sqrt price 96:

    sqrt_price_x_96 = 3443439269043870780644209
    q = 2 ** 96
    p = (sqrt_price_x_96 / q) ** 2

    decimals_0 = 1e18;
    decimals_1 = 1e6;

    p * decimals_0 / decimals_1

    tick = 2 * math.log(sqrt_price / q) / math.log(1.0001)
    */
    function _updatePosition(
        address owner, 
        int24 tickLower,
        int24 tickUpper,
        int128 liquidityDelta,
        int24 tick
    ) private returns (Position.Info storage position) {
        position = positions.get(owner, tickLower, tickUpper);

        uint256 _feeGrowthGlobal0X128 = 0;
        uint256 _feeGrowthGlobal1X128 = 0;
        
        bool flippedLower;
        bool flippedUpper;

        if (liquidityDelta !=0) {
            flippedLower = ticks.update(
                tickLower,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                false,
                maxLiquidityPerTick
            );
            flippedUpper = ticks.update(
                tickUpper,
                tick,
                liquidityDelta,
                _feeGrowthGlobal0X128,
                _feeGrowthGlobal1X128,
                true,
                maxLiquidityPerTick
            );
        }


        position.update(liquidityDelta, 0, 0);

        if (liquidityDelta < 0) {
            if(flippedLower) {
                ticks.clear(tickLower);
            }
            if(flippedUpper) {
                ticks.clear(tickUpper);
            }
        }
    }

    function _modifyPosition(ModifyPositionParams memory params) private returns (Position.Info storage position, int256 amount0, int256 amount1) {
        checkTicks(params.tickLower, params.tickUpper);

        Slot0 memory _slot0 = slot0;
        _updatePosition(
            params.owner,
            params.tickLower,
            params.tickUpper, 
            params.liquidityDelta,
            _slot0.tick
        );

        return (positions[bytes32(0)], 0, 0);
    }

    function mint(
        address recipient, 
        int24 tickLower,
        int24 tickUpper,
        uint128 amount
    ) external lock returns (uint256 amount0, uint256 amount1) {
        require(amount > 0, "amount is zero");

        (, int256 amount0Int, int256 amount1Int) = 
            _modifyPosition(
                ModifyPositionParams({
                    owner: recipient,
                    tickLower: tickLower,
                    tickUpper: tickUpper,
                    liquidityDelta: int256(uint256(amount)).toInt128()
            })
        );

        amount0 = uint256(amount0Int);
        amount1 = uint256(amount1Int);

        if (amount0 > 0 ) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0 ) {
            IERC20(token0).transferFrom(msg.sender, address(this), amount1);
        }
    }
}

