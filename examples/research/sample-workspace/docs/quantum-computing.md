# A Short Note on Quantum Computing

Classical computers store information in bits that are either 0 or 1. A quantum
computer instead uses qubits, which can exist in a superposition of both states
at once. When many qubits are entangled, the machine can represent and operate
on an exponentially large space of possibilities simultaneously.

This does not make quantum computers universally faster. Their advantage shows
up for specific problem structures. Shor's algorithm factors large integers in
polynomial time, threatening RSA-style cryptography. Grover's algorithm gives a
quadratic speedup for unstructured search. Quantum simulation promises accurate
modelling of molecules and materials that are intractable classically.

The central engineering obstacle is decoherence: qubits lose their quantum state
when they interact with the environment. Error-correcting codes spread one
logical qubit across many physical qubits, but the overhead is large, so
building a fault-tolerant machine remains a formidable challenge.
