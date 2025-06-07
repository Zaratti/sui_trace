# 🌾 SuiTrace – Smart Contract Supply Chain on Sui


**SuiTrace** is a blockchain-based platform designed to bring **transparency**, **traceability**, and **trust** to Nigeria’s agricultural supply chain. Built on the high-performance **Sui blockchain**, SuiTrace enables stakeholders to register, track, and verify product movement from **farm to shelf** — using smart contracts, zkLogin, and digital product passports.

---

## 🚀 Features

- 🔗 **On-chain Product Lifecycle Tracking**  
  Each batch is minted as a Sui object and updated through its journey.

- 📍 **Real-time Product Journey Map**  
  Visualize product movement across handlers and locations.

- 🧠 **Handler Reputation System**  
  Stakeholders gain trust scores based on their performance.

- 📄 **Downloadable Blockchain Certificates**  
  Generate proof-of-origin and handling history for audits and exports.

- 🏷️ **Smart Verification Badges**  
  Products earn labels based on freshness, inspection, and location.

- 🔐 **zkLogin for Easy Onboarding**  
  Farmers and retailers log in with Web2 accounts — no wallet setup required.

- 🚩 **Flagging System for Quality Control**  
  Users can report compromised goods; admins monitor flagged batches.

---

## 🧑‍💼 Use Cases

- **Farmers**: Register products, monitor downstream movement, and build digital trust.
- **Transporters**: Log logistics updates, confirm delivery, and maintain clean handoffs.
- **Retailers**: Verify source, track freshness, and share QR codes with customers.
- **Consumers**: Scan to verify product authenticity and see its entire journey.
- **Admins**: Oversee platform activity, generate reports, and respond to flagged issues.

---

## 🛠 Tech Stack

- **Frontend**: React, Tailwind CSS  
- **Backend**: Node.js, Express (optional), Supabase/IPFS  
- **Blockchain**: Sui Network, Move Language  
- **Authentication**: zkLogin (walletless)  
- **Mapping**: Leaflet.js or Google Maps API  
- **QR Codes**: [`qrcode.react`](https://www.npmjs.com/package/qrcode.react), [`jsQR`](https://www.npmjs.com/package/jsqr)

---

## 🧾 Smart Contract Overview

- **`ProductObject.move`**  
  Mint, transfer, and update product objects.

- **`Tracking.move`**  
  Log product events (e.g., “Shipped”, “Delivered”, “Spoiled”).

- **`AccessControl.move`**  
  Manage role-based permissions: Farmer, Retailer, Admin.

- **Smart Contract is Available here**: [`Smart-Contract`](https://github.com/Zaratti/sui_trace),

---

## 📌 Contribution

We welcome contributions to improve SuiTrace! Feel free to open issues or submit pull requests.

---

## 📜 License

This project is licensed under the [MIT License](LICENSE).

---

## 💬 Contact

For inquiries, partnerships, or contributions: [your-email@example.com]  
Follow us on [Twitter](https://twitter.com/your-handle) | [LinkedIn](https://linkedin.com/in/your-profile)