//SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;
import "./library/TimeLock.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract Governor is Initializable, Timelock {
    function __Governor_init__() public initializer {
        __Timelock_init__();
    }

    /// @notice The name of this contract
    string public constant name = "ANW Governor";

    /// @notice The total number of proposals
    uint256 public proposalCount;

    struct Proposal {
        /// @notice Unique id for looking up a proposal
        uint256 id;
        /// @notice The timestamp that the proposal will be available for execution, set once the vote succeeds
        uint256 eta;
        /// @notice The quorum percent proposal
        uint256 quorum;
        /// @notice the ordered list of target addresses for calls to be made
        address targets;
        /// @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint256 values;
        /// @notice The ordered list of function signatures to be called
        string signatures;
        /// @notice The ordered list of calldata to be passed to each call
        bytes calldatas;
        /// @notice The block time at which voting begins: holders must delegate their votes prior to this time
        uint256 startTime;
        /// @notice The block time at which voting ends: votes must be cast prior to this time
        uint256 endTime;
        /// @notice The block time at which pending preposor ends: votes must be cast prior to this block
        uint256 endExcuteTime;
        /// @notice The block time at which pending preposor ends: votes must be cast prior to this block
        uint256 endQueuedTime;
        /// @notice Flag marking whether the proposal has been defeated
        bool defeated;
        /// @notice Flag marking whether the proposal has been canceled
        bool canceled;
        /// @notice Flag marking whether the proposal has been executed
        bool executed;
    }

    struct ProposalPayload {
        /// @notice The quorum percent proposal
        uint256 quorum;
        /// @notice the ordered list of target addresses for calls to be made
        address targets;
        /// @notice The ordered list of values (i.e. msg.value) to be passed to the calls to be made
        uint256 values;
        /// @notice The ordered list of function signatures to be called
        string signatures;
        /// @notice The ordered list of calldata to be passed to each call
        bytes calldatas;
        /// @notice The block time at which voting begins: holders must delegate their votes prior to this time
        uint256 startTime;
        /// @notice The block time at which voting ends: votes must be cast prior to this time
        uint256 endTime;
        /// @notice The block time at which queued time ends: proposol must be add into queue prior to this timr
        uint256 endQueuedTime;
        /// @notice The block time at which pending preposor ends: votes must be cast prior to this block
        uint256 endExcuteTime;
    }

    /// @notice Ballot receipt record for a voter
    struct Receipt {
        /// @notice Whether or not a vote has been cast
        bool hasVoted;
        /// @notice Whether or not the voter supports the proposal
        bool support;
        /// @notice The number of votes the voter had, which were cast
        uint256 votes;
    }

    /// @notice Possible states that a proposal may be in
    enum ProposalState {
        Pending,
        Active,
        Canceled,
        Defeated,
        Succeeded,
        Queued,
        Expired,
        Executed
    }

    /// @notice The official record of all proposals ever proposed
    mapping(uint256 => Proposal) public proposals;

    /// @notice Receipts of ballots for the entire set of voters
    mapping(uint256 => mapping(address => Receipt)) receipts;

    /// @notice The latest proposal for each proposer
    mapping(address => uint256) public latestProposalIds;

    /// @notice An event emitted when a new proposal is created
    event ProposalCreated(
        uint256 id,
        address targets,
        uint256 values,
        string signatures,
        bytes calldatas,
        uint256 startTime,
        uint256 endTime
    );

    /// @notice An event emitted when a vote has been cast on a proposal
    event VoteCast(
        address voter,
        uint256 proposalId,
        bool support,
        uint256 votes
    );

    /// @notice An event emitted when a proposal has been canceled
    event ProposalCanceled(uint256 id);

    /// @notice An event emitted when a proposal has been queued in the Timelock
    event ProposalQueued(uint256 id, uint256 eta);

    /// @notice An event emitted when a proposal has been defeated in the Timelock
    event ProposalDefeated(uint256 id);

    /// @notice An event emitted when a proposal has been executed in the Timelock
    event ProposalExecuted(uint256 id);

    function propose(ProposalPayload memory _payload)
        public
        adminOrGovernor
        returns (uint256)
    {
        require(
            _payload.targets != address(0),
            "GovernorAlpha::propose: must provide actions"
        );

        uint256 latestProposalId = latestProposalIds[msg.sender];
        if (latestProposalId != 0) {
            ProposalState proposersLatestProposalState = state(
                latestProposalId
            );
            require(
                proposersLatestProposalState != ProposalState.Active,
                "GovernorAlpha::propose: found an already active proposal"
            );
            require(
                proposersLatestProposalState != ProposalState.Pending,
                "GovernorAlpha::propose: found an already pending proposal"
            );
        }

        proposalCount++;

        Proposal memory newProposal = Proposal({
            id: proposalCount,
            eta: 0,
            quorum: _payload.quorum,
            targets: _payload.targets,
            values: _payload.values,
            signatures: _payload.signatures,
            calldatas: _payload.calldatas,
            startTime: _payload.startTime,
            endTime: _payload.endTime,
            endQueuedTime: _payload.endQueuedTime,
            endExcuteTime: _payload.endExcuteTime,
            canceled: false,
            defeated: false,
            executed: false
        });
        
        
        {
            proposals[newProposal.id] = newProposal;
            latestProposalIds[msg.sender] = newProposal.id;

            emit ProposalCreated(
                newProposal.id,
                _payload.targets,
                _payload.values,
                _payload.signatures,
                _payload.calldatas,
                _payload.startTime,
                _payload.endTime
            );

        }

        
        return newProposal.id;
    }

    function queue(uint256 proposalId) public adminOrGovernor {
        Proposal storage proposal = proposals[proposalId];

        require(block.timestamp < proposal.endQueuedTime, "GovernorAlpha::queue: proposal can only be queued if not been end queued time yet");
        require(
            state(proposalId) == ProposalState.Succeeded,
            "GovernorAlpha::queue: proposal can only be queued if it is succeeded"
        );
        uint256 eta = block.timestamp + delay;
        _queueOrRevert(
            proposal.targets,
            proposal.values,
            proposal.signatures,
            proposal.calldatas,
            eta
        );
        proposal.eta = eta;
        emit ProposalQueued(proposalId, eta);
    }

    function _queueOrRevert(
        address target,
        uint256 value,
        string memory signature,
        bytes memory data,
        uint256 eta
    ) internal {
        require(
            !queuedTransactions[
                keccak256(abi.encode(target, value, signature, data, eta))
            ],
            "GovernorAlpha::_queueOrRevert: proposal action already queued at eta"
        );
        queueTransaction(target, value, signature, data, eta);
    }

    function execute(uint256 proposalId) external payable adminOrGovernor {
        require(
            state(proposalId) == ProposalState.Queued,
            "GovernorAlpha::execute: proposal can only be executed if it is queued"
        );
        Proposal storage proposal = proposals[proposalId];

        proposal.executed = true;
        executeTransaction(
            proposal.targets,
            proposal.values,
            proposal.signatures,
            proposal.calldatas,
            proposal.eta
        );
        emit ProposalExecuted(proposalId);
    }

    function cancel(uint256 proposalId) external adminOrGovernor {
        require(
            state(proposalId) != ProposalState.Executed,
            "GovernorAlpha::cancel: cannot cancel executed proposal"
        );

        Proposal storage proposal = proposals[proposalId];

        proposal.canceled = true;
        cancelTransaction(
            proposal.targets,
            proposal.values,
            proposal.signatures,
            proposal.calldatas,
            proposal.eta
        );

        emit ProposalCanceled(proposalId);
    }

    function defeated(uint256 proposalId) external adminOrGovernor {
        require(
            state(proposalId) == ProposalState.Queued,
            "GovernorAlpha::cancel: defeat only when proposal in queue executed proposal"
        );

        Proposal storage proposal = proposals[proposalId];

        proposal.defeated = true;
        defeatedTransaction(
            proposal.targets,
            proposal.values,
            proposal.signatures,
            proposal.calldatas,
            proposal.eta
        );

        emit ProposalDefeated(proposalId);
    }

    function getActions(uint256 proposalId)
        external
        view
        returns (
            address targets,
            uint256 values,
            string memory signatures,
            bytes memory calldatas
        )
    {
        Proposal storage p = proposals[proposalId];
        return (p.targets, p.values, p.signatures, p.calldatas);
    }

    function getReceipt(uint256 proposalId, address voter)
        external
        view
        returns (Receipt memory)
    {
        return receipts[proposalId][voter];
    }

    function state(uint256 proposalId) public view returns (ProposalState) {
        require(
            proposalCount >= proposalId && proposalId > 0,
            "GovernorAlpha::state: invalid proposal id"
        );
        Proposal storage proposal = proposals[proposalId];

        if (proposal.canceled) {
            return ProposalState.Canceled;
        } else if (proposal.defeated) {
            return ProposalState.Defeated;
        } else if (block.timestamp <= proposal.startTime) {
            return ProposalState.Pending;
        } else if (block.timestamp <= proposal.endTime) {
            return ProposalState.Active;
        } else if (proposal.eta == 0) {
            return ProposalState.Succeeded;
        } else if (proposal.executed) {
            return ProposalState.Executed;
        } else if (block.timestamp >= proposal.endExcuteTime) {
            return ProposalState.Expired;
        } else 
            return ProposalState.Queued;
    }

    function castVote(uint256 proposalId, bool support) external {
        return _castVote(msg.sender, proposalId, support);
    }


    function _castVote(
        address voter,
        uint256 proposalId,
        bool support
    ) internal {
        require(
            state(proposalId) == ProposalState.Active,
            "GovernorAlpha::_castVote: voting is closed"
        );
        Receipt storage receipt = receipts[proposalId][msg.sender];
        require(
            receipt.hasVoted == false,
            "GovernorAlpha::_castVote: voter already voted"
        );

        receipt.hasVoted = true;
        receipt.support = support;
        receipt.votes = 1;

        emit VoteCast(voter, proposalId, support, 1);
    }

    function getChainId() internal view returns (uint256) {
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        return chainId;
    }
}


