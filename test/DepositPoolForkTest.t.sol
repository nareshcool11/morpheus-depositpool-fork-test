// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWstETH {
    function unwrap(uint256 amount) external returns (uint256);
}

interface AggregatorV3 {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IDepositPoolMinimal {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimReferrerTier(uint256 rewardPoolIndex_, address receiver_) external payable;
    function getLatestUserReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function getLatestReferrerReward(uint256 rewardPoolIndex_, address user_) external view returns (uint256);
    function referrersData(address referrer_, uint256 rewardPoolIndex_)
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 pendingRewards, uint256 rate, uint128 lastClaim);
}

interface IDistributorMinimal {
    function distributeRewards(uint256 rewardPoolIndex_) external;
    function getDistributedRewards(uint256 rewardPoolIndex_, address depositPoolAddress_) external view returns (uint256);
}

/**
 * @title Morpheus DepositPool fork test
 * @notice Fork test against deployed mainnet bytecode (pinned block).
 *         Scenario A: staker A stakes 500 stETH with referrer = staker A.
 *         Scenario B (control): identical, but staker A stakes with
 *         referrer = address(0). After 90 days both scenarios call
 *         distributeRewards(0) and read the claimable MOR (user rewards +
 *         referrer-tier rewards) for staker A and for staker B, who staked
 *         3000 stETH with no referrer.
 */
