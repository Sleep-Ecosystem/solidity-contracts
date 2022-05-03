// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// OpenZeppelin implementations
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";

// UniswapV2 Router interface
import "./IUniswapV2Router.sol";

// DividendDistributor interface
import "./IDividendDistributor.sol";

// Auth contract
import "./Auth.sol";

contract DividendDistributor is IDividendDistributor, Initializable, Auth {
    address public tokenAddress;

    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        uint256 totalRealised;
    }

    IUniswapV2Router public router;
    IERC20Upgradeable public REWARD;
    address public BASE_ERC20_TOKEN;

    address[] private shareholders;
    mapping(address => uint256) private shareholderClaims;
    mapping(address => uint256) private shareholderIndexes;

    mapping(address => Share) public shares;

    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public totalDistributed;
    uint256 public dividendsPerShare;
    uint256 public dividendsPerShareAccuracyFactor;

    uint256 public minPeriod;
    uint256 public minDistribution;

    uint256 currentIndex;

    bool public tokenAddressInitialized;

    modifier tokenAddressInitialization() {
        require(
            !tokenAddressInitialized,
            "Token address initialization flag must be false"
        );
        _;
        tokenAddressInitialized = true;
    }

    modifier onlyToken() {
        require(tokenAddress != address(0) && msg.sender == tokenAddress);
        _;
    }

    function initialize(
        address _BASE_ERC20_TOKEN,
        IUniswapV2Router _router,
        IERC20Upgradeable _REWARD
    ) public initializer {
        __Auth_init(msg.sender);

        router = _router;

        REWARD = _REWARD;
        BASE_ERC20_TOKEN = _BASE_ERC20_TOKEN;

        dividendsPerShareAccuracyFactor = 10**36;

        minPeriod = uint256(45) * 60;
        minDistribution = uint256(1) * (10**13);
    }

    function setTokenAddress(address _tokenAddress)
        external
        onlyOwner
        tokenAddressInitialization
    {
        require(_tokenAddress != address(0), "Token address is invalid");

        tokenAddress = _tokenAddress;
    }

    function setDistributionCriteria(
        uint256 _minPeriod,
        uint256 _minDistribution
    ) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }

    function setShare(address _shareholder, uint256 _amount)
        external
        override
        onlyToken
    {
        if (shares[_shareholder].amount > 0) {
            distributeDividend(_shareholder);
        }

        if (_amount > 0 && shares[_shareholder].amount == 0) {
            addShareholder(_shareholder);
        } else if (_amount == 0 && shares[_shareholder].amount > 0) {
            removeShareholder(_shareholder);
        }

        totalShares = totalShares - shares[_shareholder].amount + _amount;
        shares[_shareholder].amount = _amount;
        shares[_shareholder].totalExcluded = getCumulativeDividends(
            shares[_shareholder].amount
        );
    }

    function deposit() external payable override onlyToken {
        uint256 balanceBefore = REWARD.balanceOf(address(this));

        address[] memory path = new address[](2);
        path[0] = BASE_ERC20_TOKEN;
        path[1] = address(REWARD);

        router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: msg.value
        }(0, path, address(this), block.timestamp);

        uint256 amount = REWARD.balanceOf(address(this)) - balanceBefore;

        totalDividends = totalDividends + amount;
        dividendsPerShare =
            dividendsPerShare +
            ((dividendsPerShareAccuracyFactor * amount) / totalShares);
    }

    function process(uint256 _gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if (shareholderCount == 0) {
            return;
        }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;

        while (gasUsed < _gas && iterations < shareholderCount) {
            if (currentIndex >= shareholderCount) {
                currentIndex = 0;
            }

            if (shouldDistribute(shareholders[currentIndex])) {
                distributeDividend(shareholders[currentIndex]);
            }

            gasUsed = gasUsed + (gasLeft - gasleft());
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }

    function shouldDistribute(address _shareholder)
        internal
        view
        returns (bool)
    {
        return
            shareholderClaims[_shareholder] + minPeriod < block.timestamp &&
            getUnpaidEarnings(_shareholder) > minDistribution;
    }

    function distributeDividend(address _shareholder) internal {
        if (shares[_shareholder].amount == 0) {
            return;
        }

        uint256 amount = getUnpaidEarnings(_shareholder);
        if (amount > 0) {
            totalDistributed = totalDistributed + amount;
            require(REWARD.transfer(_shareholder, amount), "transfer failed");
            shareholderClaims[_shareholder] = block.timestamp;
            shares[_shareholder].totalRealised =
                shares[_shareholder].totalRealised +
                amount;
            shares[_shareholder].totalExcluded = getCumulativeDividends(
                shares[_shareholder].amount
            );
        }
    }

    function claimDividend(address _claimingAddress) external onlyToken {
        distributeDividend(_claimingAddress);
    }

    function getUnpaidEarnings(address _shareholder)
        public
        view
        returns (uint256)
    {
        if (shares[_shareholder].amount == 0) {
            return 0;
        }

        uint256 shareholderTotalDividends = getCumulativeDividends(
            shares[_shareholder].amount
        );
        uint256 shareholderTotalExcluded = shares[_shareholder].totalExcluded;

        if (shareholderTotalDividends <= shareholderTotalExcluded) {
            return 0;
        }

        return shareholderTotalDividends - shareholderTotalExcluded;
    }

    function getCumulativeDividends(uint256 _share)
        internal
        view
        returns (uint256)
    {
        return (_share * dividendsPerShare) / dividendsPerShareAccuracyFactor;
    }

    function addShareholder(address _shareholder) internal {
        shareholderIndexes[_shareholder] = shareholders.length;
        shareholders.push(_shareholder);
    }

    function removeShareholder(address _shareholder) internal {
        shareholders[shareholderIndexes[_shareholder]] = shareholders[
            shareholders.length - 1
        ];
        shareholderIndexes[
            shareholders[shareholders.length - 1]
        ] = shareholderIndexes[_shareholder];
        shareholders.pop();
    }
}
