1. Pin acceptance to canonical B2 HEAD/GET after validated PUT; local completion or multipart completion alone cannot count.
2. Pin incremental Blake3 and the existing blob/b3/base58 layout, with outboard semantics kept distinct.
3. Pin bounded transfer memory on PUT and GET, including multipart buffers at the 1 TiB rail.
4. Refuse cache placement inside the snapshot tree; configured paths and actual resolved locations must agree.
5. Refuse unchecked request identifiers becoming filesystem paths; cache hits must stay within the object directory.
6. Require concurrent promotion and eviction to preserve the cache budget and availability of canonical objects.
7. Require interrupted PUT/GET and multipart failures to clean temporary state without ever implying acceptance.
8. Require failed or partial GET fills to remain invisible as complete cached objects.
9. Preserve repeat-PUT no-op behavior when B2 already holds the key, including uncertainty from failed HEAD requests.
10. Accept disk staging latency and finite free-space limits as the tradeoff for bounded RAM, provided cache failure does not redefine durability.
