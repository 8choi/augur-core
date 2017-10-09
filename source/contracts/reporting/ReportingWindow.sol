// Copyright (C) 2015 Forecast Foundation OU, full GPL notice in LICENSE

pragma solidity 0.4.17;


import 'reporting/IReportingWindow.sol';
import 'libraries/DelegationTarget.sol';
import 'libraries/Typed.sol';
import 'libraries/Initializable.sol';
import 'libraries/collections/Set.sol';
import 'reporting/IUniverse.sol';
import 'reporting/IReputationToken.sol';
import 'reporting/IMarket.sol';
import 'reporting/IReportingToken.sol';
import 'trading/ICash.sol';
import 'factories/MarketFactory.sol';
import 'reporting/Reporting.sol';
import 'libraries/math/SafeMathUint256.sol';
import 'libraries/math/RunningAverage.sol';


contract ReportingWindow is DelegationTarget, Typed, Initializable, IReportingWindow {
    using SafeMathUint256 for uint256;
    using Set for Set.Data;
    using RunningAverage for RunningAverage.Data;

    struct ReportingStatus {
        Set.Data marketsReportedOn;
        bool finishedReporting;
    }

    IUniverse private universe;
    uint256 private startTime;
    Set.Data private markets;
    Set.Data private firstReporterMarkets;
    Set.Data private lastReporterMarkets;
    Set.Data private finalizedMarkets;
    uint256 private invalidMarketCount;
    uint256 private incorrectDesignatedReportMarketCount;
    mapping(address => ReportingStatus) private reporterStatus;
    mapping(address => uint256) private numberOfReportsByMarket;
    uint256 private constant BASE_MINIMUM_REPORTERS_PER_MARKET = 7;
    RunningAverage.Data private reportingGasPrice;
    RunningAverage.Data private marketReports;
    uint256 private totalWinningReportingTokens;

    function initialize(IUniverse _universe, uint256 _reportingWindowId) public beforeInitialized returns (bool) {
        endInitialization();
        universe = _universe;
        startTime = _reportingWindowId * universe.getReportingPeriodDurationInSeconds();
        // Initialize these to some reasonable value to handle the first market ever created without branching code 
        reportingGasPrice.record(Reporting.defaultReportingGasPrice());
        marketReports.record(Reporting.defaultReportsPerMarket());
        return true;
    }

    function createNewMarket(uint256 _endTime, uint8 _numOutcomes, uint256 _numTicks, uint256 _feePerEthInWei, ICash _denominationToken, address _creator, address _designatedReporterAddress) public afterInitialized payable returns (IMarket _newMarket) {
        require(block.timestamp < startTime);
        require(universe.getReportingWindowByMarketEndTime(_endTime,).getTypeName() == "ReportingWindow");
        MarketFactory _marketFactory = MarketFactory(controller.lookup("MarketFactory"));
        _newMarket = _marketFactory.createMarket.value(msg.value)(controller, this, _endTime, _numOutcomes, _numTicks, _feePerEthInWei, _denominationToken, _creator, _designatedReporterAddress);
        markets.add(_newMarket);
        firstReporterMarkets.add(_newMarket);
        return _newMarket;
    }

    function migrateMarketInFromSibling() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        IReportingWindow _shadyReportingWindow = _market.getReportingWindow();
        require(universe.isContainerForReportingWindow(_shadyReportingWindow));
        IReportingWindow _originalReportingWindow = _shadyReportingWindow;
        require(_originalReportingWindow.isContainerForMarket(_market));
        privateAddMarket(_market);
        return true;
    }

    function migrateMarketInFromNibling() public afterInitialized returns (bool) {
        IMarket _shadyMarket = IMarket(msg.sender);
        IUniverse _shadyUniverse = _shadyMarket.getUniverse();
        require(_shadyUniverse == universe.getParentUniverse());
        IUniverse _originalUniverse = _shadyUniverse;
        IReportingWindow _shadyReportingWindow = _shadyMarket.getReportingWindow();
        require(_originalUniverse.isContainerForReportingWindow(_shadyReportingWindow));
        IReportingWindow _originalReportingWindow = _shadyReportingWindow;
        require(_originalReportingWindow.isContainerForMarket(_shadyMarket));
        IMarket _legitMarket = _shadyMarket;
        _originalReportingWindow.migrateFeesDueToFork();
        privateAddMarket(_legitMarket);
        return true;
    }

    function removeMarket() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        require(markets.contains(_market));
        markets.remove(_market);
        firstReporterMarkets.remove(_market);
        lastReporterMarkets.remove(_market);
        return true;
    }

    function updateMarketPhase() public afterInitialized returns (bool) {
        IMarket _market = IMarket(msg.sender);
        require(markets.contains(_market));
        IMarket.ReportingState _state = _market.getReportingState();

        if (_state == IMarket.ReportingState.LAST_REPORTING) {
            lastReporterMarkets.add(_market);
        } else {
            lastReporterMarkets.remove(_market);
        }

        if (_state == IMarket.ReportingState.FIRST_REPORTING) {
            firstReporterMarkets.add(_market);
        } else {
            firstReporterMarkets.remove(_market);
        }

        if (_state == IMarket.ReportingState.FINALIZED) {
            updateFinalizedMarket(_market);
        }

        return true;
    }

    function updateFinalizedMarket(IMarket _market) private returns (bool) {
        require(!finalizedMarkets.contains(_market));

        if (!_market.isValid()) {
            invalidMarketCount++;
        }
        if (_market.getFinalPayoutDistributionHash() != _market.getDesignatedReportPayoutHash()) {
            incorrectDesignatedReportMarketCount++;
        }
        finalizedMarkets.add(_market);
        marketReports.record(numberOfReportsByMarket[_market]);
        uint256 _totalWinningReportingTokens = _market.getFinalWinningReportingToken().totalSupply();
        totalWinningReportingTokens = totalWinningReportingTokens.add(_totalWinningReportingTokens);
    }

    function noteReport(IMarket _market, address _reporter, bytes32 _payoutDistributionHash) public afterInitialized returns (bool) {
        require(markets.contains(_market));
        require(_market.getReportingTokenOrZeroByPayoutDistributionHash(_payoutDistributionHash) == msg.sender);
        IMarket.ReportingState _state = _market.getReportingState();
        require(_state == IMarket.ReportingState.LAST_REPORTING
            || _state == IMarket.ReportingState.FIRST_REPORTING
            || _state == IMarket.ReportingState.DESIGNATED_REPORTING);
        if (_state == IMarket.ReportingState.LAST_REPORTING) {
            // always give credit for events in all-reporters phase
            privateNoteReport(_market, _reporter);
        } else if (_state == IMarket.ReportingState.DESIGNATED_REPORTING) {
            privateNoteReport(_market, _reporter);
        } else if (numberOfReportsByMarket[_market] < getMaxReportsPerFirstReporterMarket()) {
            // only give credit for first reporter markets up to the max reporters for that market
            privateNoteReport(_market, _reporter);
        }
        // no credit in all other cases (but user can still report)
        return true;
    }

    function getAvgReportingGasCost() public returns (uint256) {
        return reportingGasPrice.currentAverage();
    }

    function getAvgReportsPerMarket() public returns (uint256) {
        return marketReports.currentAverage();
    }

    function getTypeName() public afterInitialized view returns (bytes32) {
        return "ReportingWindow";
    }

    function getUniverse() public afterInitialized view returns (IUniverse) {
        return universe;
    }

    function getReputationToken() public afterInitialized view returns (IReputationToken) {
        return universe.getReputationToken();
    }

    function getStartTime() public afterInitialized view returns (uint256) {
        return startTime;
    }

    function getEndTime() public afterInitialized view returns (uint256) {
        return getDisputeEndTime();
    }

    function getNumMarkets() public afterInitialized view returns (uint256) {
        return markets.count;
    }

    function getNumInvalidMarkets() public afterInitialized view returns (uint256) {
        return invalidMarketCount;
    }

    function getNumIncorrectDesignatedReportMarkets() public view returns (uint256) {
        return incorrectDesignatedReportMarketCount;
    }

    function getReportingStartTime() public afterInitialized view returns (uint256) {
        return getStartTime();
    }

    function getReportingEndTime() public afterInitialized view returns (uint256) {
        return getStartTime() + Reporting.reportingDurationSeconds();
    }

    function getDisputeStartTime() public afterInitialized view returns (uint256) {
        return getReportingEndTime();
    }

    function getDisputeEndTime() public afterInitialized view returns (uint256) {
        return getDisputeStartTime() + Reporting.reportingDisputeDurationSeconds();
    }

    function getNextReportingWindow() public returns (IReportingWindow) {
        uint256 _nextTimestamp = getEndTime() + 1;
        return getUniverse().getReportingWindowByTimestamp(_nextTimestamp);
    }

    function getPreviousReportingWindow() public returns (IReportingWindow) {
        uint256 _previousTimestamp = getStartTime() - 1;
        return getUniverse().getReportingWindowByTimestamp(_previousTimestamp);
    }

    function allMarketsFinalized() constant public returns (bool) {
        return markets.count == finalizedMarkets.count;
    }

    function checkIn() public afterInitialized returns (bool) {
        uint256 _totalReportableMarkets = getFirstReporterMarketsCount() + getLastReporterMarketsCount();
        require(_totalReportableMarkets < 1);
        require(isActive());
        reporterStatus[msg.sender].finishedReporting = true;
        return true;
    }

    function collectReportingFees(address _reporterAddress, uint256 _attoReportingTokens) public returns (bool) {
        IReportingToken _shadyReportingToken = IReportingToken(msg.sender);
        require(isContainerForReportingToken(_shadyReportingToken));
        // NOTE: Will need to handle other denominations when that is implemented
        ICash _cash = ICash(controller.lookup("Cash"));
        uint256 _balance = _cash.balanceOf(this);
        uint256 _feePayoutShare = _balance.mul(_attoReportingTokens).div(totalWinningReportingTokens);
        totalWinningReportingTokens = totalWinningReportingTokens.sub(_attoReportingTokens);
        if (_feePayoutShare > 0) {
            _cash.withdrawEtherTo(_reporterAddress, _feePayoutShare);
        }
        return true;
    }

    // This exists as an edge case handler for when a ReportingWindow has no markets but we want to migrate fees to a new universe. If a market exists it should be migrated and that will trigger a fee migration. Otherwise calling this on the desitnation reporting window in the forked universe with the old reporting window as an argument will trigger a fee migration manaully
    function triggerMigrateFeesDueToFork(IReportingWindow _reportingWindow) public afterInitialized returns (bool) {
        require(_reportingWindow.getNumMarkets() == 0);
        _reportingWindow.migrateFeesDueToFork();
    }

    function migrateFeesDueToFork() public afterInitialized returns (bool) {
        require(isForkingMarketFinalized());
        // NOTE: Will need to figure out a way to transfer other denominations when that is implemented
        ICash _cash = ICash(controller.lookup("Cash"));
        uint256 _balance = _cash.balanceOf(this);
        if (_balance == 0) {
            return false;
        }
        IReportingWindow _shadyReportingWindow = IReportingWindow(msg.sender);
        IUniverse _shadyUniverse = _shadyReportingWindow.getUniverse();
        require(_shadyUniverse.isContainerForReportingWindow(_shadyReportingWindow));
        require(universe.isParentOf(_shadyUniverse));
        IUniverse _destinationUniverse = _shadyUniverse;
        IReportingWindow _destinationReportingWindow = _shadyReportingWindow;
        bytes32 _winningForkPayoutDistributionHash = universe.getForkingMarket().getFinalPayoutDistributionHash();
        require(_destinationUniverse == universe.getChildUniverse(_winningForkPayoutDistributionHash));
        _cash.transfer(_destinationReportingWindow, _balance);
        return true;
    }

    function isActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getStartTime()) {
            return false;
        }
        if (block.timestamp >= getEndTime()) {
            return false;
        }
        return true;
    }

    function isReportingActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getStartTime()) {
            return false;
        }
        if (block.timestamp >= getReportingEndTime()) {
            return false;
        }
        return true;
    }

    function isDisputeActive() public afterInitialized view returns (bool) {
        if (block.timestamp <= getDisputeStartTime()) {
            return false;
        }
        if (block.timestamp >= getEndTime()) {
            return false;
        }
        return true;
    }

    function getTargetReportsPerFirstReporterMarket() public afterInitialized view returns (uint256) {
        uint256 _firstReporterMarketCount = firstReporterMarkets.count;
        if (_firstReporterMarketCount == 0) {
            return 0;
        }

        uint256 _registeredReporters = 1;// TODO XXX
        uint256 _minimumReportsPerMarket = BASE_MINIMUM_REPORTERS_PER_MARKET;
        uint256 _totalReportsForAllFirstReporterMarkets = _minimumReportsPerMarket * _firstReporterMarketCount;

        if (_registeredReporters > _totalReportsForAllFirstReporterMarkets) {
            uint256 _factor = _registeredReporters / _totalReportsForAllFirstReporterMarkets;
            _minimumReportsPerMarket = _minimumReportsPerMarket * _factor;
        }

        return _minimumReportsPerMarket;
    }

    function getMaxReportsPerFirstReporterMarket() public afterInitialized view returns (uint256) {
        return getTargetReportsPerFirstReporterMarket() + 2;
    }

    function getRequiredReportsPerReporterForfirstReporterMarkets() public afterInitialized view returns (uint256) {
        return 1;// TODO XXX
    }

    function getTargetReportsPerReporter() public afterInitialized view returns (uint256) {
        uint256 _firstMarketReportsPerReporter = getRequiredReportsPerReporterForfirstReporterMarkets();
        return lastReporterMarkets.count + _firstMarketReportsPerReporter;
    }

    function getMarketsCount() public afterInitialized view returns (uint256) {
        return markets.count;
    }

    function getFirstReporterMarketsCount() public afterInitialized view returns (uint256) {
        return firstReporterMarkets.count;
    }

    function getLastReporterMarketsCount() public afterInitialized view returns (uint256) {
        return lastReporterMarkets.count;
    }

    function isContainerForReportingToken(Typed _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "ReportingToken") {
            return false;
        }
        IReportingToken _shadyReportingToken = IReportingToken(_shadyTarget);
        IMarket _shadyMarket = _shadyReportingToken.getMarket();
        require(isContainerForMarket(_shadyMarket));
        IMarket _market = _shadyMarket;
        return _market.isContainerForReportingToken(_shadyReportingToken);
    }

    function isContainerForMarket(Typed _shadyTarget) public afterInitialized view returns (bool) {
        if (_shadyTarget.getTypeName() != "Market") {
            return false;
        }
        IMarket _shadyMarket = IMarket(_shadyTarget);
        return markets.contains(_shadyMarket);
    }

    function isDoneReporting(address _reporter) public afterInitialized view returns (bool) {
        return reporterStatus[_reporter].finishedReporting;
    }

    function privateAddMarket(IMarket _market) private afterInitialized returns (bool) {
        require(!markets.contains(_market));
        require(!firstReporterMarkets.contains(_market));
        require(!lastReporterMarkets.contains(_market));
        markets.add(_market);
        return true;
    }

    function privateNoteReport(IMarket _market, address _reporter) private afterInitialized returns (bool) {
        Set.Data storage marketsReportedOn = reporterStatus[_reporter].marketsReportedOn;
        if (!marketsReportedOn.add(_market)) {
            return true;
        }
        if (marketsReportedOn.count >= getTargetReportsPerReporter()) {
            reporterStatus[_reporter].finishedReporting = true;
        }
        numberOfReportsByMarket[_market] += 1;
        reportingGasPrice.record(tx.gasprice);
        return true;
    }

    function isForkingMarketFinalized() public afterInitialized view returns (bool) {
        return getUniverse().getForkingMarket().getReportingState() == IMarket.ReportingState.FINALIZED;
    }
}
