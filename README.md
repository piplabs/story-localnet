## **Docker Compose Configuration Overview**

This setup defines services for a **local blockchain network** using multiple
`docker-compose.yml` files. Nodes include bootnodes (`bootnode1`) and validators
(`validator1`, `validator2`, `validator3`, `validator4`). Each node is managed
via its own Docker Compose file for modularity.

---

### **General Structure**

#### **Docker Compose Files**

- **Bootnodes**:
  - `docker-compose-bootnode1.yml`: Manage nodes responsible for P2P discovery
    and network initialization.
- **Validators**:
  - `docker-compose-validator1.yml` through `docker-compose-validator4.yml`:
    Manage nodes responsible for block proposal and consensus.

#### **Features**

1. **Images**:

   - `story-geth:local`: Ethereum client image built from the `../story-geth`
     repository.
   - `story-node:local`: Consensus layer image built from the `../story`
     repository.

2. **Volumes**:

   - Dedicated volumes for storing blockchain data (`db-<role>-geth-data`) and
     consensus data (`db-<role>-node-data`).

3. **Networks**:
   - All nodes are connected to a custom Docker network (`story-localnet`) with
     a predefined subnet (`10.0.0.0/16`) and static IP addresses for
     deterministic communication.

### **Start and Terminate Scripts**

---

#### **Start**

Use the `start.sh` script to bring up all nodes and monitoring system:

```bash
./start.sh
```

#### **Terminate**

Use the `terminate.sh` script to stop and remove all nodes and their volumes:

```bash
./terminate.sh
```

---

## **Monitoring Integration**

This setup includes a monitoring stack to provide centralized metrics and logs
visualization for the blockchain network. Tools include **Prometheus**,
**Loki**, **Promtail**, and **Grafana**, all integrated through Docker Compose.

---

### **Components and Access Information**

| **Service**    | **Role**                                                           | **Default Port**               | **Access URL**          |
| -------------- | ------------------------------------------------------------------ | ------------------------------ | ----------------------- |
| **Prometheus** | Collects metrics from nodes and itself for performance monitoring. | `9090`                         | `http://localhost:9090` |
| **Loki**       | Aggregates and stores logs from the network nodes via Promtail.    | `3100`                         | `http://localhost:3100` |
| **Promtail**   | Scrapes logs from Docker containers and sends them to Loki.        | `9080` (API), `9095` (Metrics) | `http://localhost:9080` |
| **Grafana**    | Provides a dashboard interface for metrics and logs visualization. | `3000`                         | `http://localhost:3000` |

---

### **How to Start and Stop Monitoring Services**

#### **Start Monitoring Services**

Run the following command to bring up the monitoring stack:

```bash
docker-compose -f docker-compose-monitoring.yml up -d
```

#### **Stop Monitoring Services**

To stop and remove the monitoring stack:

```bash
docker-compose -f docker-compose-monitoring.yml down
```

---

### **Service Details**

#### **Prometheus**

- **Purpose**: Monitors blockchain nodes for performance metrics (e.g., block
  times, CPU usage).
- **Access**: Navigate to [http://localhost:9090](http://localhost:9090).
- **Usage**:
  - Query metrics using PromQL.
  - Monitor raw metrics or set up alerts.

#### **Loki**

- **Purpose**: Centralizes log storage for the blockchain network.
- **Access**: Logs are primarily visualized through Grafana.
- **Usage**:
  - Query logs via Grafana or the Loki API.
  - Correlate logs with metrics for debugging.

#### **Promtail**

- **Purpose**: Collects logs from Docker containers and ships them to Loki.
- **Ports**:
  - `9080`: HTTP API for internal communication.
  - `9095`: Metrics endpoint for Prometheus scraping.
- **Access**: Works in the background with no direct user interaction.

#### **Grafana**

- **Purpose**: Unified interface for visualizing metrics and logs.
- **Access**: Navigate to [http://localhost:3000](http://localhost:3000).
- **Default Credentials**:
  - Username: `admin`
  - Password: `password`
- **Usage**:
  - Pre-configured dashboards for node performance and logs.
  - Integrates seamlessly with Prometheus and Loki.

---

### **Predefined Ports and Their Roles**

| **Port**  | **Service** | **Role**                                                |
| --------- | ----------- | ------------------------------------------------------- |
| **3000**  | Grafana     | Dashboard interface for metrics and logs visualization. |
| **9090**  | Prometheus  | Metrics scraping and querying with PromQL.              |
| **3100**  | Loki        | Log aggregation and access storage API.                 |
| **9080**  | Promtail    | HTTP API for internal communication with Promtail.      |
| **9095**  | Promtail    | Metrics endpoint for Prometheus scraping.               |
| **8545**  | story-geth  | HTTP-RPC endpoint for blockchain node interaction.      |
| **8546**  | story-geth  | WebSocket-RPC endpoint for real-time events.            |
| **8551**  | story-geth  | Authenticated RPC endpoint for secure communication.    |
| **6060**  | story-geth  | Metrics endpoint for monitoring Geth performance.       |
| **30303** | story-geth  | UDP port for P2P discovery.                             |
| **30303** | story-geth  | TCP port for P2P discovery.                             |
| **1317**  | story-node  | HTTP API for interacting with the Story blockchain.     |
| **26656** | story-node  | P2P networking for the Story consensus layer.           |
| **26657** | story-node  | HTTP-RPC endpoint for Story blockchain communication.   |
| **26660** | story-node  | Metrics endpoint for Story performance monitoring.      |

---
