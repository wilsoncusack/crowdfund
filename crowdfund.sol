//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {
    ReentrancyGuard
} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC165} from "@openzeppelin/contracts/introspection/IERC165.sol";
import {IMarket} from "../interfaces/IMarket.sol";
import {IMedia} from "../interfaces/IMedia.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC721TokenReceiver} from "./interfaces/IERC721TokenReceiver.sol";

/**
 * @title CrowdfundV2
 * @author MirrorXYZ
 *
 * Crowdfund the creation of NFTs by issuing ERC20 tokens that
 * can be redeemed for the underlying value of the NFT once sold.
 */
contract CrowdfundV2 is ERC721, ReentrancyGuard, IERC721TokenReceiver {
    using SafeMath for uint256;
    using Address for address payable;

    // ============ Structs ============
    // Stores values used to compute how much 
    // an NFT holder is entitled to
    struct TokenSharesInfo {
        uint256 shareValueOnJoin;
        uint256 valueWithdrawn;
        uint256 shares;
    } 

    // ============ Enums ============

    // The two states that this contract can exist in. "FUNDING" allows
    // contributors to add funds, and "TRADING" allows the operator to sell the NFT.
    enum Status {FUNDING, TRADING}

    // ============ Constants ============

    // Used to multiply values before division, to minimize rounding errors.
    uint64 internal constant SCALING_FACTOR = 1e18;
    // Returned by the hook that is invoked when an ERC721 token is sent to this address.
    bytes4 internal constant ERC721_RECEIVED_RETURN = 0x150b7a02;
    // To check that the given media address represents an ERC721 contract.
    bytes4 internal constant NFT_INTERFACE_ID = 0x80ac58cd;
    // The factor by which ETH contributions will multiply into crowdfund tokens.
    uint16 internal constant TOKEN_SCALE = 1000;

    // ============ Immutable Storage ============

    // The operator has a special role to control NFT sale and change contract status.
    address payable public immutable operator;
    // An NFT contract address that represents the media that will eventually be traded.
    address public immutable mediaAddress;
    // Address of WETH contract. We expect payment to come in as WETH, which we will unwrap.
    address public immutable WETH;
    // We add a hard cap to prevent raising more funds than deemed reasonable.
    uint256 public immutable fundingCap;
    // The operator takes some equity in the tokens, represented by this percent.
    uint256 public immutable operatorPercent;

    // ============ Mutable Storage ============

    // Represents the current state of the campaign.
    Status public status;
    // tracks mapping from backer ERC721 tokens to TokenSharesInfo
    mapping(uint256 => TokenSharesInfo) private _tokenSharesInfo;
    // tracks backer numbers
    uint256 private _nonce;
    // tracks the notional value which one share is entitled to
    // assuming the share holder never withdraws any value to which 
    // they are entitled
    uint256 private _shareValue;
    // total shares = address.balance * SCALING FACTOR, tracked statically for efficiency
    uint256 private _totalShares;


    // ============ Events ============

    event ReceivedERC721(uint256 tokenId, address sender);
    event Contribution(address contributor, uint256 amount);
    event FundingClosed(uint256 amountRaised, uint256 creatorAllocation);
    event BidAccepted(uint256 amount);
    event Redeemed(address contributor, uint256 amount);

    // ============ Modifiers ============

    /**
     * @dev Modifier to check whether the `msg.sender` is the operator.
     * If it is, it will run the function. Otherwise, it will revert.
     */
    modifier onlyOperator() {
        require(msg.sender == operator);
        _;
    }

    // ============ Constructor ============

    constructor(
        string memory name_,
        string memory symbol_,
        address payable operator_,
        address mediaAddress_,
        address WETH_,
        uint256 fundingCap_,
        uint256 operatorPercent_
    ) public ERC721(name_, symbol_) {
        // Null checks.
        require(operator_ != address(0), "Operator is null");
        require(operatorPercent_ < 100, "Operator percent >= 100");
        require(WETH_ != address(0), "WETH must not be null");
        // NFT compatibility check.
        require(
            IERC165(mediaAddress_).supportsInterface(NFT_INTERFACE_ID),
            "Media address must be ERC721"
        );
        // Initialize immutable storage.
        mediaAddress = mediaAddress_;
        operator = operator_;
        operatorPercent = operatorPercent_;
        WETH = WETH_;
        fundingCap = fundingCap_;
        // Initialize mutable storage.
        status = Status.FUNDING;
    }

    // ============ Crowdfunding Methods ============

    /**
     * @notice Mints tokens for the sender propotional to the
     *  amount of ETH sent in the transaction.
     * @dev Emits the Contribution event.
     */
    function contribute(address payable backer, uint256 amount)
        external
        payable
        nonReentrant
    {
        require(status == Status.FUNDING, "Crowdfund: Funding must be open");
        require(backer == msg.sender, "Crowdfund: Backer is not sender");
        require(amount == msg.value, "Crowdfund: Amount is not value sent");
        // This first case is the happy path, so we will keep it efficient.
        // The balance, which includes the current contribution, is less than or equal to cap.
        if (address(this).balance <= fundingCap) {
            processContribution(backer, amount);
        } else {
            // Compute the balance of the crowdfund before the contribution was made.
            uint256 startAmount = address(this).balance.sub(amount);
            // If that amount was already greater than the funding cap, then we should revert immediately.
            require(
                startAmount < fundingCap,
                "Crowdfund: Funding cap already reached"
            );
            // Otherwise, the contribution helped us reach the funding cap. We should
            // take what we can until the funding cap is reached, and refund the rest.
            uint256 eligibleAmount = fundingCap.sub(startAmount);
            // Otherwise, we process the contribution as if it were the minimal amount.
            processContribution(backer, eligibleAmount);
            // Refund the sender with their contribution (e.g. 2.5 minus the diff - e.g. 1.5 = 1 ETH)
            backer.sendValue(amount.sub(eligibleAmount));
        }
    }

    /**
     * @notice Mints an NFT to the backers and sets the TokenSharesInfo
     * @dev Emits the Contribution event.
     */ 
    function processContribution(address backer, uint256 amount) private {
        uint256 token = ++_nonce;
        _safeMint(backer, token, "");
        uint256 shares = valueToTokens(amount);
        _totalShares = _totalShares + shares;
        _tokenSharesInfo[token] = TokenSharesInfo({
            shareValueOnJoin: _shareValue, 
            valueWithdrawn: 0,
            shares: shares,
            });
        updateShareValue(); // update now that shareValueOnJoin has been stored
        emit Contribution(backer, eligibleAmount);
    }

    /**
     * @notice Updates share to ETH conversion value
     */
    function updateShareValue() private {
        _shareValue = address(this).balance
            .div(_totalShares)
            .sub(1)
            .div(SCALING_FACTOR)
            .add(1);
    }

    /**
     * @notice Returns the amount of underlying ETH the token is entitled
     to, scaled
     */
    function underlyingBalanceOf(uint256 tokenId) public view returns (uint256){
        _tokenSharesInfo[tokenId].shares
            .mul(_shareValue)
            .sub(_tokenSharesInfo[tokenId].valueWithdrawn);
    }

    /**
     * @notice Burns the sender's tokens and redeems underlying ETH.
     * @dev Emits the Redeemed event.
     */
    function redeem(uint256 backerToken, uint256 tokenAmount) external nonReentrant {
        // Prevent backers from accidently redeeming when balance is 0.
        require(
            address(this).balance > 0,
            "Crowdfund: No ETH available to redeem"
        );
        // check sender owns backerToken
        require(
            ownerOf(backerToken) == msg.sender, 
            "Crowdfund: Only token owner can redeem"
        )
        // Check
        require(
            underlyingBalanceOf(backerToken) >= tokenAmount,
            "Crowdfund: Insufficient balance"
        );
        // Effect
        uint256 redeemable = redeemableFromTokens(tokenAmount);
        // debit backerToken
        _tokenSharesInfo[backerToken].valueWithdrawn = _tokenSharesInfo[backerToken].valueWithdrawn + tokenAmount;
        // Safe version of transfer.
        msg.sender.sendValue(redeemable);
        emit Redeemed(msg.sender, redeemable);
    }

    /**
     * @notice Returns the amount of ETH that is redeemable for tokenAmount.
     */
    function redeemableFromTokens(uint256 tokenAmount)
        public
        view
        returns (uint256 redeemable)
    {
        redeemable = tokenAmount
            .mul(SCALING_FACTOR)
            .mul(address(this).balance)
            .div(totalSupply())
            .sub(1)
            .div(SCALING_FACTOR)
            .add(1);
    }

    function valueToTokens(uint256 value) public pure returns (uint256 tokens) {
        tokens = value.mul(TOKEN_SCALE);
    }

    function tokensToValue(uint256 tokenAmount)
        internal
        pure
        returns (uint256 value)
    {
        value = tokenAmount.div(TOKEN_SCALE);
    }

    // ============ Operator Methods ============

    /**
     * @notice Transfers all funds to operator, and mints tokens for the operator.
     *  Updates status to TRADING.
     * @dev Emits the FundingClosed event.
     */
    function closeFunding() external onlyOperator nonReentrant {
        require(status == Status.FUNDING, "Crowdfund: Funding must be open");
        // Close funding status, move to tradable.
        status = Status.TRADING;
        // Mint the operator a percent of the total supply.
        uint256 token = ++_nonce;
        _safeMint(operator, token, "");
        uint256 shares = (operatorPercent * totalSupply()) / (100 - operatorPercent);
        _totalShares = _totalShares + shares;
        updateShareValue(); // share value will be diluted
        _tokenSharesInfo[token] = TokenSharesInfo({
            shareValueOnJoin: _shareValue, 
            valueWithdrawn: 0,
            shares: shares,
            });
        updateShareValue();
        // Announce that funding has been closed.
        emit FundingClosed(address(this).balance, operatorTokens);
        // Transfer all funds to the operator.
        operator.sendValue(address(this).balance);
    }

    // Allows the operator to mint an NFT token.
    function mintNFT(
        IMedia.MediaData calldata data,
        IMarket.BidShares calldata bidShares
    ) external onlyOperator nonReentrant {
        // Mint an NFT token.
        IMedia(mediaAddress).mint(data, bidShares);
    }

    /**
     * @notice Accepts the given bid on the associated market and unwraps WETH.
     * @dev Emits the BidAccepted event.
     */
    function acceptNFTBid(uint256 tokenId, IMarket.Bid calldata bid)
        external
        onlyOperator
        nonReentrant
    {
        require(status == Status.TRADING, "Crowdfund: Trading must be open");
        // This will work if the crowdfund is the owner of the token.
        IMedia(mediaAddress).acceptBid(tokenId, bid);
        // Accepting the bid will transfer WETH into this contract.
        unwrapWETH(bid.amount);
        // update share value
        _shareValue = _shareValue
            .add(
                bid.amount
                    .div(_totalShares)
                    .sub(1)
                    .div(SCALING_FACTOR)
                    .add(1);
                );
        // Annouce that the bid has been accepted, with the given amount.
        emit BidAccepted(bid.amount);
    }

    // Allows the operator to update metadata associated with the NFT.
    function updateTokenURI(uint256 tokenId, string calldata tokenURI)
        external
        onlyOperator
        nonReentrant
    {
        IMedia(mediaAddress).updateTokenURI(tokenId, tokenURI);
    }

    // Allows the operator to update metadata associated with the NFT.
    function updateTokenMetadataURI(
        uint256 tokenId,
        string calldata metadataURI
    ) external onlyOperator nonReentrant {
        IMedia(mediaAddress).updateTokenMetadataURI(tokenId, metadataURI);
    }

    // Allows the operator to transfer the NFT to some given recipient.
    function transferNFT(uint256 tokenId, address recipient)
        external
        onlyOperator
        nonReentrant
    {
        IMedia(mediaAddress).transferFrom(address(this), recipient, tokenId);
    }

    // ============ Utility Methods ============

    /**
     * @notice Anyone can unwrap WETH to ETH on this contract.
     *  This will be used if the NFT's royalties are shared in WETH.
     */
    function unwrapWETH(uint256 amount) public {
        IWETH(WETH).withdraw(amount);
    }

    /**
     * @notice Prevents ETH from being sent directly to the contract, except
     *  from the WETH contract, during acceptBid.
     */
    receive() external payable {
        assert(msg.sender == WETH);
    }

    function onERC721Received(
        address,
        address,
        uint256 _tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        emit ReceivedERC721(_tokenId, msg.sender);
        return ERC721_RECEIVED_RETURN;
    }

    function _baseURI() internal pure override returns (string memory) {
        // TODO: give backers a fun image with their backer number!
        return "http"
    }
}
