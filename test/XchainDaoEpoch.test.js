const { expect } = require("chai");
const { ethers } = require("hardhat");
const { encode } = require("rlp");

function toHex(buf) {
  buf = buf.toString('hex');
  if (buf.substring(0, 2) == "0x")
    return buf;
  return "0x" + buf.toString("hex");
};

function get_validators_hash(users, epoch) {
    let hash = ethers.utils.hexZeroPad(epoch, 32);
    for (let i = 0; i < users.length; i++) {
        hash = ethers.utils.solidityKeccak256(["bytes32", "address"], [hash, users[i]]);
    }
    return hash;
}


describe("XChainDaoEpoch", () => {
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

    await dao.initialize(signerAddrs, factory.address, daoToken.address, 0);
    await dao.setMaxSize(3);

    expect(await dao.getSigner(0, 0)).to.equal(signerAddrs[0]);

  });

  it("stake in the first epoch", async () => {
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

    let validators = await dao.getAll();
    expect(validators[0]).to.equal(dave.address);
    expect(validators[3]).to.equal(alice.address);

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

    let signers = await dao.getNextSigners(2);
    expect(signers[0]).to.equal(bob.address);
    expect(signers[1]).to.equal(dave.address);
    expect(signers[2]).to.equal(carol.address);

    // unstake
    expect(await daoToken.balanceOf(alice.address)).to.equal(0);
    await dao.connect(alice).unstake(carol.address, zeroAddr);
    expect(await daoToken.balanceOf(alice.address)).to.equal(1000);

    expect(await daoToken.balanceOf(bob.address)).to.equal(0);
    expect(await dao.getSignerCount(2)).to.equal(3);
    await dao.connect(bob).unstake(carol.address, zeroAddr);
    expect(await dao.getSignerCount(2)).to.equal(3);
    expect(await daoToken.balanceOf(bob.address)).to.equal(0);
    await expect(
      dao.connect(bob).claimUnstake()
    ).to.be.revertedWith("unbond not expired");
    expect(await dao.size()).to.equal(2);
    validators = await dao.getAll();
    expect(validators[0]).to.equal(dave.address);
    expect(validators[1]).to.equal(carol.address);

    await dao.startNewEpochTest([0, 1]);

    hashStr = get_validators_hash([dave.address, carol.address], 3);
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

    expect(await dao.getSignerCount(3)).to.equal(3);
    signers = await dao.getCurrentSigners(3);
    expect(signers[0]).to.equal(bob.address);
    expect(signers[1]).to.equal(dave.address);
    expect(signers[2]).to.equal(carol.address);
    await dao.startNewEpochTest([0, 1]);
    expect(await dao.getSignerCount(4)).to.equal(2);

    await dao.connect(bob).claimUnstake();
    expect(await daoToken.balanceOf(bob.address)).to.equal(2000);
  });

  it("delegator stake & unstake", async () => {
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
    await bobValidatorDelegation.connect(edward).buyVoucher(1500, 0, dave.address, carol.address);
    const aliceDelegationAddress = await dao.getValidatorDelegationAddress(alice.address);
    const aliceValidatorDelegation = await ValidatorDelegation.attach(aliceDelegationAddress);
    await aliceValidatorDelegation.connect(edward).buyVoucher(1500, 0, carol.address, zeroAddr);

    let delegators = await aliceValidatorDelegation.getDelegators();
    expect(delegators[0]).to.equal(edward.address);

    await dao.startNewEpochTest([1, 0, 2]);

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

    await dao.startNewEpochTest([1, 0, 2]);

    expect(await dao.getSignerCount(2)).to.equal(3);

    let firstSigner = [bob, carol, dave].reduce(function (p, v) {
      return ( p.address > v.address ? p : v );
    });
  
    expect(await dao.getSigner(2, 0)).to.equal(firstSigner.address);
    
    await dao.connect(alice).unstake(carol.address, zeroAddr);
    await dao.connect(bob).unstake(carol.address, zeroAddr);

    // sellVouncher
    expect(await daoToken.balanceOf(edward.address)).to.equal(0);
    await aliceValidatorDelegation.connect(edward).sellVoucher(1500, 3000, carol.address, zeroAddr); // alice is not a signer
    expect(await daoToken.balanceOf(edward.address)).to.equal(1500);
    delegators = await aliceValidatorDelegation.getDelegators();
    expect(delegators[0]).to.equal(zeroAddr);

    // buyVoucher after the validator unstake
    await daoToken.connect(edward).approve(dao.address, 1500);
    await bobValidatorDelegation.connect(edward).buyVoucher(1500, 0, dave.address, carol.address);
    await bobValidatorDelegation.connect(edward).sellVoucher(3000, 6000, dave.address, carol.address);
    delegators = await bobValidatorDelegation.getDelegators();
    expect(delegators[0]).to.equal(edward.address);

    await dao.startNewEpochTest([0, 1]);
    
    // unstake
    bobValidatorDelegation.connect(edward).unstakeClaimTokens();
    expect(await daoToken.balanceOf(edward.address)).to.equal(3000);
    delegators = await bobValidatorDelegation.getDelegators();
    expect(delegators[0]).to.equal(zeroAddr);
    
    hashStr = get_validators_hash([dave.address, carol.address], 3);
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
 
    await dao.startNewEpochTest([0, 1]);
    expect(await dao.getSignerCount(4)).to.equal(2);
  });

});
