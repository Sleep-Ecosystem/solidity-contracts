// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";

// UniswapV2 Factory and Router interfaces
import "./IUniswapV2Router.sol";
import "./IUniswapV2Factory.sol";

// Auth contract
import "./Auth.sol";

// Distributor contract
import "./DividendDistributor.sol";

contract SleepToken is
    Initializable,
    Auth,
    ERC20Upgradeable,
    ERC20CappedUpgradeable,
    ReentrancyGuardUpgradeable
{
    uint256 private cappedSupply;
    uint256 public initialTokenSupply;

    IUniswapV2Router public pancakeSwapRouter;
    IUniswapV2Factory public pancakeSwapFactory;
    address public createdPairAddress;

    DividendDistributor public distributor;
    bool public autoProcessDistributions;
    uint256 public distributorGas;

    address public marketingFeeReceiver;
    address public autoLiquidityReceiver;

    uint256 public maxTxAmount;
    uint256 public maxTokensPerWallet;

    bool public blacklistMode;
    mapping(address => bool) public isBlacklisted;

    mapping(address => bool) isFeeExempt;
    mapping(address => bool) isTxLimitExempt;
    mapping(address => bool) isTimelockExempt;
    mapping(address => bool) isDividendExempt;

    uint256 public buyBurnFee;
    uint256 public buyLiquidityFee;
    uint256 public buyMarketingFee;
    uint256 public buyReflectionFee;
    uint256 public buyTotalFee;
    uint256 public buyFeeDenominator;

    uint256 public sellBurnFee;
    uint256 public sellLiquidityFee;
    uint256 public sellMarketingFee;
    uint256 public sellReflectionFee;
    uint256 public sellTotalFee;
    uint256 public sellFeeDenominator;

    uint256 public targetLiquidity;
    uint256 public targetLiquidityDenominator;

    bool public buyCooldownEnabled;
    uint256 public cooldownTimerInterval;
    mapping(address => uint256) private cooldownTimer;

    bool public swapEnabled;
    uint256 public swapThreshold;
    bool public inSwap;

    address public WBNB;
    address public DEAD;

    address public tokenStakingAddress;
    bool public isTokenStakingAddressInitialized;
    address public nftStakingAddress;
    bool public isNFTStakingAddressInitialized;
    address public nftMarketAddress;
    bool public isNFTMarketAddressInitialized;

    event AutoLiquify(uint256 _amountBNB, uint256 _amount);

    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    modifier onlyExemptContracts() {
        require(isExemptContract(msg.sender), "Exempt contract access denied");
        _;
    }

    function initialize(
        address _owner,
        address _WBNB,
        address _DEAD,
        DividendDistributor _distributor,
        IUniswapV2Router _pancakeSwapRouter,
        IUniswapV2Factory _pancakeSwapFactory
    ) public initializer {
        cappedSupply = 300_000_000 ether;

        __ERC20_init("Sleep Token", "SLEEP");
        __ERC20Capped_init(cappedSupply);
        __Auth_init(msg.sender);
        __ReentrancyGuard_init();

        initialTokenSupply = 245_000_000 ether;

        maxTxAmount = cappedSupply;
        maxTokensPerWallet = cappedSupply;

        blacklistMode = true;

        buyBurnFee = 1;
        buyLiquidityFee = 0;
        buyMarketingFee = 5;
        buyReflectionFee = 5;
        buyTotalFee =
            buyBurnFee +
            buyLiquidityFee +
            buyMarketingFee +
            buyReflectionFee;
        buyFeeDenominator = 100;

        sellBurnFee = 2;
        sellLiquidityFee = 0;
        sellMarketingFee = 6;
        sellReflectionFee = 6;
        sellTotalFee =
            sellBurnFee +
            sellLiquidityFee +
            sellMarketingFee +
            sellReflectionFee;
        sellFeeDenominator = 100;

        targetLiquidity = 20;
        targetLiquidityDenominator = 100;

        buyCooldownEnabled = true;
        cooldownTimerInterval = 3;

        swapEnabled = true;
        swapThreshold = (cappedSupply * uint256(50)) / uint256(10000);
        inSwap = false;

        WBNB = _WBNB;
        DEAD = _DEAD;

        pancakeSwapRouter = _pancakeSwapRouter;
        pancakeSwapFactory = _pancakeSwapFactory;
        createdPairAddress = pancakeSwapFactory.createPair(WBNB, address(this));
        _approve(address(this), address(pancakeSwapRouter), type(uint256).max);

        distributor = _distributor;
        distributorGas = 500_000;
        autoProcessDistributions = true;

        isTimelockExempt[_owner] = true;
        isTimelockExempt[DEAD] = true;
        isTimelockExempt[address(this)] = true;

        isDividendExempt[createdPairAddress] = true;
        isDividendExempt[DEAD] = true;
        isDividendExempt[address(this)] = true;

        marketingFeeReceiver = _owner;
        autoLiquidityReceiver = _owner;

        _mint(_owner, initialTokenSupply);
    }

    receive() external payable {
        // React to receiving bnb
    }

    function setMaxWalletPercent_base1000(uint256 _maxWallPercent_base1000)
        external
        onlyOwner
    {
        maxTokensPerWallet = (cappedSupply * _maxWallPercent_base1000) / 1000;
    }

    function setMaxTxPercent_base1000(uint256 _maxTXPercentage_base1000)
        external
        onlyOwner
    {
        maxTxAmount = (cappedSupply * _maxTXPercentage_base1000) / 1000;
    }

    function setTxLimit(uint256 _amount) external authorized {
        maxTxAmount = _amount;
    }

    function setCooldownStatus(bool _status, uint256 _interval)
        external
        onlyOwner
    {
        buyCooldownEnabled = _status;
        cooldownTimerInterval = _interval;
    }

    function setBlacklistMode(bool _status) external onlyOwner {
        blacklistMode = _status;
    }

    function manageBlacklist(address[] calldata _addresses, bool _status)
        external
        onlyOwner
    {
        for (uint256 i; i < _addresses.length; i++) {
            isBlacklisted[_addresses[i]] = _status;
        }
    }

    function setIsFeeExempt(address _holder, bool _exempt) external authorized {
        isFeeExempt[_holder] = _exempt;
    }

    function setIsTxLimitExempt(address _holder, bool _exempt)
        external
        authorized
    {
        isTxLimitExempt[_holder] = _exempt;
    }

    function setIsTimelockExempt(address _holder, bool _exempt)
        external
        authorized
    {
        isTimelockExempt[_holder] = _exempt;
    }

    function setIsDividendExempt(address _holder, bool _exempt)
        external
        authorized
    {
        require(_holder != address(this) && _holder != createdPairAddress);
        isDividendExempt[_holder] = _exempt;
        if (_exempt) {
            distributor.setShare(_holder, 0);
        } else {
            distributor.setShare(_holder, balanceOf(_holder));
        }
    }

    function setBuyFees(
        uint256 _burnFee,
        uint256 _liquidityFee,
        uint256 _marketingFee,
        uint256 _reflectionFee,
        uint256 _feeDenominator
    ) external authorized {
        buyBurnFee = _burnFee;
        buyLiquidityFee = _liquidityFee;
        buyMarketingFee = _marketingFee;
        buyReflectionFee = _reflectionFee;
        buyFeeDenominator = _feeDenominator;
        buyTotalFee = _burnFee + _liquidityFee + _marketingFee + _reflectionFee;
        require(
            buyTotalFee < buyFeeDenominator / 4,
            "Fees cannot be more than 25%"
        );
    }

    function setSellFees(
        uint256 _burnFee,
        uint256 _liquidityFee,
        uint256 _marketingFee,
        uint256 _reflectionFee,
        uint256 _feeDenominator
    ) external authorized {
        sellBurnFee = _burnFee;
        sellLiquidityFee = _liquidityFee;
        sellMarketingFee = _marketingFee;
        sellReflectionFee = _reflectionFee;
        sellFeeDenominator = _feeDenominator;
        sellTotalFee =
            _burnFee +
            _liquidityFee +
            _marketingFee +
            _reflectionFee;
        require(
            sellTotalFee < sellFeeDenominator / 4,
            "Fees cannot be more than 25%"
        );
    }

    function setDistributorSettings(uint256 _gas) external authorized {
        require(_gas < 750000);
        distributorGas = _gas;
    }

    function setDistributionCriteria(
        uint256 _minPeriod,
        uint256 _minDistribution
    ) external authorized {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
    }

    function setAutoProcessDistributions(bool _autoProcessDistributions)
        external
        authorized
    {
        autoProcessDistributions = _autoProcessDistributions;
    }

    function setFeeReceivers(
        address _autoLiquidityReceiver,
        address _marketingFeeReceiver
    ) external authorized {
        autoLiquidityReceiver = _autoLiquidityReceiver;
        marketingFeeReceiver = _marketingFeeReceiver;
    }

    function setSwapBackSettings(bool _enabled, uint256 _amount)
        external
        authorized
    {
        swapEnabled = _enabled;
        swapThreshold = _amount;
    }

    function setTargetLiquidity(uint256 _target, uint256 _denominator)
        external
        authorized
    {
        targetLiquidity = _target;
        targetLiquidityDenominator = _denominator;
    }

    function setTokenStakingAddress(address _tokenStakingAddress)
        external
        onlyOwner
    {
        require(
            !isTokenStakingAddressInitialized,
            "Token staking address already initialized"
        );

        tokenStakingAddress = _tokenStakingAddress;
        isTokenStakingAddressInitialized = true;
        isDividendExempt[_tokenStakingAddress] = true;
    }

    function setNFTStakingAddress(address _nftStakingAddress)
        external
        onlyOwner
    {
        require(
            !isNFTStakingAddressInitialized,
            "NFT staking address already initialized"
        );

        nftStakingAddress = _nftStakingAddress;
        isNFTStakingAddressInitialized = true;
        isDividendExempt[_nftStakingAddress] = true;
    }

    function setNFTMarketAddress(address _nftMarketAddress) external onlyOwner {
        require(
            !isNFTMarketAddressInitialized,
            "NFT market address already initialized"
        );

        nftMarketAddress = _nftMarketAddress;
        isNFTMarketAddressInitialized = true;
        isDividendExempt[_nftMarketAddress] = true;
    }

    function approveMax(address _spender) external returns (bool) {
        return approve(_spender, type(uint256).max);
    }

    function _mint(address _account, uint256 _amount)
        internal
        override(ERC20Upgradeable, ERC20CappedUpgradeable)
    {
        super._mint(_account, _amount);
    }

    function _transfer(
        address _sender,
        address _recipient,
        uint256 _amount
    ) internal virtual override {
        if (inSwap) {
            return super._transfer(_sender, _recipient, _amount);
        }

        if (blacklistMode) {
            require(
                !isBlacklisted[_sender] && !isBlacklisted[_recipient],
                "Either the sender or recipient is blacklisted"
            );
        }

        if (
            !authorizations[_sender] &&
            _recipient != address(this) &&
            _recipient != address(DEAD) &&
            _recipient != createdPairAddress &&
            _recipient != marketingFeeReceiver &&
            _recipient != autoLiquidityReceiver
        ) {
            uint256 heldTokens = balanceOf(_recipient);
            require(
                heldTokens + _amount <= maxTokensPerWallet,
                "Recipient will surpass maximum tokens per wallet"
            );
        }

        if (
            _sender == createdPairAddress &&
            buyCooldownEnabled &&
            !isTimelockExempt[_recipient]
        ) {
            require(
                cooldownTimer[_recipient] < block.timestamp,
                "Please wait for required cooldown period between buys"
            );
            cooldownTimer[_recipient] = block.timestamp + cooldownTimerInterval;
        }

        checkTxLimit(_sender, _amount);

        uint256 amountReceived = shouldTakeFee(_sender, _recipient)
            ? takeFee(_sender, _amount, (_recipient == createdPairAddress))
            : _amount;

        super._transfer(_sender, _recipient, amountReceived);

        if (shouldSwapBack()) {
            swapBack();
        }

        if (!isDividendExempt[_sender]) {
            try distributor.setShare(_sender, balanceOf(_sender)) {} catch {}
        }

        if (!isDividendExempt[_recipient]) {
            try
                distributor.setShare(_recipient, balanceOf(_recipient))
            {} catch {}
        }

        if (autoProcessDistributions) {
            try distributor.process(distributorGas) {} catch {}
        }
    }

    function checkTxLimit(address _sender, uint256 _amount) internal view {
        require(
            _amount <= maxTxAmount || isTxLimitExempt[_sender],
            "Transaction limit exceeded"
        );
    }

    function shouldTakeFee(address _sender, address _recipient)
        internal
        view
        returns (bool)
    {
        return
            !(isFeeExempt[_sender] ||
                isExemptContract(_sender) ||
                isExemptContract(_recipient));
    }

    function takeFee(
        address _sender,
        uint256 _amount,
        bool _isSell
    ) internal returns (uint256) {
        uint256 feeAmount = 0;
        uint256 burnFee = 0;

        if (_isSell) {
            feeAmount = (_amount * sellTotalFee) / sellFeeDenominator;
            if (sellBurnFee > 0) {
                burnFee = (feeAmount * sellBurnFee) / sellTotalFee;
                super._transfer(_sender, DEAD, burnFee);
            }
        } else {
            feeAmount = (_amount * buyTotalFee) / buyFeeDenominator;
            if (buyBurnFee > 0) {
                burnFee = (feeAmount * buyBurnFee) / buyTotalFee;
                super._transfer(_sender, DEAD, burnFee);
            }
        }

        super._transfer(_sender, address(this), feeAmount - burnFee);

        return _amount - feeAmount;
    }

    function shouldSwapBack() internal view returns (bool) {
        return
            msg.sender != createdPairAddress &&
            !inSwap &&
            swapEnabled &&
            balanceOf(address(this)) >= swapThreshold;
    }

    function swapBack() internal swapping {
        uint256 dynamicLiquidityFee = isOverLiquified(
            targetLiquidity,
            targetLiquidityDenominator
        )
            ? 0
            : buyLiquidityFee;
        uint256 amountToLiquify = (swapThreshold * dynamicLiquidityFee) /
            buyTotalFee /
            2;
        uint256 amountToSwap = swapThreshold - amountToLiquify;

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = WBNB;

        uint256 balanceBefore = address(this).balance;

        pancakeSwapRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amountToSwap,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 amountBNB = address(this).balance - balanceBefore;

        uint256 totalBNBFee = buyTotalFee - (dynamicLiquidityFee / 2);

        uint256 amountBNBLiquidity = (amountBNB * dynamicLiquidityFee) /
            totalBNBFee /
            2;
        uint256 amountBNBReflection = (amountBNB * buyReflectionFee) /
            totalBNBFee;
        uint256 amountBNBMarketing = (amountBNB * buyMarketingFee) /
            totalBNBFee;

        try distributor.deposit{value: amountBNBReflection}() {} catch {}

        (bool tmpSuccess, ) = payable(marketingFeeReceiver).call{
            value: amountBNBMarketing,
            gas: 30000
        }("");

        // Supress warning msg
        tmpSuccess = false;

        if (amountToLiquify > 0) {
            pancakeSwapRouter.addLiquidityETH{value: amountBNBLiquidity}(
                address(this),
                amountToLiquify,
                0,
                0,
                autoLiquidityReceiver,
                block.timestamp
            );
            emit AutoLiquify(amountBNBLiquidity, amountToLiquify);
        }
    }

    function getCirculatingSupply() public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        return totalSupply - balanceOf(DEAD) - balanceOf(address(0));
    }

    function getLiquidityBacking(uint256 _accuracy)
        public
        view
        returns (uint256)
    {
        return
            (_accuracy * (balanceOf(createdPairAddress) * 2)) /
            getCirculatingSupply();
    }

    function isOverLiquified(uint256 _target, uint256 _accuracy)
        public
        view
        returns (bool)
    {
        return getLiquidityBacking(_accuracy) > _target;
    }

    function clearStuckBalance(uint256 _amountPercentage) external authorized {
        uint256 amountBNB = address(this).balance;
        payable(marketingFeeReceiver).transfer(
            (amountBNB * _amountPercentage) / 100
        );
    }

    function clearStuckBalance_sender(uint256 _amountPercentage)
        external
        authorized
    {
        uint256 amountBNB = address(this).balance;
        payable(msg.sender).transfer((amountBNB * _amountPercentage) / 100);
    }

    function getUnpaidDividends(address _user) external view returns (uint256) {
        return distributor.getUnpaidEarnings(_user);
    }

    function claimRewardDividends() external nonReentrant {
        distributor.claimDividend(msg.sender);
    }

    function isExemptContract(address _address) public view returns (bool) {
        return
            _address != address(0) &&
            (_address == tokenStakingAddress ||
                _address == nftStakingAddress ||
                _address == nftMarketAddress);
    }

    function mintRewards(address _recipient, uint256 _rewardAmount)
        external
        onlyExemptContracts
    {
        _mint(_recipient, _rewardAmount);
        if (!isDividendExempt[_recipient]) {
            try
                distributor.setShare(_recipient, balanceOf(_recipient))
            {} catch {}
        }
    }
}
