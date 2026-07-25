defmodule Syncordian.CRDT.Logoot.Info do
  @moduledoc """
  Output helpers for a Logoot peer's document.

  Materializes a `Syncordian.CRDT.Logoot.Sequence` into plain text and writes it
  to `debug/documents/logoot/document_<peer_id>` so that, after a run, every
  peer's document can be compared for byte-for-byte convergence with
  `scripts/verify_convergence.exs`.
  """
  alias Syncordian.CRDT.Logoot.Sequence

  @doc """
  Writes `sequence`'s materialized text to `debug/documents/logoot/document_<peer_id>`,
  creating the directory if needed.
  """
  @spec save_tree_content(Sequence.t(), Syncordian.Basic_Types.peer_id()) :: :ok
  def save_tree_content(sequence, peer_id) do
    file_path = Syncordian.Run.path("documents/logoot") <> "/"

    # Ensure the directory exists
    unless File.dir?(file_path) do
      File.mkdir_p!(file_path)
    end

    # Write the file
    File.write!(file_path <> "document_#{peer_id}", sequence_to_string(sequence))
  end

  @doc "Joins a sequence's atom values into a single newline-separated document string."
  @spec sequence_to_string(Sequence.t()) :: String.t()
  def sequence_to_string(sequence) do
    sequence
    |> Sequence.get_values()
    # Join all strings with a newline
    |> Enum.join("\n")
  end
end
