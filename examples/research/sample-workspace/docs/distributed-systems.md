# A Short Note on Distributed Systems

A distributed system is a collection of independent computers that appears to
its users as a single coherent system. The appeal is scalability and fault
tolerance: no single machine is a bottleneck, and the failure of one node need
not bring down the whole service.

The difficulty is that the network is unreliable. Messages can be delayed,
reordered, duplicated, or lost, and nodes can crash at any time. The CAP theorem
captures a fundamental tension: under a network partition, a system must choose
between remaining consistent and remaining available. Consensus protocols such
as Paxos and Raft let a set of nodes agree on a single value despite failures,
and they underpin replicated logs, leader election, and configuration stores.

Good distributed design leans on idempotency, retries with backoff, and careful
attention to what happens when a component is slow rather than simply down.