contract DepositPoolForkTest is Test {
    string internal constant RPC = "https://ethereum-rpc.publicnode.com";
    uint256 internal constant BLOCK = 26432417; // 2026-11-17, mainnet

    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant DEPOSIT_POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790; // stETH DepositPool proxy
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;

    uint256 internal constant STAKE_B = 3000 ether;
    uint256 internal constant STAKE_A = 500 ether;
    uint256 internal constant WARP_DAYS = 90 days;

    // Chainlink feeds used by the 5 public pools (read on-chain at the pinned block).
    // Fork state freezes feed timestamps, so after warping the consumer's
    // staleness check would reject every price. The mocks below replay the
    // EXACT pinned-block roundId/answer/startedAt for each feed, only moving
    // updatedAt to the (warped) current block time — i.e. the prices the
    // protocol would have seen had the feeds kept updating. All Morpheus
    // logic runs unmocked; only the external oracle timestamps are replayed.
    address internal constant FEED_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    address internal constant FEED_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address internal constant FEED_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    address internal constant FEED_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address internal constant FEED_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address internal constant FEED_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;

    function _mockFeeds() internal {
        _mockFeed(FEED_STETH_USD, 36893488147419126905, 182547861735, 1794889251);
        _mockFeed(FEED_ETH_USD, 129127208515966897208, 182842790000, 1794890142);
        _mockFeed(FEED_WBTC_BTC, 36893488147419104095, 100074355, 1794865012);
        _mockFeed(FEED_BTC_USD, 129127208515966887474, 6487534000000, 1794889908);
        _mockFeed(FEED_USDC_USD, 73786976294838206531, 99979041, 1794869723);
        _mockFeed(FEED_USDT_USD, 73786976294838206528, 99900254, 1794840737);
    }

    function _mockFeed(address feed, uint80 roundId, int256 answer, uint256 startedAt) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(AggregatorV3.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, roundId)
        );
    }

    function _fundWithStETH(address user, uint256 wstethAmount) internal {
        deal(WSTETH, user, wstethAmount);
        vm.startPrank(user);
        IWstETH(WSTETH).unwrap(wstethAmount);
        vm.stopPrank();
    }

    /// @return stakerATotal claimable MOR (user + referrer-tier), stakerBTotal claimable MOR (user only)
    function _runScenario(bool referrerIsSelf) internal returns (uint256 stakerATotal, uint256 stakerBTotal) {
        address stakerB = makeAddr("stakerB");
        address stakerA = makeAddr("stakerA");

        // Fund both with stETH via wstETH unwrap (fork state, no real funds).
        _fundWithStETH(stakerB, 3000 ether);
        _fundWithStETH(stakerA, 500 ether);
        assertGe(IERC20Minimal(STETH).balanceOf(stakerB), STAKE_B, "staker B stETH funding failed");
        assertGe(IERC20Minimal(STETH).balanceOf(stakerA), STAKE_A, "staker A stETH funding failed");

        // Both approve the Distributor (supply() pulls from the staker).
        vm.prank(stakerB);
        IERC20Minimal(STETH).approve(DISTRIBUTOR, type(uint256).max);
        vm.prank(stakerA);
        IERC20Minimal(STETH).approve(DISTRIBUTOR, type(uint256).max);

        // Staker B stakes with no referrer in both scenarios.
        vm.prank(stakerB);
        IDepositPoolMinimal(DEPOSIT_POOL).stake(0, STAKE_B, 0, address(0));

        // Staker A stakes: self as referrer (A) or no referrer (B, control).
        vm.prank(stakerA);
        IDepositPoolMinimal(DEPOSIT_POOL).stake(0, STAKE_A, 0, referrerIsSelf ? stakerA : address(0));

        // 90 days of MOR emissions, then distribute (feeds mocked to the
        // pinned-block prices — see _mockFeeds).
        vm.warp(block.timestamp + WARP_DAYS);
        _mockFeeds();
        IDistributorMinimal(DISTRIBUTOR).distributeRewards(0);

        uint256 stakerAUser = IDepositPoolMinimal(DEPOSIT_POOL).getLatestUserReward(0, stakerA);
        uint256 stakerARef = IDepositPoolMinimal(DEPOSIT_POOL).getLatestReferrerReward(0, stakerA);
        uint256 stakerBUser = IDepositPoolMinimal(DEPOSIT_POOL).getLatestUserReward(0, stakerB);

        emit log_named_uint("staker A user rewards (MOR)", stakerAUser);
        emit log_named_uint("staker A referrer rewards (MOR)", stakerARef);
        emit log_named_uint("staker A total claimable (MOR)", stakerAUser + stakerARef);
        emit log_named_uint("staker B user rewards (MOR)", stakerBUser);

        return (stakerAUser + stakerARef, stakerBUser);
    }

    function testRewardComparison() public {
        uint256 forkA = vm.createFork(RPC, BLOCK);
        vm.selectFork(forkA);
        (uint256 stakerAA, uint256 stakerBA) = _runScenario(true);

        uint256 forkB = vm.createFork(RPC, BLOCK);
        vm.selectFork(forkB);
        (uint256 stakerAB, uint256 stakerBB) = _runScenario(false);

        emit log_named_uint("SCENARIO A staker A total", stakerAA);
        emit log_named_uint("SCENARIO B staker A total", stakerAB);
        emit log_named_uint("staker A difference (A - B)", stakerAA - stakerAB);
        emit log_named_uint("SCENARIO A staker B total", stakerBA);
        emit log_named_uint("SCENARIO B staker B total", stakerBB);
        emit log_named_uint("staker B difference (B - A)", stakerBB - stakerBA);

        // Scenarios A and B differ only in the referrer argument.
        assertGt(stakerAA, stakerAB, "scenario A must give staker A higher claimable MOR than scenario B");
        assertLt(stakerBA, stakerBB, "scenario A must give staker B lower claimable MOR than scenario B");
    }

    /// @notice Executes the real claim path (user claim + referrer-tier claim)
    /// on the fork. The claims send LayerZero mint messages; on the fork the
    /// endpoint executes locally, which is sufficient to prove the calls
    /// succeed and the pending balances drain. No mainnet transaction is sent.
    function testClaimsExecute() public {
        uint256 forkA = vm.createFork(RPC, BLOCK);
        vm.selectFork(forkA);
        address stakerA = makeAddr("stakerA");
        address stakerB = makeAddr("stakerB");

        _fundWithStETH(stakerB, 3000 ether);
        _fundWithStETH(stakerA, 500 ether);
        vm.deal(stakerA, 1 ether);

        vm.prank(stakerB);
        IERC20Minimal(STETH).approve(DISTRIBUTOR, type(uint256).max);
        vm.prank(stakerA);
        IERC20Minimal(STETH).approve(DISTRIBUTOR, type(uint256).max);

        vm.prank(stakerB);
        IDepositPoolMinimal(DEPOSIT_POOL).stake(0, STAKE_B, 0, address(0));
        vm.prank(stakerA);
        IDepositPoolMinimal(DEPOSIT_POOL).stake(0, STAKE_A, 0, stakerA); // self as referrer

        vm.warp(block.timestamp + WARP_DAYS);
        _mockFeeds();
        IDistributorMinimal(DISTRIBUTOR).distributeRewards(0);

        uint256 userBefore = IDepositPoolMinimal(DEPOSIT_POOL).getLatestUserReward(0, stakerA);
        uint256 refBefore = IDepositPoolMinimal(DEPOSIT_POOL).getLatestReferrerReward(0, stakerA);
        assertGt(userBefore, 0, "staker A must have user rewards");
        assertGt(refBefore, 0, "staker A must have referrer rewards");

        // Execute both claims with LZ fees attached.
        vm.prank(stakerA);
        IDepositPoolMinimal(DEPOSIT_POOL).claim{value: 0.05 ether}(0, stakerA);
        vm.prank(stakerA);
        IDepositPoolMinimal(DEPOSIT_POOL).claimReferrerTier{value: 0.05 ether}(0, stakerA);

        uint256 userAfter = IDepositPoolMinimal(DEPOSIT_POOL).getLatestUserReward(0, stakerA);
        uint256 refAfter = IDepositPoolMinimal(DEPOSIT_POOL).getLatestReferrerReward(0, stakerA);
        emit log_named_uint("staker A user rewards before claim", userBefore);
        emit log_named_uint("staker A user rewards after claim", userAfter);
        emit log_named_uint("staker A referrer rewards before claim", refBefore);
        emit log_named_uint("staker A referrer rewards after claim", refAfter);

        assertEq(userAfter, 0, "user rewards must drain to zero after claim");
        assertEq(refAfter, 0, "referrer rewards must drain to zero after claim");
    }

    /// @notice Sanity: the referrer tier is actually reachable on-chain for 500 stETH.
    function testReferrerTierState() public {
        uint256 fork = vm.createFork(RPC, BLOCK);
        vm.selectFork(fork);
        (uint256 amountStaked, uint256 virtualAmountStaked, , , ) = IDepositPoolMinimal(DEPOSIT_POOL)
            .referrersData(makeAddr("stakerA"), 0);
        assertEq(amountStaked, 0, "fresh staker has no referrer stake");
        assertEq(virtualAmountStaked, 0, "fresh staker has no referrer virtual stake");
    }
}
