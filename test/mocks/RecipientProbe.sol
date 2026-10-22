// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract RecipientProbe {
    bool public reject;
    address public target;
    bytes public payload;
    uint256 public attempts;
    bool public reentrySucceeded;

    function setReject(bool reject_) external {
        reject = reject_;
    }

    function setReentry(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    receive() external payable {
        require(!reject, "reject ETH");
        if (target != address(0)) {
            ++attempts;
            (reentrySucceeded,) = target.call(payload);
        }
    }
}
