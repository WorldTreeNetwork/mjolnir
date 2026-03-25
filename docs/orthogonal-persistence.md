# Orthogonal Persistence Pattern

## Abstract

This document explores the orthogonal persistence pattern as implemented in the `TestDeploymentManager` singleton class, which demonstrates how computational state can be transparently persisted across process boundaries while maintaining the illusion of continuous existence. This pattern has deep implications for distributed computation and process calculus implementations.

## Introduction to Orthogonal Persistence

Orthogonal persistence is a programming paradigm where the persistence of data is orthogonal (independent) to its type, structure, or usage in the program. In traditional systems, developers must explicitly manage when and how data is saved to storage. With orthogonal persistence, objects naturally persist across process lifetimes without explicit serialization code.

The key principle is that persistence should be:
- **Transparent**: Objects persist without explicit save/load operations
- **Complete**: The entire computational state is preserved
- **Orthogonal**: Independent of the object's type or structure
- **Seamless**: The program operates as if objects never ceased to exist

## Implementation Analysis: TestDeploymentManager

The `TestDeploymentManager` class demonstrates a practical implementation of orthogonal persistence through several key mechanisms:

### 1. Singleton Pattern with State Preservation

```typescript
export class TestDeploymentManager {
  private static instance: TestDeploymentManager | null = null;
  private deploymentCache: DevNetDeploymentCache;
  
  static getInstance(config?: TestDeploymentConfig): TestDeploymentManager {
    if (!TestDeploymentManager.instance) {
      // Instance reconstitution point
      TestDeploymentManager.instance = new TestDeploymentManager(config);
    }
    return TestDeploymentManager.instance;
  }
}
```

The singleton pattern ensures a single source of truth for the deployment state. When the instance is recreated after process termination, it automatically reconnects to the persisted state through the cache layer.

### 2. Transparent Cache Layer

The `DevNetDeploymentCache` provides the persistence mechanism:

```typescript
private async loadCache(): Promise<Record<string, DeploymentInfo>> {
  await this.acquireLock();
  try {
    if (!fs.existsSync(this.cacheFile)) {
      return {};
    }
    const data = fs.readFileSync(this.cacheFile, 'utf-8');
    return JSON.parse(data);
  } finally {
    this.releaseLock();
  }
}
```

This cache layer operates transparently - the `TestDeploymentManager` doesn't need to know how persistence is implemented, only that state is preserved.

### 3. Identity Preservation Through Deployment IDs

Each deployment has a unique identity that persists across process boundaries:

```typescript
private generateDeploymentId(config: any): string {
  const symbol = config.tokenParams?.symbol || 'UNK';
  const threshold = config.migrationQuoteThreshold || 0;
  const hash = this.simpleHash(`${symbol}-${threshold}`);
  return `${symbol}-${hash}`.substring(0, 20);
}
```

This identity system allows the manager to recognize and reuse previous deployments, maintaining referential integrity across process restarts.

### 4. State Validation and Reconciliation

The system validates persisted state against the actual blockchain:

```typescript
private async validateCachedDeployment(
  deployment: DeploymentInfo
): Promise<CacheValidationResult> {
  // Check if token mint still exists
  const tokenMintInfo = await this.connection.getAccountInfo(
    new PublicKey(deployment.tokenMint)
  );
  if (!tokenMintInfo) {
    return { isValid: false, reason: 'Token mint account not found' };
  }
  // Additional validation...
}
```

This ensures the persisted state remains consistent with external reality - a critical aspect when dealing with distributed systems.

## Relationship to Process Calculus and Pi-Calculus

### Process Mobility and State Migration

In π-calculus, processes can migrate between locations while maintaining their computational state. The `TestDeploymentManager` exhibits similar properties:

1. **Process State**: The deployment configuration and contract addresses
2. **Channel Names**: The deployment IDs serve as persistent channel names
3. **Process Migration**: State moves from memory to disk and back transparently

### Formal Representation

We can represent this pattern in π-calculus notation:

```
P ::= deploy⟨config⟩.P'
    | cache⟨id, state⟩.P'
    | restore⟨id⟩(state).P'
    
Where:
- deploy represents the deployment process
- cache represents persistence operation
- restore represents state reconstitution
```

