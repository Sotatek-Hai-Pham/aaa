import { ethers, waffle } from "hardhat";
import web3 from "web3";
import { Wallet, Signer, utils, BigNumber } from "ethers";
import { expect } from "chai";
import { deployContract } from "ethereum-waffle";
import { Governor, SimpleStorage } from "../typechain"

import * as GovernorABI from "../artifacts/contracts/Governor.sol/Governor.json";
import * as SimpleStorageABI from "../artifacts/contracts/mock/SImpleStorage.sol/SimpleStorage.json";
import { increase, latest, encodeParameters } from "./utils/time";

describe("Governor test!!!", () => {

  let wallets: Wallet[];
  let governor: Governor;
  let simpleStorage: SimpleStorage
  let deployer: Wallet;
  let user: Wallet;
  let testProposal: any;
  let current: BigNumber

  before("load", async () => {
    wallets = await (ethers as any).getSigners();
    deployer = wallets[0];
    user = wallets[1];
  })

  beforeEach("load", async () => {
    governor = (await deployContract(
      wallets[0] as any,
      GovernorABI,
    )) as unknown as Governor;

    simpleStorage = (await deployContract(
      wallets[0] as any,
      SimpleStorageABI,
    )) as unknown as SimpleStorage;

    await (await governor.__Governor_init__()).wait();
    current = await latest();
    testProposal = {
      quorum: 10,
      targets: simpleStorage.address,
      values: '0',
      signatures: '0x00',
      calldatas: '0x00',
      startTime: current,
      endTime: current.add(900),
      endQueuedTime: current.add(1800),
      endExcuteTime: current.add(3600)
    }

  })

  describe("create and queue proposal", () => {
    it("not an admin or governor create a proposal", async () => {
      await expect(
        governor.connect(user).propose(testProposal)
      ).to.be.reverted;
    });

    it("create success proposal", async () => {
      await expect(
        governor.connect(deployer).propose(testProposal)
      ).to.emit(governor, "ProposalCreated")
        .withArgs(1, simpleStorage.address, '0', '0x00', '0x00', current, current.add(900));
    });

    it("queue a proposal before end vote time", async () => {
      await governor.connect(deployer).propose(testProposal);

      await expect(
        governor.queue(1)
      ).to.revertedWith("GovernorAlpha::queue: proposal can only be queued if it is succeeded");

    })

    it("queue success a proposal", async () => {

      const current = await latest();
      const proposal = {
        quorum: 10,
        targets: simpleStorage.address,
        values: '0',
        signatures: '0x00',
        calldatas: '0x00',
        startTime: current,
        endTime: current.add(900),
        endQueuedTime: current.add(1800),
        endExcuteTime: current.add(3600)
      }
      await governor.connect(deployer).propose(proposal);

      await increase(BigNumber.from(1600));

      await expect(
        governor.connect(deployer).queue(1)
      ).to.emit(governor, "ProposalQueued")
        .withArgs(1, await (await latest()).add(1))
    })

    it("queue a proposal after endQueuedTime", async () => {
      await governor.connect(deployer).propose(testProposal);

      await increase(BigNumber.from(1900));
      await expect(
        governor.queue(1)
      ).to.revertedWith("GovernorAlpha::queue: proposal can only be queued if not been end queued time yet");
    });
  })

  describe("voting flow", () => {

    beforeEach(async () => {
      // let proposal = {
      //   quorum: 10,
      //   targets: simpleStorage.address,
      //   values: '0',
      //   signatures: signature,
      //   calldatas: data,
      //   startTime: current,
      //   endTime: current.add(900),
      //   endQueuedTime: current.add(1800),
      //   endExcuteTime: current.add(3600)
      // }

      await governor.connect(deployer).propose(testProposal);
    })

    it("vote an active proposal", async () => {
      await expect(
        governor.connect(user).castVote(1, true)
      ).to.emit(governor, "VoteCast")
        .withArgs(user.address, 1, true, 1);
    });

    it("an user vote more than 1 time", async () => {

      await governor.connect(user).castVote(1, true);
      await expect(
        governor.connect(user).castVote(1, true)
      ).to.revertedWith("GovernorAlpha::_castVote: voter already voted");
    });

    it("user vote to inactive proposal", async () => {
      await increase(BigNumber.from(900));
      await expect(
        governor.connect(user).castVote(1, true)
      ).to.revertedWith("GovernorAlpha::_castVote: voting is closed")
    })
  })

  describe("handle after voting end", () => {
    let signature = 'setValue(uint256)';
    let data = encodeParameters(['uint256'], [5]);

    beforeEach(async () => {
      let proposal = {
        quorum: 10,
        targets: simpleStorage.address,
        values: '0',
        signatures: signature,
        calldatas: data,
        startTime: current,
        endTime: current.add(900),
        endQueuedTime: current.add(1800),
        endExcuteTime: current.add(3600)
      }

      const a = await governor.connect(deployer).propose(proposal);
      await a.wait();
      await governor.connect(user).castVote(1, true);
      await governor.connect(wallets[2]).castVote(1, true);
    });

    it("defeat a voting before ququed it", async () => {
      await expect(
        governor.connect(deployer).defeated(1)
      ).to.revertedWith("GovernorAlpha::cancel: defeat only when proposal in queue executed proposal")
    });

    it("defeat a voting", async () => {

      await increase(BigNumber.from(1000));
      await governor.connect(deployer).queue(1);
      await expect(
        governor.connect(deployer).defeated(1)
      ).to.emit(governor, "ProposalDefeated")
        .withArgs(1);

      await expect(
        governor.connect(deployer).execute(1)
      ).to.revertedWith("GovernorAlpha::execute: proposal can only be executed if it is queued");
    })

    it("execute a proposal", async () => {
      await increase(BigNumber.from(1000));
      await governor.connect(deployer).queue(1);

      await governor.connect(deployer).execute(1);

      await expect(await simpleStorage.getValue()).to.equal(BigNumber.from(5));

      await expect(
        governor.connect(deployer).execute(1)
      ).to.revertedWith("GovernorAlpha::execute: proposal can only be executed if it is queued");
    })

    it("cancel a proposal", async () => {
      await expect(
        governor.connect(deployer).cancel(1)
      ).to.emit(governor, "ProposalCanceled")
        .withArgs(1);

      await expect(
        governor.connect(deployer).execute(1)
      ).to.revertedWith("GovernorAlpha::execute: proposal can only be executed if it is queued");
    });

    it("execute after end execute time", async () => {
      await increase(BigNumber.from(1000));
      await governor.connect(deployer).queue(1);

      await increase(BigNumber.from(3000));

      await expect(
        governor.connect(deployer).execute(1)
      ).to.revertedWith("GovernorAlpha::execute: proposal can only be executed if it is queued")
    })
  })

});
