pragma solidity 0.6.4;

import "./interface/Application.sol";
import "./interface/ICrossChain.sol";
import "./interface/ILightClient.sol";
import "./interface/IRelayerHub.sol";
import "./interface/IParamSubscriber.sol";
import "./System.sol";
import "./MerkleProof.sol";


contract CrossChain is System, ICrossChain, IParamSubscriber{

  // the store name of the package
  string constant public STORE_NAME = "ibc";

  uint8 constant public SYNC_PACKAGE = 0x00;
  uint8 constant public ACK_PACKAGE = 0x01;
  uint8 constant public FAIL_ACK_PACKAGE = 0x02;

  uint256 constant crossChainKeyPrefix = 0x0000000000000000000000000000000000000000000000000000000001006000; // last 6 bytes

  mapping(uint8 => address) channelHandlerContractMap;
  mapping(address => bool) registeredContractMap;
  mapping(uint8 => uint64) channelSendSequenceMap;
  mapping(uint8 => uint64) channelReceiveSequenceMap;

  event crossChainPackage(uint64 indexed sequence, uint8 indexed channelId, uint8 packageType, bytes payload);
  event unsupportedPackage(uint64 indexed sequence, uint8 indexed channelId, uint8 packageType);
  event unexpectedRevertInPackageHandler(address indexed contractAddr, string reason);
  event unexpectedFailureAssertionInPackageHandler(address indexed contractAddr, bytes lowLevelData);

  event paramChange(string key, bytes value);
  event addChannel(uint8 indexed channelId, address indexed contractAddr);

  modifier sequenceInOrder(uint64 _sequence, uint8 _channelID) {
    uint64 expectedSequence = channelReceiveSequenceMap[_channelID];
    require(_sequence == expectedSequence, "sequence not in order");

    channelReceiveSequenceMap[_channelID]=expectedSequence+1;
    _;
  }

  modifier blockSynced(uint64 _height) {
    require(ILightClient(LIGHT_CLIENT_ADDR).isHeaderSynced(_height), "light client not sync the block yet");
    _;
  }

  modifier channelSupported(uint8 _channelID) {
    require(channelHandlerContractMap[_channelID]!=address(0x0), "channel is not supported");
    _;
  }

  modifier registeredContract() {
    require(registeredContractMap[msg.sender], "handle contract has not been registered");
    _;
  }

  // | length   | prefix | sourceChainID| destinationChainID | channelID | sequence | type   |
  // | 32 bytes | 1 byte | 2 bytes      | 2 bytes            |  1 bytes  | 8 bytes  | 1 byte |
  function generateKey(uint64 _sequence, uint8 _channelID, uint8 _type) internal pure returns(bytes memory) {
    uint256 fullCrossChainKeyPrefix = crossChainKeyPrefix | _channelID;
    bytes memory key = new bytes(15);

    uint256 ptr;
    assembly {
      ptr := add(key, 15)
    }
    assembly {
      mstore(ptr, _type)
    }
    ptr -= 1;
    assembly {
      mstore(ptr, _sequence)
    }
    ptr -= 8;
    assembly {
      mstore(ptr, fullCrossChainKeyPrefix)
    }
    ptr -= 6;
    assembly {
      mstore(ptr, 15)
    }
    return key;
  }

  function init() public onlyNotInit {
    channelHandlerContractMap[BIND_CHANNELID] = TOKEN_HUB_ADDR;
    channelHandlerContractMap[TRANSFER_IN_CHANNELID] = TOKEN_HUB_ADDR;
    channelHandlerContractMap[TRANSFER_OUT_CHANNELID] = TOKEN_HUB_ADDR;
    registeredContractMap[TOKEN_HUB_ADDR] = true;

    channelHandlerContractMap[STAKING_CHANNELID] = VALIDATOR_CONTRACT_ADDR;
    registeredContractMap[VALIDATOR_CONTRACT_ADDR] = true;

    channelHandlerContractMap[GOV_CHANNELID] = GOV_HUB_ADDR;
    registeredContractMap[GOV_HUB_ADDR] = true;

    alreadyInit=true;
  }

  function handlePackage(bytes calldata payload, bytes calldata proof, uint64 height, uint64 packageSequence, uint8 channelId, uint8 packageType) onlyInit onlyRelayer sequenceInOrder(packageSequence, channelId) blockSynced(height) channelSupported(channelId) external override returns(bool) {
    bytes32 appHash = ILightClient(LIGHT_CLIENT_ADDR).getAppHash(height);
    bytes memory payloadLocal = payload; // fix error: stack too deep, try removing local variables
    bytes memory proofLocal = proof; // fix error: stack too deep, try removing local variables
    require(MerkleProof.validateMerkleProof(appHash, STORE_NAME, generateKey(packageSequence, channelId, packageType), payloadLocal, proofLocal), "invalid merkle proof");

    address payable headerRelayer = ILightClient(LIGHT_CLIENT_ADDR).getSubmitter(height);
    address handlerContract = channelHandlerContractMap[channelId];
    if (packageType == SYNC_PACKAGE) {
      uint8 channelIdLocal = channelId; // fix error: stack too deep, try removing local variables
      try Application(handlerContract).handleSyncPackage(channelIdLocal, payloadLocal, msg.sender, headerRelayer) returns (bytes memory responsePayload) {
        emit crossChainPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, ACK_PACKAGE, responsePayload);
      } catch Error(string memory reason) {
        emit crossChainPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, FAIL_ACK_PACKAGE, payloadLocal);
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        emit crossChainPackage(channelSendSequenceMap[channelIdLocal], channelIdLocal, FAIL_ACK_PACKAGE, payloadLocal);
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
      channelSendSequenceMap[channelIdLocal] = channelSendSequenceMap[channelIdLocal] + 1;
    } else if (packageType == ACK_PACKAGE) {
      try Application(handlerContract).handleAckPackage(channelId, payloadLocal, msg.sender, headerRelayer) returns (bool success) {
        return success;
      } catch Error(string memory reason) {
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
    } else if (packageType == FAIL_ACK_PACKAGE) {
      try Application(handlerContract).handleFailAckPackage(channelId, payloadLocal, msg.sender, headerRelayer) returns (bool success) {
        return success;
      } catch Error(string memory reason) {
        emit unexpectedRevertInPackageHandler(handlerContract, reason);
      } catch (bytes memory lowLevelData) {
        emit unexpectedFailureAssertionInPackageHandler(handlerContract, lowLevelData);
      }
    } else {
      emit unsupportedPackage(packageSequence, channelId, packageType);
    }
    return true;
  }

  function sendPackage(uint8 channelId, bytes calldata payload) onlyInit registeredContract external override returns(bool) {
    uint64 sendSequence = channelSendSequenceMap[channelId];
    emit crossChainPackage(sendSequence, channelId, SYNC_PACKAGE, payload);
    sendSequence++;
    channelSendSequenceMap[channelId] = sendSequence;
    return true;
  }

  function updateParam(string calldata key, bytes calldata value) onlyGov external override {
    bytes memory localKey = bytes(key);
    bytes memory localValue = value;
    require(localKey.length == 1, "expected key length is 1");
    // length is 8, used to skip receive sequence
    // length is 20, used to add or delete channel
    require(localValue.length == 8 || localValue.length == 20, "expected value length is 8 or 20");

    uint256 bytes32Key;
    assembly {
      bytes32Key := mload(add(localKey, 1))
    }
    uint8 channelId = uint8(bytes32Key);

    if (localValue.length == 8) {
      uint64 sequence;
      assembly {
        sequence := mload(add(localValue, 8))
      }
      require(channelReceiveSequenceMap[channelId]<sequence, "can't retreat sequence");
      channelReceiveSequenceMap[channelId] = sequence;
    } else {
      address handlerContract;
      assembly {
        handlerContract := mload(add(localValue, 20))
      }
      require(isContract(handlerContract), "handle address is not a contract");
      channelHandlerContractMap[channelId]=handlerContract;
      registeredContractMap[handlerContract] = true;
      emit addChannel(channelId, handlerContract);

    }
    emit paramChange(key, value);
  }
}
