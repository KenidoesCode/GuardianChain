import { ethers } from "hardhat";
import fs from "fs";

async function main() {
  console.log("🚀 Deploying GuardianChain contract...");

  const GuardianChain = await ethers.getContractFactory("GuardianChain");
  const guardianChain = await GuardianChain.deploy();

  await guardianChain.waitForDeployment();

  const address = await guardianChain.getAddress();
  console.log(`✅ GuardianChain deployed at: ${address}`);

  // Save deployment info locally
  const data = {
    contract: "GuardianChain",
    address,
    network: "hardhatMainnet",
    timestamp: new Date().toISOString(),
  };

  fs.writeFileSync("deployments.json", JSON.stringify(data, null, 2));

  console.log("💾 Deployment info saved in deployments.json");
}

main().catch((error) => {
  console.error("❌ Deployment failed:", error);
  process.exitCode = 1;
});