The orthogonal persistence ensures that `P'` continues execution with the same state regardless of process termination between operations.

### Distributed Computation Implications

The pattern enables several distributed computation capabilities:

1. **Location Transparency**: Computations can resume on different nodes
2. **Failure Recovery**: Process state survives node failures
3. **Load Distribution**: Stateful processes can be migrated for load balancing
4. **Checkpoint/Restart**: Natural checkpoint mechanism for long-running computations

## Key Design Patterns Observed

### 1. Memento Pattern with Automatic Restoration

The cache acts as a memento, storing deployment snapshots that can be restored automatically:

```typescript
async deployTestToken(tokenConfig: any, options: {}) {
  // Automatic restoration attempt
  if (this.config.cacheEnabled && !options.forceRedeploy) {
    const cached = await this.deploymentCache.getCachedDeployment(deploymentId);
    if (cached && (await this.validateCachedDeployment(cached)).isValid) {
      return this.reconstitute(cached); // Transparent restoration
    }
  }
  // Continue with new deployment if needed...
}
```

### 2. Write-Through Cache with Validation

The system implements a write-through cache with blockchain validation:

```typescript
// Write-through on deployment
await this.deploymentCache.cacheDeployment(deploymentId, deploymentInfo);

// Read-through with validation
const cached = await this.deploymentCache.getCachedDeployment(deploymentId);
const validation = await this.validateCachedDeployment(cached);
```

### 3. Optimistic Locking with File-Based Coordination

The cache uses file-based locks for multi-process coordination:

```typescript
private async acquireLock(timeoutMs: number = 5000): Promise<void> {
  while (fs.existsSync(this.lockFile)) {
    if (Date.now() - startTime > timeoutMs) {
      fs.unlinkSync(this.lockFile); // Force release stale lock
      break;
    }
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  fs.writeFileSync(this.lockFile, process.pid.toString());
}
```

## Practical Benefits

### 1. Cost Optimization
By persisting deployment state, the system avoids redundant blockchain transactions, reducing costs from ~0.5 SOL per test to <0.1 SOL through deployment reuse.

### 2. Test Isolation with Shared State
Different test suites can share deployed contracts while maintaining isolation through the deployment ID system.

### 3. Fault Tolerance
Test failures don't lose deployment state, allowing tests to resume without redeployment.

### 4. Performance Optimization
Cache hits eliminate deployment latency (30-60 seconds → instant).

## Theoretical Implications for Distributed Systems

### 1. CAP Theorem Considerations

The implementation makes specific trade-offs:
- **Consistency**: Eventual consistency through validation
- **Availability**: High availability through local cache
- **Partition Tolerance**: Survives network partitions via local state

### 2. Byzantine Fault Tolerance

The blockchain validation provides Byzantine fault tolerance - the cache cannot persist invalid state that conflicts with the blockchain consensus.

### 3. Idempotency Through Identity

The deployment ID system ensures idempotent operations - repeated deployments with the same configuration reuse existing state.

## Extension to General Distributed Computation

This pattern can be generalized for distributed computation frameworks:

```typescript
interface OrthogonallyPersistent<T> {
  // Identity generation
  generateId(input: any): string;
  
  // State persistence
  persist(id: string, state: T): Promise<void>;
  
  // State restoration
  restore(id: string): Promise<T | null>;
  
  // State validation
  validate(state: T): Promise<boolean>;
  
  // Computation execution
  execute(state: T): Promise<T>;
}
```

This interface enables:
1. **Stateful Microservices**: Services that maintain state across restarts
2. **Workflow Engines**: Long-running workflows with automatic state preservation
3. **Distributed Actors**: Actor systems with persistent actor state
4. **Blockchain Oracles**: Persistent external data feeds

## Relationship to Mobile Processes

In the context of mobile process calculi, this pattern enables:

1. **Process Serialization**: Automatic serialization of process state
2. **Location Independence**: Processes can resume at any location with cache access
3. **Strong Mobility**: Both code and state can migrate (though this implementation focuses on state)

## Conclusion

The `TestDeploymentManager` demonstrates a practical implementation of orthogonal persistence that bridges the gap between traditional imperative programming and distributed process calculus. By making persistence transparent and automatic, it enables patterns typically associated with academic distributed systems in production code.

