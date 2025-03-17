defmodule Syncordian.CRDT.Fugue.Test do
  import Syncordian.Utilities, only: [debug_print: 2]
  alias Syncordian.CRDT.Fugue.Tree
  alias Syncordian.CRDT.Fugue.Node
  @moduledoc """
  This module provides test utilities for the Fugue CRDT tree implementation.

  It offers helper functions to abstract and combine the behavior of node
  insertion (`create_and_update/5`) and deletion (`delete_and_update/2`) on the
  Fugue tree. In addition, it provides routines to perform bulk inserts and to
  simulate a sequence of operations coming from different replica peers.

  The included `execute/0` function demonstrates a typical workflow:

    - Initial bulk insertion by one replica.
    - Sequential insertions by another replica (including cases that test
      out-of-order messaging).
    - Deletion operations to mark nodes as removed.

  The module is useful during development and debugging to verify that the CRDT
  behavior (insertion and deletion propagation) works as expected.
  """

  @doc """
  Creates a new node using the CRDT `insert/5` function and then updates the tree with
  the new node via `insert_local/2`. This function abstracts the behavior of performing
  an insert and then updating the tree.

  ## Parameters
  - `tree`: The current tree.
  - `replica_id`: The replica ID to associate with the node.
  - `counter`: The counter value for the new node.
  - `position`: The position at which to insert the node.
  - `value`: The value of the new node.

  ## Returns
  A new tree with the node inserted.
  """
  @spec create_and_update(Tree.t(), String.t(), integer(), integer(), Node.node_value()) :: Tree.t()
  def create_and_update(tree, replica_id, counter, position, value) do
    new_node = Tree.insert(tree, replica_id, counter, position, value)
    Tree.insert_local(tree, new_node)
  end

  @doc """
  Creates a new tree by marking the node at the given position as deleted.

  This function first determines the node ID at the specified position via `delete/2`
  and then updates the tree by marking that node as deleted using `delete_local/2`.

  ## Parameters
  - `tree`: The current tree.
  - `position`: The position of the node to delete (0-based index).

  ## Returns
  A new tree with the specified node marked as deleted.
  """
  @spec delete_and_update(Tree.t(), integer()) :: Tree.t()
  def delete_and_update(tree, position) do
    node_id = Tree.delete(tree, position)
    Tree.delete_local(tree, node_id)
  end

  @doc """
  Performs bulk inserts into the tree by creating `n` new nodes.
  For each iteration `i` (starting at 0), a new node is inserted where:
    - The counter and position are set to `i`.
    - The value is set to `Integer.to_string(i)`.

  ## Parameters
  - `tree`: The current tree.
  - `replica_id`: The replica ID to use for all new nodes.
  - `n`: The number of nodes to insert.

  ## Returns
  A new tree with `n` nodes inserted.
  """
  @spec bulk_insert(Tree.t(), String.t(), integer(), integer()) :: Tree.t()
  def bulk_insert(tree, replica_id, start, finish) do
    Enum.reduce(start..(finish - 1), tree, fn i, acc_tree ->
      create_and_update(acc_tree, replica_id, i, i, Integer.to_string(i))
    end)
  end

  @doc """
  Executes a series of test operations on a Fugue tree to simulate a multi-replica
  workflow.

  The execution flow is as follows:

    1. **Replica "r0" Initialization**:
       A new tree is created via `Tree.new/0` and then initialized with six nodes using
       `bulk_insert/4`. This represents the initial state for replica "r0".

    2. **Replica replica_1_id Insert Operations**:
       - Insertion at position 0 with value `"if"`
       - Insertion at position 1 with value `"is"`
       - Insertion at position 2 with value `"md"`
       - Insertion at position 3 with value `"mr"`
       These operations update the tree using `create_and_update/5` and simulate sequential
       messaging by replica replica_1_id.
       Additionally, an out-of-order messaging case is simulated by inserting another pair of
       nodes (`"3 before 2"` and `"2 after 3"`) to test the system's ability to manage such
       discrepancies.

    3. **Deletion Operations**:
       The function then applies two deletions:
         - First, it deletes the node at position 3.
         - Then, it deletes the node at position 0.
       These deletions use the `delete_and_update/2` function, marking the specified nodes as
       deleted in the tree.

    4. **Debug Output**:
       Finally, the complete tree is printed (traversed using `Tree.full_traverse/1`) to allow
       inspection of the tree’s final state.

  ## Returns
  No value is returned explicitly. Instead, the function outputs debug information to the
  console using `debug_print/2`, allowing the developer to observe the intermediate states of
  the tree during the test execution.
  """
  @spec execute() :: any
  def execute() do
    # Replica 0 messages
    replica_0_id = 0

    empty_tree = Tree.new()

    new_tree = bulk_insert(empty_tree, replica_0_id, 0, 6)
    # debug_print("new tree", Tree.traverse(new_tree))

    # Replica 1 messages
    replica_1_id = 1

    intermediate_first = create_and_update(new_tree, replica_1_id, 0 , 0, "if")
    # debug_print("intermediate tree", Tree.traverse(intermediate_first))

    intermediate_second = create_and_update(intermediate_first, replica_1_id, 1 , 1, "is")
    # debug_print("intermediate tree", Tree.traverse(intermediate_second))

    message_delay = create_and_update(intermediate_second, replica_1_id, 2 , 2, "md")
    # debug_print("intermediate tree", Tree.traverse(message_delay))

    message_reach = create_and_update(message_delay, replica_1_id, 3 , 3, "mr")
    debug_print("intermediate tree", Tree.traverse(message_reach))

    ######### This is the 'question' this message order might not be correct

    error_message_delay = create_and_update(intermediate_second, replica_1_id, 3 , 3, "3 before 2")
    # debug_print("intermediate tree", Tree.traverse(error_message_delay))

    error_message_reach = create_and_update(error_message_delay, replica_1_id, 2 , 2, "2 after 3")
    debug_print("intermediate tree", Tree.traverse(error_message_reach))

    ######################### DELETE TEST ############################

    last_tree = delete_and_update(message_reach, 3)
    last_last_tree = delete_and_update(last_tree, 0)
    debug_print("intermediate tree", Tree.full_traverse(last_last_tree))

  end

end
