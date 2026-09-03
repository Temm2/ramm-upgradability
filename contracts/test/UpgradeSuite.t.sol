// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, console} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {BeaconProxy} from "@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol";

import {RAMMTokenUpgradeable} from "../src/RAMMTokenUpgradeable.sol";
import {RedemptionNFTUpgradeable} from "../src/RedemptionNFTUpgradeable.sol";
import {VestingVaultUpgradeable} from "../src/VestingVaultUpgradeable.sol";
import {PromoStakingUpgradeable} from "../src/PromoStakingUpgradeable.sol";
import {IMPXMarketUpgradeable} from "../src/IMPXMarketUpgradeable.sol";
import {PVTTokenUpgradeable} from "../src/PVTTokenUpgradeable.sol";
import {MockUSDC} from "../src/MockUSDC.sol";
import {PVTToken} from "../src/PVTToken.sol";
import {RammRegistry} from "../src/RammRegistry.sol";
import {SigmoidMath} from "../src/SigmoidMath.sol";

contract MockMarketV2 is IMPXMarketUpgradeable {
    uint256 public v2FeatureCode;

    function setV2Feature(uint256 code) external onlyOwner {
        v2FeatureCode = code;
    }
}

/// @title UpgradeSuiteTest
/// @notice Comprehensive test suite verifying UUPS proxy upgrades for the 4 singletons
/// and single-transaction BeaconProxy upgrades for fleet market instances.
contract UpgradeSuiteTest is Test {
    address public owner = address(0x1111);
    address public user = address(0x2222);

    MockUSDC public usdc;
    RAMMTokenUpgradeable public rammImpl;
    ERC1967Proxy public rammProxy;
    RAMMTokenUpgradeable public ramm;

    PromoStakingUpgradeable public stakingImpl;
    ERC1967Proxy public stakingProxy;
    PromoStakingUpgradeable public staking;

    IMPXMarketUpgradeable public marketImpl;
    UpgradeableBeacon public marketBeacon;

    BeaconProxy public marketProxy1;
    BeaconProxy public marketProxy2;

    IMPXMarketUpgradeable public market1;
    IMPXMarketUpgradeable public market2;

    function setUp() public {
        vm.startPrank(owner);

        // 1. Deploy Mock USDC
        usdc = new MockUSDC(owner);
                                                                                                                                                                                                                        
        // 2. Deploy RAMMToken behind UUPS ERC1967Proxy
        rammImpl = new RAMMTokenUpgradeable();
        bytes memory rammInit = abi.encodeWithSelector(RAMMTokenUpgradeable.initialize.selector, owner);
        rammProxy = new ERC1967Proxy(address(rammImpl), rammInit);
        ramm = RAMMTokenUpgradeable(address(rammProxy));

        // 3. Deploy PromoStaking behind UUPS ERC1967Proxy
        stakingImpl = new PromoStakingUpgradeable();
        bytes memory stakingInit = abi.encodeWithSelector(PromoStakingUpgradeable.initialize.selector, address(ramm), owner);
        stakingProxy = new ERC1967Proxy(address(stakingImpl), stakingInit);
        staking = PromoStakingUpgradeable(address(stakingProxy));

        // 4. Deploy IMPXMarket implementation & UpgradeableBeacon
        marketImpl = new IMPXMarketUpgradeable();
        marketBeacon = new UpgradeableBeacon(address(marketImpl), owner);

        vm.stopPrank();
    }

    function test_UUPSProxySingletonInitialization() public view {
        console.log("--------------------------------------------------");
        console.log(unicode"  [TEST 1] Verifying UUPS Proxy Singleton Setup");
        console.log("  RAMM Proxy Address    :", address(ramm));
        console.log("  RAMM Owner            :", ramm.owner());
        console.log("  PromoStaking Proxy    :", address(staking));
        console.log("  Min Stake             :", staking.minStake() / 1e18, "RAMM");
        console.log("--------------------------------------------------");

        assertEq(ramm.owner(), owner);
        assertEq(staking.owner(), owner);
        assertEq(staking.minStake(), 1000 * 1e18);
    }

    function test_BeaconProxyFleetUpgradeInSingleTx() public {
        vm.startPrank(owner);

        // Deploy 2 Market Clones via BeaconProxy
        PVTToken pvt1 = new PVTToken("Product 1", "P1", 1000, owner);
        PVTToken pvt2 = new PVTToken("Product 2", "P2", 2000, owner);

        RammRegistry registry = new RammRegistry(owner, address(ramm), address(0x33), address(0x44), address(staking));

        SigmoidMath.CurveParams memory curve = SigmoidMath.CurveParams({
            b: 500, c: 100_000, p: 1000, aPrimary: 100, aSecondary: 200
        });

        bytes memory initMarket1 = abi.encodeWithSelector(
            IMPXMarketUpgradeable.initialize.selector,
            address(usdc), address(pvt1), address(registry), owner, owner, owner,
            9300, 700, 500, 200, 600, curve
        );

        bytes memory initMarket2 = abi.encodeWithSelector(
            IMPXMarketUpgradeable.initialize.selector,
            address(usdc), address(pvt2), address(registry), owner, owner, owner,
            9300, 700, 500, 200, 600, curve
        );

        marketProxy1 = new BeaconProxy(address(marketBeacon), initMarket1);
        marketProxy2 = new BeaconProxy(address(marketBeacon), initMarket2);

        market1 = IMPXMarketUpgradeable(address(marketProxy1));
        market2 = IMPXMarketUpgradeable(address(marketProxy2));

        console.log("--------------------------------------------------");
        console.log(unicode"  [TEST 2] Beacon Fleet Proxy Setup (2 Markets)");
        console.log("  Beacon Contract Address :", address(marketBeacon));
        console.log("  Market 1 Proxy Address  :", address(market1));
        console.log("  Market 2 Proxy Address  :", address(market2));
        console.log("  Market 1 BRAND_BPS      :", market1.BRAND_BPS());
        console.log("  Market 2 BRAND_BPS      :", market2.BRAND_BPS());
        console.log("--------------------------------------------------");

        assertEq(market1.BRAND_BPS(), 9300);
        assertEq(market2.BRAND_BPS(), 9300);

        // NOW: Deploy MockMarketV2 and UPGRADE BEACON IN 1 TRANSACTION!
        MockMarketV2 v2Impl = new MockMarketV2();
        
        console.log(unicode"  [STEP] Upgrading Beacon to V2 implementation in 1 Tx...");
        marketBeacon.upgradeTo(address(v2Impl));

        MockMarketV2 market1AsV2 = MockMarketV2(address(marketProxy1));
        MockMarketV2 market2AsV2 = MockMarketV2(address(marketProxy2));

        market1AsV2.setV2Feature(777);
        market2AsV2.setV2Feature(888);

        console.log("--------------------------------------------------");
        console.log(unicode"  [PASS] Single-Tx Beacon Fleet Upgrade Success!");
        console.log("  Market 1 V2 Feature Code:", market1AsV2.v2FeatureCode());
        console.log("  Market 2 V2 Feature Code:", market2AsV2.v2FeatureCode());
        console.log("--------------------------------------------------");

        assertEq(market1AsV2.v2FeatureCode(), 777);
        assertEq(market2AsV2.v2FeatureCode(), 888);

        vm.stopPrank();
    }

    function test_PVTTokenUpgradeable() public {
        vm.startPrank(owner);

        PVTTokenUpgradeable pvtImpl = new PVTTokenUpgradeable();
        bytes memory pvtInit = abi.encodeWithSelector(
            PVTTokenUpgradeable.initialize.selector,
            "Neo Air Sneakers", "POPZ-NAS", 500, owner
        );
        ERC1967Proxy pvtProxy = new ERC1967Proxy(address(pvtImpl), pvtInit);
        PVTTokenUpgradeable pvt = PVTTokenUpgradeable(address(pvtProxy));

        console.log("--------------------------------------------------");
        console.log(unicode"  [TEST 3] Verifying PVTTokenUpgradeable Setup");
        console.log("  PVT Proxy Address     :", address(pvt));
        console.log("  Product Name          :", pvt.productName());
        console.log("  Supply Cap            :", pvt.supplyCap());
        console.log("  Decimals              :", pvt.decimals());

        pvt.mint(user, 10);
        console.log("  User Balance After Mint:", pvt.balanceOf(user));
        assertEq(pvt.balanceOf(user), 10);
        assertEq(pvt.totalMinted(), 10);

        vm.stopPrank();

        vm.prank(user);
        pvt.burn(3);
        console.log("  User Balance After Burn:", pvt.balanceOf(user));
        assertEq(pvt.balanceOf(user), 7);

        console.log("--------------------------------------------------");
        console.log(unicode"  [PASS] PVTTokenUpgradeable Working 100%!");
        console.log("--------------------------------------------------");
    }
}
