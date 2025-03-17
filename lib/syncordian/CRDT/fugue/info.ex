defmodule Syncordian.CRDT.Fugue.Info do
  @moduledoc """
  This module is responsible for handling the output of a Fugue CRDT tree.
  It provides functions to convert the tree to a string (with or without tombstone filtering),
  save the tree content to a file, and print it to the console.
  """

  alias Syncordian.CRDT.Fugue.{Tree, Node}

  @doc """
  Saves the content of the Fugue tree to a file.

  The tree is first converted to a string (with tombstone filtering) and then saved
  under the directory `debug/documents/fugue` with a filename based on the peer id.

  ## Parameters
    - tree: The Fugue tree structure.
    - peer_id: The identifier of the current peer.

  ## Returns
    - :ok if the file is written successfully.
  """
  @spec save_tree_content(Tree.tree(), Syncordian.Basic_Types.peer_id()) :: :ok
  def save_tree_content(tree, peer_id) do
    File.write!("debug/documents/fugue/tree_peer_#{peer_id}", string_tree_content(tree))
  end

  @doc """
  Converts a Fugue tree to a string by traversing the tree and concatenating each node's value,
  filtering out nodes marked as tombstones.

  This function uses the full tree traversal and then removes any node for which `Node.is_tombstone?`
  returns true. Each remaining node's value is appended to the result string followed by a newline.

  ## Parameters
    - tree: The Fugue tree structure.

  ## Returns
    A string representing the tree's content.
  """
  @spec string_tree_content(Tree.tree()) :: String.t()
  def string_tree_content(tree) do
    Tree.traverse(tree)
    |> Enum.reduce("", fn node, acc ->
      # Assumes that the node's value is convertible to a string.
      acc <> to_string(Node.get_value(node)) <> "\n"
    end)
  end

  @doc """
  Converts a Fugue tree to a string (without filtering any node) by traversing the tree and concatenating
  each node's value. Includes a header and footer displaying the peer id.

  ## Parameters
    - tree: The Fugue tree structure.
    - peer_id: The identifier of the current peer.

  ## Returns
    A string representing the tree's unfiltered content.
  """
  @spec string_tree_content(Tree.tree(), Syncordian.Basic_Types.peer_id()) :: String.t()
  def string_tree_content(tree, peer_id) do
    peer_id_string = Integer.to_string(peer_id)
    header = "-----------------Peer id: #{peer_id_string}-----------------\n"
    content =
      Tree.full_traverse(tree)
      |> Enum.reduce("", fn node, acc ->
        acc <> to_string(Node.get_value(node)) <> "\n"
      end)
    footer = "-----------------End of Peer id: #{peer_id_string}-----------------\n"
    header <> content <> footer
  end

  @doc """
  Prints the Fugue tree content to the console.

  This function converts the tree to a string (without filtering) and prints it out.

  ## Parameters
    - tree: The Fugue tree structure.
    - peer_id: The identifier of the peer.

  ## Returns
    - :ok after printing to the console.
  """
  @spec print_tree_content(Tree.tree(), Syncordian.Basic_Types.peer_id()) :: :ok
  def print_tree_content(tree, peer_id) do
    string_tree_content(tree, peer_id)
    |> IO.puts()
  end
end