Key takeaways:
1. **Orthogonal persistence simplifies distributed state management**
2. **Identity-based caching provides natural checkpoint/restart semantics**
3. **Validation against external truth sources maintains consistency**
4. **The pattern naturally extends to general distributed computation**

This implementation serves as a concrete example of how theoretical computer science concepts like orthogonal persistence and process calculus can be applied to solve practical engineering challenges in blockchain and distributed systems development.

## Future: Full VM State Snapshots

Mjolnir currently implements **filesystem-only persistence** via BTRFS reflink copies. This captures workspace state (files, installed packages) but not running process state (memory, CPU registers).

For true orthogonal persistence—where a VM can be paused mid-execution and resumed exactly where it left off—a hypervisor must provide native **memory + CPU + device state snapshots**. The notes below were written when Firecracker was the active hypervisor (now deprecated in favor of Cloud Hypervisor). Cloud Hypervisor supports pause/resume via its REST API (`vm.pause`, `vm.resume`) but does not currently expose full memory snapshot/restore in the same way. This section is preserved as a reference for when full-state checkpointing is implemented.

```bash
# Pause VM and create full state snapshot
curl --unix-socket $API_SOCK -X PATCH /vm -d '{"state": "Paused"}'
curl --unix-socket $API_SOCK -X PUT /snapshot/create -d '{
  "snapshot_path": "/path/to/snapshot",
  "mem_file_path": "/path/to/memory",
  "snapshot_type": "Full"
}'

# Restore on same or different host
curl --unix-socket $API_SOCK -X PUT /snapshot/load -d '{
  "snapshot_path": "/path/to/snapshot",
  "mem_backend": {"backend_path": "/path/to/memory", "backend_type": "File"},
  "enable_diff_snapshots": false
}'
```

### Capabilities This Enables

| Capability | Description |
|------------|-------------|
| **Instant resume** | Sub-8ms restore time (lazy page loading) |
| **Live migration** | Transfer running VM between hosts without restart |
| **VM forking** | Clone a running VM, both continue independently |
| **Time travel debugging** | Checkpoint before risky operations, restore on failure |

### Key Limitations

Hypervisor snapshots (Firecracker, Cloud Hypervisor) have significant constraints:

- **CPU compatibility**: Snapshots not portable across CPU models (Intel ↔ AMD)
- **Kernel compatibility**: Cross-kernel-version restore is "considered unstable"
- **Network state**: TCP connections and vsock state may not survive
- **Disk not included**: Hypervisor snapshots capture memory/CPU only—disk must be managed separately (hence BTRFS)

### When We'll Need This

Full-state snapshots become valuable for:
1. **Live migration** across hosts without service interruption
2. **Agent forking** where multiple agents diverge from same point
3. **Speculative execution** with rollback on failure
4. **Long-running computation** checkpointing

For now, filesystem snapshots + fresh VM boots are sufficient. The path to full orthogonal persistence is documented here for when the need arises.

## References for Further Reading

- Atkinson, M.P. & Morrison, R. (1985). "Procedures as Persistent Data Objects"
- Milner, R. (1999). "Communicating and Mobile Systems: The π-Calculus"
- Cardelli, L. & Gordon, A.D. (1998). "Mobile Ambients"
- Morrison, R. et al. (1999). "Design of an Object-Oriented Database for Orthogonal Persistence"
- [Cloud Hypervisor Documentation](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/)
- [Firecracker Snapshot Documentation (legacy reference)](https://github.com/firecracker-microvm/firecracker/blob/main/docs/snapshotting/snapshot-support.md)

## Application to Pi-Calculus Based Systems

When importing this pattern into a π-calculus based distributed computation repository, consider:

1. **Name Persistence**: Deployment IDs map to persistent channel names
2. **Process State**: Cache entries represent suspended process states  
3. **Replication**: Multiple nodes can share cache for replicated processes
4. **Mobility Primitives**: Cache operations as mobility primitives in the calculus
5. **Formal Verification**: The pattern enables model checking of persistent processes

The orthogonal persistence pattern provides a bridge between theoretical process calculus and practical distributed systems implementation, enabling formally verifiable yet practically deployable systems.