// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// internal & private view & pure functions
// external & public view & pure functions

// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

/*

 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */
contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////
    error DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenNotAllowed(address token);
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactorValue);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////////
    // Types
    ///////////////////
    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////
    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant FEED_PRECISION = 1e8;

    /// @dev Mapping of token address to price feed address
    mapping(address collateralToken => address priceFeed) private s_priceFeeds;
    /// @dev Amount of collateral deposited by user
    mapping(address user => mapping(address collateralToken => uint256 amount))
        private s_collateralDeposited;
    /// @dev Amount of DSC minted by user
    mapping(address user => uint256 amount) private s_DSCMinted;
    /// @dev If we know exactly how many tokens we have, we could make this immutable!
    address[] private s_collateralTokens;

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(
        address indexed user,
        address indexed token,
        uint256 indexed amount
    );
    event CollateralRedeemed(
        address indexed redeemFrom,
        address indexed redeemTo,
        address token,
        uint256 amount
    ); // if redeemFrom != redeemedTo, then it was liquidated

    ///////////////////
    // Modifiers
    ///////////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__TokenNotAllowed(token);
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////
    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch();
        }
        // These feeds will be the USD pairs
        // For example ETH / USD or MKR / USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////
    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToMint: The amount of DSC you want to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     * @param amountDscToBurn: The amount of DSC you want to burn
     * @notice This function will withdraw your collateral and burn DSC in one transaction
     */
    function redeemCollateralForDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToBurn
    )
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
    {
        _burnDsc(amountDscToBurn, msg.sender, msg.sender);
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     */
    function redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        external
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        _redeemCollateral(
            tokenCollateralAddress,
            amountCollateral,
            msg.sender,
            msg.sender
        );
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /*
     * @notice careful! You'll burn your DSC here! Make sure you want to do this...
     * @dev you might want to use this if you're nervous you might get liquidated and want to just burn
     * you DSC but keep your collateral in.
     */
    function burnDsc(uint256 amount) external moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit...
    }

    /*
     * @param collateral: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(
        address collateral,
        address user,
        uint256 debtToCover
    ) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        // If covering 100 DSC, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(
            collateral,
            debtToCover
        );
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered *
            LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn DSC equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        _redeemCollateral(
            collateral,
            tokenAmountFromDebtCovered + bonusCollateral,
            user,
            msg.sender
        );
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        revertIfHealthFactorIsBroken(msg.sender);
    }

    ///////////////////
    // Public Functions
    ///////////////////
    /*
     * @param amountDscToMint: The amount of DSC you want to mint
     * You can only mint DSC if you hav enough collateral
     */
    function mintDsc(
        uint256 amountDscToMint
    ) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);

        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }

    /*
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're depositing
     * @param amountCollateral: The amount of collateral you're depositing
     */
    function depositCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral
    )
        public
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][
            tokenCollateralAddress
        ] += amountCollateral;
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    ///////////////////
    // Private Functions
    ///////////////////
    function _redeemCollateral(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        address from,
        address to
    ) private {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(
            from,
            to,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success = IERC20(tokenCollateralAddress).transfer(
            to,
            amountCollateral
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _burnDsc(
        uint256 amountDscToBurn,
        address onBehalfOf,
        address dscFrom
    ) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;

        bool success = i_dsc.transferFrom(
            dscFrom,
            address(this),
            amountDscToBurn
        );
        // This conditional is hypothetically unreachable
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

    function _getAccountInformation(
        address user
    )
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _getUsdValue(
        address token,
        uint256 amount
    ) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return
            ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) internal pure returns (uint256) {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd *
            LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////
    function calculateHealthFactor(
        uint256 totalDscMinted,
        uint256 collateralValueInUsd
    ) external pure returns (uint256) {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getAccountInformation(
        address user
    )
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        return _getAccountInformation(user);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    function getCollateralBalanceOfUser(
        address user,
        address token
    ) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(
        address user
    ) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getTokenAmountFromUsd(
        address token,
        uint256 usdAmountInWei
    ) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(
            s_priceFeeds[token]
        );
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) /
            (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(
        address token
    ) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }











    ///////////////////
    // NEW FUNCTIONS //
    ///////////////////

    uint256 public constant YEAR = 31536000;
    uint256 private constant MONTH = 2628000;
    uint256 private constant DAY = 86400;
    uint256 private constant HOUR = 3600;
    uint256 public constant MINUTE = 60;
    
    address private weth = 0xdd13E55209Fd76AfE204dBda4007C227904f0a81;

    mapping(address user => uint256 amountWEther) private s_WEtherSaved;
    mapping(address user => uint256 endTimeSaved) private s_endTimeSaved; // 1 tk chi duoc gui 1 lan
    mapping(address user =>  uint256 InterestingRate) private s_InterestingRate;
    mapping(address user => uint256 amountDSCMintForSaving) private s_DSCMintedForInterest;

    // mapping for borrowing
    mapping(address user => uint256 amount) private s_WEtherBorrowed;
    mapping(address user => uint256 endTimeBorrowed) private s_endTimeBorrowed; 
    mapping(address user => uint256 BorrowingFee) private s_BorrowingFee;
    mapping(address user => mapping(address collateralToken => uint256 amount)) private s_collateralDepositedForBorrowEther;

    uint256 private totalAmountWEtherSaving = 0;
    uint256 private totalAmountWEtherBorrowing = 0;

    // gui tai san tiet kiem 
    function savingWEther(
        uint256 amount
    )
        private
        moreThanZero(amount)
        nonReentrant
        isAllowedToken(weth)
    {
        s_WEtherSaved[msg.sender] += amount;

        totalAmountWEtherSaving += amount;

        s_InterestingRate[msg.sender] = _calculateInterestingRate();

        emit CollateralDeposited(msg.sender, weth, amount);
        bool success = IERC20(weth).transferFrom(
            msg.sender,
            address(this),
            amount
        );
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // lay lai tai san tiet kiem private
    function redeemSavedWEther(
        uint256 amount
    )
        private
        moreThanZero(amount)
        nonReentrant
        isAllowedToken(weth)
    {
        s_WEtherSaved[msg.sender] -= amount;
        totalAmountWEtherSaving -= amount;
        emit CollateralRedeemed(
            msg.sender,
            msg.sender,
            weth,
            amount
        );
        bool success = IERC20(weth).transfer(msg.sender,amount);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    // mint private
    function mintDSCForInterest(uint256 amount) private {  //khong can ham revertIfHealthFactorIsBroken
        s_DSCMintedForInterest[msg.sender] += amount;
        bool minted = i_dsc.mint(msg.sender, amount);
        if (minted != true) {
            revert DSCEngine__MintFailed();
        }
    }
    /////////////////////////////////////////////////////////////////////////////////////////
    function savingWEtherFor_1_Year(
        uint256 amount
    ) external {
        s_endTimeSaved[msg.sender] = block.timestamp + YEAR;
        
        savingWEther(amount);
    }

    function savingWEtherFor_1_Minute(
        uint256 amount
    ) external {
        s_endTimeSaved[msg.sender]= block.timestamp + MINUTE;

        savingWEther(amount);
    }
    /////////////////////////////////////////////////////////////////////////////////////////
    function redeemSavedWEtherAfter_1_Year(
        uint256 amount
    )
        private
        moreThanZero(amount)
        nonReentrant
        isAllowedToken(weth)
    {
        require(block.timestamp >= s_endTimeSaved[msg.sender],"DSCEngine: Cannot redeem before 1 year");
        redeemSavedWEther(amount);
    }

    /////////////////////////////////////////////////////////////////////////////////////////
    function redeemSavedWEtherAfter_1_YearAndMintDscForInterest(uint256 amount) 
        external
        moreThanZero(amount)
        isAllowedToken(weth)
    {
        uint256 R = s_InterestingRate[msg.sender];
        redeemSavedWEtherAfter_1_Year(amount);
        mintDSCForInterest((_getUsdValue(weth, amount)) * R / (1000*100)); // get 5% for interest in DSC after 1 year
    } 

    function redeemSavedWEtherAfter_1_MinuteAndMintDscForInterest(uint256 amount) 
        external
        moreThanZero(amount)
        isAllowedToken(weth)
    {   
        uint256 R = s_InterestingRate[msg.sender];
        require(block.timestamp >= s_endTimeSaved[msg.sender],"DSCEngine: Cannot redeem before 1 minute");
        redeemSavedWEther(amount);
        mintDSCForInterest((_getUsdValue(weth, amount)) * R / (1000*100)); // get 5% for interest in DSC after 1 minute
    }
    /////////////////////////////////////////////////////////////////////////////////////////

    //lay lai 1 phan tai san dat coc truoc hop dong private
    function _redeemPartOfCollateralAndReturnWEther(
        address tokenCollateralAddress, uint256 amountCollateral, uint256 amountWEther, address from, address to
        )
        private
        moreThanZero(amountCollateral)
        nonReentrant
        isAllowedToken(weth)
    {
        s_WEtherBorrowed[from] -= amountWEther;
        emit CollateralRedeemed(from,to,tokenCollateralAddress, amountCollateral);
        s_collateralDepositedForBorrowEther[from][tokenCollateralAddress] -= amountCollateral;

        totalAmountWEtherBorrowing -= amountWEther;

        revertIfHealthFactorForBorrowWEtherIsBroken(to);
        bool successWEther = IERC20(weth).transferFrom(from, address(this), amountWEther); 
        if (!successWEther) {
            revert DSCEngine__TransferFailed();
        }
        bool successCollateral = IERC20(tokenCollateralAddress).transfer(to,amountCollateral);
        if (!successCollateral) {
            revert DSCEngine__TransferFailed();
        }
    }
    
    //lay lai full collateral
    function _redeemAllCollateralAndReturnWEtherAfterExpired(address tokenCollateralAddress, uint256 timeExpired, uint256 borrowTime) 
    private 
    {   // timeExpired: thoi gian bay gio - thoi gian het han
        // borrowTime: thoi gian hop dong vay, vd: 1 minute, 1 year
        uint256 startCollateral = s_collateralDepositedForBorrowEther[msg.sender][tokenCollateralAddress];
        uint256 periodNumber = (timeExpired/borrowTime) + 1;
        uint256 endCollateral;

        // 17% is highest borrow fee rate
        if (periodNumber == 1) {
            endCollateral = (startCollateral * 87) / 100; //84% of startCollateral. 
        }
        if (periodNumber == 2) {
            endCollateral = (startCollateral * 87 * 87) / (100 * 100); //71% of startCollateral
        }
        if (periodNumber == 3) {
            endCollateral = (startCollateral * 87 * 87 * 87) / (100 * 100 * 100); //61% of startCollateral
        }
        if (periodNumber == 4) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100); //53% of startCollateral
        }
        if (periodNumber == 5) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100 * 100); //46% of startCollateral
        }
        if (periodNumber == 6) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100 * 100 * 100); //41% of startCollateral
        }
        if (periodNumber == 7) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100 * 100 * 100 * 100); //37% of startCollateral
        }
        if (periodNumber == 8) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87 * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100 * 100 * 100 * 100 * 100); //34% of startCollateral
        }
        if (periodNumber == 9) {
            endCollateral = (startCollateral * 87 * 87 * 87 * 87 * 87 * 87 * 87 * 87 * 87) / (100 * 100 * 100 * 100 * 100 * 100 * 100 * 100 * 100); //31% of startCollateral
        }
        if (periodNumber > 10) {
            endCollateral = 0;
        }
        
        uint256 amountWEther = s_WEtherBorrowed[msg.sender];
        bool successWEther = IERC20(weth).transferFrom(msg.sender, address(this), amountWEther); 
        if (!successWEther) {
            revert DSCEngine__TransferFailed();
        }
        bool successCollateral = IERC20(tokenCollateralAddress).transfer(msg.sender,endCollateral);
        if (!successCollateral) {
            revert DSCEngine__TransferFailed();
        }
        s_collateralDepositedForBorrowEther[msg.sender][tokenCollateralAddress] = 0;
        s_WEtherBorrowed[msg.sender] = 0;
    }


    // dat coc va vay tien private
    function _depositCollateralAndBorrowWEther (
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountWEther
    ) private
    {
        require(amountWEther < totalAmountWEtherSaving * 100 / 90, "DSCEngine: Not enough WEther in saving");

        uint256 interestingRate = _calculateInterestingRate();
        uint256 Fee = (interestingRate * (100000 + interestingRate)) / (1000*100);
        s_BorrowingFee[msg.sender] = Fee;

        s_WEtherBorrowed[msg.sender] += (amountWEther * (100000-Fee)) / (100*1000); //94% of amountWEther
        s_collateralDepositedForBorrowEther[msg.sender][tokenCollateralAddress] += amountCollateral;

        totalAmountWEtherBorrowing += (amountWEther * (100000-Fee)) / (100*1000);

        revertIfHealthFactorForBorrowWEtherIsBroken(msg.sender); //check health factor
        //deposit collateral
        emit CollateralDeposited(
            msg.sender,
            tokenCollateralAddress,
            amountCollateral
        );
        bool success_deposit = IERC20(tokenCollateralAddress).transferFrom(
            msg.sender,
            address(this),
            amountCollateral
        );
        if (!success_deposit) {
            revert DSCEngine__TransferFailed();
        }
        revertIfHealthFactorIsBroken(msg.sender);
        bool success_borrow = IERC20(weth).transfer(msg.sender, (amountWEther * 94) / 100); //
        if (!success_borrow) {
            revert DSCEngine__TransferFailed();
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////
    function depositCollateralAndBorrowWEther_1_Year(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountWEther
    ) external {
        s_endTimeBorrowed[msg.sender] = block.timestamp + YEAR;
        _depositCollateralAndBorrowWEther(tokenCollateralAddress, amountCollateral, amountWEther);
    }

    function depositCollateralAndBorrowWEther_1_Minute(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountWEther
    ) external {
        s_endTimeBorrowed[msg.sender] = block.timestamp + MINUTE;
        _depositCollateralAndBorrowWEther(tokenCollateralAddress, amountCollateral, amountWEther);
    }
    ///////////////////////////////////////////////////////////////////////////////////////////////////////

    function redeemAllCollateralAndReturnWEtherAfter_1_Year(
        address tokenCollateralAddress 
    ) external {
        require (block.timestamp >= s_endTimeBorrowed[msg.sender],"DSCEngine: Cannot redeem before 1 year");
        uint256 timeExpired = block.timestamp - s_endTimeBorrowed[msg.sender];
        
        _redeemAllCollateralAndReturnWEtherAfterExpired(tokenCollateralAddress, timeExpired, YEAR);(tokenCollateralAddress);
    }

    // 
    function redeemAllCollateralAndReturnWEtherAfter_1_Minute(
        address tokenCollateralAddress 
    ) external {
        require (block.timestamp > s_endTimeBorrowed[msg.sender],"DSCEngine: Cannot redeem before 1 minute");
        uint256 timeExpired = block.timestamp - s_endTimeBorrowed[msg.sender];
        _redeemAllCollateralAndReturnWEtherAfterExpired(tokenCollateralAddress, timeExpired, MINUTE);(tokenCollateralAddress);
    }

    function redeemCollateralAndReturnWEtherBefore_1_Year(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountWEther
    ) external {
        require (block.timestamp <= s_endTimeBorrowed[msg.sender],"DSCEngine: Cannot redeem by this method after 1 year");
        _redeemPartOfCollateralAndReturnWEther(tokenCollateralAddress, amountCollateral, amountWEther, msg.sender, msg.sender);
    }

    function redeemCollateralAndReturnWEtherBefore_1_Minute(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountWEther
    ) external {
        require (block.timestamp <= s_endTimeBorrowed[msg.sender],"DSCEngine: Cannot redeem by this method after 1 minute");
        _redeemPartOfCollateralAndReturnWEther(tokenCollateralAddress, amountCollateral, amountWEther, msg.sender, msg.sender);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////////

    function liquidateForBorrowedWEther (address tokenCollateralDeposited, address user ) 
    external
    nonReentrant
    {
        uint256 startingUserHealthFactor = _healthFactorForBorrowWEther(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorOk();
        }
        uint256 timeExpired = 0;
        _redeemAllCollateralAndReturnWEtherAfterExpired(tokenCollateralDeposited, timeExpired, YEAR);

    } 









    function _balanceOfWEtherInContract() internal view returns (uint256) {
        return IERC20(weth).balanceOf(address(this));
    }

    function getBalanceOfWEtherInContract() external view returns (uint256) {
        return _balanceOfWEtherInContract();
    }

    // function getEndTimeSaved(address user) external view returns (uint256) {
    //     return s_endTimeSaved[user];
    // }

    function _getAccountInformationForBorrowEtherInUsd(address user)
        private
        view
        returns (uint256 EtherBorrowingInUsd, uint256 collateralValueInUsd)
    {
        EtherBorrowingInUsd = getWEtherBorrowedInUsd(user);
        collateralValueInUsd = getAccountCollateralValueForBorrowEther(user);
    }

    function getAccountCollateralValueForBorrowEther(address user)
        public
        view
        returns (uint256 totalCollateralValueInUsd)
    {
        for (uint256 index = 0; index < s_collateralTokens.length; index++) {
            address token = s_collateralTokens[index];
            uint256 amount = s_collateralDepositedForBorrowEther[user][token];
            totalCollateralValueInUsd += _getUsdValue(token, amount);
        }
    }

    function getWEtherBorrowedInUsd(address user) public view returns (uint256) {
        return _getUsdValue(weth, s_WEtherBorrowed[user]);
    }

    function _healthFactorForBorrowWEther(address user) private view returns (uint256) {
        (uint256 EtherBorrowingInUsd, uint256 collateralValueInUsd) = _getAccountInformationForBorrowEtherInUsd(user);
        return _calculateHealthFactor(EtherBorrowingInUsd, collateralValueInUsd); //Ti le la 1:2. Deposit 2$ thi co the vay 1$
        // Neu deposit 2$, vay 1$ thi health factor = 1 * 1e18 (= 2 * 50/100 / 1)
    }

    function revertIfHealthFactorForBorrowWEtherIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactorForBorrowWEther(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) { //Min health factor = 1e18
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    function getHealthFactorForBorrowWEther(address user) external view returns (uint256) {
        return _healthFactorForBorrowWEther(user);
    }






    /////////////////////////////////////////////////////////////////////////////////////////
    function getEndTimeBorrowed(address user) external view returns (uint256) {
        return s_endTimeBorrowed[user];
    }

    function getWEtherBorrowed(address user) external view returns (uint256) {
        return s_WEtherBorrowed[user];
    }

    function getCollateralDepositedForBorrowEther(address user, address token) external view returns (uint256) {
        return s_collateralDepositedForBorrowEther[user][token];
    }

    function getDSCMintedForInterest(address user) external view returns (uint256) {
        return s_DSCMintedForInterest[user];
    }

    function getWEtherSaved(address user) external view returns (uint256) {
        return s_WEtherSaved[user];
    }

    function getEndTimeSaved(address user) external view returns (uint256) {
        return s_endTimeSaved[user];
    }

    









    ///////////////////////////////////////
    /// Saving rate and Borrowing Fee   ///
    //////////////////////////////////////

    uint256 private constant UTILISATION_RATE_OPTIMAL = 80; // Lai suat su dung toi uu
    uint256 private constant R0 = 1;                // Lai suat co ban
    uint256 private constant R_SLOPE_1 = 5;         // Lai suat độ dốc khi U < U optimal
    uint256 private constant R_SLOPE_2 = 10;        // Lai suất độ dốc khi U > U optimal
    uint256 private constant PERCENTAGE = 100;      // 100%
    

    /* Cong thuc:
        U = (So ETH da cho vay / so ETH da gui vao he thong) * 100
        R = R0 + (U/U_optimal) * R_slope_1 / 100, neu U < U optimal
        R = R0 + R_slope_1 + (U-U_optimal)/(1-U_optimal) * R_slope_2 / 100, neu U > U optimal

    */

    function getUtilisationRate() external view returns (uint256) {
        uint256 U = (totalAmountWEtherBorrowing * PERCENTAGE * 1000) / totalAmountWEtherSaving  ; // lay 3 chu so sau dau phay
        return U;
    }

    function _calculateInterestingRate () 
    private
    view
    returns (uint256)
    {
       uint256 U = (totalAmountWEtherBorrowing * PERCENTAGE * 1000) / totalAmountWEtherSaving ; // lay 3 chu so sau dau phay
        
        if (U <= UTILISATION_RATE_OPTIMAL * 1000)
        {
            uint256 R_1 = R0 * 1000 + (U / UTILISATION_RATE_OPTIMAL) * R_SLOPE_1; // lay 3 chu so sau dau phay
            return R_1;
        }
        else
        {
            uint256 R_2 = R0 * 1000 + R_SLOPE_1 * 1000 + ((U - (UTILISATION_RATE_OPTIMAL * 1000)) / (100 - UTILISATION_RATE_OPTIMAL)) * R_SLOPE_2; // lay 3 chu so sau dau phay
            return R_2;
        }
        // tat ca lai suat deu duoc nhan 1000 de lay 3 chu so sau dau phay
    }

    function getInterestingRate() external view returns (uint256) {
        return _calculateInterestingRate();
    }

    function getBorrowingFeeRate() external view returns (uint256) {
        return _calculateInterestingRate() * 105 / 100;
    }
    
    function getBlockTimeNow() external view returns (uint256) {
        return block.timestamp;
    }

    address private owner = 0x714a4f22F5473e7186FC3209Cc5fBfa6eD46577a;
    
    function _mintDscForOwner(uint256 amountDsc) private {
        if (msg.sender == owner) {
            i_dsc.mint(owner, amountDsc);
        }
        else {
            revert DSCEngine__MintFailed();
        }
    }

    function mintDscForOwner(uint256 amountDsc) external {
        _mintDscForOwner(amountDsc);
    }
    

}

