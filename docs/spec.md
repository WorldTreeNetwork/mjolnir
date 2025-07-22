# mjolnir: cross-language type synchronization system

## core requirements

### type synchronization
- **cross-language compatibility**: must work across different programming languages seamlessly
- **type safety**: maintain type integrity during serialization/deserialization 
- **schema evolution**: handle type changes over time without breaking compatibility

### transport layer
- **transport agnostic**: support multiple transport protocols:
  - http/https for request-response patterns
  - websockets for real-time bidirectional communication  
  - webrtc for peer-to-peer data channels
  - extensible to other protocols
- **automatic failover**: gracefully handle transport failures by switching protocols

### data format
- **compact serialization**: use cbor (concise binary object representation) for efficient wire format
- **schema-aware**: embed minimal type metadata for deserialization hints
- **compression**: optional compression layer for large payloads

### type discovery
- **minimal ceremony**: type registration shouldn't require complex tooling or code generation
- **runtime introspection**: discover types dynamically at runtime where possible
- **caching**: production deployments should cache discovered types for performance
- **invalidation**: cache invalidation when types change

### network topology  
- **flexible routing**: support various network patterns beyond point-to-point:
  - fan-out: broadcast to multiple consumers
  - round-robin: load balance across multiple handlers
  - request-response emulation: maintain rpc semantics over message passing
  - pub/sub: topic-based message routing
- **service discovery**: nodes should be able to find and connect to each other
- **fault tolerance**: handle node failures gracefully with reconnection logic

### operational requirements
- **simplicity**: easy to integrate into existing codebases
- **robustness**: handle network partitions, node failures, and protocol mismatches
- **observability**: logging and metrics for debugging and monitoring
- **security**: authentication and encryption where needed

## implementation notes
- inspired by zeromq's approach to network patterns
- prioritize developer experience over theoretical purity
- performance should be "good enough" rather than optimal - simplicity wins

## project references & inspiration

### cap'n proto
- **schema definition language**: compact binary format with minimal ceremony
- **type discovery/caching**: schema files required but minimal codegen compared to protobuf
- **schema evolution**: first-class feature for handling type changes over time
- **borrow**: flexible schema evolution methodology, compact serialization approach

### zeromq & patterns  
- **network topologies**: designed for flexible, non-point-to-point patterns
- **supported patterns**: request-reply, fan-out, pub-sub, round-robin, pipelines, custom routing
- **borrow**: network topology patterns and routing methodologies

### pojntfx/panrpc
- **curl cli tool**: provides command-line interface for rpc interactions
- **borrow**: cli utility design for testing and debugging

### bigstepinc/jsonrpc-bidirectional
- **routing plugins**: modular routing system
- **network topology emulation**: can emulate various network patterns at application level
- **borrow**: plugin architecture for routing, topology emulation patterns

## theoretical foundations
- **remote closures**: pi calculus - functions as first class citizens
- **service discovery**: related to rho calculus principles
