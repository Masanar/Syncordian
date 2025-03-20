# Syncordian: Managing Adversarial Behavior and Interleaving Anomalies in CRDTs

We thank the reviewers for their insightful feedback. Below, we address three key areas of
concern: update operations, interleaving prevention, and vector clock design—along
with specific clarifications.

## Update

We clarify that Syncordian’s core operations Insert and Delete are coordination free and
follows to CRDT principles, ensuring eventual consistency without synchronization. The
Update operation is an optional optimization introduced with the objective of reduce
memory overhead from tombstones, explicitly decoupled from normal operation, it basically
works as an garbage collection mechanisms. It is designed for use only under stable
network conditions (e.g., no partitions) in particular under network quiescence, and
tombstone retention does not affect correctness or convergence it merely increases memory
usage linearly with deletion count, this is comparable to conventional tombstone based CRDTs.

Regarding convergence, dropped or aborted updates do not compromise Syncordian’s
guarantees. Tombstones are metadata, their presence impacts only memory, not operational
semantics. Convergence remains assured even if updates are not apply, as the core
operations remain unaffected. For leader failure after notification, while our current
focus is not on failure recovery, our RAFT inspired design naturally supports leader
re-election and retries (via timeouts), which we will explicitly mention as future work.

We acknowledge the oversight in message authentication. All update messages
will require authentication to prevent disruption by untrusted nodes.
For unresponsive peers, the leader employs timeout/retry mechanisms. After repeated
failures, the update aborts gracefully, leaving tombstones intact—again, affecting only
memory, not consistency.

To improve clarity, we will:

- Distinguish core CRDT operations (Insert/Delete) from the optional Update optimization.

- Emphasize that Update requires optimal network conditions and is not part of Syncordian’s CRDT guarantees.

- Add authentication details for update-related messages.

- Expand on failure-handling limitations as future work.

## Interlivings

We acknowledge the reviewer's concern regarding the linear nature of Git commit history.
While the original data source is linear, our experimental design intentionally introduces
non linear execution through randomized message delays. The supervisor agent do not
enforce message ordering each peer processes messages asynchronously, creating
interleaving scenarios. For instance, commit n+1 (from Alice) can arrive and process
before commit n messages (from Bob) at several peers, forcing Syncordian to handle
potential interleaving through the presented conflict resolution mechanisms. We acknowledge
that we must clarify in the paper that our setup allows extreme concurrency scenarios
through near-simultaneous message flooding. Additionally aiming to make this clear, we
prose to quantified and display in the evaluation section the number of times that Syncordian
found and solve such anomalies.

Regarding existing text CRDTs, our work specifically advances the state of the art in
adversarial environments. While state of the art work like Fuge/FugeMax [1] achieves interleaving
freedom, it do not address Byzantine fault tolerance one of the key Syncordian
contribution. Our Elixir implementation and evaluation against real-world collaborative
patterns (via the Oh My Zsh README) provide practical validation missing from purely
theoretical proposals. The experimental results demonstrate both interleaving prevention
(through 703 conflict-free edits) while managing adversarial behaviors
(maintaining consistency despite 12 adversarial nodes), which existing CRDTs do not
achieve simultaneously.

[1]Weidner, Matthew, and Martin Kleppmann.
"The Art of the Fugue: Minimizing Interleaving in Collaborative Text Editing."
arXiv preprint arXiv:2305.00583 (2023).

## Particular Clarifications

- Why is it safe to broadcast signatures in delete operations without hashing them,
when secret signatures are critical to preventing unauthorized inserts?

  - Although it is true that a delete message broadcasts the PID, the line signature,
  and the signature*, this information is not valuable to distrusted nodes. The PID
  reveals the line’s location, and even if distrusted nodes collect all these messages,
  they would only obtain a rough idea of the document’s overall structure and size.
  Currently, we do not have an alternative way to share this information. Moreover, the hash of
  the line is not the primary secret of a Syncordian document. Even if a distrusted node
  collects line signatures, it would still have to try numerous combinations of parent
  lines, contents, and peer_ids to obtain a valid signature*. And even in that case
  (which would require a huge computational power) all the signatures depend on a common
  main secret known only to trusted peers.

- How is the threshold for requeuing before dropping a message determined?

  - This parameter is defined based on the network quality. The higher the likelihood of
  network delays, the higher the threshold should be. The same applies when there is a
  higher likelihood of encountering untrusted nodes. In essence, it is a practical
  parameter determined by the application's requirements.

- The authors do not justify why standard authentication techniques
(e.g., HMAC, KMAC, authenticated encryption) are insufficient for disturbance-freedom.

  - Specifically, we do not assert that conventional authentication methods are inadequate.
  Rather, in order to build an adversarially resilient and interleaving-free CRDT, we are
  investigating the possibility of utilizing only a hash function. Furthermore, we make
  clear that a hash function is an effective tool for handling cryptographic secrets and
  signatures. State of the art hash functions are far more effective than a designing a
  CRDT that uses public/private key cryptography, HMAC, or KMAC. Furthermore, it should
  be noted that we are not aiming (yet) for a fully Byzantine fault tolerant CRDT, which
  would be a much more demanding goal, furthermore, if one were to rely only on hash functions.
  However, achieving that goal is the broader objective of our project, which is why we
  mention it briefly, even though the current state of Syncordian does not support that claim.

- Signature recalculation scales poorly—if each character has a signature, the entire
document requires recomputation upon updates.

  - In Syncordian, the granularity of line signatures is chosen during implementation. For
  instance, in the presented evaluation, each line of the document corresponds to a line
  in the Git README log history. Thus, in general, Syncordian does not compute a signature
  for each character. Instead, it calculates one signature per line. This applies to all
  operations, particularly the primary operations of Insert and Delete.

- Does your algorithm expect all the trusted nodes to be known at the start and not to
change? What if a trusted node should become disconnected?

  - Syncordian works under the assumption that 'All local edits made by a node are ensured
  to be propagated, eventually, to all peers'. Thus in this scenario, even if a node
  become disconnected the message will be eventually receive by the node and due to
  Syncordian definition the message will be updated in the local document. In the other
  scenario, yes in this current version all trusted node must be known at the start if
  a new one come into the network, a new document must be started and a older trusted node
  should copy the old document information into the new one. This is not the best strategy
  and must be part of the future work.

- ... Vector clocks, which is a well-know concept in distributed systems, in the paper it
has a very different (and wrong) interpretation.

  - We use a vector clock like structure, drawing inspiration from traditional vector
  clocks to establish a partial order of events in a distributed system. However, we
  redefine the ≺ operation, modifying the conventional definition and introducing a new
  norm for this structure. In conclusion, our structure is not a pure vector clock.
  Rather, it is a variant inspired by vector clocks that is more appropriately
  described as a vector clock like structure.

## Grammatical issues

We acknowledge grammatical inconsistencies and will rigorously proofread the final
manuscript.
