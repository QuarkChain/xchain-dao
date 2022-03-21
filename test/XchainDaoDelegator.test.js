const { expect } = require("chai");
const { ethers } = require("hardhat");

function get_validators_hash(users, epoch) {
    let hash = ethers.utils.hexZeroPad(epoch, 32);
    for (let i = 0; i < users.length; i++) {
        hash = ethers.utils.solidityKeccak256(["bytes32", "address"], [hash, users[i]]);
    }
    return hash;
}
  

describe("XChainDaoDelegator", () => {
  let dao;
  let daoToken;
  let factory;
  let accounts;
  const zeroAddr = '0x0000000000000000000000000000000000000000';

  beforeEach(async () => {
    const XChainDao = await ethers.getContractFactory("XchainDaoTester");
    dao = await XChainDao.deploy();
    await dao.deployed();

    const Token = await ethers.getContractFactory("TestERC20");
    daoToken = await Token.deploy();
    await daoToken.deployed();

    const ValidatorDelegationFactory = await ethers.getContractFactory("ValidatorDelegationFactory");
    factory = await ValidatorDelegationFactory.deploy();
    await factory.deployed();

    accounts = await ethers.getSigners();
    const signerAddrs = accounts.map(function(signer) {
        return signer.address;
    }).slice(0, 5);

    await dao.initialize(signerAddrs, factory.address, daoToken.address, 300);
    await dao.setMaxSize(3);
    
    expect(await dao.getSigner(0, 0)).to.equal(signerAddrs[0]);

  });
  
  it("delegator unstake in a corner case", async () => {
    const alice = accounts[5];
    await daoToken.mint(alice.address, 1000);
    await daoToken.connect(alice).approve(dao.address, 1000);
    await dao.connect(alice).stake(alice.address, zeroAddr, zeroAddr, 1000);

    const bob = accounts[6];
    await daoToken.mint(bob.address, 2000);
    await daoToken.connect(bob).approve(dao.address, 2000);
    await dao.connect(bob).stake(bob.address, alice.address, zeroAddr, 2000);

    const carol = accounts[7];
    await daoToken.mint(carol.address, 3000);
    await daoToken.connect(carol).approve(dao.address, 3000);
    await dao.connect(carol).stake(carol.address, bob.address, zeroAddr, 3000);

    const dave = accounts[8];
    await daoToken.mint(dave.address, 4000);
    await daoToken.connect(dave).approve(dao.address, 4000);
    await dao.connect(dave).stake(dave.address, carol.address, zeroAddr, 4000);

    // buy voucher
    const edward = accounts[9];
    await daoToken.mint(edward.address, 3000);
    const ValidatorDelegation = await ethers.getContractFactory("ValidatorDelegation");
    const bobDelegationAddress = await dao.getValidatorDelegationAddress(bob.address);
    const bobValidatorDelegation = await ValidatorDelegation.attach(bobDelegationAddress);
    await daoToken.connect(edward).approve(dao.address, 3000);
    await bobValidatorDelegation.connect(edward).buyVoucher(500, 0, carol.address, alice.address);
    const aliceDelegationAddress = await dao.getValidatorDelegationAddress(alice.address);
    const aliceValidatorDelegation = await ValidatorDelegation.attach(aliceDelegationAddress);
    await aliceValidatorDelegation.connect(edward).buyVoucher(500, 0, carol.address, zeroAddr);

    await dao.startNewEpochTest([2, 0, 1]);

    let hashStr = get_validators_hash([bob.address, dave.address, carol.address], 1);
    // https://github.com/ethers-io/ethers.js/issues/468
    let messageHashBinary = ethers.utils.arrayify(hashStr);
    let signedMsg = await accounts[0].signMessage(messageHashBinary);
    let splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.signForValidators(splitSig.v, splitSig.r, splitSig.s, "0");

    signedMsg = await accounts[1].signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.signForValidators(splitSig.v, splitSig.r, splitSig.s, "1");

    signedMsg = await accounts[2].signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.signForValidators(splitSig.v, splitSig.r, splitSig.s, "2");

    signedMsg = await accounts[3].signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.signForValidators(splitSig.v, splitSig.r, splitSig.s, "3");

    await dao.startNewEpochTest([2, 0, 1]);

    expect(await dao.getSignerCount(2)).to.equal(3);

    let firstSigner = [bob, carol, dave].reduce(function (p, v) {
      return ( p.address > v.address ? p : v );
    });
  
    expect(await dao.getSigner(2, 0)).to.equal(firstSigner.address);
    
    await aliceValidatorDelegation.connect(edward).buyVoucher(2000, 0, dave.address, carol.address);
    await dao.startNewEpochTest([1, 0, 2]);

    hashStr = get_validators_hash([alice.address, dave.address, carol.address], 3);
    // https://github.com/ethers-io/ethers.js/issues/468
    messageHashBinary = ethers.utils.arrayify(hashStr);
    signedMsg = await dave.signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.connect(dave).signForValidators(splitSig.v, splitSig.r, splitSig.s, "1");

    signedMsg = await carol.signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.connect(carol).signForValidators(splitSig.v, splitSig.r, splitSig.s, "2");
    
    signedMsg = await bob.signMessage(messageHashBinary);
    splitSig = ethers.utils.splitSignature(signedMsg);
    await dao.connect(bob).signForValidators(splitSig.v, splitSig.r, splitSig.s, "0");
    
    await dao.startNewEpochTest([1, 0, 2]);

    await expect(
      dao.connect(bob).unstake(carol.address, zeroAddr)
    ).to.be.revertedWith("");
    
    // sellVouncher
    await bobValidatorDelegation.connect(edward).sellVoucher(500, 1000, dave.address, carol.address);
    expect(await daoToken.balanceOf(edward.address)).to.equal(0);
    
    await expect(
      bobValidatorDelegation.connect(edward).unstakeClaimTokens()
    ).to.be.revertedWith("unbond not expired");

    await dao.startNewEpochTest([1, 0, 2]);

    await ethers.provider.send('evm_increaseTime', [300]);
    await ethers.provider.send('evm_mine');
    // unstake
    bobValidatorDelegation.connect(edward).unstakeClaimTokens();
    expect(await daoToken.balanceOf(edward.address)).to.equal(500);
  });
});
